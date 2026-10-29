import AppKit
import AVFoundation
import DuhcordCore
import UniformTypeIdentifiers

/// Something that is currently moving: a video or an animating GIF.
protocol Playable: AnyObject {
    func stopPlayback()
}

/// Keeps motion bounded: one video at a time, a few GIFs at a time, and all GIFs stop when Duhcord isn't
/// in front. Nothing plays unless a view asks, and views only ask on a click or hover (or when visible,
/// if the user chose that).
final class PlaybackCoordinator {
    static let shared = PlaybackCoordinator()

    private var video: Playable?
    private var gifs: [Playable] = []
    private static let maxGIFs = 3

    private init() {
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(stopGIFs), name: NSApplication.didResignActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(stopGIFs), name: NSWindow.didMiniaturizeNotification, object: nil)
    }

    func startVideo(_ item: Playable) {
        if let video, video !== item { video.stopPlayback() }
        video = item
    }

    func startGIF(_ item: Playable) {
        gifs.removeAll { $0 === item }
        gifs.append(item)
        while gifs.count > Self.maxGIFs { gifs.removeFirst().stopPlayback() }
    }

    func stopped(_ item: Playable) {
        if video === item { video = nil }
        gifs.removeAll { $0 === item }
    }

    @objc private func stopGIFs() {
        let current = gifs
        gifs = []
        current.forEach { $0.stopPlayback() }
    }

    /// GIFs only move on hover when the user picked that, or asked macOS to reduce motion.
    static var gifsPlayWhenVisible: Bool {
        Settings.animateGIFs == .whenVisible && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
}

/// Streams a video for AVFoundation through Duhcord's own connection (SecureSession.media), so playback keeps
/// the same rules as everything else: Discord hosts only, Apple root certificates only, no redirects, no token.
/// AVFoundation asks for byte ranges; each is fetched and handed back as it arrives, so nothing is buffered
/// beyond what the player requests.
final class StreamingLoader: NSObject, AVAssetResourceLoaderDelegate {
    static let scheme = "duhcord-stream"

    private let sources: [URL]
    private var sourceIndex = 0
    private let queue = DispatchQueue(label: "duhcord.stream")
    private var tasks: [AVAssetResourceLoadingRequest: (URLSessionDataTask, RangeTask)] = [:]

    /// `sources` are tried in order; a later one is used if an earlier one fails (e.g. proxy → CDN).
    init(sources: [URL]) {
        self.sources = sources.filter(MediaRequest.isAllowedVideoURL)
        super.init()
    }

    /// An asset that AVFoundation can play, routed through this loader.
    func makeAsset() -> AVURLAsset? {
        guard let first = sources.first, var components = URLComponents(url: first, resolvingAgainstBaseURL: false) else { return nil }
        components.scheme = Self.scheme
        guard let url = components.url else { return nil }
        let asset = AVURLAsset(url: url)
        asset.resourceLoader.setDelegate(self, queue: queue)
        return asset
    }

    func cancelAll() {
        queue.async {
            self.tasks.values.forEach { $0.0.cancel() }
            self.tasks.removeAll()
        }
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        guard sourceIndex < sources.count else { return false }
        start(loadingRequest)
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        tasks.removeValue(forKey: loadingRequest)?.0.cancel()
    }

    private func start(_ loadingRequest: AVAssetResourceLoadingRequest) {
        var request = URLRequest(url: sources[sourceIndex])
        if let data = loadingRequest.dataRequest {
            let start = data.requestedOffset
            let range = data.requestsAllDataToEndOfResource ? "bytes=\(start)-" : "bytes=\(start)-\(start + Int64(data.requestedLength) - 1)"
            request.setValue(range, forHTTPHeaderField: "Range")
        }
        let handler = RangeTask(loadingRequest: loadingRequest) { [weak self] failed in
            guard let self else { return }
            self.queue.async {
                self.tasks[loadingRequest] = nil
                // The first source didn't work (and nothing was delivered yet): try the next one.
                if failed, self.sourceIndex + 1 < self.sources.count, !loadingRequest.isFinished, !loadingRequest.isCancelled {
                    self.sourceIndex += 1
                    self.start(loadingRequest)
                } else if failed, !loadingRequest.isFinished {
                    loadingRequest.finishLoading(with: URLError(.cannotLoadFromNetwork))
                }
            }
        }
        let task = SecureSession.media.session.dataTask(with: request)
        // A per-task delegate gets the data; certificate checks still go to SecureSession.
        task.delegate = handler
        tasks[loadingRequest] = (task, handler)
        task.resume()
    }
}

/// Feeds one byte range from the network to AVFoundation as it arrives.
private final class RangeTask: NSObject, URLSessionDataDelegate {
    private let loadingRequest: AVAssetResourceLoadingRequest
    private let onDone: (_ failed: Bool) -> Void
    private var delivered = false
    private var reported = false

    init(loadingRequest: AVAssetResourceLoadingRequest, done: @escaping (Bool) -> Void) {
        self.loadingRequest = loadingRequest
        onDone = done
    }

    /// A rejected response also ends in a cancellation callback; report only once.
    private func done(_ failed: Bool) {
        guard !reported else { return }
        reported = true
        onDone(failed)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              startsAtRequestedOffset(http) else {
            completionHandler(.cancel)
            done(true)
            return
        }
        if let info = loadingRequest.contentInformationRequest {
            if let mime = http.mimeType, let type = UTType(mimeType: mime) { info.contentType = type.identifier }
            info.isByteRangeAccessSupported = http.statusCode == 206
            // "bytes 0-1/123456" → 123456; a plain 200 carries the whole length.
            if let range = http.value(forHTTPHeaderField: "Content-Range"), let total = range.split(separator: "/").last.flatMap({ Int64($0) }) {
                info.contentLength = total
            } else if http.expectedContentLength > 0 {
                info.contentLength = http.expectedContentLength
            }
        }
        completionHandler(.allow)
    }

    /// The bytes must start where AVFoundation asked, or they'd be spliced in at the wrong place.
    /// A plain 200 is only usable from offset 0; a 206 must name the requested start.
    private func startsAtRequestedOffset(_ http: HTTPURLResponse) -> Bool {
        let offset = loadingRequest.dataRequest?.requestedOffset ?? 0
        if http.statusCode == 200 { return offset == 0 }
        guard let range = http.value(forHTTPHeaderField: "Content-Range"),
              let spec = range.split(separator: " ").last,
              let start = spec.split(separator: "-").first.flatMap({ Int64($0) }) else { return offset == 0 }
        return start == offset
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        delivered = true
        loadingRequest.dataRequest?.respond(with: data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            if (error as? URLError)?.code == .cancelled, loadingRequest.isCancelled { return }
            if delivered {
                loadingRequest.finishLoading(with: error)
                done(false)
            } else {
                done(true)
            }
        } else {
            loadingRequest.finishLoading()
            done(false)
        }
    }
}

/// Plays a GIF with ImageIO's animated-image player, which decodes one frame at a time instead of holding
/// every frame in memory.
final class GIFAnimator {
    private var stopped = true
    private var timer: Timer?
    private var frames: [CGImage] = []
    private var delays: [Double] = []
    private var frameIndex = 0
    private var frameCallback: ((CGImage) -> Void)?
    private var failedCallback: (() -> Void)?

    /// Downloaded GIFs, so hovering the same one again (or scrolling back) doesn't fetch it again.
    private static let cache: NSCache<NSURL, NSData> = {
        let cache = NSCache<NSURL, NSData>()
        cache.totalCostLimit = 16 * 1024 * 1024
        return cache
    }()
    private static let animatableTypes: Set<String> = ["com.compuserve.gif", "org.webmproject.webp", "public.png"]

    /// Fetches the animation through the media session (or the cache) and calls `frame` on the main thread.
    func start(_ url: URL, maxPixel: Int, frame: @escaping (CGImage) -> Void, failed: @escaping () -> Void) {
        cancel()
        stopped = false
        frameCallback = frame
        failedCallback = failed
        let owner = WeakReference(self)
        let callbacks = Handoff(value: (frame: frame, failed: failed))
        Task {
            let data: Data
            if let cached = Self.cache.object(forKey: url as NSURL) {
                data = cached as Data
            } else {
                guard MediaRequest.isAllowedImageURL(url),
                      let result = try? await SecureSession.media.session.data(from: url),
                      (result.1 as? HTTPURLResponse)?.statusCode == 200 else {
                    await MainActor.run { owner.object?.fail() }
                    return
                }
                data = result.0
                Self.cache.setObject(data as NSData, forKey: url as NSURL, cost: data.count)
            }
            let bytes = Handoff(value: data)
            await MainActor.run {
                guard let animator = owner.object, !animator.stopped else { return }
                MediaDecoderClient.shared.decodeFrames(bytes.value, maxPixel: maxPixel,
                                                       allowedTypes: Array(Self.animatableTypes).sorted()) { frames, delays in
                    guard let animator = owner.object, !animator.stopped else { return }
                    guard let frames, !frames.isEmpty, frames.count == delays.count else {
                        animator.fail()
                        return
                    }
                    animator.frames = frames
                    animator.delays = delays
                    animator.frameIndex = 0
                    callbacks.value.frame(frames[0])
                    animator.scheduleNext()
                }
            }
        }
    }

    func cancel() {
        stopped = true
        timer?.invalidate()
        timer = nil
        frames = []
        delays = []
        frameCallback = nil
        failedCallback = nil
    }

    private func scheduleNext() {
        guard !stopped, frames.count > 1, frameIndex < delays.count else { return }
        let timer = Timer(timeInterval: max(0.02, delays[frameIndex]), repeats: false) { [weak self] _ in
            guard let self, !self.stopped, !self.frames.isEmpty else { return }
            self.frameIndex = (self.frameIndex + 1) % self.frames.count
            self.frameCallback?(self.frames[self.frameIndex])
            self.scheduleNext()
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func fail() {
        guard !stopped else { return }
        let failed = failedCallback
        cancel()
        failed?()
    }
}

/// Serves a decrypted private video to AVFoundation straight from memory, so it never touches the disk.
final class MemoryAssetLoader: NSObject, AVAssetResourceLoaderDelegate {
    static let scheme = "duhcord-memory"

    private let data: Data
    private let queue = DispatchQueue(label: "duhcord.memory-video")

    init(data: Data) {
        self.data = data
        super.init()
    }

    func makeAsset() -> AVURLAsset {
        let asset = AVURLAsset(url: URL(string: "\(Self.scheme)://video/private.mp4")!)
        asset.resourceLoader.setDelegate(self, queue: queue)
        return asset
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        if let info = loadingRequest.contentInformationRequest {
            info.contentType = UTType.mpeg4Movie.identifier
            info.contentLength = Int64(data.count)
            info.isByteRangeAccessSupported = true
        }
        if let request = loadingRequest.dataRequest {
            let start = Int(request.requestedOffset)
            let end = request.requestsAllDataToEndOfResource ? data.count : min(data.count, start + request.requestedLength)
            guard start >= 0, start <= end else {
                loadingRequest.finishLoading(with: URLError(.badURL))
                return true
            }
            request.respond(with: data.subdata(in: start..<end))
        }
        loadingRequest.finishLoading()
        return true
    }
}

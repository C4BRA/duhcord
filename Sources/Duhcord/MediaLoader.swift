import AppKit
import DuhcordCore
import ImageIO

/// Fetches and decodes embed and attachment images, as cheaply as possible:
/// - Only from Discord's image proxies, at exactly the pixel size that will be drawn (see MediaRequest).
/// - Decoded straight to that size with ImageIO's thumbnail path; the full image is never built.
/// - Format, byte size and pixel count are checked before decoding.
/// - Kept in a memory cache with a byte budget that macOS can also empty under memory pressure. No disk cache.
/// - Requests nobody waits for any more (rows scrolled away) are cancelled.
final class MediaLoader {
    static let shared = MediaLoader()

    typealias Token = UUID

    private let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.totalCostLimit = 24 * 1024 * 1024
        return cache
    }()
    private var waiters: [URL: [Token: (NSImage?) -> Void]] = [:]
    private var tasks: [URL: Task<Void, Never>] = [:]
    /// Decoding happens off the main thread, two at a time at most.
    private let decodeQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 2
        queue.qualityOfService = .utility
        return queue
    }()

    private static let maxBytes = 8 * 1024 * 1024
    static let maxSourcePixels = 40_000_000
    static let allowedTypes: Set<String> = ["org.webmproject.webp", "public.png", "public.jpeg", "com.compuserve.gif"]

    func cachedImage(for url: URL) -> NSImage? { cache.object(forKey: url.absoluteString as NSString) }

    /// Calls `completion` on the main thread with the image, or nil if it couldn't be loaded.
    /// Returns a token for `cancel`, or nil when the image was already cached (completion has run).
    @discardableResult
    func load(_ url: URL, pointSize: NSSize, completion: @escaping (NSImage?) -> Void) -> Token? {
        if let image = cachedImage(for: url) {
            completion(image)
            return nil
        }
        let token = Token()
        let isFirst = waiters[url] == nil
        waiters[url, default: [:]][token] = completion
        guard isFirst else { return token }

        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let maxPixel = Int((max(pointSize.width, pointSize.height) * scale).rounded(.up))
        let owner = WeakReference(self)
        let queue = Handoff(value: decodeQueue)
        tasks[url] = Task {
            let image = Handoff(value: await Self.fetch(url, maxPixel: maxPixel, pointSize: pointSize, queue: queue.value))
            await MainActor.run { owner.object?.finish(url, image: image.value) }
        }
        return token
    }

    func cancel(_ token: Token, for url: URL) {
        waiters[url]?[token] = nil
        if waiters[url]?.isEmpty == true {
            waiters[url] = nil
            tasks.removeValue(forKey: url)?.cancel()
        }
    }

    private func finish(_ url: URL, image: NSImage?) {
        tasks[url] = nil
        if let image {
            let pixels = image.representations.first.map { $0.pixelsWide * $0.pixelsHigh } ?? 0
            cache.setObject(image, forKey: url.absoluteString as NSString, cost: pixels * 4)
        }
        let callbacks = waiters.removeValue(forKey: url) ?? [:]
        callbacks.values.forEach { $0(image) }
    }

    private static func fetch(_ url: URL, maxPixel: Int, pointSize: NSSize, queue: OperationQueue?) async -> NSImage? {
        guard MediaRequest.isAllowedImageURL(url), let data = await CappedDownload.data(from: url, limit: maxBytes),
              !Task.isCancelled, let queue else { return nil }
        return await withCheckedContinuation { continuation in
            queue.addOperation {
                continuation.resume(returning: decode(data, maxPixel: maxPixel, pointSize: pointSize))
            }
        }
    }

    /// Decodes straight to `maxPixel` (ImageIO's thumbnail path), after checking the format and pixel count.
    static func decode(_ data: Data, maxPixel: Int, pointSize: NSSize, allowedTypes: Set<String> = MediaLoader.allowedTypes) -> NSImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions),
              let type = CGImageSourceGetType(source) as String?, allowedTypes.contains(type),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, sourceOptions) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width * height <= maxSourcePixels else { return nil }
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixel),
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else { return nil }
        // Keep the image's own proportions: the box it was asked for can be a slightly different shape
        // (a banner that isn't exactly 5:2), and stretching it to the box would distort it.
        let fit = min(pointSize.width / CGFloat(image.width), pointSize.height / CGFloat(image.height))
        return NSImage(cgImage: image, size: NSSize(width: CGFloat(image.width) * fit, height: CGFloat(image.height) * fit))
    }
}

/// Downloads at most `limit` bytes: a response that says it's bigger is refused before any of it arrives,
/// and one that runs past the limit anyway is cut off, so an oversized image is never buffered whole.
final class CappedDownload: NSObject, URLSessionDataDelegate {
    private let limit: Int
    private var data = Data()
    private var failed = false
    private var continuation: CheckedContinuation<Data?, Never>?

    private init(limit: Int) {
        self.limit = limit
    }

    static func data(from url: URL, limit: Int) async -> Data? {
        let loader = CappedDownload(limit: limit)
        let task = SecureSession.media.session.dataTask(with: url)
        // A per-task delegate gets the data; certificate and host checks still go to SecureSession.
        task.delegate = loader
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                loader.continuation = continuation
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let ok = (response as? HTTPURLResponse)?.statusCode == 200 && response.expectedContentLength <= Int64(limit)
        if ok, response.expectedContentLength > 0 { data.reserveCapacity(Int(response.expectedContentLength)) }
        failed = !ok
        completionHandler(ok ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        data.append(chunk)
        if data.count > limit {
            failed = true
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let result = error == nil && !failed ? data : nil
        data = Data()
        continuation?.resume(returning: result)
        continuation = nil
    }
}

/// An image view that shows a remote image through MediaLoader and cancels when it's reused.
/// Used for profile pictures and server icons.
final class RemoteImageView: NSImageView {
    private var url: URL?
    private var token: MediaLoader.Token?

    override init(frame: NSRect) {
        super.init(frame: frame)
        imageScaling = .scaleProportionallyUpOrDown
        wantsLayer = true
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    var cornerRadius: CGFloat {
        get { layer?.cornerRadius ?? 0 }
        set { layer?.cornerRadius = newValue }
    }

    /// Fill the whole frame, cropping the image's edges, instead of fitting inside it (profile banners).
    var fillsFrame = false {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard fillsFrame, let image, image.size.width > 0, image.size.height > 0 else {
            super.draw(dirtyRect)
            return
        }
        let scale = max(bounds.width / image.size.width, bounds.height / image.size.height)
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        image.draw(in: NSRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                              width: size.width, height: size.height))
    }

    /// Shows the image at `url` (nil clears it). `onLoad` reports whether an image is showing.
    func setImage(_ url: URL?, pointSize: NSSize, onLoad: ((Bool) -> Void)? = nil) {
        guard url != self.url else {
            onLoad?(image != nil)
            return
        }
        cancel()
        self.url = url
        image = nil
        guard let url else {
            onLoad?(false)
            return
        }
        token = MediaLoader.shared.load(url, pointSize: pointSize) { [weak self] loaded in
            guard let self, self.url == url else { return }
            self.token = nil
            self.image = loaded
            onLoad?(loaded != nil)
        }
    }

    func cancel() {
        if let token, let url {
            MediaLoader.shared.cancel(token, for: url)
            // Not loaded yet: forget the URL so the next setImage starts the load again.
            self.url = nil
        }
        token = nil
    }
}

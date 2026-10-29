import AppKit
import DuhcordCore
import ImageIO
import UniformTypeIdentifiers

/// Downloads, decrypts and decodes the encrypted images in private messages.
/// - Only from Discord's file CDN (MediaRequest.isAllowedAttachmentURL), and never more bytes than the image's
///   attachment must have.
/// - Only images sent from trusted keys (an accepted key, or one of our approved Macs). These are the one kind of
///   picture Duhcord decodes that Discord hasn't re-encoded, so it's limited to people you chose to trust, to JPEG
///   and PNG (all Duhcord sends), and to the same pixel limit as other images.
/// - Decrypted bytes and decoded images are kept in memory only, and dropped when the session ends.
final class PrivateImageLoader {
    static let shared = PrivateImageLoader()

    typealias Token = UUID

    /// A fresh link for an attachment whose signed link expired. Set for each session.
    var refreshURL: ((String) async -> String?)?

    private let images: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.totalCostLimit = 24 * 1024 * 1024
        return cache
    }()
    private let decrypted: NSCache<NSString, NSData> = {
        let cache = NSCache<NSString, NSData>()
        cache.totalCostLimit = 32 * 1024 * 1024
        return cache
    }()
    private var waiters: [String: [Token: (Data?) -> Void]] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]

    /// The image decoded to fit `pointSize`, on the main thread (nil if it can't be shown). Returns a token for
    /// `cancel`.
    @discardableResult
    func load(_ image: PrivateImage, pointSize: NSSize, completion: @escaping (NSImage?) -> Void) -> Token? {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let maxPixel = Int((max(pointSize.width, pointSize.height) * scale).rounded(.up))
        let key = "\(image.cacheKey)@\(maxPixel)" as NSString
        if let cached = images.object(forKey: key) {
            completion(cached)
            return nil
        }
        let allowed: Set<String> = [image.file.kind == .png ? UTType.png.identifier : UTType.jpeg.identifier]
        return data(for: image) { [weak self] data in
            guard let data else {
                completion(nil)
                return
            }
            let bytes = Handoff(value: data)
            // The same two-at-a-time queue as other images, so scrolling past many large photos stays light.
            MediaLoader.shared.decodeQueue.addOperation {
                let decoded = Handoff(value: MediaLoader.decode(bytes.value, maxPixel: maxPixel, pointSize: pointSize,
                                                                allowedTypes: allowed))
                DispatchQueue.main.async {
                    if let image = decoded.value {
                        let pixels = image.representations.first.map { $0.pixelsWide * $0.pixelsHigh } ?? 0
                        self?.images.setObject(image, forKey: key, cost: pixels * 4)
                    }
                    completion(decoded.value)
                }
            }
        }
    }

    /// The decrypted image file, on the main thread (nil if it can't be had).
    @discardableResult
    func data(for image: PrivateImage, completion: @escaping (Data?) -> Void) -> Token? {
        let key = image.cacheKey
        if let cached = decrypted.object(forKey: key as NSString) {
            completion(cached as Data)
            return nil
        }
        guard image.trusted, let url = image.attachment?.url else {
            completion(nil)
            return nil
        }
        let token = Token()
        let isFirst = waiters[key] == nil
        waiters[key, default: [:]][token] = completion
        guard isFirst else { return token }
        let owner = WeakReference(self)
        let refresh = Handoff(value: refreshURL)
        tasks[key] = Task {
            let data = Handoff(value: await Self.fetch(image, url: url, refresh: refresh.value))
            await MainActor.run { owner.object?.finish(key, data: data.value) }
        }
        return token
    }

    func cancel(_ token: Token, for image: PrivateImage) {
        let key = image.cacheKey
        waiters[key]?[token] = nil
        if waiters[key]?.isEmpty == true {
            waiters[key] = nil
            tasks.removeValue(forKey: key)?.cancel()
        }
    }

    /// Forgets every decrypted image: the account logged out or switched.
    func reset() {
        tasks.values.forEach { $0.cancel() }
        tasks = [:]
        waiters = [:]
        images.removeAllObjects()
        decrypted.removeAllObjects()
        refreshURL = nil
    }

    private func finish(_ key: String, data: Data?) {
        tasks[key] = nil
        if let data { decrypted.setObject(data as NSData, forKey: key as NSString, cost: data.count) }
        let callbacks = waiters.removeValue(forKey: key) ?? [:]
        callbacks.values.forEach { $0(data) }
    }

    private static func fetch(_ image: PrivateImage, url: String, refresh: ((String) async -> String?)?) async -> Data? {
        guard #available(macOS 14, *) else { return nil }
        func download(_ string: String) async -> Data? {
            guard let url = URL(string: string), MediaRequest.isAllowedAttachmentURL(url) else { return nil }
            return await CappedDownload.data(from: url, limit: image.file.sealedLength)
        }
        var sealed = await download(url)
        // Discord's attachment links expire after about a day; ask for a fresh one once.
        if sealed == nil, !Task.isCancelled, let fresh = await refresh?(url) { sealed = await download(fresh) }
        guard let sealed, !Task.isCancelled else { return nil }
        return PrivateCrypto.openFile(sealed, file: image.file)
    }
}

/// An image or video ready to send: re-encoded, with what the message list and the encrypted message need.
struct PreparedAttachment {
    let data: Data
    let width: Int
    let height: Int
    let kind: PrivateFile.Kind
    /// For the row of attachments above the message box.
    let thumbnail: NSImage
    let name: String
    /// Videos: how long, for the row.
    var duration: Double = 0

    /// The file as uploaded outside Private: a plain name, so the original's doesn't go to Discord either.
    var upload: UploadFile {
        switch kind {
        case .png: return UploadFile(name: "image.png", data: data, contentType: "image/png")
        case .jpeg: return UploadFile(name: "image.jpg", data: data, contentType: "image/jpeg")
        case .mp4: return UploadFile(name: "video.mp4", data: data, contentType: "video/mp4")
        }
    }
}

/// Turns a picture the user attached into what's sent (encrypted in Private, as it is otherwise): re-encoded from
/// its pixels, so nothing else in the file (location, camera, edits, other frames) goes with it, turned upright,
/// and made small enough that the most images a message can carry fit Discord's upload limit together.
enum ImagePrep {
    /// Each image's share of the upload limit, leaving room for padding.
    static let budget = PrivateMessaging.maxUploadBytes / PrivateMessaging.maxFiles * 8 / 9
    /// Files bigger than this aren't read at all.
    static let maxSourceBytes = 200 * 1024 * 1024
    private static let maxSourcePixels = 200_000_000
    private static let maxDimension = 4096

    /// Off the main thread: decoding and re-encoding a large photo takes a moment.
    static func prepare(_ source: Data, name: String) -> PreparedAttachment? {
        guard source.count <= maxSourceBytes,
              let image = CGImageSourceCreateWithData(source as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(image) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width * height <= maxSourcePixels else { return nil }
        let hasAlpha = properties[kCGImagePropertyHasAlpha] as? Bool ?? false
        var maxPixel = min(maxDimension, max(width, height))
        var quality = 0.85
        // Smaller and more compressed until it fits; a transparent picture tries PNG first.
        for attempt in 0..<8 {
            guard let pixels = thumbnail(image, maxPixel: maxPixel) else { return nil }
            let png = hasAlpha && attempt < 2
            if let data = encode(png ? pixels : flattened(pixels), png: png, quality: quality), data.count <= budget,
               let small = thumbnail(image, maxPixel: 128) {
                return PreparedAttachment(data: data, width: pixels.width, height: pixels.height, kind: png ? .png : .jpeg,
                                thumbnail: NSImage(cgImage: small, size: NSSize(width: small.width, height: small.height)),
                                name: name)
            }
            maxPixel = max(256, maxPixel * 3 / 4)
            quality = max(0.6, quality - 0.05)
        }
        return nil
    }

    private static func thumbnail(_ source: CGImageSource, maxPixel: Int) -> CGImage? {
        CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ] as CFDictionary)
    }

    /// JPEG has no transparency: draw it on white rather than let it turn black.
    private static func flattened(_ image: CGImage) -> CGImage {
        guard image.alphaInfo != .none, image.alphaInfo != .noneSkipFirst, image.alphaInfo != .noneSkipLast,
              let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return image }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(rect)
        context.draw(image, in: rect)
        return context.makeImage() ?? image
    }

    /// The pixels alone: no metadata is copied from the original.
    private static func encode(_ image: CGImage, png: Bool, quality: Double) -> Data? {
        let data = NSMutableData()
        let type = (png ? UTType.png : UTType.jpeg).identifier as CFString
        guard let destination = CGImageDestinationCreateWithData(data, type, 1, nil) else { return nil }
        let options: [CFString: Any] = png ? [:] : [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// Something dropped or pasted to attach: an image's bytes, or a video file (read later, as it's encoded).
    enum Source {
        case image(Data, name: String)
        case video(URL, name: String)
    }

    private static let fileOptions: [NSPasteboard.ReadingOptionKey: Any] = [
        .urlReadingFileURLsOnly: true,
        .urlReadingContentsConformToTypes: [UTType.image.identifier, UTType.movie.identifier],
    ]

    /// Images and videos from the pasteboard (pasted or dropped): files, or a picture copied from another app.
    static func sources(from pasteboard: NSPasteboard) -> [Source] {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: fileOptions) as? [URL], !urls.isEmpty {
            return sources(from: urls)
        }
        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            if let data = pasteboard.data(forType: type) { return [.image(data, name: "Pasted image")] }
        }
        return []
    }

    static func sources(from urls: [URL]) -> [Source] {
        urls.compactMap { url in
            if UTType(filenameExtension: url.pathExtension)?.conforms(to: .movie) == true {
                return .video(url, name: url.lastPathComponent)
            }
            return read(url).map { .image($0.data, name: $0.name) }
        }
    }

    /// Image or video files, or a copied picture that isn't also text (copied web page text can carry a picture
    /// of itself).
    static func canRead(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.canReadObject(forClasses: [NSURL.self], options: fileOptions)
            || (pasteboard.availableType(from: [.png, .tiff]) != nil && pasteboard.availableType(from: [.string]) == nil)
    }

    /// A file's contents, if it's small enough to read.
    static func read(_ url: URL) -> (data: Data, name: String)? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= maxSourceBytes,
              let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return (data, url.lastPathComponent)
    }
}

/// A private image at full size, in a window of its own. Copy (⌘C or the right-click menu) puts it on the
/// clipboard as it was sent.
final class PrivateImagePreview: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    /// Open previews, so each stays alive until it's closed.
    private static var open: [PrivateImagePreview] = []

    private let imageView = NSImageView()
    private var data: Data?
    private var kind = PrivateFile.Kind.jpeg

    static var canSaveCurrentImage: Bool {
        (NSApp.keyWindow?.windowController as? PrivateImagePreview)?.data != nil
    }

    static func show(_ image: PrivateImage, from parent: NSWindow?) {
        PrivateImageLoader.shared.data(for: image) { data in
            guard let data else { return }
            let screen = (parent?.screen ?? NSScreen.main)?.visibleFrame.size ?? NSSize(width: 1200, height: 800)
            let box = NSSize(width: screen.width * 0.8, height: screen.height * 0.8)
            let fit = MediaRequest.fit(width: image.file.width, height: image.file.height,
                                       maxWidth: Double(box.width), maxHeight: Double(box.height))
            let size = NSSize(width: max(200, fit.width), height: max(150, fit.height))
            let allowed: Set<String> = [image.file.kind == .png ? UTType.png.identifier : UTType.jpeg.identifier]
            let scale = parent?.backingScaleFactor ?? 2
            guard let decoded = MediaLoader.decode(data, maxPixel: Int(max(size.width, size.height) * scale),
                                                   pointSize: size, allowedTypes: allowed) else { return }
            let preview = PrivateImagePreview(image: decoded, data: data, kind: image.file.kind, size: size)
            open.append(preview)
            preview.showWindow(nil)
        }
    }

    private init(image: NSImage, data: Data, kind: PrivateFile.Kind, size: NSSize) {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Private Image"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        self.data = data
        self.kind = kind
        imageView.image = image
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.setAccessibilityLabel("Private image")
        window.contentView = imageView
        window.delegate = self
        window.center()

        let copy = NSMenuItem(title: "Copy Image", action: #selector(copyImage), keyEquivalent: "")
        copy.target = self
        let save = NSMenuItem(title: "Save Image…", action: #selector(saveImage(_:)), keyEquivalent: "")
        save.target = self
        imageView.menu = NSMenu()
        imageView.menu?.addItem(copy)
        imageView.menu?.addItem(save)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// ⌘C copies the image.
    @objc func copy(_ sender: Any?) { copyImage() }

    /// The full image as it was sent, not the copy sized for the window.
    @objc private func copyImage() {
        guard let data else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(data, forType: kind == .png ? .png : NSPasteboard.PasteboardType(UTType.jpeg.identifier))
    }

    @objc func saveImage(_ sender: Any?) {
        guard data != nil, let window else { return }
        let panel = NSSavePanel()
        let isPNG = kind == .png
        panel.nameFieldStringValue = isPNG ? "image.png" : "image.jpg"
        panel.allowedContentTypes = [isPNG ? .png : .jpeg]
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self, let url = panel.url, let data = self.data else { return }
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                let alert = NSAlert()
                alert.messageText = "Couldn't save image"
                alert.informativeText = error.localizedDescription
                alert.beginSheetModal(for: window)
            }
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(saveImage(_:)) { return data != nil }
        return true
    }

    func windowWillClose(_ notification: Notification) {
        data = nil
        Self.open.removeAll { $0 === self }
    }

    /// The account logged out or switched: its images close with it.
    static func closeAll() {
        open.forEach { $0.close() }
        open = []
    }
}

import AppKit
import DuhcordCore

/// Where everything in one message row goes. Computed once per message and width, before any image loads:
/// Discord sends image sizes up front, so space is reserved exactly and the list never jumps.
struct MessageLayout {
    struct Box {
        let frame: NSRect
        let color: NSColor?
    }

    struct Text {
        let frame: NSRect
        let text: NSAttributedString
    }

    struct Media {
        let frame: NSRect
        /// The exact-size proxy request, or nil if the image can't be fetched safely.
        let request: URL?
        /// What a click opens once the image is showing.
        let open: URL?
        /// Waits for a click before loading (spoilers, or "Click to load").
        let gated: Bool
        let label: String?
        let isVideo: Bool
    }

    var height: CGFloat = 0
    var header: NSRect?
    var body = Text(frame: .zero, text: NSAttributedString())
    var boxes: [Box] = []
    var texts: [Text] = []
    var media: [Media] = []
}

enum MessageLayoutBuilder {
    static let imageMax = NSSize(width: 360, height: 270)
    static let thumbnailSize: CGFloat = 72
    static let embedMaxWidth: CGFloat = 440
    private static let bar: CGFloat = 4
    private static let pad: CGFloat = 10

    static func build(message: Message, grouped: Bool, cellWidth: CGFloat, sidePadding: CGFloat, headerHeight: CGFloat,
                      topPadding: CGFloat, bottomPadding: CGFloat, resolver: Markdown.Resolver) -> MessageLayout {
        let mode = Settings.mediaPreviews
        let showMedia = mode != .off
        let x = sidePadding
        let width = max(50, cellWidth - 2 * sidePadding)
        var layout = MessageLayout()
        var y = topPadding

        if !grouped {
            layout.header = NSRect(x: x, y: y, width: width, height: headerHeight)
            y += headerHeight
        }

        let inline = showMedia ? message.attachments.filter { $0.isImage } : []
        let visibleEmbeds = message.embeds.filter { $0.hasText || (showMedia && media(of: $0) != nil) }
        let bodyText = Theme.body(for: message, resolver: resolver, inlineAttachments: Set(inline.map(\.id)),
                                  hasVisuals: !inline.isEmpty || !visibleEmbeds.isEmpty)
        let bodyHeight = bodyText.length > 0 ? measure(bodyText, width: width) : 0
        layout.body = MessageLayout.Text(frame: NSRect(x: x, y: y, width: width, height: bodyHeight), text: bodyText)
        y += bodyHeight

        for attachment in inline {
            let size = fit(attachment.width, attachment.height, max: NSSize(width: min(imageMax.width, width), height: imageMax.height))
            y += 6
            let frame = NSRect(origin: NSPoint(x: x, y: y), size: size)
            layout.media.append(MessageLayout.Media(
                frame: frame, request: request(attachment.proxyUrl, size: size), open: URL(string: attachment.url),
                gated: mode == .onClick || attachment.isSpoiler,
                label: attachment.isSpoiler ? "Spoiler · click to show" : (mode == .onClick ? "Click to load image" : nil),
                isVideo: false))
            y += size.height
        }

        for embed in visibleEmbeds {
            if embed.isMediaOnly {
                // A bare image or GIF link: just the picture, no card.
                guard let picture = media(of: embed) else { continue }
                let size = fit(picture.width, picture.height, max: NSSize(width: min(imageMax.width, width), height: imageMax.height))
                y += 6
                layout.media.append(MessageLayout.Media(
                    frame: NSRect(origin: NSPoint(x: x, y: y), size: size), request: request(picture.proxyUrl, size: size),
                    open: (embed.url ?? picture.url).flatMap(URL.init(string:)), gated: mode == .onClick,
                    label: mode == .onClick ? "Click to load image" : nil, isVideo: embed.isVideo))
                y += size.height
                continue
            }

            let boxWidth = min(width, embedMaxWidth)
            let boxTop = y + 6
            let textX = x + bar + pad
            // Videos (YouTube and the like) show their thumbnail large; other cards show it small on the right.
            let large = showMedia ? (embed.image ?? (embed.isVideo ? embed.thumbnail : nil)) : nil
            let small = showMedia && large == nil ? embed.thumbnail : nil
            let textWidth = max(40, boxWidth - bar - 2 * pad - (small != nil ? thumbnailSize + pad : 0))
            var cursor = boxTop + pad

            let text = Theme.embedText(embed, resolver: resolver)
            if text.length > 0 {
                let height = measure(text, width: textWidth)
                layout.texts.append(MessageLayout.Text(frame: NSRect(x: textX, y: cursor, width: textWidth, height: height), text: text))
                cursor += height
            }
            if let small, small.proxyUrl != nil {
                let size = fit(small.width, small.height, max: NSSize(width: thumbnailSize, height: thumbnailSize))
                let frame = NSRect(x: x + boxWidth - pad - size.width, y: boxTop + pad, width: size.width, height: size.height)
                layout.media.append(MessageLayout.Media(
                    frame: frame, request: request(small.proxyUrl, size: size), open: (embed.url ?? small.url).flatMap(URL.init(string:)),
                    gated: mode == .onClick, label: nil, isVideo: false))
                cursor = max(cursor, frame.maxY)
            }
            if let large, large.proxyUrl != nil {
                let size = fit(large.width, large.height, max: NSSize(width: boxWidth - bar - 2 * pad, height: imageMax.height))
                if text.length > 0 { cursor += 8 }
                layout.media.append(MessageLayout.Media(
                    frame: NSRect(origin: NSPoint(x: textX, y: cursor), size: size), request: request(large.proxyUrl, size: size),
                    open: (embed.url ?? large.url).flatMap(URL.init(string:)), gated: mode == .onClick,
                    label: mode == .onClick ? "Click to load image" : nil, isVideo: embed.isVideo))
                cursor += size.height
            }
            let boxBottom = cursor + pad
            layout.boxes.append(MessageLayout.Box(frame: NSRect(x: x, y: boxTop, width: boxWidth, height: boxBottom - boxTop),
                                                  color: embed.color.map(color(from:))))
            y = boxBottom
        }

        layout.height = y + bottomPadding
        return layout
    }

    /// The picture a media-only embed shows.
    private static func media(of embed: Embed) -> EmbedMedia? {
        embed.isMediaOnly ? (embed.thumbnail ?? embed.image) : (embed.image ?? embed.thumbnail)
    }

    private static func fit(_ width: Int?, _ height: Int?, max box: NSSize) -> NSSize {
        guard let width, let height else { return NSSize(width: min(box.width, 240), height: min(box.height, 160)) }
        let size = MediaRequest.fit(width: width, height: height, maxWidth: Double(box.width), maxHeight: Double(box.height))
        return NSSize(width: max(1, size.width), height: max(1, size.height))
    }

    private static func request(_ proxy: String?, size: NSSize) -> URL? {
        guard let proxy else { return nil }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        return MediaRequest.url(proxy: proxy, pixelWidth: Int((size.width * scale).rounded()),
                                pixelHeight: Int((size.height * scale).rounded()))
    }

    private static func measure(_ text: NSAttributedString, width: CGFloat) -> CGFloat {
        ceil(text.boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude),
                               options: [.usesLineFragmentOrigin, .usesFontLeading]).height)
    }

    private static func color(from value: Int) -> NSColor {
        NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }
}

/// One image in a message. Shows a placeholder at the final size until the image arrives, so nothing moves.
final class MediaView: NSView {
    /// Spoilers and click-to-load images the user already opened this session.
    private static var revealed: Set<URL> = []

    private let imageView = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private var item: MessageLayout.Media?
    private var token: MediaLoader.Token?

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.masksToBounds = true
        imageView.imageScaling = .scaleAxesIndependently
        imageView.autoresizingMask = [.width, .height]
        label.alignment = .center
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        label.textColor = .secondaryLabelColor
        addSubview(imageView)
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func configure(_ item: MessageLayout.Media) {
        cancel()
        self.item = item
        imageView.image = nil
        imageView.frame = bounds
        toolTip = item.open?.host
        if let request = item.request, !item.gated || Self.revealed.contains(request) {
            load(request)
        }
        updateLabel()
    }

    /// Called when the row is reused or removed, so off-screen images stop downloading.
    func cancel() {
        if let token, let request = item?.request { MediaLoader.shared.cancel(token, for: request) }
        token = nil
    }

    private func load(_ request: URL) {
        let size = bounds.size == .zero ? item?.frame.size ?? .zero : bounds.size
        token = MediaLoader.shared.load(request, pointSize: size) { [weak self] image in
            guard let self, self.item?.request == request else { return }
            self.token = nil
            self.imageView.image = image
            self.updateLabel()
        }
    }

    private func updateLabel() {
        guard let item else { return }
        if imageView.image != nil {
            label.stringValue = item.isVideo ? "▶" : ""
            label.font = item.isVideo ? .systemFont(ofSize: 28) : .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
            label.textColor = item.isVideo ? .white : .secondaryLabelColor
        } else {
            let waiting = item.request != nil && (!item.gated || Self.revealed.contains(item.request!))
            label.stringValue = waiting ? "" : (item.label ?? (item.request == nil ? "Image unavailable" : ""))
            label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
            label.textColor = .secondaryLabelColor
        }
        label.sizeToFit()
        label.frame = NSRect(x: 0, y: (bounds.height - label.frame.height) / 2, width: bounds.width, height: label.frame.height)
        label.isHidden = label.stringValue.isEmpty
    }

    override func layout() {
        super.layout()
        imageView.frame = bounds
        updateLabel()
    }

    /// Placeholder, drawn with dynamic colours so it follows light and dark mode.
    override func draw(_ dirtyRect: NSRect) {
        NSColor.quaternaryLabelColor.setFill()
        bounds.fill()
    }

    override func mouseDown(with event: NSEvent) {
        guard let item else { return }
        if imageView.image == nil, let request = item.request {
            // First click on a gated image loads it; nothing opens.
            Self.revealed.insert(request)
            if token == nil { load(request) }
            updateLabel()
        } else if let open = item.open {
            LinkOpener.open(open, shownText: nil, from: window)
        }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

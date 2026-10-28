import AppKit
import AVFoundation
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
        enum Kind {
            case image
            /// An uploaded GIF: the animated source, fetched only when it's about to play.
            case gif(URL?)
            /// A Tenor/Giphy-style GIF delivered as a short MP4: plays muted and looped.
            case loopingVideo([URL])
            /// A real video: plays with sound, only after a click.
            case video([URL])
        }

        let frame: NSRect
        /// The exact-size still image (or video poster) from the proxy, or nil if none can be fetched safely.
        let request: URL?
        /// What "open in browser" opens.
        let open: URL?
        /// Waits for a click before the still loads (spoilers, or "Click to load").
        let gated: Bool
        let label: String?
        let kind: Kind
        /// A video that can't be played inline (YouTube and the like): clicking opens it in the browser.
        let externalVideo: Bool
    }

    var height: CGFloat = 0
    var header: NSRect?
    var body = Text(frame: .zero, text: NSAttributedString())
    var boxes: [Box] = []
    var texts: [Text] = []
    var media: [Media] = []
    /// The author's profile picture, beside the name line (not on grouped follow-up messages).
    var avatar: (frame: NSRect, url: URL?)?
}

enum MessageLayoutBuilder {
    static let imageMax = NSSize(width: 360, height: 270)
    static let thumbnailSize: CGFloat = 72
    static let embedMaxWidth: CGFloat = 440
    static let avatarSize: CGFloat = 32
    static let avatarColumn: CGFloat = 42
    private static let bar: CGFloat = 4
    private static let pad: CGFloat = 10

    static func build(message: Message, grouped: Bool, cellWidth: CGFloat, sidePadding: CGFloat, headerHeight: CGFloat,
                      topPadding: CGFloat, bottomPadding: CGFloat, resolver: Markdown.Resolver) -> MessageLayout {
        let mode = Settings.mediaPreviews
        let showMedia = mode != .off
        // Everything sits right of a column for profile pictures, so follow-ups line up under the name.
        let x = sidePadding + avatarColumn
        let width = max(50, cellWidth - 2 * sidePadding - avatarColumn)
        let box = NSSize(width: min(imageMax.width, width), height: imageMax.height)
        var layout = MessageLayout()
        var y = topPadding

        if !grouped {
            let scale = NSScreen.main?.backingScaleFactor ?? 2
            layout.avatar = (NSRect(x: sidePadding, y: y + 2, width: avatarSize, height: avatarSize),
                             MediaRequest.avatarURL(for: message.author, pixels: Int(avatarSize * scale)))
            layout.header = NSRect(x: x, y: y, width: width, height: headerHeight)
            y += headerHeight
        }

        let inline = showMedia ? message.attachments.filter { $0.isImage || $0.isPlayableVideo } : []
        let visibleEmbeds = message.embeds.filter { $0.hasText || (showMedia && picture(of: $0) != nil) }
        let bodyText = Theme.body(for: message, resolver: resolver, inlineAttachments: Set(inline.map(\.id)),
                                  hasVisuals: !inline.isEmpty || !visibleEmbeds.isEmpty)
        let bodyHeight = bodyText.length > 0 ? measure(bodyText, width: width) : 0
        layout.body = MessageLayout.Text(frame: NSRect(x: x, y: y, width: width, height: bodyHeight), text: bodyText)
        y += bodyHeight

        for attachment in inline {
            let size = fit(attachment.width, attachment.height, max: box)
            y += 6
            let kind: MessageLayout.Media.Kind
            if attachment.isPlayableVideo {
                // Proxy first; some uploads are only served from Discord's file CDN.
                kind = .video([attachment.proxyUrl, attachment.url].compactMap { $0.flatMap(URL.init(string:)) })
            } else if attachment.isGIF {
                kind = .gif(request(attachment.proxyUrl, size: size, format: nil))
            } else {
                kind = .image
            }
            layout.media.append(MessageLayout.Media(
                frame: NSRect(origin: NSPoint(x: x, y: y), size: size), request: request(attachment.proxyUrl, size: size),
                open: URL(string: attachment.url), gated: mode == .onClick || attachment.isSpoiler,
                label: attachment.isSpoiler ? "Spoiler · click to show" : (mode == .onClick ? "Click to load" : nil),
                kind: kind, externalVideo: false))
            y += size.height
        }

        for embed in visibleEmbeds {
            let stream = embed.playableVideoURL.flatMap(URL.init(string:))
            if embed.isMediaOnly {
                // A bare image or GIF link: just the picture, no card.
                guard let picture = picture(of: embed) else { continue }
                let size = fit(picture.width ?? embed.video?.width, picture.height ?? embed.video?.height, max: box)
                y += 6
                layout.media.append(MessageLayout.Media(
                    frame: NSRect(origin: NSPoint(x: x, y: y), size: size), request: request(picture.proxyUrl, size: size),
                    open: (embed.url ?? picture.url).flatMap(URL.init(string:)), gated: mode == .onClick,
                    label: mode == .onClick ? "Click to load" : nil,
                    kind: stream.map { .loopingVideo([$0]) } ?? .image, externalVideo: embed.isVideo && stream == nil))
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
                    gated: mode == .onClick, label: nil, kind: .image, externalVideo: false))
                cursor = max(cursor, frame.maxY)
            }
            if let large, large.proxyUrl != nil {
                let size = fit(large.width, large.height, max: NSSize(width: boxWidth - bar - 2 * pad, height: imageMax.height))
                if text.length > 0 { cursor += 8 }
                let kind: MessageLayout.Media.Kind = stream.map { embed.type == "gifv" ? .loopingVideo([$0]) : .video([$0]) } ?? .image
                layout.media.append(MessageLayout.Media(
                    frame: NSRect(origin: NSPoint(x: textX, y: cursor), size: size), request: request(large.proxyUrl, size: size),
                    open: (embed.url ?? large.url).flatMap(URL.init(string:)), gated: mode == .onClick,
                    label: mode == .onClick ? "Click to load" : nil, kind: kind, externalVideo: embed.isVideo && stream == nil))
                cursor += size.height
            }
            let boxBottom = cursor + pad
            layout.boxes.append(MessageLayout.Box(frame: NSRect(x: x, y: boxTop, width: boxWidth, height: boxBottom - boxTop),
                                                  color: embed.color.map(color(from:))))
            y = boxBottom
        }

        layout.height = max(y, layout.avatar?.frame.maxY ?? 0) + bottomPadding
        return layout
    }

    /// The still a media-only embed shows.
    private static func picture(of embed: Embed) -> EmbedMedia? {
        embed.isMediaOnly ? (embed.thumbnail ?? embed.image) : (embed.image ?? embed.thumbnail)
    }

    private static func fit(_ width: Int?, _ height: Int?, max box: NSSize) -> NSSize {
        guard let width, let height else { return NSSize(width: min(box.width, 240), height: min(box.height, 160)) }
        let size = MediaRequest.fit(width: width, height: height, maxWidth: Double(box.width), maxHeight: Double(box.height))
        return NSSize(width: max(1, size.width), height: max(1, size.height))
    }

    private static func request(_ proxy: String?, size: NSSize, format: String? = "webp") -> URL? {
        guard let proxy else { return nil }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        return MediaRequest.url(proxy: proxy, pixelWidth: Int((size.width * scale).rounded()),
                                pixelHeight: Int((size.height * scale).rounded()), format: format)
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

/// Hosts an AVPlayerLayer as its backing layer.
private final class PlayerView: NSView {
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        playerLayer.videoGravity = .resizeAspect
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func makeBackingLayer() -> CALayer { AVPlayerLayer() }
}

/// One image, GIF or video in a message. Shows a placeholder at the final size until the still arrives,
/// so nothing moves; GIFs animate on hover (or when visible), videos play on click.
final class MediaView: NSView, Playable {
    /// Spoilers and click-to-load images the user already opened this session.
    private static var revealed: Set<URL> = []

    private let imageView = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let badge = NSTextField(labelWithString: "")
    private let openButton = NSButton(title: "↗", target: nil, action: nil)
    private var item: MessageLayout.Media?
    private var token: MediaLoader.Token?
    private var still: NSImage?

    // Playback state; all torn down by stopPlayback().
    private var animator: GIFAnimator?
    private var playerView: PlayerView?
    private var player: AVPlayer?
    private var looper: AVPlayerLooper?
    private var loader: StreamingLoader?
    private var statusObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var isPlaying: Bool { animator != nil || player != nil }

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.masksToBounds = true
        imageView.imageScaling = .scaleAxesIndependently
        label.alignment = .center
        badge.font = .systemFont(ofSize: 10, weight: .bold)
        badge.textColor = .white
        badge.drawsBackground = true
        badge.backgroundColor = NSColor.black.withAlphaComponent(0.55)
        openButton.bezelStyle = .inline
        openButton.target = self
        openButton.action = #selector(openInBrowser)
        openButton.toolTip = "Open in browser"
        [imageView, label, badge, openButton].forEach(addSubview)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func configure(_ item: MessageLayout.Media) {
        cancel()
        self.item = item
        still = nil
        imageView.image = nil
        toolTip = item.open?.host
        if let request = item.request, !item.gated || Self.revealed.contains(request) {
            load(request)
        }
        refreshOverlays()
        if isAnimatedGIF, PlaybackCoordinator.gifsPlayWhenVisible, !item.gated { startGIF() }
    }

    /// Called when the row is reused or scrolled away: stops downloads and playback.
    func cancel() {
        if let token, let request = item?.request { MediaLoader.shared.cancel(token, for: request) }
        token = nil
        stopPlayback()
    }

    // MARK: - Stills

    private func load(_ request: URL) {
        let size = bounds.size == .zero ? item?.frame.size ?? .zero : bounds.size
        token = MediaLoader.shared.load(request, pointSize: size) { [weak self] image in
            guard let self, self.item?.request == request else { return }
            self.token = nil
            self.still = image
            if !self.isPlaying { self.imageView.image = image }
            self.refreshOverlays()
        }
    }

    private var isAnimatedGIF: Bool {
        guard let item, Settings.animateGIFs != .never else { return false }
        switch item.kind {
        case .gif(let url): return url != nil
        case .loopingVideo: return true
        default: return false
        }
    }

    private var isVideo: Bool {
        if case .video = item?.kind { return true }
        return false
    }

    // MARK: - Playback

    private func startGIF() {
        guard let item, !isPlaying else { return }
        switch item.kind {
        case .gif(let url?):
            let animator = GIFAnimator()
            self.animator = animator
            PlaybackCoordinator.shared.startGIF(self)
            animator.start(url, frame: { [weak self] frame in
                guard let self, self.animator === animator else { return }
                self.imageView.image = NSImage(cgImage: frame, size: self.bounds.size)
            }, failed: { [weak self] in
                guard let self, self.animator === animator else { return }
                self.stopPlayback()
            })
        case .loopingVideo(let urls):
            startPlayer(urls, looping: true, muted: true)
            PlaybackCoordinator.shared.startGIF(self)
        default:
            break
        }
        refreshOverlays()
    }

    private func startVideo() {
        guard case .video(let urls) = item?.kind, !isPlaying else { return }
        startPlayer(urls, looping: false, muted: false)
        PlaybackCoordinator.shared.startVideo(self)
        refreshOverlays()
    }

    private func startPlayer(_ urls: [URL], looping: Bool, muted: Bool) {
        let loader = StreamingLoader(sources: urls)
        guard let asset = loader.makeAsset() else {
            showFailure()
            return
        }
        let playerItem = AVPlayerItem(asset: asset)
        // Only a few seconds are buffered ahead, which keeps memory small while playing.
        playerItem.preferredForwardBufferDuration = 5
        let player: AVPlayer
        if looping {
            let queuePlayer = AVQueuePlayer()
            looper = AVPlayerLooper(player: queuePlayer, templateItem: playerItem)
            player = queuePlayer
        } else {
            player = AVPlayer(playerItem: playerItem)
            endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: playerItem, queue: .main) { [weak self] _ in
                self?.stopPlayback()
            }
        }
        player.isMuted = muted
        statusObservation = player.observe(\.currentItem?.status, options: [.new]) { [weak self] player, _ in
            guard player.currentItem?.status == .failed else { return }
            DispatchQueue.main.async { self?.showFailure() }
        }

        let view = PlayerView(frame: bounds)
        view.autoresizingMask = [.width, .height]
        view.playerLayer.player = player
        addSubview(view, positioned: .above, relativeTo: imageView)
        playerView = view
        self.player = player
        self.loader = loader
        player.play()
    }

    func stopPlayback() {
        animator?.cancel()
        animator = nil
        player?.pause()
        looper?.disableLooping()
        player?.replaceCurrentItem(with: nil)
        loader?.cancelAll()
        playerView?.removeFromSuperview()
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        statusObservation = nil
        endObserver = nil
        playerView = nil
        player = nil
        looper = nil
        loader = nil
        imageView.image = still
        PlaybackCoordinator.shared.stopped(self)
        refreshOverlays()
    }

    private func showFailure() {
        stopPlayback()
        label.stringValue = "Couldn't play this here · ↗ opens it"
        layoutLabel()
    }

    @objc private func openInBrowser() {
        guard let open = item?.open else { return }
        if isVideo { stopPlayback() }
        LinkOpener.open(open, shownText: nil, from: window)
    }

    // MARK: - Overlays

    private func refreshOverlays() {
        guard let item else { return }
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        label.textColor = .secondaryLabelColor
        if isPlaying {
            label.stringValue = ""
        } else if still != nil || imageView.image != nil {
            let playable = isVideo || item.externalVideo
            label.stringValue = playable ? "▶" : ""
            label.font = .systemFont(ofSize: 30)
            label.textColor = .white
        } else {
            let waiting = item.request != nil && (!item.gated || Self.revealed.contains(item.request!))
            if waiting {
                label.stringValue = isVideo ? "▶" : ""
            } else {
                label.stringValue = item.label ?? (isVideo ? "▶" : (item.request == nil ? "Image unavailable" : ""))
            }
        }
        if case .gif = item.kind, !isPlaying { badge.stringValue = " GIF " } else if case .loopingVideo = item.kind, !isPlaying {
            badge.stringValue = " GIF "
        } else {
            badge.stringValue = ""
        }
        badge.isHidden = badge.stringValue.isEmpty
        // Videos get an "open in browser" button while playing; everything else opens with a click.
        openButton.isHidden = !(isVideo && isPlaying)
        needsLayout = true
    }

    private func layoutLabel() {
        label.sizeToFit()
        label.frame = NSRect(x: 0, y: (bounds.height - label.frame.height) / 2, width: bounds.width, height: label.frame.height)
        label.isHidden = label.stringValue.isEmpty
    }

    override func layout() {
        super.layout()
        imageView.frame = bounds
        playerView?.frame = bounds
        layoutLabel()
        badge.sizeToFit()
        badge.frame.origin = NSPoint(x: 6, y: bounds.height - badge.frame.height - 6)
        openButton.sizeToFit()
        openButton.frame.origin = NSPoint(x: bounds.width - openButton.frame.width - 6, y: 6)
    }

    /// Placeholder, drawn with dynamic colours so it follows light and dark mode.
    override func draw(_ dirtyRect: NSRect) {
        NSColor.quaternaryLabelColor.setFill()
        bounds.fill()
    }

    // MARK: - Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        guard isAnimatedGIF, !PlaybackCoordinator.gifsPlayWhenVisible, still != nil else { return }
        startGIF()
    }

    override func mouseExited(with event: NSEvent) {
        guard isAnimatedGIF, !PlaybackCoordinator.gifsPlayWhenVisible, isPlaying else { return }
        stopPlayback()
    }

    override func mouseDown(with event: NSEvent) {
        guard let item else { return }
        if still == nil, let request = item.request, item.gated, !Self.revealed.contains(request) {
            // First click on a gated image loads it; nothing opens.
            Self.revealed.insert(request)
            if token == nil { load(request) }
            refreshOverlays()
        } else if isVideo {
            // Click plays; while playing, click pauses and resumes.
            if let player {
                if player.timeControlStatus == .paused { player.play() } else { player.pause() }
            } else {
                startVideo()
            }
        } else if let open = item.open {
            LinkOpener.open(open, shownText: nil, from: window)
        }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

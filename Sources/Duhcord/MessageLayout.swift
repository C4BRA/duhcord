import AppKit
import AVFoundation
import DuhcordCore

/// Where everything in one message row goes. Computed once per message and width, before any image loads:
/// Discord sends image sizes up front, so space is reserved exactly and the list never jumps.
@MainActor
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
            /// An encrypted image in a private message, decrypted here (`request` only names it).
            case privateImage(PrivateImage)
            /// An encrypted video in a private message: downloaded and decrypted on click, played from memory.
            case privateVideo(PrivateImage)
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

@MainActor
enum MessageLayoutBuilder {
    static let imageMax = NSSize(width: 360, height: 270)
    static let thumbnailSize: CGFloat = 72
    static let embedMaxWidth: CGFloat = 440
    static let avatarSize: CGFloat = 32
    static let avatarColumn: CGFloat = 42
    private static let bar: CGFloat = 4
    private static let pad: CGFloat = 10

    static func build(message: Message, grouped: Bool, cellWidth: CGFloat, sidePadding: CGFloat, headerHeight: CGFloat,
                      scale: CGFloat, topPadding: CGFloat, bottomPadding: CGFloat, resolver: Markdown.Resolver,
                      privateImages: [PrivateImage] = []) -> MessageLayout {
        let mode = Settings.mediaPreviews
        let showMedia = mode != .off
        // Everything sits right of a column for profile pictures, so follow-ups line up under the name.
        let x = sidePadding + avatarColumn
        let width = max(50, cellWidth - 2 * sidePadding - avatarColumn)
        let box = NSSize(width: min(imageMax.width, width), height: imageMax.height)
        var layout = MessageLayout()
        var y = topPadding

        if !grouped {
            layout.avatar = (NSRect(x: sidePadding, y: y + 2, width: avatarSize, height: avatarSize),
                             MediaRequest.avatarURL(for: message.author, pixels: Int(avatarSize * scale)))
            layout.header = NSRect(x: x, y: y, width: width, height: headerHeight)
            y += headerHeight
        }

        let inline = showMedia ? message.attachments.filter { $0.isImage || $0.isPlayableVideo } : []
        let visibleEmbeds = message.embeds.filter { $0.hasText || (showMedia && picture(of: $0) != nil) }
        let bodyText = Theme.body(for: message, resolver: resolver, inlineAttachments: Set(inline.map(\.id)),
                                  hasVisuals: !inline.isEmpty || !visibleEmbeds.isEmpty || !privateImages.isEmpty)
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
                kind = .gif(request(attachment.proxyUrl, size: size, scale: scale, format: nil))
            } else {
                kind = .image
            }
            layout.media.append(MessageLayout.Media(
                frame: NSRect(origin: NSPoint(x: x, y: y), size: size),
                request: request(attachment.proxyUrl, size: size, scale: scale),
                open: URL(string: attachment.url), gated: mode == .onClick || attachment.isSpoiler,
                label: attachment.isSpoiler ? "Spoiler · click to show" : (mode == .onClick ? "Click to load" : nil),
                kind: kind, externalVideo: false))
            y += size.height
        }

        // Encrypted images: their size comes inside the message, so space is reserved before they're decrypted.
        // They're the only way to see the picture, so with previews off they wait for a click instead of hiding.
        for image in privateImages {
            // Later pieces of a split video play from the first one. They aren't a second player.
            if image.filmID != nil, image.filmPart > 0 { continue }
            let size = fit(image.file.width, image.file.height, max: box)
            y += 6
            let available = image.trusted && image.attachment != nil
            if image.file.kind.isVideo {
                // Videos wait for a click: nothing that large downloads on its own.
                let label = !image.trusted ? "Not shown: sent from a key you haven't accepted"
                    : (image.attachment == nil ? "Video unavailable" : nil)
                layout.media.append(MessageLayout.Media(
                    frame: NSRect(origin: NSPoint(x: x, y: y), size: size), request: nil, open: nil, gated: true,
                    label: label, kind: .privateVideo(image), externalVideo: false))
                y += size.height
                continue
            }
            let label = !image.trusted ? "Not shown: sent from a key you haven't accepted"
                : (mode != .always ? "Click to load" : nil)
            layout.media.append(MessageLayout.Media(
                frame: NSRect(origin: NSPoint(x: x, y: y), size: size), request: available ? image.placeholderURL : nil,
                open: nil, gated: mode != .always, label: label, kind: .privateImage(image), externalVideo: false))
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
                    frame: NSRect(origin: NSPoint(x: x, y: y), size: size),
                    request: request(picture.proxyUrl, size: size, scale: scale),
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
                    frame: frame, request: request(small.proxyUrl, size: size, scale: scale),
                    open: (embed.url ?? small.url).flatMap(URL.init(string:)),
                    gated: mode == .onClick, label: nil, kind: .image, externalVideo: false))
                cursor = max(cursor, frame.maxY)
            }
            if let large, large.proxyUrl != nil {
                let size = fit(large.width, large.height, max: NSSize(width: boxWidth - bar - 2 * pad, height: imageMax.height))
                if text.length > 0 { cursor += 8 }
                let kind: MessageLayout.Media.Kind = stream.map { embed.type == "gifv" ? .loopingVideo([$0]) : .video([$0]) } ?? .image
                layout.media.append(MessageLayout.Media(
                    frame: NSRect(origin: NSPoint(x: textX, y: cursor), size: size),
                    request: request(large.proxyUrl, size: size, scale: scale),
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

    private static func request(_ proxy: String?, size: NSSize, scale: CGFloat, format: String? = "webp") -> URL? {
        guard let proxy else { return nil }
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
@MainActor
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

/// Play, pause, a place in the video, and volume. Drawn on the dark bar along the bottom of a playing video.
@MainActor
private final class VideoControls: NSView {
    static let barHeight: CGFloat = 32
    /// Kept for the next video this session. A call's speaker volume is a different setting.
    private static var volume: Float = 1
    private static var unmuted: Float = 1

    private let play = NSButton()
    private let elapsed = NSTextField(labelWithString: "0:00")
    private let duration = NSTextField(labelWithString: "0:00")
    private let scrubber = TrackingSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let speaker = NSButton()
    private let volumeSlider = NSSlider(value: 1, minValue: 0, maxValue: 1, target: nil, action: nil)
    private weak var player: AVPlayer?
    private var timeObserver: Any?
    private var statusObserver: NSKeyValueObservation?
    private var durationObserver: NSKeyValueObservation?
    private var scrubbing = false
    private var seekID = 0
    /// Where this piece sits in a split video, how long the piece is, and how long the whole video is.
    /// A total of zero means the bar is this file alone.
    private var filmOrigin: Double = 0
    private var pieceLength: Double = 0
    private var filmTotal: Double = 0
    /// Called with a time in the whole video when a drag ends outside this piece.
    var onFilmSeek: ((Double) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        appearance = NSAppearance(named: .darkAqua)
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.62).cgColor

        play.isBordered = false
        play.imagePosition = .imageOnly
        play.target = self
        play.action = #selector(togglePlay)
        play.setAccessibilityLabel("Pause")

        speaker.isBordered = false
        speaker.imagePosition = .imageOnly
        speaker.target = self
        speaker.action = #selector(toggleMute)
        speaker.toolTip = "Mute"

        for label in [elapsed, duration] {
            label.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
            label.textColor = .white
            label.alignment = label === elapsed ? .left : .right
        }
        elapsed.setAccessibilityLabel("Elapsed")
        duration.setAccessibilityLabel("Duration")

        scrubber.controlSize = .small
        scrubber.isContinuous = true
        scrubber.isEnabled = false
        scrubber.target = self
        scrubber.action = #selector(scrubbed)
        scrubber.setAccessibilityLabel("Position")
        scrubber.tracking = { [weak self] active in
            guard let self else { return }
            if active { self.scrubbing = true } else { self.finishScrub() }
        }

        volumeSlider.controlSize = .small
        volumeSlider.isContinuous = true
        volumeSlider.target = self
        volumeSlider.action = #selector(volumeChanged)
        volumeSlider.setAccessibilityLabel("Volume")
        volumeSlider.doubleValue = Double(Self.volume)

        [play, elapsed, scrubber, duration, speaker, volumeSlider].forEach(addSubview)
        showPlaySymbol(paused: false)
        showSpeaker()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func attach(_ player: AVPlayer) {
        self.player = player
        player.volume = Self.volume
        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            let seconds = time.seconds
            Task { @MainActor in self?.note(seconds) }
        }
        statusObserver = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
            let paused = player.timeControlStatus == .paused
            Task { @MainActor in self?.showPlaySymbol(paused: paused) }
        }
        if let item = player.currentItem {
            durationObserver = item.observe(\.duration, options: [.initial, .new]) { [weak self] item, _ in
                let seconds = item.duration.seconds
                Task { @MainActor in self?.noteDuration(seconds) }
            }
        }
    }

    /// The scrubber covers the whole film. `total` of zero leaves the bar on this file alone.
    func bindFilm(origin: Double, piece: Double, total: Double) {
        filmOrigin = origin
        pieceLength = piece
        filmTotal = total
        guard total > 0 else { return }
        duration.stringValue = Self.clock(total)
        scrubber.maxValue = total
        scrubber.isEnabled = true
        guard !scrubbing else { return }
        elapsed.stringValue = Self.clock(origin)
        scrubber.doubleValue = origin
    }

    /// A jump to another piece landed, so the playhead may follow the picture again.
    func releaseScrub() {
        scrubbing = false
    }

    func detach() {
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        timeObserver = nil
        statusObserver = nil
        durationObserver = nil
        player = nil
    }

    /// A click on the bar stays here. A click on the picture behind it pauses and resumes.
    override func mouseDown(with event: NSEvent) {}

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        let tight = bounds.width < 250
        duration.isHidden = tight
        volumeSlider.isHidden = bounds.width < 210
        var x: CGFloat = 4
        play.frame = NSRect(x: x, y: (h - 22) / 2, width: 22, height: 22)
        x = play.frame.maxX + 4
        elapsed.frame = NSRect(x: x, y: (h - 14) / 2, width: 52, height: 14)
        x = elapsed.frame.maxX + 4

        var right = bounds.width - 4
        if !volumeSlider.isHidden {
            volumeSlider.frame = NSRect(x: right - 48, y: (h - 16) / 2, width: 48, height: 16)
            right = volumeSlider.frame.minX - 2
        }
        speaker.frame = NSRect(x: right - 20, y: (h - 20) / 2, width: 20, height: 20)
        right = speaker.frame.minX - 4
        if !duration.isHidden {
            duration.frame = NSRect(x: right - 52, y: (h - 14) / 2, width: 52, height: 14)
            right = duration.frame.minX - 4
        }
        scrubber.frame = NSRect(x: x, y: (h - 16) / 2, width: max(24, right - x), height: 16)
    }

    private func note(_ seconds: Double) {
        if filmTotal <= 0, !scrubber.isEnabled { noteDuration(player?.currentItem?.duration.seconds ?? .nan) }
        guard !scrubbing, seconds.isFinite, seconds >= 0 else { return }
        let shown = filmTotal > 0 ? filmOrigin + seconds : seconds
        elapsed.stringValue = Self.clock(shown)
        guard scrubber.isEnabled else { return }
        scrubber.doubleValue = min(scrubber.maxValue, shown)
    }

    private func noteDuration(_ seconds: Double) {
        guard filmTotal <= 0, seconds.isFinite, seconds > 0 else { return }
        duration.stringValue = Self.clock(seconds)
        scrubber.maxValue = seconds
        scrubber.isEnabled = true
    }

    private func showPlaySymbol(paused: Bool) {
        let name = paused ? "play.fill" : "pause.fill"
        let label = paused ? "Play" : "Pause"
        play.image = Self.symbol(name, label: label)
        play.toolTip = label
        play.setAccessibilityLabel(label)
    }

    private func showSpeaker() {
        let silent = Self.volume <= 0.001
        speaker.image = Self.symbol(silent ? "speaker.slash.fill" : "speaker.wave.2.fill", label: silent ? "Unmute" : "Mute")
        speaker.toolTip = silent ? "Unmute" : "Mute"
        speaker.setAccessibilityLabel(silent ? "Unmute" : "Mute")
    }

    @objc private func togglePlay() {
        guard let player else { return }
        if player.timeControlStatus == .paused { player.play() } else { player.pause() }
    }

    @objc private func scrubbed() {
        seek(to: scrubber.doubleValue, releaseWhenLanded: false)
    }

    /// The last seek of a drag holds the playhead still until it lands, so a time update can't pull it backwards.
    private func finishScrub() {
        scrubbing = true
        seek(to: scrubber.doubleValue, releaseWhenLanded: true)
    }

    private func seek(to seconds: Double, releaseWhenLanded: Bool) {
        guard scrubber.isEnabled, player != nil else {
            scrubbing = false
            return
        }
        let seconds = min(max(0, seconds), scrubber.maxValue)
        elapsed.stringValue = Self.clock(seconds)
        if filmTotal > 0 {
            let local = seconds - filmOrigin
            let inside = local >= -0.05 && local <= pieceLength + 0.05
            if !inside {
                if releaseWhenLanded { onFilmSeek?(seconds) }
                return
            }
            seekPlayer(to: min(max(0, local), pieceLength), releaseWhenLanded: releaseWhenLanded)
            return
        }
        seekPlayer(to: seconds, releaseWhenLanded: releaseWhenLanded)
    }

    private func seekPlayer(to seconds: Double, releaseWhenLanded: Bool) {
        guard let player else {
            scrubbing = false
            return
        }
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        let tolerance = CMTime(seconds: 0.25, preferredTimescale: 600)
        seekID += 1
        let seekID = seekID
        player.seek(to: time, toleranceBefore: tolerance, toleranceAfter: tolerance) { [weak self] _ in
            guard releaseWhenLanded else { return }
            Task { @MainActor in
                guard let self, seekID == self.seekID else { return }
                self.scrubbing = false
            }
        }
    }

    @objc private func toggleMute() {
        if volumeSlider.doubleValue > 0.001 {
            Self.unmuted = Float(volumeSlider.doubleValue)
            volumeSlider.doubleValue = 0
        } else {
            volumeSlider.doubleValue = Double(max(Self.unmuted, 0.2))
        }
        volumeChanged()
    }

    @objc private func volumeChanged() {
        let value = Float(min(1, max(0, volumeSlider.doubleValue)))
        if value > 0.001 { Self.unmuted = value }
        Self.volume = value
        player?.volume = value
        showSpeaker()
    }

    private static func clock(_ seconds: Double) -> String {
        let total = Int(seconds.rounded(.down))
        let s = total % 60
        let m = (total / 60) % 60
        let h = total / 3600
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }

    private static func symbol(_ name: String, label: String) -> NSImage {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: label) ?? NSImage()
        let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        return image.withSymbolConfiguration(config) ?? image
    }
}

/// Reports the start and end of a drag, so the playhead isn't pulled back while it's being moved.
@MainActor
private enum FilmPlaybackError: Error {
    case failed
}

/// Pieces of one film, filled as each download finishes. Touched only on the main actor.
private final class FilmGather: @unchecked Sendable {
    var slots: [Data?]
    var left: Int

    init(count: Int) {
        slots = Array(repeating: nil, count: count)
        left = count
    }
}

private final class TrackingSlider: NSSlider {
    var tracking: ((Bool) -> Void)?

    override func mouseDown(with event: NSEvent) {
        tracking?(true)
        super.mouseDown(with: event)
        tracking?(false)
    }
}

/// One image, GIF or video in a message. Shows a placeholder at the final size until the still arrives,
/// so nothing moves; GIFs animate on hover (or when visible), videos play on click.
@MainActor
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
    /// A private image that couldn't be downloaded or decrypted.
    private var loadFailed = false

    // Playback state; all torn down by stopPlayback().
    private var animator: GIFAnimator?
    private var playerView: PlayerView?
    private var controls: VideoControls?
    private var player: AVPlayer?
    private var looper: AVPlayerLooper?
    private var loader: StreamingLoader?
    /// A decrypted private video being played from memory.
    private var memoryLoader: MemoryAssetLoader?
    /// Every piece of a split film, kept until playback stops so the join never waits on a download.
    private var filmLoaders: [MemoryAssetLoader] = []
    /// The same pieces, in order, when they could not be joined into one item.
    private var filmBytes: [Data] = []
    /// Waiting for a private video to download and decrypt.
    private var videoToken: PrivateImageLoader.Token?
    /// The piece `videoToken` belongs to, so a seek can cancel that download.
    private var loadingPiece: PrivateImage?
    /// Downloads started for a whole film, so stopping can cancel each one.
    private var filmDownloads: [(PrivateImageLoader.Token, PrivateImage)] = []
    /// A split private video. Empty for anything else. One composition plays every piece; a failed join falls back to one piece at a time.
    private var filmQueue: [PrivateImage] = []
    private var filmAt = 0
    /// The pieces were loaded up front and joined into the player item now showing.
    private var composedFilm = false
    /// Joining the pieces failed, so they play one after another from `filmBytes`.
    private var pieceByPiece = false
    /// A whole-film download is in flight. A second click must not start another.
    private var filmOpening = false
    /// Bumps every time a piece is asked for, so a slow download can't start after a seek or a stop.
    private var playGeneration = 0
    /// Where to start inside the piece that's about to play, when a drag landed past the current one.
    private var pendingSeek: Double = 0
    /// The next piece, decrypted while this one plays, so the join doesn't wait.
    private var heldNext: (part: Int, data: Data)?
    private var nextToken: PrivateImageLoader.Token?
    private var nextPiece: PrivateImage?
    /// The part the row shows, so a callback from a later piece is dropped if the row was reused.
    private var filmAnchor: String?
    /// Rebuilds a film from the messages loaded now. Nil when this row has no film.
    var filmResolver: ((PrivateImage) -> [PrivateImage])?
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
        loadFailed = false
        imageView.image = nil
        toolTip = item.open?.host
        if let request = item.request, !item.gated || Self.revealed.contains(request) {
            load(request)
        }
        switch item.kind {
        case .privateImage: setAccessibilityLabel("Private image")
        case .privateVideo: setAccessibilityLabel("Private video")
        default: setAccessibilityLabel(nil)
        }
        refreshOverlays()
        if isAnimatedGIF, PlaybackCoordinator.gifsPlayWhenVisible, !item.gated { startGIF() }
    }

    /// Called when the row is reused or scrolled away: stops downloads and playback.
    func cancel() {
        if let token, case .privateImage(let image)? = item?.kind {
            PrivateImageLoader.shared.cancel(token, for: image)
        } else if let token, let request = item?.request {
            MediaLoader.shared.cancel(token, for: request)
        }
        token = nil
        stopPlayback()
    }

    // MARK: - Stills

    private func load(_ request: URL) {
        let size = bounds.size == .zero ? item?.frame.size ?? .zero : bounds.size
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        if case .privateImage(let image)? = item?.kind {
            token = PrivateImageLoader.shared.load(image, pointSize: size, scale: scale) { [weak self] loaded in
                guard let self, self.item?.request == request else { return }
                self.token = nil
                self.still = loaded
                self.imageView.image = loaded
                self.loadFailed = loaded == nil
                self.refreshOverlays()
            }
            return
        }
        token = MediaLoader.shared.load(request, pointSize: size, scale: scale) { [weak self] image in
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
        switch item?.kind {
        case .video, .privateVideo: return true
        default: return false
        }
    }

    // MARK: - Playback

    private func startGIF() {
        guard let item, !isPlaying else { return }
        switch item.kind {
        case .gif(let url?):
            let animator = GIFAnimator()
            self.animator = animator
            PlaybackCoordinator.shared.startGIF(self)
            let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
            let maxPixel = max(1, Int((max(bounds.width, bounds.height) * scale).rounded(.up)))
            animator.start(url, maxPixel: maxPixel, frame: { [weak self] frame in
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
        guard !isPlaying else { return }
        if case .privateVideo(let video)? = item?.kind {
            startPrivateVideo(video)
            return
        }
        guard case .video(let urls) = item?.kind else { return }
        startPlayer(urls, looping: false, muted: false)
        PlaybackCoordinator.shared.startVideo(self)
        refreshOverlays()
    }

    /// Downloads and decrypts a private video (only from a trusted key), then plays it from memory. Its first
    /// frame stays as the still afterwards.
    private func startPrivateVideo(_ video: PrivateImage) {
        guard video.trusted, video.attachment != nil, videoToken == nil, !filmOpening else { return }
        if video.filmID != nil {
            guard let fresh = filmResolver?(video), fresh.first?.attachment != nil else { return }
            filmQueue = fresh
        } else {
            filmQueue = [video]
        }
        filmAt = 0
        filmAnchor = video.cacheKey
        playCurrentPart()
    }

    /// Decrypts the piece at `filmAt` and plays it. A film of several pieces is decrypted in full first.
    /// A player that's already up keeps its picture until the next piece is ready.
    private func playCurrentPart() {
        if filmQueue.count > 1, filmBytes.isEmpty, !pieceByPiece, !composedFilm, player == nil {
            playWholeFilm()
            return
        }
        guard filmQueue.indices.contains(filmAt) else {
            stopPlayback()
            return
        }
        let video = filmQueue[filmAt]
        let anchor = filmAnchor
        guard video.trusted, video.attachment != nil else {
            showFailure()
            return
        }
        if let loadingPiece, let videoToken {
            PrivateImageLoader.shared.cancel(videoToken, for: loadingPiece)
        }
        self.videoToken = nil
        loadingPiece = nil
        playGeneration += 1
        let generation = playGeneration
        if filmBytes.indices.contains(filmAt) {
            beginPiece(filmBytes[filmAt], generation: generation, anchor: anchor)
            return
        }
        if let held = heldNext, held.part == filmAt {
            heldNext = nil
            beginPiece(held.data, generation: generation, anchor: anchor)
            return
        }
        label.stringValue = filmQueue.count > 1 ? "Decrypting part \(filmAt + 1) of \(filmQueue.count)…" : "Decrypting…"
        addSubview(label)
        if let controls { addSubview(controls) }
        layoutLabel()
        loadingPiece = video
        videoToken = PrivateImageLoader.shared.data(for: video) { [weak self] data in
            guard let self, self.playGeneration == generation,
                  case .privateVideo(let current)? = self.item?.kind, current.cacheKey == anchor else { return }
            self.videoToken = nil
            self.loadingPiece = nil
            guard let data else {
                self.showFailure()
                return
            }
            self.beginPiece(data, generation: generation, anchor: anchor)
        }
    }

    /// Decrypts every piece before the first frame, then plays them as one film.
    private func playWholeFilm() {
        let queue = filmQueue
        guard queue.count > 1, queue.allSatisfy({ $0.trusted && $0.attachment != nil }) else {
            pieceByPiece = true
            playCurrentPart()
            return
        }
        filmOpening = true
        playGeneration += 1
        let generation = playGeneration
        let anchor = filmAnchor
        label.stringValue = "Decrypting \(queue.count) parts…"
        addSubview(label)
        layoutLabel()
        let gathered = FilmGather(count: queue.count)
        for (index, video) in queue.enumerated() {
            guard playGeneration == generation else { return }
            guard let token = PrivateImageLoader.shared.data(for: video, completion: { [weak self] data in
                guard let self, self.playGeneration == generation,
                      case .privateVideo(let current)? = self.item?.kind, current.cacheKey == anchor else { return }
                guard let data else {
                    self.showFailure()
                    return
                }
                gathered.slots[index] = data
                gathered.left -= 1
                guard gathered.left == 0 else { return }
                let parts = gathered.slots.compactMap { $0 }
                guard parts.count == queue.count, self.playGeneration == generation else {
                    self.showFailure()
                    return
                }
                self.filmBytes = parts
                for piece in queue { PrivateImageLoader.shared.discard(piece) }
                self.filmDownloads = []
                Task { @MainActor in
                    await self.compose(parts, generation: generation, anchor: anchor)
                }
            }) else { continue }
            filmDownloads.append((token, video))
        }
    }

    /// One player item for the whole film. Its clock is the film clock, so the bar needs no per-piece offset.
    @MainActor
    private func compose(_ parts: [Data], generation: Int, anchor: String?) async {
        guard playGeneration == generation else { return }
        do {
            let composition = AVMutableComposition()
            guard let picture = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw FilmPlaybackError.failed
            }
            var soundtrack: AVMutableCompositionTrack?
            var loaders: [MemoryAssetLoader] = []
            var cursor = CMTime.zero
            for data in parts {
                guard playGeneration == generation else { return }
                let loader = MemoryAssetLoader(data: data)
                loaders.append(loader)
                let asset = loader.makeAsset()
                let videoTracks = try await asset.loadTracks(withMediaType: .video)
                guard let source = videoTracks.first else { throw FilmPlaybackError.failed }
                let videoRange = try await source.load(.timeRange)
                if cursor == .zero {
                    picture.preferredTransform = try await source.load(.preferredTransform)
                }
                try picture.insertTimeRange(videoRange, of: source, at: cursor)
                if let audio = try await asset.loadTracks(withMediaType: .audio).first,
                   let sound = soundtrack ?? composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                    soundtrack = sound
                    let audioRange = try await audio.load(.timeRange)
                    try? sound.insertTimeRange(audioRange, of: audio, at: cursor)
                }
                cursor = CMTimeAdd(cursor, videoRange.duration)
            }
            guard playGeneration == generation else { return }
            filmLoaders = loaders
            composedFilm = true
            filmOpening = false
            startPlayer(asset: composition, retaining: nil, looping: false, muted: false)
            player?.automaticallyWaitsToMinimizeStalling = false
            PlaybackCoordinator.shared.startVideo(self)
            refreshOverlays()
            guard filmQueue.first?.cacheKey == anchor else { return }
            let generator = AVAssetImageGenerator(asset: composition)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = bounds.size.applying(CGAffineTransform(scaleX: 2, y: 2))
            generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: .zero)]) { [weak self] _, image, _, _, _ in
                guard let image else { return }
                let still = Handoff(value: image)
                Task { @MainActor [weak self] in
                    guard let self, case .privateVideo(let current)? = self.item?.kind, current.cacheKey == anchor else { return }
                    self.still = NSImage(cgImage: still.value, size: self.bounds.size)
                    if !self.isPlaying { self.imageView.image = self.still }
                }
            }
        } catch {
            guard playGeneration == generation else { return }
            filmLoaders = []
            composedFilm = false
            filmOpening = false
            pieceByPiece = true
            playCurrentPart()
        }
    }

    /// Where `index` starts in the film, when every piece recorded its length.
    private func filmOffset(_ index: Int) -> Double {
        filmQueue.prefix(index).reduce(0) { $0 + $1.filmSpan }
    }

    /// The whole film, or zero when a piece was sent before lengths were kept.
    private var filmLength: Double {
        guard filmQueue.count > 1, filmQueue.allSatisfy({ $0.filmSpan > 0.05 }) else { return 0 }
        return filmQueue.reduce(0) { $0 + $1.filmSpan }
    }

    private func filmIndex(at time: Double) -> Int? {
        guard filmLength > 0 else { return nil }
        var cursor = 0.0
        for (index, video) in filmQueue.enumerated() {
            if time < cursor + video.filmSpan - 0.001 || index == filmQueue.count - 1 { return index }
            cursor += video.filmSpan
        }
        return nil
    }

    private func wireFilmControls() {
        let total = filmLength
        let piece = filmQueue.indices.contains(filmAt) ? filmQueue[filmAt].filmSpan : 0
        controls?.onFilmSeek = total > 0 ? { [weak self] time in self?.jumpFilm(to: time) } : nil
        controls?.bindFilm(origin: filmOffset(filmAt), piece: piece, total: total)
    }

    /// Starts this piece's bytes. The first piece builds the player; a later one keeps it and moves the clock.
    private func beginPiece(_ data: Data, generation: Int, anchor: String?) {
        guard playGeneration == generation else { return }
        let loader = MemoryAssetLoader(data: data)
        let asset = loader.makeAsset()
        memoryLoader = loader
        let startAt = pendingSeek
        pendingSeek = 0
        if player == nil {
            startPlayer(asset: asset, retaining: nil, looping: false, muted: false)
        } else {
            replacePiece(with: asset)
        }
        wireFilmControls()
        PlaybackCoordinator.shared.startVideo(self)
        if startAt > 0.25 {
            let time = CMTime(seconds: startAt, preferredTimescale: 600)
            let tolerance = CMTime(seconds: 0.25, preferredTimescale: 600)
            player?.seek(to: time, toleranceBefore: tolerance, toleranceAfter: tolerance) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.playGeneration == generation else { return }
                    self.controls?.releaseScrub()
                    self.player?.play()
                    self.refreshOverlays()
                }
            }
        } else {
            controls?.releaseScrub()
            player?.play()
            refreshOverlays()
        }
        prefetchNext()
        guard filmAt == 0 else { return }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = bounds.size.applying(CGAffineTransform(scaleX: 2, y: 2))
        generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: .zero)]) { [weak self] _, image, _, _, _ in
            guard let image else { return }
            let still = Handoff(value: image)
            Task { @MainActor [weak self] in
                guard let self, case .privateVideo(let current)? = self.item?.kind, current.cacheKey == anchor else { return }
                self.still = NSImage(cgImage: still.value, size: self.bounds.size)
                if !self.isPlaying { self.imageView.image = self.still }
            }
        }
    }

    /// The next file, in the player that's already on screen, so the clock doesn't go back to the start.
    private func replacePiece(with asset: AVAsset) {
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = 5
        guard let player else { return }
        player.replaceCurrentItem(with: item)
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.finishedPart() }
        }
        controls?.detach()
        controls?.attach(player)
        statusObservation = player.observe(\.currentItem?.status, options: [.new]) { [weak self] player, _ in
            guard player.currentItem?.status == .failed else { return }
            Task { @MainActor in self?.showFailure() }
        }
    }

    /// A drag ended in another piece. That piece starts at the matching moment.
    /// A joined film is already one timeline, so the drag is a normal seek.
    private func jumpFilm(to absolute: Double) {
        if composedFilm {
            let time = CMTime(seconds: max(0, absolute), preferredTimescale: 600)
            let tolerance = CMTime(seconds: 0.25, preferredTimescale: 600)
            player?.seek(to: time, toleranceBefore: tolerance, toleranceAfter: tolerance) { [weak self] _ in
                Task { @MainActor in self?.controls?.releaseScrub() }
            }
            return
        }
        guard let index = filmIndex(at: absolute), filmQueue.indices.contains(index) else {
            controls?.releaseScrub()
            return
        }
        if index == filmAt {
            let local = absolute - filmOffset(index)
            let time = CMTime(seconds: max(0, local), preferredTimescale: 600)
            let tolerance = CMTime(seconds: 0.25, preferredTimescale: 600)
            player?.seek(to: time, toleranceBefore: tolerance, toleranceAfter: tolerance) { [weak self] _ in
                Task { @MainActor in self?.controls?.releaseScrub() }
            }
            return
        }
        if filmQueue.indices.contains(filmAt) { PrivateImageLoader.shared.discard(filmQueue[filmAt]) }
        filmAt = index
        pendingSeek = max(0, absolute - filmOffset(index))
        if heldNext?.part != index { heldNext = nil }
        playCurrentPart()
    }

    /// Decrypts the following piece while this one plays. A film loaded up front has nothing left to fetch.
    private func prefetchNext() {
        if filmBytes.count == filmQueue.count { return }
        let next = filmAt + 1
        guard filmQueue.indices.contains(next) else { return }
        if heldNext?.part == next { return }
        if let nextToken, let nextPiece {
            PrivateImageLoader.shared.cancel(nextToken, for: nextPiece)
        }
        self.nextToken = nil
        let video = filmQueue[next]
        nextPiece = video
        nextToken = PrivateImageLoader.shared.data(for: video) { [weak self] data in
            guard let self, let data, self.filmAt + 1 == next else { return }
            self.heldNext = (next, data)
            self.nextToken = nil
        }
    }

    /// The piece ended. The chain is read again, so a piece that arrived while this one played can follow.
    /// A joined film has no next piece: the player item was the whole film.
    /// A missing index still stops playback. The player stays up, so the clock keeps its place in the film.
    private func finishedPart() {
        if composedFilm {
            stopPlayback()
            return
        }
        let played = filmQueue.indices.contains(filmAt) ? filmQueue[filmAt] : nil
        if let played { PrivateImageLoader.shared.discard(played) }
        let anchor = filmQueue.first
        let fresh: [PrivateImage]
        if let anchor, anchor.filmID != nil, let resolved = filmResolver?(anchor) {
            fresh = resolved
        } else {
            fresh = filmQueue
        }
        let next = filmAt + 1
        if fresh.indices.contains(next), fresh[next].attachment != nil {
            filmQueue = fresh
            filmAt = next
            pendingSeek = 0
            playCurrentPart()
        } else {
            stopPlayback()
        }
    }

    private func startPlayer(_ urls: [URL], looping: Bool, muted: Bool) {
        let loader = StreamingLoader(sources: urls)
        guard let asset = loader.makeAsset() else {
            showFailure()
            return
        }
        startPlayer(asset: asset, retaining: loader, looping: looping, muted: muted)
    }

    private func startPlayer(asset: AVAsset, retaining loader: StreamingLoader?, looping: Bool, muted: Bool) {
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
                Task { @MainActor in self?.finishedPart() }
            }
        }
        player.isMuted = muted
        statusObservation = player.observe(\.currentItem?.status, options: [.new]) { [weak self] player, _ in
            guard player.currentItem?.status == .failed else { return }
            Task { @MainActor in self?.showFailure() }
        }

        let view = PlayerView(frame: bounds)
        view.autoresizingMask = [.width, .height]
        view.playerLayer.player = player
        addSubview(view, positioned: .above, relativeTo: imageView)
        playerView = view
        self.player = player
        self.loader = loader
        if !looping {
            let bar = VideoControls(frame: NSRect(x: 0, y: bounds.height - VideoControls.barHeight,
                                                  width: bounds.width, height: VideoControls.barHeight))
            bar.attach(player)
            addSubview(bar, positioned: .above, relativeTo: view)
            controls = bar
        }
        player.play()
    }

    func stopPlayback() {
        endPlayback(advancing: false)
    }

    /// `advancing` keeps the film queue so the next piece can start. The piece that just played is released.
    /// `keepFilm` leaves the decrypted pieces in place so a joined film can fall back to one piece at a time.
    private func endPlayback(advancing: Bool, keepFilm: Bool = false) {
        playGeneration += 1
        for download in filmDownloads {
            PrivateImageLoader.shared.cancel(download.0, for: download.1)
        }
        filmDownloads = []
        filmLoaders = []
        composedFilm = false
        filmOpening = false
        if !keepFilm {
            filmBytes = []
            pieceByPiece = false
        }
        if let videoToken {
            let video = loadingPiece ?? (filmQueue.indices.contains(filmAt) ? filmQueue[filmAt] : nil)
            if let video {
                PrivateImageLoader.shared.cancel(videoToken, for: video)
            } else if case .privateVideo(let video)? = item?.kind {
                PrivateImageLoader.shared.cancel(videoToken, for: video)
            }
            self.videoToken = nil
        }
        loadingPiece = nil
        if let nextToken, let nextPiece {
            PrivateImageLoader.shared.cancel(nextToken, for: nextPiece)
        }
        nextToken = nil
        nextPiece = nil
        heldNext = nil
        pendingSeek = 0
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        statusObservation = nil
        endObserver = nil
        animator?.cancel()
        animator = nil
        controls?.detach()
        controls?.removeFromSuperview()
        controls = nil
        player?.pause()
        looper?.disableLooping()
        player?.replaceCurrentItem(with: nil)
        loader?.cancelAll()
        memoryLoader = nil
        playerView?.removeFromSuperview()
        playerView = nil
        player = nil
        looper = nil
        loader = nil
        if keepFilm {
            imageView.image = still
            PlaybackCoordinator.shared.stopped(self)
            refreshOverlays()
            return
        }
        if !advancing {
            if filmQueue.indices.contains(filmAt) { PrivateImageLoader.shared.discard(filmQueue[filmAt]) }
            filmQueue = []
            filmAt = 0
            filmAnchor = nil
        }
        imageView.image = still
        PlaybackCoordinator.shared.stopped(self)
        refreshOverlays()
    }

    private func showFailure() {
        // A joined film that won't play still has every piece decrypted, so they can play one after another.
        if composedFilm, !pieceByPiece, filmBytes.count > 1 {
            pieceByPiece = true
            endPlayback(advancing: true, keepFilm: true)
            filmAt = 0
            playCurrentPart()
            return
        }
        stopPlayback()
        label.stringValue = item?.open == nil ? "Couldn't play this video" : "Couldn't play this here · ↗ opens it"
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
        } else if loadFailed {
            label.stringValue = "Couldn't load this image"
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
        // Private videos have nothing to open: they exist decrypted only here.
        openButton.isHidden = !(isVideo && isPlaying && item.open != nil)
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
        controls?.frame = NSRect(x: 0, y: bounds.height - VideoControls.barHeight,
                                 width: bounds.width, height: VideoControls.barHeight)
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
            // Click plays. While it plays, a click on the picture pauses and resumes; the bar seeks and sets volume.
            if let player {
                if player.timeControlStatus == .paused { player.play() } else { player.pause() }
            } else {
                startVideo()
            }
        } else if case .privateImage(let image) = item.kind, still != nil {
            PrivateImagePreview.show(image, from: window)
        } else if let open = item.open {
            LinkOpener.open(open, shownText: nil, from: window)
        }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

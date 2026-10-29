import AppKit
import DuhcordCore

/// Opens profiles, the way the official client does: clicking someone shows a small card next to where you
/// clicked (their banner, picture, names, status, bio, roles, mutual friends and servers, and a message field);
/// clicking the picture on the card opens their full profile in its own window (activity, board, mutual friends
/// and mutual servers).
///
/// Profiles are fetched when opened and kept for a couple of minutes, so clicking around doesn't refetch.
@MainActor
final class ProfileController {
    enum Tab: Int, CaseIterable {
        case activity, board, mutualFriends, mutualServers
    }

    /// A mutual server was clicked.
    var onOpenGuild: ((Snowflake) -> Void)?
    /// "Message" in a full profile: show the DM with this person.
    var onOpenDM: ((Snowflake) -> Void)?
    /// True while the app is locked because Discord can't be reached: nothing opens then.
    var isLocked: () -> Bool = { false }

    let session: DiscordSession
    private var popover: NSPopover?
    private var card: ProfileCardViewController?
    private var windows: [Snowflake: ProfileWindowController] = [:]

    private struct Key: Hashable {
        let userID: Snowflake
        let guildID: Snowflake?
    }
    private var profiles: [Key: (profile: UserProfile, fetched: Date)] = [:]
    private var loading: [Key: [(Result<UserProfile, Error>) -> Void]] = [:]
    private static let profileLifetime: TimeInterval = 120

    /// Game and app names and icons, for activities and board widgets. Asked for once each per session.
    private(set) var applications: [Snowflake: PartialApplication] = [:]
    private var requestedApplications: Set<Snowflake> = []

    init(session: DiscordSession) {
        self.session = session
    }

    // MARK: - Opening

    /// Shows someone's profile card beside `rect` in `view`. `guildID` is the server they were clicked in,
    /// which adds their roles and server profile.
    func showCard(userID: Snowflake, guildID: Snowflake?, relativeTo rect: NSRect, of view: NSView) {
        popover?.close()
        guard !isLocked() else { return }
        let card = ProfileCardViewController(controller: self, userID: userID, guildID: guildID)
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = card
        popover.animates = true
        self.card = card
        self.popover = popover
        popover.show(relativeTo: rect, of: view, preferredEdge: .maxX)
        if let guildID { session.requestPresence(of: userID, guildID: guildID) }
    }

    /// Opens (or brings forward) someone's full profile.
    func showFullProfile(userID: Snowflake, guildID: Snowflake?, tab: Tab = .activity) {
        popover?.close()
        guard !isLocked() else { return }
        if let existing = windows[userID] {
            existing.select(tab)
            existing.showWindow(nil)
            return
        }
        let window = ProfileWindowController(controller: self, userID: userID, guildID: guildID, tab: tab)
        window.onClose = { [weak self] in self?.windows[userID] = nil }
        windows[userID] = window
        window.showWindow(nil)
        if let guildID { session.requestPresence(of: userID, guildID: guildID) }
    }

    func closeCard() { popover?.close() }

    /// Closes the card and every full profile (the app is locking).
    func closeAll() {
        popover?.close()
        windows.values.forEach { $0.close() }
    }

    // MARK: - Data

    func cachedProfile(userID: Snowflake, guildID: Snowflake?) -> UserProfile? {
        guard let entry = profiles[Key(userID: userID, guildID: guildID)],
              Date().timeIntervalSince(entry.fetched) < Self.profileLifetime else { return nil }
        return entry.profile
    }

    func loadProfile(userID: Snowflake, guildID: Snowflake?, completion: @escaping (Result<UserProfile, Error>) -> Void) {
        if let cached = cachedProfile(userID: userID, guildID: guildID) {
            completion(.success(cached))
            return
        }
        let key = Key(userID: userID, guildID: guildID)
        // Two views asking at once share one request.
        if loading[key] != nil {
            loading[key]?.append(completion)
            return
        }
        loading[key] = [completion]
        Task { @MainActor [weak self, session] in
            let result: Result<UserProfile, Error>
            do {
                result = .success(try await session.rest.profile(of: userID, guildID: guildID))
            } catch {
                result = .failure(error)
            }
            guard let self else { return }
            if case .success(let profile) = result {
                // Only keep a handful; profiles are refetched after a couple of minutes anyway.
                if self.profiles.count > 30 { self.profiles = self.profiles.filter { Date().timeIntervalSince($0.value.fetched) < Self.profileLifetime } }
                self.profiles[key] = (profile, Date())
            }
            let waiting = self.loading.removeValue(forKey: key) ?? []
            waiting.forEach { $0(result) }
        }
    }

    /// Fetches names and icons for apps we haven't looked up yet, then calls `completion` if any arrived.
    func loadApplications(_ ids: [Snowflake], completion: @escaping () -> Void) {
        let missing = Array(Set(ids).subtracting(requestedApplications))
        guard !missing.isEmpty else { return }
        requestedApplications.formUnion(missing)
        Task { @MainActor [weak self, session] in
            // The endpoint takes a list; keep each request a reasonable size.
            var found: [PartialApplication] = []
            for start in stride(from: 0, to: missing.count, by: 50) {
                let batch = Array(missing[start..<min(start + 50, missing.count)])
                if let apps = try? await session.rest.applications(batch) { found += apps }
            }
            guard let self, !found.isEmpty else { return }
            for app in found { self.applications[app.id] = app }
            completion()
        }
    }

    /// Someone's status or activities changed: refresh their open card or window.
    func presenceChanged(_ userID: Snowflake) {
        if card?.userID == userID { card?.render() }
        windows[userID]?.render()
    }
}

// MARK: - Shared pieces

extension NSColor {
    /// A colour Discord sends as 0xRRGGBB.
    convenience init(discordColor value: Int) {
        self.init(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                  blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }
}

@MainActor
enum ProfileText {
    static func status(_ status: Presence.Status) -> String {
        switch status {
        case .online: return "Online"
        case .idle: return "Idle"
        case .dnd: return "Do Not Disturb"
        case .offline: return "Offline"
        }
    }

    static func statusColor(_ status: Presence.Status) -> NSColor {
        switch status {
        case .online: return .systemGreen
        case .idle: return .systemYellow
        case .dnd: return .systemRed
        case .offline: return .systemGray
        }
    }

    /// The bio as Markdown, with links left as plain text: a link in someone's bio shouldn't open with one click
    /// from a field that doesn't run it past LinkOpener's checks.
    static func bio(_ text: String, store: Store) -> NSAttributedString {
        let resolver = Markdown.Resolver(user: { store.user($0)?.displayName }, channel: { store.channel($0)?.displayName })
        let rendered = NSMutableAttributedString(attributedString: Theme.render(Markdown.parse(text, resolver: resolver)))
        rendered.removeAttribute(.link, range: NSRange(location: 0, length: rendered.length))
        return rendered
    }

    static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    static let clockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.doesRelativeDateFormatting = true
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()

    /// When the account was made, read from its ID.
    static func accountCreated(_ userID: Snowflake) -> Date {
        Date(timeIntervalSince1970: TimeInterval((userID.snowflakeValue >> 22) + 1_420_070_400_000) / 1000)
    }
}

/// The banner, picture and status dot at the top of a card or full profile.
@MainActor
final class ProfileHeaderView: NSView {
    var onAvatarClick: (() -> Void)?

    private let banner = RemoteImageView()
    private let avatar = RemoteImageView()
    private let ring = NSView()
    private let statusDot = NSView()
    private let avatarSize: CGFloat
    private var bannerHeight: NSLayoutConstraint!
    private let fullBannerHeight: CGFloat

    init(avatarSize: CGFloat, bannerHeight: CGFloat) {
        self.avatarSize = avatarSize
        fullBannerHeight = bannerHeight
        super.init(frame: .zero)
        banner.fillsFrame = true
        banner.wantsLayer = true
        avatar.cornerRadius = avatarSize / 2
        ring.wantsLayer = true
        ring.layer?.cornerRadius = avatarSize / 2 + 4
        statusDot.wantsLayer = true
        let dotSize = round(avatarSize * 0.22)
        statusDot.layer?.cornerRadius = dotSize / 2
        statusDot.layer?.borderWidth = 3
        [banner, ring, avatar, statusDot].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }
        self.bannerHeight = banner.heightAnchor.constraint(equalToConstant: bannerHeight)
        NSLayoutConstraint.activate([
            banner.topAnchor.constraint(equalTo: topAnchor),
            banner.leadingAnchor.constraint(equalTo: leadingAnchor),
            banner.trailingAnchor.constraint(equalTo: trailingAnchor),
            self.bannerHeight,
            avatar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Spacing.edge),
            avatar.centerYAnchor.constraint(equalTo: banner.bottomAnchor),
            avatar.widthAnchor.constraint(equalToConstant: avatarSize),
            avatar.heightAnchor.constraint(equalToConstant: avatarSize),
            ring.centerXAnchor.constraint(equalTo: avatar.centerXAnchor),
            ring.centerYAnchor.constraint(equalTo: avatar.centerYAnchor),
            ring.widthAnchor.constraint(equalToConstant: avatarSize + 8),
            ring.heightAnchor.constraint(equalToConstant: avatarSize + 8),
            statusDot.widthAnchor.constraint(equalToConstant: dotSize),
            statusDot.heightAnchor.constraint(equalToConstant: dotSize),
            statusDot.trailingAnchor.constraint(equalTo: avatar.trailingAnchor, constant: -1),
            statusDot.bottomAnchor.constraint(equalTo: avatar.bottomAnchor, constant: -1),
            bottomAnchor.constraint(equalTo: avatar.bottomAnchor),
        ])
        let click = NSClickGestureRecognizer(target: self, action: #selector(avatarClicked))
        avatar.addGestureRecognizer(click)
        avatar.setAccessibilityElement(true)
        avatar.setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private var accent: Int?
    private var status: Presence.Status = .offline

    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            // The ring and the dot's border match what's behind the card, so the picture looks cut out.
            ring.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            statusDot.layer?.borderColor = NSColor.windowBackgroundColor.cgColor
            statusDot.layer?.backgroundColor = ProfileText.statusColor(status).cgColor
            banner.layer?.backgroundColor = (accent.map { NSColor(discordColor: $0) } ?? NSColor.quaternaryLabelColor).cgColor
        }
    }

    /// `bannerURL` nil shows the accent colour, in a shorter strip, as the official client does.
    func configure(bannerURL: URL?, accentColor: Int?, avatarURL: URL?, status: Presence.Status, avatarHint: String?) {
        accent = accentColor
        self.status = status
        bannerHeight.constant = bannerURL == nil ? round(fullBannerHeight * 0.6) : fullBannerHeight
        let width = max(bounds.width, 300)
        banner.setImage(bannerURL, pointSize: NSSize(width: width, height: width / 2.5))
        avatar.setImage(avatarURL, pointSize: NSSize(width: avatarSize, height: avatarSize))
        statusDot.toolTip = ProfileText.status(status)
        statusDot.setAccessibilityLabel(ProfileText.status(status))
        avatar.toolTip = avatarHint
        avatar.setAccessibilityLabel(avatarHint ?? "Profile picture")
        updateColors()
    }

    @objc private func avatarClicked() { onAvatarClick?() }

    override func resetCursorRects() {
        if onAvatarClick != nil { addCursorRect(avatar.frame, cursor: .pointingHand) }
    }
}

/// A rounded tag: a role (with its colour dot) or a game widget tag.
@MainActor
final class PillView: NSView {
    private let label = NSTextField(labelWithString: "")
    private let dot = NSView()
    private let dotColor: NSColor?

    init(text: String, dotColor: NSColor? = nil) {
        self.dotColor = dotColor
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Theme.Radius.small
        label.stringValue = text
        label.font = Theme.captionFont
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
        if dotColor != nil {
            dot.wantsLayer = true
            dot.layer?.cornerRadius = 4
            addSubview(dot)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(text)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.15).cgColor
        dot.layer?.backgroundColor = dotColor?.cgColor
    }

    private var dotSpace: CGFloat { dotColor == nil ? 0 : 8 + 5 }

    var naturalSize: NSSize {
        let text = label.fittingSize
        return NSSize(width: ceil(text.width) + dotSpace + 12, height: ceil(text.height) + 4)
    }

    override func layout() {
        super.layout()
        if dotColor != nil { dot.frame = NSRect(x: 6, y: (bounds.height - 8) / 2, width: 8, height: 8) }
        let text = label.fittingSize
        label.frame = NSRect(x: 6 + dotSpace, y: (bounds.height - text.height) / 2,
                             width: max(0, bounds.width - 12 - dotSpace), height: text.height)
    }
}

/// Lays pills out in rows, wrapping at its width.
@MainActor
final class FlowView: NSView {
    var pills: [PillView] = [] {
        didSet {
            oldValue.forEach { $0.removeFromSuperview() }
            pills.forEach { addSubview($0) }
            invalidateIntrinsicContentSize()
            needsLayout = true
        }
    }

    override var isFlipped: Bool { true }

    private func frames(for width: CGFloat) -> [NSRect] {
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        return pills.map { pill in
            var size = pill.naturalSize
            size.width = min(size.width, width)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + Theme.Spacing.tight
                rowHeight = 0
            }
            defer {
                x += size.width + Theme.Spacing.tight
                rowHeight = max(rowHeight, size.height)
            }
            return NSRect(origin: NSPoint(x: x, y: y), size: size)
        }
    }

    override var intrinsicContentSize: NSSize {
        let height = frames(for: bounds.width > 0 ? bounds.width : 260).map(\.maxY).max() ?? 0
        return NSSize(width: NSView.noIntrinsicMetric, height: height)
    }

    private var laidOutHeight: CGFloat = -1

    override func layout() {
        super.layout()
        let placed = frames(for: bounds.width)
        for (pill, frame) in zip(pills, placed) { pill.frame = frame }
        // The height depends on the width, which is only known now.
        let height = placed.map(\.maxY).max() ?? 0
        if height != laidOutHeight {
            laidOutHeight = height
            invalidateIntrinsicContentSize()
        }
    }
}

/// A clickable row in a list: picture, title and an optional subtitle (mutual friends and servers).
@MainActor
final class ProfileRowButton: NSButton {
    private let picture = RemoteImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let onClick: () -> Void

    init(imageURL: URL?, fallback: String, title: String, subtitle: String?, round: Bool, onClick: @escaping () -> Void) {
        self.onClick = onClick
        super.init(frame: .zero)
        self.title = ""
        isBordered = false
        bezelStyle = .regularSquare
        target = self
        action = #selector(clicked)
        setAccessibilityLabel([title, subtitle].compactMap { $0 }.joined(separator: ", "))
        picture.cornerRadius = round ? 16 : Theme.Radius.control
        picture.setImage(imageURL, pointSize: NSSize(width: 32, height: 32))
        picture.toolTip = fallback
        titleLabel.stringValue = title
        titleLabel.font = Theme.bodyFont
        titleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.stringValue = subtitle ?? ""
        subtitleLabel.font = Theme.smallFont
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.isHidden = subtitle == nil
        let text = NSStackView(views: [titleLabel, subtitleLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 0
        [picture, text].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }
        [titleLabel, subtitleLabel].forEach { $0.setContentCompressionResistancePriority(.defaultLow, for: .horizontal) }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 44),
            picture.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Spacing.tight),
            picture.centerYAnchor.constraint(equalTo: centerYAnchor),
            picture.widthAnchor.constraint(equalToConstant: 32),
            picture.heightAnchor.constraint(equalToConstant: 32),
            text.leadingAnchor.constraint(equalTo: picture.trailingAnchor, constant: Theme.Spacing.related),
            text.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Theme.Spacing.tight),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    @objc private func clicked() { onClick() }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

@MainActor
extension NSTextField {
    /// A wrapping, selectable label for profile text.
    static func profileText(_ string: String = "", font: NSFont? = nil, color: NSColor = .labelColor) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: string)
        field.font = font ?? Theme.bodyFont
        field.textColor = color
        field.isSelectable = true
        return field
    }

    static func sectionTitle(_ string: String) -> NSTextField {
        let field = NSTextField(labelWithString: string)
        field.font = Theme.smallFont.withWeight(.semibold)
        field.textColor = .secondaryLabelColor
        return field
    }
}

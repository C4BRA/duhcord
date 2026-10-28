import AppKit
import DuhcordCore

/// The parts of a profile shown both on the card and in the full profile.
private enum ProfileParts {
    /// Display name, then "username · pronouns", then badges.
    static func identity(user: User, profile: UserProfile?, nameFont: NSFont) -> [NSView] {
        let name = NSTextField.profileText(profile?.displayName ?? user.displayName, font: nameFont)
        var second = [user.username]
        if let legacy = profile?.legacyUsername { second.append("Originally known as \(legacy)") }
        if let pronouns = profile?.pronouns { second.append(pronouns) }
        if user.bot == true { second.append("Bot") }
        let username = NSTextField.profileText(second.joined(separator: " · "), font: Theme.smallFont, color: .secondaryLabelColor)
        var views: [NSView] = [name, username]
        if let badges = profile?.badges, !badges.isEmpty {
            let icons: [NSView] = badges.map { badge in
                let icon = RemoteImageView()
                icon.setImage(MediaRequest.badgeIconURL(badge), pointSize: NSSize(width: 18, height: 18))
                icon.toolTip = badge.description
                icon.setAccessibilityElement(true)
                icon.setAccessibilityLabel(badge.description)
                icon.translatesAutoresizingMaskIntoConstraints = false
                icon.widthAnchor.constraint(equalToConstant: 18).isActive = true
                icon.heightAnchor.constraint(equalToConstant: 18).isActive = true
                return icon
            }
            let row = NSStackView(views: icons)
            row.spacing = Theme.Spacing.tight
            views.append(row)
        }
        return views
    }

    /// The custom status, then the first activity as one line ("Playing Rocket League").
    static func status(_ presence: Presence?) -> [NSView] {
        var views: [NSView] = []
        if let custom = presence?.customStatus, !custom.headline.isEmpty {
            views.append(NSTextField.profileText(custom.headline, font: Theme.smallFont))
        }
        if let activity = presence?.shownActivities.first {
            views.append(NSTextField.profileText(activity.headline, font: Theme.smallFont.withWeight(.medium), color: .secondaryLabelColor))
        }
        return views
    }

    static func bio(_ profile: UserProfile?, store: Store, maxLines: Int) -> [NSView] {
        guard let bio = profile?.bio else { return [] }
        let field = NSTextField.profileText()
        field.attributedStringValue = ProfileText.bio(bio, store: store)
        field.maximumNumberOfLines = maxLines
        field.lineBreakMode = .byTruncatingTail
        field.cell?.truncatesLastVisibleLine = true
        return [field]
    }

    /// Their roles in this server, most senior first, as coloured pills. @everyone isn't shown.
    static func roles(_ profile: UserProfile?, guildID: Snowflake?, store: Store, width: CGFloat) -> [NSView] {
        guard let guildID, let guild = store.guilds[guildID], let ids = profile?.guildMember?.roles, !ids.isEmpty else { return [] }
        let byID = Dictionary(guild.roles.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let roles = ids.compactMap { byID[$0] }.filter { $0.id != guildID }.sorted { $0.position > $1.position }
        guard !roles.isEmpty else { return [] }
        let flow = FlowView()
        flow.pills = roles.map { PillView(text: $0.name, dotColor: $0.color == 0 ? .secondaryLabelColor : NSColor(discordColor: $0.color)) }
        flow.translatesAutoresizingMaskIntoConstraints = false
        flow.widthAnchor.constraint(equalToConstant: width).isActive = true
        return [NSTextField.sectionTitle(roles.count == 1 ? "Role" : "Roles"), flow]
    }
}

// MARK: - Card

/// The small profile card shown in a popover where someone was clicked.
final class ProfileCardViewController: NSViewController, NSTextFieldDelegate {
    private static let width: CGFloat = 300

    let userID: Snowflake
    private let guildID: Snowflake?
    private unowned let controller: ProfileController
    private var store: Store { controller.session.store }

    private let header = ProfileHeaderView(avatarSize: 80, bannerHeight: 105)
    private let stack = NSStackView()
    private let messageField = NSTextField()
    /// "Sent" or why sending failed, under the message field.
    private let sendStatus = NSTextField.profileText("", font: Theme.smallFont, color: .secondaryLabelColor)
    private var profile: UserProfile?
    private var failed = false
    private var sending = false

    init(controller: ProfileController, userID: Snowflake, guildID: Snowflake?) {
        self.controller = controller
        self.userID = userID
        self.guildID = guildID
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        let root = NSView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Theme.Spacing.related
        // The message field sits outside the part that's rebuilt, so a status change doesn't take away its focus.
        let body = NSStackView(views: [stack, messageField, sendStatus])
        sendStatus.isHidden = true
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = Theme.Spacing.group
        body.detachesHiddenViews = true
        let contentWidth = Self.width - 2 * Theme.Spacing.edge
        messageField.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
        sendStatus.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
        body.setCustomSpacing(Theme.Spacing.tight, after: messageField)
        [header, body].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview($0)
        }
        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: Self.width),
            header.topAnchor.constraint(equalTo: root.topAnchor),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            body.topAnchor.constraint(equalTo: header.bottomAnchor, constant: Theme.Spacing.related),
            body.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Theme.Spacing.edge),
            body.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Theme.Spacing.edge),
            body.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -Theme.Spacing.edge),
        ])
        header.onAvatarClick = { [weak self] in self?.openFullProfile(.activity) }

        messageField.delegate = self
        messageField.target = self
        messageField.action = #selector(send)
        messageField.lineBreakMode = .byTruncatingTail
        messageField.cell?.isScrollable = true
        messageField.cell?.sendsActionOnEndEditing = false
        view = root

        profile = controller.cachedProfile(userID: userID, guildID: guildID)
        render()
        if profile == nil { load() }
    }

    private func load() {
        controller.loadProfile(userID: userID, guildID: guildID) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let profile): self.profile = profile
            case .failure: self.failed = true
            }
            self.render()
        }
    }

    /// Builds the card from what we know: the profile once it's loaded, the cached user before that.
    func render() {
        guard isViewLoaded else { return }
        let user = profile?.user ?? store.user(userID) ?? User(id: userID, username: "…")
        let presence = store.presence(of: userID)
        let scale = view.window?.backingScaleFactor ?? 2
        header.configure(
            bannerURL: profile.flatMap { MediaRequest.bannerURL(for: $0, guildID: guildID, pixels: Int(Self.width * scale)) },
            accentColor: profile?.accentColor,
            avatarURL: profile.flatMap { MediaRequest.profileAvatarURL(for: $0, guildID: guildID, pixels: Int(80 * scale)) }
                ?? MediaRequest.avatarURL(for: user, pixels: Int(80 * scale)),
            status: presence?.status ?? .offline,
            avatarHint: "View Full Profile")

        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let contentWidth = Self.width - 2 * Theme.Spacing.edge
        var views = ProfileParts.identity(user: user, profile: profile, nameFont: Theme.titleFont.withWeight(.semibold))
        views += ProfileParts.status(presence)
        views += ProfileParts.bio(profile, store: store, maxLines: 6)
        views += ProfileParts.roles(profile, guildID: guildID, store: store, width: contentWidth)
        if let mutuals = mutualsRow() { views.append(mutuals) }
        if profile == nil {
            if failed {
                views.append(NSTextField.profileText("Couldn't load the rest of this profile.", font: Theme.smallFont,
                                                     color: .secondaryLabelColor))
            } else {
                let spinner = NSProgressIndicator()
                spinner.style = .spinning
                spinner.controlSize = .small
                spinner.startAnimation(nil)
                views.append(spinner)
            }
        }
        messageField.isHidden = userID == store.me?.id
        messageField.placeholderString = "Message @\(user.username)"
        messageField.setAccessibilityLabel("Message \(user.displayName)")
        for subview in views {
            stack.addArrangedSubview(subview)
            if subview is NSTextField {
                subview.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
            }
        }
        if let first = views.first, views.count > 1 { stack.setCustomSpacing(0, after: first) }
        view.layoutSubtreeIfNeeded()
        preferredContentSize = view.fittingSize
    }

    /// "3 Mutual Friends · 5 Mutual Servers", each opening that list in the full profile.
    private func mutualsRow() -> NSView? {
        guard let profile, profile.user.id != store.me?.id else { return nil }
        var buttons: [NSView] = []
        if let friends = profile.friendsInCommon, friends > 0 {
            buttons.append(link("\(friends) Mutual Friend\(friends == 1 ? "" : "s")", tab: .mutualFriends))
        }
        if let servers = profile.mutualGuilds?.count, servers > 0 {
            if !buttons.isEmpty { buttons.append(NSTextField(labelWithString: "·")) }
            buttons.append(link("\(servers) Mutual Server\(servers == 1 ? "" : "s")", tab: .mutualServers))
        }
        guard !buttons.isEmpty else { return nil }
        let row = NSStackView(views: buttons)
        row.spacing = Theme.Spacing.tight
        return row
    }

    private func link(_ title: String, tab: ProfileController.Tab) -> NSButton {
        let button = NSButton(title: title, target: self, action: #selector(openTab(_:)))
        button.isBordered = false
        button.tag = tab.rawValue
        button.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: Theme.smallFont, .foregroundColor: NSColor.linkColor,
        ])
        return button
    }

    @objc private func openTab(_ sender: NSButton) {
        openFullProfile(ProfileController.Tab(rawValue: sender.tag) ?? .activity)
    }

    private func openFullProfile(_ tab: ProfileController.Tab) {
        controller.showFullProfile(userID: userID, guildID: guildID, tab: tab)
    }

    @objc private func send() {
        let text = messageField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sending else { return }
        sending = true
        messageField.isEnabled = false
        controller.session.sendDirectMessage(text, to: userID) { [weak self] error in
            guard let self else { return }
            self.sending = false
            self.messageField.isEnabled = true
            if let error {
                // Keep what they wrote so it can be sent again.
                self.sendStatus.stringValue = "Couldn't send: \(error.localizedDescription)"
                self.sendStatus.textColor = .systemRed
            } else {
                self.messageField.stringValue = ""
                self.sendStatus.stringValue = "Sent."
                self.sendStatus.textColor = .secondaryLabelColor
            }
            self.sendStatus.isHidden = false
            self.sendStatus.setAccessibilityLabel(self.sendStatus.stringValue)
            NSAccessibility.post(element: self.sendStatus, notification: .announcementRequested,
                                 userInfo: [.announcement: self.sendStatus.stringValue])
            self.view.layoutSubtreeIfNeeded()
            self.preferredContentSize = self.view.fittingSize
            self.view.window?.makeFirstResponder(self.messageField)
        }
    }
}

// MARK: - Full profile

/// Someone's full profile in its own window: everything on the card, plus their activity, profile board,
/// mutual friends and mutual servers in tabs.
final class ProfileWindowController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?

    private let userID: Snowflake
    private let guildID: Snowflake?
    private unowned let controller: ProfileController
    private var store: Store { controller.session.store }

    private let header = ProfileHeaderView(avatarSize: 96, bannerHeight: 160)
    private let summary = NSStackView()
    private let tabs = NSSegmentedControl()
    private let tabContent = NSStackView()
    private var tab: ProfileController.Tab
    private var profile: UserProfile?
    private var failed = false
    private static let contentWidth: CGFloat = 520

    init(controller: ProfileController, userID: Snowflake, guildID: Snowflake?, tab: ProfileController.Tab) {
        self.controller = controller
        self.userID = userID
        self.guildID = guildID
        self.tab = tab
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: ProfileWindowController.contentWidth + 2 * Theme.Spacing.edge,
                                                  height: 640),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.styleMask.insert(.fullSizeContentView)
        super.init(window: window)
        window.delegate = self
        buildContent()
        window.center()
        profile = controller.cachedProfile(userID: userID, guildID: guildID)
        render()
        controller.loadProfile(userID: userID, guildID: guildID) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let profile): self.profile = profile
            case .failure: self.failed = true
            }
            self.render()
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func windowWillClose(_ notification: Notification) { onClose?() }

    func select(_ tab: ProfileController.Tab) {
        self.tab = tab
        tabs.selectedSegment = tab.rawValue
        renderTab()
    }

    private func buildContent() {
        summary.orientation = .vertical
        summary.alignment = .leading
        summary.spacing = Theme.Spacing.related
        tabs.segmentCount = ProfileController.Tab.allCases.count
        tabs.trackingMode = .selectOne
        tabs.target = self
        tabs.action = #selector(tabChanged)
        tabs.selectedSegment = tab.rawValue
        tabContent.orientation = .vertical
        tabContent.alignment = .leading
        tabContent.spacing = Theme.Spacing.related
        header.onAvatarClick = nil

        let document = FlippedView()
        [header, summary, tabs, tabContent].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            document.addSubview($0)
        }
        let edge = Theme.Spacing.edge
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: document.topAnchor),
            header.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            summary.topAnchor.constraint(equalTo: header.bottomAnchor, constant: Theme.Spacing.group),
            summary.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: edge),
            summary.widthAnchor.constraint(equalToConstant: Self.contentWidth),
            tabs.topAnchor.constraint(equalTo: summary.bottomAnchor, constant: edge),
            tabs.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: edge),
            tabContent.topAnchor.constraint(equalTo: tabs.bottomAnchor, constant: Theme.Spacing.group),
            tabContent.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: edge),
            tabContent.widthAnchor.constraint(equalToConstant: Self.contentWidth),
            tabContent.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -edge),
            document.widthAnchor.constraint(equalToConstant: Self.contentWidth + 2 * edge),
        ])

        let scroll = VerticalScrollView()
        scroll.documentView = document
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false
        window?.contentView = scroll
    }

    func render() {
        let user = profile?.user ?? store.user(userID) ?? User(id: userID, username: "…")
        let presence = store.presence(of: userID)
        let scale = window?.backingScaleFactor ?? 2
        let name = profile?.displayName ?? user.displayName
        window?.title = name
        header.configure(
            bannerURL: profile.flatMap { MediaRequest.bannerURL(for: $0, guildID: guildID, pixels: Int((Self.contentWidth + 40) * scale)) },
            accentColor: profile?.accentColor,
            avatarURL: profile.flatMap { MediaRequest.profileAvatarURL(for: $0, guildID: guildID, pixels: Int(96 * scale)) }
                ?? MediaRequest.avatarURL(for: user, pixels: Int(96 * scale)),
            status: presence?.status ?? .offline,
            avatarHint: nil)

        summary.arrangedSubviews.forEach { $0.removeFromSuperview() }
        var views = ProfileParts.identity(user: user, profile: profile, nameFont: Theme.titleFont.withWeight(.bold))
        views += ProfileParts.status(presence)
        if userID != store.me?.id {
            views.append(NSButton(title: "Message", target: self, action: #selector(message)))
        }
        if let bio = ProfileParts.bio(profile, store: store, maxLines: 0).first {
            views += [NSTextField.sectionTitle("About Me"), bio]
        }
        views.append(NSTextField.sectionTitle("Member Since"))
        var since = "Discord: " + ProfileText.dayFormatter.string(from: ProfileText.accountCreated(userID))
        if let guildID, let joined = profile?.guildMember?.joinedAt.flatMap(DiscordDate.parse) {
            since += "   \(store.guilds[guildID]?.name ?? "This server"): " + ProfileText.dayFormatter.string(from: joined)
        }
        views.append(NSTextField.profileText(since, font: Theme.smallFont))
        views += ProfileParts.roles(profile, guildID: guildID, store: store, width: Self.contentWidth)
        if profile == nil, failed {
            views.append(NSTextField.profileText("Couldn't load the rest of this profile.", font: Theme.smallFont,
                                                 color: .secondaryLabelColor))
        }
        for subview in views {
            summary.addArrangedSubview(subview)
            if subview is NSTextField { subview.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true }
        }
        if let first = views.first, views.count > 1 { summary.setCustomSpacing(0, after: first) }

        let friends = profile?.friendsInCommon
        let servers = profile?.mutualGuilds?.count
        let labels = ["Activity", "Board",
                      friends.map { "Mutual Friends (\($0))" } ?? "Mutual Friends",
                      servers.map { "Mutual Servers (\($0))" } ?? "Mutual Servers"]
        for (i, label) in labels.enumerated() { tabs.setLabel(label, forSegment: i) }
        let isMe = userID == store.me?.id
        tabs.setEnabled(!isMe, forSegment: ProfileController.Tab.mutualFriends.rawValue)
        tabs.setEnabled(!isMe, forSegment: ProfileController.Tab.mutualServers.rawValue)
        if isMe, tab == .mutualFriends || tab == .mutualServers { select(.activity) }
        renderTab()
    }

    @objc private func tabChanged() {
        tab = ProfileController.Tab(rawValue: tabs.selectedSegment) ?? .activity
        renderTab()
    }

    @objc private func message() {
        controller.onOpenDM?(userID)
    }

    private func renderTab() {
        tabContent.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let views: [NSView]
        switch tab {
        case .activity: views = activityViews()
        case .board: views = boardViews()
        case .mutualFriends: views = mutualFriendViews()
        case .mutualServers: views = mutualServerViews()
        }
        for view in views {
            tabContent.addArrangedSubview(view)
            if view is NSTextField || view is ProfileRowButton || view is ActivityRow {
                view.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true
            }
        }
    }

    private func placeholder(_ text: String) -> [NSView] {
        [NSTextField.profileText(text, font: Theme.bodyFont, color: .secondaryLabelColor)]
    }

    private var loadingOrFailed: [NSView]? {
        guard profile == nil else { return nil }
        return placeholder(failed ? "Couldn't load this profile." : "Loading…")
    }

    // Activity: what they're doing right now, from their presence.
    private func activityViews() -> [NSView] {
        let activities = store.presence(of: userID)?.shownActivities ?? []
        guard !activities.isEmpty else {
            return placeholder(userID == store.me?.id
                ? "Your own activity isn't shown here."
                : "Nothing to show right now. Games, music and other activities appear here while they're happening.")
        }
        controller.loadApplications(activities.compactMap(\.applicationId)) { [weak self] in self?.renderTab() }
        let scale = window?.backingScaleFactor ?? 2
        return activities.map { activity -> NSView in
            let app = activity.applicationId.flatMap { controller.applications[$0] }
            let image = MediaRequest.activityImageURL(activity, pixels: Int(48 * scale))
                ?? app.flatMap { MediaRequest.applicationIconURL($0, pixels: Int(48 * scale)) }
            var lines = [activity.details, activity.state].compactMap { $0 }.filter { !$0.isEmpty }
            if let start = activity.startDate { lines.append("Since " + ProfileText.clockFormatter.string(from: start)) }
            return ActivityRow(imageURL: image, title: activity.headline, lines: lines, tooltip: activity.assets?.largeText)
        }
    }

    // Board: their profile widgets (favourite game, games in rotation, games they like or want to play).
    private func boardViews() -> [NSView] {
        if let waiting = loadingOrFailed { return waiting }
        let widgets = profile?.widgets ?? []
        guard !widgets.isEmpty else { return placeholder("No board yet. Favorite games and games in rotation show here.") }
        let ids = widgets.flatMap { $0.games.map(\.gameId) + [$0.applicationId].compactMap { $0 } }
        controller.loadApplications(ids) { [weak self] in self?.renderTab() }
        let scale = window?.backingScaleFactor ?? 2
        var views: [NSView] = []
        for widget in widgets {
            views.append(NSTextField.sectionTitle(widget.title))
            let games: [(Snowflake, String?, [String])] = widget.games.isEmpty ? widget.applicationId.map { [($0, nil as String?, [] as [String])] } ?? []
                : widget.games.map { ($0.gameId, $0.comment, $0.tags ?? []) }
            for (gameID, comment, tags) in games {
                let app = controller.applications[gameID]
                var lines: [String] = []
                if widget.isDetailed, let comment, !comment.isEmpty { lines.append(comment) }
                let row = ActivityRow(imageURL: app.flatMap { MediaRequest.applicationIconURL($0, pixels: Int(48 * scale)) },
                                      title: app?.name ?? "Unknown game", lines: lines, tooltip: nil)
                views.append(row)
                if widget.isDetailed, !tags.isEmpty {
                    let flow = FlowView()
                    flow.pills = tags.map { PillView(text: ProfileWidget.tagTitle($0)) }
                    flow.translatesAutoresizingMaskIntoConstraints = false
                    flow.widthAnchor.constraint(equalToConstant: Self.contentWidth - 56).isActive = true
                    let indented = NSStackView(views: [flow])
                    indented.edgeInsets = NSEdgeInsets(top: 0, left: 56, bottom: 0, right: 0)
                    views.append(indented)
                }
            }
        }
        return views
    }

    private func mutualFriendViews() -> [NSView] {
        if let waiting = loadingOrFailed { return waiting }
        guard let friends = profile?.mutualFriends, !friends.isEmpty else {
            if let count = profile?.friendsInCommon, count > 0 { return placeholder("\(count) mutual friends. Their names are private.") }
            return placeholder("No mutual friends.")
        }
        let scale = window?.backingScaleFactor ?? 2
        return friends.map { friend in
            ProfileRowButton(imageURL: MediaRequest.avatarURL(for: friend, pixels: Int(32 * scale)), fallback: friend.displayName,
                             title: friend.displayName, subtitle: friend.username, round: true) { [weak controller = self.controller] in
                controller?.showFullProfile(userID: friend.id, guildID: nil)
            }
        }
    }

    private func mutualServerViews() -> [NSView] {
        if let waiting = loadingOrFailed { return waiting }
        guard let mutual = profile?.mutualGuilds, !mutual.isEmpty else { return placeholder("No mutual servers.") }
        let scale = window?.backingScaleFactor ?? 2
        return mutual.compactMap { entry -> NSView? in
            guard let guild = store.guilds[entry.id] else { return nil }
            let nick = entry.nick.flatMap { $0.isEmpty ? nil : $0 }
            return ProfileRowButton(imageURL: MediaRequest.iconURL(for: guild, pixels: Int(32 * scale)), fallback: guild.name,
                                    title: guild.name, subtitle: nick, round: false) { [weak controller = self.controller] in
                controller?.onOpenGuild?(guild.id)
            }
        }
    }
}

/// An activity or a game on someone's board: icon, a bold line, and smaller lines under it.
private final class ActivityRow: NSView {
    init(imageURL: URL?, title: String, lines: [String], tooltip: String?) {
        super.init(frame: .zero)
        let icon = RemoteImageView()
        icon.cornerRadius = Theme.Radius.card
        icon.setImage(imageURL, pointSize: NSSize(width: 48, height: 48))
        icon.toolTip = tooltip
        icon.wantsLayer = true
        icon.layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.2).cgColor
        let titleField = NSTextField.profileText(title, font: Theme.bodyFont.withWeight(.semibold))
        let text = NSStackView(views: [titleField] + lines.map {
            NSTextField.profileText($0, font: Theme.smallFont, color: .secondaryLabelColor)
        })
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        [icon, text].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor),
            icon.topAnchor.constraint(equalTo: topAnchor),
            icon.widthAnchor.constraint(equalToConstant: 48),
            icon.heightAnchor.constraint(equalToConstant: 48),
            text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: Theme.Spacing.group),
            text.trailingAnchor.constraint(equalTo: trailingAnchor),
            text.topAnchor.constraint(equalTo: topAnchor),
            bottomAnchor.constraint(greaterThanOrEqualTo: icon.bottomAnchor),
            bottomAnchor.constraint(greaterThanOrEqualTo: text.bottomAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(([title] + lines).joined(separator: ", "))
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

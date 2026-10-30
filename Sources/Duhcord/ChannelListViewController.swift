import AppKit
import DuhcordCore

/// The middle column: text and voice channels under their categories, or the DM list. Who's in each voice
/// channel is listed under it. A call shows the voice bar, and the account bar stays under that.
@MainActor
final class ChannelListViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    var onSelect: ((Snowflake) -> Void)?
    var onJoinVoice: ((Channel) -> Void)?
    /// "Mark as Read" on a channel.
    var onMarkRead: ((Snowflake) -> Void)?
    /// "Message" on someone in a voice channel: open the DM with them.
    var onMessageUser: ((Snowflake) -> Void)?
    /// Someone in a voice channel was clicked: show their profile card beside `rect` in `view`.
    var onShowProfile: ((_ userID: Snowflake, _ guildID: Snowflake?, _ rect: NSRect, _ view: NSView) -> Void)?
    /// "Voice Connected" in the voice bar was clicked.
    var onShowVoiceDetails: (() -> Void)?
    /// The account bar's name or picture was clicked.
    var onShowAccount: ((NSView) -> Void)?
    /// People in voice channels whose names we don't know yet.
    var onMissingNames: ((Snowflake, [Snowflake]) -> Void)?

    private enum Row {
        case item(ChannelListItem)
        /// Someone in the voice channel above.
        case member(VoiceState, guildID: Snowflake)

        /// Identity for telling whether the list's shape changed.
        var key: String {
            switch self {
            case .item(.category(let c)), .item(.channel(let c)), .item(.voiceChannel(let c)): return c.id
            case .member(let state, _): return (state.channelId ?? "") + "/" + state.userId
            }
        }
    }

    private let store: Store
    private let voice: VoiceController
    private let titleLabel = NSTextField(labelWithString: "")
    private let table = KeyTableView()
    private let emptyLabel = NSTextField(labelWithString: "")
    private let voiceBar = VoiceBar()
    private let accountBar = AccountBar()
    private var audioPopover: NSPopover?
    private var place: Place = .directMessages
    private var items: [ChannelListItem] = []
    private var rows: [Row] = []
    private var suppressSelection = false
    private var listToAccount: NSLayoutConstraint!
    private var listToBar: NSLayoutConstraint!

    /// Text channel IDs in display order, for keyboard navigation.
    var channelIDs: [Snowflake] {
        items.compactMap { if case .channel(let c) = $0 { return c.id } else { return nil } }
    }

    init(store: Store, voice: VoiceController) {
        self.store = store
        self.voice = voice
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        let column = NSTableColumn(identifier: .init("channel"))
        table.addTableColumn(column)
        table.fitColumnToWidth()
        table.headerView = nil
        table.style = .sourceList
        table.rowSizeStyle = Theme.listRowSize
        table.setAccessibilityLabel("Channels")
        let menu = NSMenu()
        menu.delegate = self
        table.menu = menu
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(rowClicked)
        // Return joins the selected voice channel or opens the selected person's profile, so both work from the
        // keyboard too.
        table.onReturn = { [weak self] in self?.activateSelectedRow() }

        let scroll = VerticalScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false

        titleLabel.font = Theme.boldFont
        titleLabel.lineBreakMode = .byTruncatingTail

        voiceBar.isHidden = true
        voiceBar.onMute = { [weak self] in self?.voice.toggleMute() }
        voiceBar.onDeafen = { [weak self] in self?.voice.toggleDeafen() }
        voiceBar.onLeave = { [weak self] in self?.voice.leave() }
        voiceBar.onShowDetails = { [weak self] in self?.onShowVoiceDetails?() }
        accountBar.onMute = { [weak self] in self?.voice.toggleMute() }
        accountBar.onDeafen = { [weak self] in self?.voice.toggleDeafen() }
        accountBar.onShowAccount = { [weak self] anchor in
            self?.audioPopover?.close()
            self?.onShowAccount?(anchor)
        }
        accountBar.onInputOptions = { [weak self] anchor in self?.showAudioOptions(input: true, from: anchor) }
        accountBar.onOutputOptions = { [weak self] anchor in self?.showAudioOptions(input: false, from: anchor) }

        let container = NSVisualEffectView()
        container.material = .sidebar
        container.blendingMode = .behindWindow
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.isHidden = true
        [titleLabel, scroll, voiceBar, accountBar, emptyLabel].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview($0)
        }
        // Both bars are always laid out at full width. While the voice bar is hidden the list runs over its
        // space and stops at the account bar. (A stack view here left a bar half-width until the window was resized.)
        listToAccount = scroll.bottomAnchor.constraint(equalTo: accountBar.topAnchor)
        listToBar = scroll.bottomAnchor.constraint(equalTo: voiceBar.topAnchor)
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor, constant: Theme.Spacing.group),
            titleLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Theme.Spacing.group),
            titleLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -Theme.Spacing.group),
            scroll.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: Theme.Spacing.related),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            voiceBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            voiceBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            voiceBar.bottomAnchor.constraint(equalTo: accountBar.topAnchor),
            accountBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            accountBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            accountBar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            emptyLabel.widthAnchor.constraint(lessThanOrEqualTo: scroll.widthAnchor, constant: -2 * Theme.Spacing.edge),
            listToAccount,
        ])
        view = container
        NotificationCenter.default.addObserver(self, selector: #selector(settingsChanged), name: Settings.didChange, object: nil)
    }

    @objc private func settingsChanged() {
        guard table.rowSizeStyle != Theme.listRowSize else { return }
        table.rowSizeStyle = Theme.listRowSize
        reload()
    }

    /// Keeps the column fitted to the list after layout changes. AppKit does the sizing so the source list's row
    /// insets are taken into account; setting the column to the full visible width made cells wider than their
    /// rows and clipped anything on the right (mute icons, mention badges).
    override func viewDidLayout() {
        super.viewDidLayout()
        table.sizeLastColumnToFit()
    }

    func show(_ place: Place) {
        self.place = place
        reload()
    }

    func reload() {
        switch place {
        case .directMessages:
            titleLabel.stringValue = "Direct Messages"
            items = store.privateChannels.map { .channel($0) }
        case .guild(let id):
            titleLabel.stringValue = store.guilds[id]?.name ?? ""
            items = store.channelList(guildID: id)
        }
        rows = buildRows()
        table.reloadData()
        emptyLabel.stringValue = place == .directMessages ? "No Direct Messages" : "No Channels You Can See"
        emptyLabel.isHidden = !rows.isEmpty
        if let focused = store.focusedChannelID { select(focused) }
        refreshVoiceBar()
    }

    /// Someone joined, left, muted or got a name in a voice channel of the guild on screen. Updates in place
    /// without moving the scroll position, and only reloads the table if rows came or went.
    func voiceMembersChanged() {
        guard case .guild = place else { return }
        let oldKeys = rows.map(\.key)
        rows = buildRows()
        guard rows.map(\.key) != oldKeys else {
            refreshVisibleRows()
            return
        }
        table.reloadData()
        if let focused = store.focusedChannelID { select(focused, scroll: false) }
    }

    private func buildRows() -> [Row] {
        var unnamed: [Snowflake: [Snowflake]] = [:]
        let built = items.flatMap { item -> [Row] in
            guard case .voiceChannel(let channel) = item, let guildID = channel.guildId else { return [.item(item)] }
            let members = store.voiceStates(in: channel.id, guildID: guildID)
            unnamed[guildID, default: []] += members.filter { knownName(of: $0, in: guildID) == nil }.map(\.userId)
            let sorted = members.sorted {
                name(of: $0, in: guildID).localizedCaseInsensitiveCompare(name(of: $1, in: guildID)) == .orderedAscending
            }
            return [.item(item)] + sorted.map { .member($0, guildID: guildID) }
        }
        for (guildID, userIDs) in unnamed where !userIDs.isEmpty { onMissingNames?(guildID, userIDs) }
        return built
    }

    func refreshIndicators() {
        // DM order follows activity, so it can change with any new message.
        if place == .directMessages, channelIDs != store.privateChannels.map(\.id) {
            reload()
            return
        }
        refreshVisibleRows()
    }

    /// The call's status, mute state or who's talking changed.
    func voiceChanged() {
        refreshVisibleRows()
        refreshVoiceBar()
        refreshAccountControls()
    }

    /// The signed-in account's picture and status line.
    func updateAccount(user: User?, choice: OwnStatus.Choice) {
        accountBar.update(user: user, choice: choice)
        refreshAccountControls()
    }

    /// A friend's status changed. Only the direct-message rows on screen are redrawn.
    func refreshPresence(_ userID: Snowflake) {
        guard place == .directMessages else { return }
        table.enumerateAvailableRowViews { rowView, row in
            guard row < rows.count, case .item(.channel(let channel)) = rows[row], channel.kind == .dm,
                  channel.recipients?.contains(where: { $0.id == userID }) == true,
                  let cell = rowView.view(atColumn: 0) as? ChannelCell else { return }
            configure(cell, rows[row])
        }
    }

    func closePopovers() { audioPopover?.close() }

    func select(_ channelID: Snowflake, scroll: Bool = true) {
        guard let row = rows.firstIndex(where: { if case .item(.channel(let c)) = $0 { return c.id == channelID } else { return false } })
        else { return }
        suppressSelection = true
        table.selectRowIndexes([row], byExtendingSelection: false)
        if scroll { table.scrollRowToVisible(row) }
        suppressSelection = false
    }

    private func refreshVisibleRows() {
        table.enumerateAvailableRowViews { rowView, row in
            guard row < rows.count, let cell = rowView.view(atColumn: 0) as? ChannelCell else { return }
            configure(cell, rows[row])
        }
    }

    private func refreshVoiceBar() {
        guard voice.isInCall, let channelID = voice.channelID else {
            showVoiceBar(false)
            return
        }
        let channel = store.channel(channelID)
        let guild = voice.guildID.flatMap { store.guilds[$0] }
        voiceBar.update(status: voice.status, place: [channel?.displayName, guild?.name].compactMap { $0 }.joined(separator: " · "),
                        muted: voice.muted || voice.deafened, deafened: voice.deafened,
                        serverMuted: voice.serverMuted, serverDeafened: voice.serverDeafened)
        showVoiceBar(true)
    }

    private func showVoiceBar(_ show: Bool) {
        guard voiceBar.isHidden == show else { return }
        voiceBar.isHidden = !show
        listToAccount.isActive = !show
        listToBar.isActive = show
    }

    private func refreshAccountControls() {
        accountBar.updateAudio(muted: voice.muted, deafened: voice.deafened,
                               serverMuted: voice.serverMuted, serverDeafened: voice.serverDeafened)
    }

    private func showAudioOptions(input: Bool, from anchor: NSView) {
        audioPopover?.close()
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = AudioOptionsViewController(input: input)
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        audioPopover = popover
    }

    private func knownName(of state: VoiceState, in guildID: Snowflake) -> String? {
        state.displayName ?? store.memberName(state.userId, in: guildID) ?? store.user(state.userId)?.displayName
    }

    private func name(of state: VoiceState, in guildID: Snowflake) -> String {
        knownName(of: state, in: guildID) ?? "Someone"
    }

    private func configure(_ cell: ChannelCell, _ row: Row) {
        switch row {
        case .item(let item):
            var inCall = false
            if case .voiceChannel(let c) = item { inCall = c.id == voice.channelID }
            cell.configure(item, store: store, inCall: inCall, size: table.effectiveRowSizeStyle)
            cell.setAccessibilityCustomActions(nil)
        case .member(let state, let guildID):
            let user = state.member?.user ?? store.memberUser(state.userId, in: guildID)
                ?? User(id: state.userId, username: "")
            cell.configureMember(name: name(of: state, in: guildID), user: user, size: table.effectiveRowSizeStyle,
                                 speaking: voice.speaking.contains(state.userId), state: state)
            // VoiceOver can open the profile too (VO-Command-Space lists the actions).
            let userID = state.userId
            cell.setAccessibilityCustomActions([NSAccessibilityCustomAction(name: "Show Profile") { [weak self] in
                self?.showProfile(userID: userID, guildID: guildID)
                return true
            }])
        }
    }

    // MARK: - Right-click menu

    /// Built for the row that was right-clicked, as in the official client.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = table.clickedRow
        guard row >= 0, row < rows.count else { return }
        menuItems(for: rows[row]).forEach { menu.addItem($0) }
    }

    private func menuItems(for row: Row) -> [NSMenuItem] {
        switch row {
        case .item(.channel(let c)):
            var items: [NSMenuItem] = [
                ActionMenuItem("Mark as Read", enabled: store.isUnread(c.id)) { [weak self] in self?.onMarkRead?(c.id) },
                ActionMenuItem("Copy Link") { Pasteboard.copy(DiscordLink.channel(c.id, guildID: c.guildId)) },
            ]
            if c.kind == .dm, let recipient = c.recipients?.first {
                items += [.separator(), ActionMenuItem("Show \(recipient.displayName)'s Profile") { [weak self] in
                    guard let self, let index = self.rows.firstIndex(where: { if case .item(.channel(let x)) = $0 { return x.id == c.id }; return false })
                    else { return }
                    self.onShowProfile?(recipient.id, nil, self.table.rect(ofRow: index), self.table)
                }]
            }
            return items
        case .item(.voiceChannel(let c)):
            let inCall = voice.channelID == c.id
            let joinOrLeave: NSMenuItem = inCall
                ? ActionMenuItem("Disconnect", handler: { [weak self] in self?.voice.leave() })
                : ActionMenuItem("Join", handler: { [weak self] in self?.onJoinVoice?(c) })
            return [
                joinOrLeave,
                ActionMenuItem("Copy Link") { Pasteboard.copy(DiscordLink.channel(c.id, guildID: c.guildId)) },
            ]
        case .member(let state, let guildID):
            let userID = state.userId
            let user = store.memberUser(userID, in: guildID)
            var items: [NSMenuItem] = [
                ActionMenuItem("Show Profile") { [weak self] in self?.showProfile(userID: userID, guildID: guildID) },
            ]
            if userID != store.me?.id {
                items.append(ActionMenuItem("Message") { [weak self] in self?.onMessageUser?(userID) })
            }
            if let username = user?.username, !username.isEmpty {
                items += [.separator(), ActionMenuItem("Copy Username") { Pasteboard.copy(username) }]
            }
            return items
        case .item(.category):
            return []
        }
    }

    /// Shows someone's profile card beside their row in the list.
    private func showProfile(userID: Snowflake, guildID: Snowflake) {
        guard let row = rows.firstIndex(where: { if case .member(let s, let g) = $0 { return s.userId == userID && g == guildID }; return false })
        else { return }
        table.scrollRowToVisible(row)
        onShowProfile?(userID, guildID, table.rect(ofRow: row), table)
    }

    @objc private func rowClicked() {
        let row = table.clickedRow
        if row >= 0, row < rows.count, case .member(let state, let guildID) = rows[row] {
            onShowProfile?(state.userId, guildID, table.rect(ofRow: row), table)
            // A click only opens the card; the selection stays on the channel being read.
            if let focused = store.focusedChannelID { select(focused, scroll: false) }
            return
        }
        join(row: row)
    }

    /// Return on the selected row: joins a voice channel, or opens the profile of someone in one.
    private func activateSelectedRow() {
        let row = table.selectedRow
        if row >= 0, row < rows.count, case .member(let state, let guildID) = rows[row] {
            showProfile(userID: state.userId, guildID: guildID)
            return
        }
        join(row: row)
    }

    /// Joins the voice channel in `row`, then puts the selection back on the text channel being read.
    private func join(row: Int) {
        guard row >= 0, row < rows.count, case .item(.voiceChannel(let channel)) = rows[row] else { return }
        onJoinVoice?(channel)
        if let focused = store.focusedChannelID { select(focused, scroll: false) }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: ChannelCell.identifier, owner: nil) as? ChannelCell ?? ChannelCell()
        configure(cell, rows[row])
        return cell
    }

    /// Rows take the system's height for the sidebar size. Pictures need a little more than a text row.
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        switch rows[row] {
        case .member:
            return max(tableView.rowHeight, Theme.IconSize.listAvatar + Theme.Spacing.related)
        case .item(.channel(let channel)) where channel.isPrivate:
            return max(tableView.rowHeight, Theme.IconSize.dmAvatar + Theme.Spacing.related)
        default:
            return tableView.rowHeight
        }
    }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .item(.category) = rows[row] { return true }
        return false
    }

    /// Text channels are selected to read them. Voice channels and the people in them can be selected with the
    /// keyboard (Return joins, or opens the profile); clicking one does that straight away.
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        switch rows[row] {
        case .item(.channel), .item(.voiceChannel), .member: return true
        default: return false
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !suppressSelection, table.selectedRow >= 0, case .item(.channel(let c)) = rows[table.selectedRow] else { return }
        onSelect?(c.id)
    }
}

@MainActor
private final class ChannelCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("ChannelCell")

    /// What sits in front of the name.
    private enum Leading { case none, icon, avatar, cluster }

    private let icon = NSImageView()
    private let avatar = RemoteImageView()
    private let cluster = AvatarClusterView()
    private let statusDot = NSView()
    private let label = NSTextField(labelWithString: "")
    private let badge = BadgeView()
    /// Mute and deafen, in white when the person chose it, in red when a moderator did.
    private let muteIcon = NSImageView()
    private let deafenIcon = NSImageView()
    private lazy var voiceIcons = NSStackView(views: [muteIcon, deafenIcon])
    private var labelAtStart: NSLayoutConstraint!
    private var labelAfterIcon: NSLayoutConstraint!
    private var labelAfterAvatar: NSLayoutConstraint!
    private var labelAfterCluster: NSLayoutConstraint!
    private var avatarLeadingFlush: NSLayoutConstraint!
    private var avatarLeadingIndented: NSLayoutConstraint!
    private var avatarWidth: NSLayoutConstraint!
    private var avatarHeight: NSLayoutConstraint!
    private var rowEmphasized = false

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        label.lineBreakMode = .byTruncatingTail
        icon.symbolConfiguration = .init(pointSize: 12, weight: .medium)
        for (view, symbol, label) in [(muteIcon, "mic.slash.fill", "Muted"), (deafenIcon, "speaker.slash.fill", "Deafened")] {
            view.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            view.symbolConfiguration = .init(pointSize: 12, weight: .medium)
        }
        voiceIcons.spacing = Theme.Spacing.tight
        voiceIcons.setHuggingPriority(.required, for: .horizontal)
        avatar.layer?.borderColor = NSColor.systemGreen.cgColor
        statusDot.wantsLayer = true
        statusDot.layer?.cornerRadius = 4.5
        statusDot.layer?.borderWidth = 1.5
        statusDot.setAccessibilityElement(false)
        [icon, avatar, cluster, statusDot, label, badge, voiceIcons].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }
        badge.setContentCompressionResistancePriority(.required, for: .horizontal)
        voiceIcons.setContentCompressionResistancePriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        labelAtStart = label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Spacing.tight)
        labelAfterIcon = label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: Theme.Spacing.related)
        labelAfterAvatar = label.leadingAnchor.constraint(equalTo: avatar.trailingAnchor, constant: Theme.Spacing.related)
        labelAfterCluster = label.leadingAnchor.constraint(equalTo: cluster.trailingAnchor, constant: Theme.Spacing.related)
        avatarLeadingFlush = avatar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Spacing.tight)
        // Members sit under their channel's name, lined up with it.
        avatarLeadingIndented = avatar.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: Theme.Spacing.related)
        avatarWidth = avatar.widthAnchor.constraint(equalToConstant: Theme.IconSize.listAvatar)
        avatarHeight = avatar.heightAnchor.constraint(equalToConstant: Theme.IconSize.listAvatar)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Spacing.tight),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: Theme.IconSize.sidebar),
            avatar.centerYAnchor.constraint(equalTo: centerYAnchor),
            avatarWidth, avatarHeight,
            cluster.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Spacing.tight),
            cluster.centerYAnchor.constraint(equalTo: centerYAnchor),
            cluster.widthAnchor.constraint(equalToConstant: Theme.IconSize.dmAvatar),
            cluster.heightAnchor.constraint(equalToConstant: Theme.IconSize.dmAvatar),
            statusDot.trailingAnchor.constraint(equalTo: avatar.trailingAnchor, constant: 1),
            statusDot.bottomAnchor.constraint(equalTo: avatar.bottomAnchor, constant: 1),
            statusDot.widthAnchor.constraint(equalToConstant: 9),
            statusDot.heightAnchor.constraint(equalToConstant: 9),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            badge.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: Theme.Spacing.tight),
            badge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.Spacing.related),
            badge.centerYAnchor.constraint(equalTo: centerYAnchor),
            voiceIcons.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: Theme.Spacing.tight),
            voiceIcons.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.Spacing.related),
            voiceIcons.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        updateCutout()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            rowEmphasized = backgroundStyle == .emphasized
            updateCutout()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            avatar.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        }
        updateCutout()
    }

    private func updateCutout() {
        let color: NSColor = rowEmphasized ? .selectedContentBackgroundColor : .windowBackgroundColor
        statusDot.layer?.borderColor = color.cgColor
        cluster.setCutout(color)
    }

    private func use(_ leading: Leading, avatarSize: CGFloat = Theme.IconSize.listAvatar, indented: Bool = false) {
        icon.isHidden = leading != .icon
        avatar.isHidden = leading != .avatar
        cluster.isHidden = leading != .cluster
        statusDot.isHidden = true
        labelAtStart.isActive = leading == .none
        labelAfterIcon.isActive = leading == .icon
        labelAfterAvatar.isActive = leading == .avatar
        labelAfterCluster.isActive = leading == .cluster
        avatarLeadingFlush.isActive = !(leading == .avatar && indented)
        avatarLeadingIndented.isActive = leading == .avatar && indented
        avatarWidth.constant = avatarSize
        avatarHeight.constant = avatarSize
        avatar.cornerRadius = avatarSize / 2
        if leading != .avatar {
            avatar.setImage(nil, pointSize: .zero)
            avatar.layer?.borderWidth = 0
        }
        if leading != .cluster { cluster.clear() }
    }

    private func showAvatar(_ user: User, side: CGFloat) {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        avatar.setImage(MediaRequest.avatarURL(for: user, pixels: Int(side * scale)),
                        pointSize: NSSize(width: side, height: side))
    }

    private func showStatus(_ status: Presence.Status) {
        statusDot.isHidden = false
        statusDot.layer?.backgroundColor = ProfileText.statusColor(status).cgColor
        updateCutout()
    }

    func configure(_ item: ChannelListItem, store: Store, inCall: Bool, size: NSTableView.RowSizeStyle) {
        voiceIcons.isHidden = true
        avatar.layer?.borderWidth = 0
        switch item {
        case .category(let c):
            use(.none)
            label.stringValue = c.displayName.uppercased()
            setAccessibilityLabel(c.displayName + ", category")
            label.font = Theme.captionFont.withWeight(.semibold)
            label.textColor = .secondaryLabelColor
            badge.count = 0
        case .channel(let c):
            let unread = store.isUnread(c.id)
            if c.kind == .groupDM, let people = c.recipients, !people.isEmpty {
                use(.cluster)
                cluster.show(people)
            } else if c.kind == .dm {
                use(.avatar, avatarSize: Theme.IconSize.dmAvatar)
                if let user = c.recipients?.first {
                    showAvatar(user, side: Theme.IconSize.dmAvatar)
                    showStatus(store.presence(of: user.id)?.status ?? .offline)
                }
            } else if c.isPrivate {
                use(.none)
            } else {
                use(.icon)
                icon.image = NSImage(systemSymbolName: c.kind == .announcement ? "megaphone" : "number",
                                     accessibilityDescription: "Text channel")
                icon.contentTintColor = unread ? .labelColor : .secondaryLabelColor
            }
            label.stringValue = c.displayName
            label.font = Theme.listFont(for: size, bold: unread)
            label.textColor = unread ? .labelColor : .secondaryLabelColor
            badge.count = store.mentionCount(c.id)
            var spoken = c.displayName
            if c.kind == .groupDM {
                spoken += ", group direct message"
            } else if c.kind == .dm {
                spoken += ", direct message"
                if let user = c.recipients?.first {
                    spoken += ", " + ProfileText.status(store.presence(of: user.id)?.status ?? .offline)
                }
            } else {
                spoken += ", text channel"
            }
            if badge.count > 0 { spoken += ", \(badge.count) mention\(badge.count == 1 ? "" : "s")" } else if unread { spoken += ", unread" }
            setAccessibilityLabel(spoken)
        case .voiceChannel(let c):
            use(.icon)
            icon.image = NSImage(systemSymbolName: "speaker.wave.2.fill", accessibilityDescription: "Voice channel")
            icon.contentTintColor = inCall ? .systemGreen : .secondaryLabelColor
            label.stringValue = c.displayName
            label.font = Theme.listFont(for: size, bold: inCall)
            label.textColor = inCall ? .labelColor : .secondaryLabelColor
            badge.count = 0
            setAccessibilityLabel(c.displayName + ", voice channel" + (inCall ? ", connected" : ""))
        }
    }

    /// Someone in a voice channel: picture (ringed in green while they talk), name, and mute/deafen.
    func configureMember(name: String, user: User, size: NSTableView.RowSizeStyle, speaking: Bool, state: VoiceState) {
        let side = Theme.IconSize.listAvatar
        use(.avatar, avatarSize: side, indented: true)
        showAvatar(user, side: side)
        avatar.layer?.borderWidth = speaking ? 2 : 0
        label.stringValue = name
        label.font = Theme.listFont(for: size)
        label.textColor = speaking ? .labelColor : .secondaryLabelColor
        badge.count = 0

        let muted = state.selfMute || state.mute
        let deafened = state.selfDeaf || state.deaf
        muteIcon.isHidden = !muted
        deafenIcon.isHidden = !deafened
        // A moderator's mute or deafen wins over the person's own.
        muteIcon.contentTintColor = state.mute ? .systemRed : .labelColor
        deafenIcon.contentTintColor = state.deaf ? .systemRed : .labelColor
        voiceIcons.isHidden = !(muted || deafened)

        var spoken = name + (speaking ? ", speaking" : "")
        if deafened { spoken += state.deaf ? ", deafened by a moderator" : ", deafened" }
        if muted { spoken += state.mute ? ", muted by a moderator" : ", muted" }
        setAccessibilityLabel(spoken)
    }
}

/// Up to three profile pictures in one direct-message slot. One person fills it; two sit side by side; three
/// are two over one.
@MainActor
private final class AvatarClusterView: NSView {
    private let images = (0..<3).map { _ in RemoteImageView() }
    private var users: [User] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for image in images {
            // Frames are set in layout(). No constraints, so Auto Layout leaves them alone.
            image.translatesAutoresizingMaskIntoConstraints = false
            image.setAccessibilityElement(false)
            addSubview(image)
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ users: [User]) {
        self.users = Array(users.prefix(3))
        needsLayout = true
    }

    func clear() {
        users = []
        for image in images {
            image.isHidden = true
            image.setImage(nil, pointSize: .zero)
        }
    }

    func setCutout(_ color: NSColor) {
        let width: CGFloat = users.count > 1 ? 1.5 : 0
        for image in images {
            image.layer?.borderWidth = width
            image.layer?.borderColor = color.cgColor
        }
    }

    override func layout() {
        super.layout()
        let frames = Self.frames(count: users.count, side: bounds.width)
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        for (index, image) in images.enumerated() {
            guard index < users.count, index < frames.count, frames[index].width > 1 else {
                image.isHidden = true
                image.setImage(nil, pointSize: .zero)
                continue
            }
            image.isHidden = false
            image.frame = frames[index]
            image.cornerRadius = frames[index].width / 2
            let pixels = max(Int(frames[index].width * scale), 1)
            image.setImage(MediaRequest.avatarURL(for: users[index], pixels: pixels), pointSize: frames[index].size)
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let color = NSColor.quaternaryLabelColor.cgColor
            for image in images { image.layer?.backgroundColor = color }
        }
    }

    private static func frames(count: Int, side: CGFloat) -> [NSRect] {
        switch count {
        case 1:
            return [NSRect(x: 0, y: 0, width: side, height: side)]
        case 2:
            let width = (side * 0.72).rounded()
            let y = ((side - width) / 2).rounded()
            return [NSRect(x: 0, y: y, width: width, height: width),
                    NSRect(x: side - width, y: y, width: width, height: width)]
        case 3...:
            let width = (side * 0.62).rounded()
            return [NSRect(x: 0, y: side - width, width: width, height: width),
                    NSRect(x: side - width, y: side - width, width: width, height: width),
                    NSRect(x: ((side - width) / 2).rounded(), y: 0, width: width, height: width)]
        default:
            return []
        }
    }
}

/// The call we're in, docked at the bottom of the channel list: where and whether it's connected, mute, deafen
/// and leave, and room for video, screen sharing and activities (not available yet). "Voice Connected" opens
/// the connection details. Same margins and type as the rest of the sidebar.
@MainActor
private final class VoiceBar: NSView {
    var onMute: (() -> Void)?
    var onDeafen: (() -> Void)?
    var onLeave: (() -> Void)?
    var onShowDetails: (() -> Void)?

    private let statusLabel = NSButton(title: "", target: nil, action: nil)
    private let placeLabel = NSTextField(labelWithString: "")
    private let muteButton = VoiceBar.button("Mute")
    private let deafenButton = VoiceBar.button("Deafen")
    private let leaveButton = VoiceBar.button("Disconnect")

    init() {
        super.init(frame: .zero)
        statusLabel.isBordered = false
        statusLabel.target = self
        statusLabel.action = #selector(showDetails)
        statusLabel.lineBreakMode = .byTruncatingTail
        placeLabel.font = Theme.smallFont
        placeLabel.lineBreakMode = .byTruncatingTail
        [statusLabel, placeLabel].forEach { $0.setContentCompressionResistancePriority(.defaultLow, for: .horizontal) }
        leaveButton.image = Self.symbol("phone.down.fill", "Disconnect")
        leaveButton.contentTintColor = .systemRed
        muteButton.target = self
        muteButton.action = #selector(mute)
        deafenButton.target = self
        deafenButton.action = #selector(deafen)
        leaveButton.target = self
        leaveButton.action = #selector(leave)

        let divider = NSBox()
        divider.boxType = .separator
        let comingSoon = NSStackView(views: [
            Self.box("video.fill", "Video"),
            Self.box("display", "Share Your Screen"),
            Self.box("gamecontroller.fill", "Activities"),
        ])
        comingSoon.distribution = .fillEqually
        comingSoon.spacing = Theme.Spacing.related
        let views: [NSView] = [divider, statusLabel, placeLabel, muteButton, deafenButton, leaveButton, comingSoon]
        views.forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }
        NSLayoutConstraint.activate([
            divider.topAnchor.constraint(equalTo: topAnchor),
            divider.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Spacing.group),
            divider.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.Spacing.group),

            statusLabel.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: Theme.Spacing.group),
            statusLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Spacing.group),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: muteButton.leadingAnchor, constant: -Theme.Spacing.related),
            placeLabel.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: Theme.Spacing.tight / 2),
            placeLabel.leadingAnchor.constraint(equalTo: statusLabel.leadingAnchor),
            placeLabel.trailingAnchor.constraint(lessThanOrEqualTo: muteButton.leadingAnchor, constant: -Theme.Spacing.related),
            comingSoon.topAnchor.constraint(equalTo: placeLabel.bottomAnchor, constant: Theme.Spacing.group),
            comingSoon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Spacing.group),
            comingSoon.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.Spacing.group),
            // The same 12 pt bottom margin as the message box next to it.
            comingSoon.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Theme.Spacing.group),

            leaveButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.Spacing.related),
            deafenButton.trailingAnchor.constraint(equalTo: leaveButton.leadingAnchor, constant: -Theme.Spacing.tight),
            muteButton.trailingAnchor.constraint(equalTo: deafenButton.leadingAnchor, constant: -Theme.Spacing.tight),
        ])
        for button in [muteButton, deafenButton, leaveButton] {
            NSLayoutConstraint.activate([
                button.centerYAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 1),
                button.widthAnchor.constraint(equalToConstant: 28),
                button.heightAnchor.constraint(equalToConstant: 28),
            ])
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func update(status: VoiceController.Status, place: String, muted: Bool, deafened: Bool, serverMuted: Bool,
                serverDeafened: Bool) {
        switch status {
        case .idle, .connecting:
            setStatus("Connecting…", color: .secondaryLabelColor)
            statusLabel.isEnabled = false
            statusLabel.toolTip = nil
        case .connected:
            setStatus("Voice Connected", color: .systemGreen)
            statusLabel.isEnabled = true
            statusLabel.toolTip = "Show connection details"
        }
        if serverMuted || serverDeafened {
            placeLabel.stringValue = serverDeafened ? "Deafened by a moderator" : "Muted by a moderator"
            placeLabel.textColor = .systemOrange
        } else {
            placeLabel.stringValue = place
            placeLabel.textColor = .secondaryLabelColor
        }
        let micOff = muted || serverMuted || serverDeafened
        let soundOff = deafened || serverDeafened
        muteButton.image = Self.symbol(micOff ? "mic.slash.fill" : "mic.fill", muted ? "Unmute" : "Mute")
        muteButton.contentTintColor = micOff ? .systemRed : .secondaryLabelColor
        muteButton.toolTip = muted ? "Unmute" : "Mute"
        deafenButton.image = Self.symbol(soundOff ? "speaker.slash.fill" : "headphones", deafened ? "Undeafen" : "Deafen")
        deafenButton.contentTintColor = soundOff ? .systemRed : .secondaryLabelColor
        deafenButton.toolTip = deafened ? "Undeafen" : "Deafen"
    }

    private func setStatus(_ text: String, color: NSColor) {
        statusLabel.attributedTitle = NSAttributedString(string: text, attributes: [
            .font: Theme.smallFont.withWeight(.semibold),
            .foregroundColor: color,
        ])
        statusLabel.setAccessibilityLabel(text)
    }

    @objc private func showDetails() { onShowDetails?() }
    @objc private func mute() { onMute?() }
    @objc private func deafen() { onDeafen?() }
    @objc private func leave() { onLeave?() }

    private static func symbol(_ name: String, _ label: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: label)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
    }

    /// A video, screen sharing or activities button, shown for where they'll go but not available yet.
    private static func box(_ symbolName: String, _ label: String) -> NSButton {
        let button = NSButton(title: "", target: nil, action: nil)
        button.bezelStyle = .rounded
        button.controlSize = .large
        button.imagePosition = .imageOnly
        button.image = symbol(symbolName, label)
        button.isEnabled = false
        button.toolTip = "\(label) — coming soon"
        button.setAccessibilityLabel("\(label), coming soon")
        return button
    }

    /// Borderless until hovered, like toolbar accessory buttons elsewhere in macOS.
    private static func button(_ label: String) -> NSButton {
        let button = NSButton(title: "", target: nil, action: nil)
        button.bezelStyle = .recessed
        button.showsBorderOnlyWhileMouseInside = true
        button.imagePosition = .imageOnly
        button.toolTip = label
        return button
    }
}

/// A table that reports Return, which plain NSTableView ignores.
@MainActor
private final class KeyTableView: NSTableView {
    var onReturn: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        // 36 is Return, 76 is Enter on the keypad.
        if event.keyCode == 36 || event.keyCode == 76, let onReturn {
            onReturn()
        } else {
            super.keyDown(with: event)
        }
    }
}

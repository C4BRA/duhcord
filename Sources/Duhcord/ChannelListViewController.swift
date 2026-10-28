import AppKit
import DuhcordCore

/// The middle column: text and voice channels under their categories, or the DM list. Who's in each voice
/// channel is listed under it, and the voice bar at the bottom shows the call we're in.
final class ChannelListViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    var onSelect: ((Snowflake) -> Void)?
    var onJoinVoice: ((Channel) -> Void)?
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
    private let table = NSTableView()
    private let voiceBar = VoiceBar()
    private var place: Place = .directMessages
    private var items: [ChannelListItem] = []
    private var rows: [Row] = []
    private var suppressSelection = false
    private var listToBottom: NSLayoutConstraint!
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
        table.rowHeight = 24
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(rowClicked)

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false

        titleLabel.font = .boldSystemFont(ofSize: 13)
        titleLabel.lineBreakMode = .byTruncatingTail

        voiceBar.isHidden = true
        voiceBar.onMute = { [weak self] in self?.voice.toggleMute() }
        voiceBar.onDeafen = { [weak self] in self?.voice.toggleDeafen() }
        voiceBar.onLeave = { [weak self] in self?.voice.leave() }

        let container = NSVisualEffectView()
        container.material = .sidebar
        container.blendingMode = .behindWindow
        [titleLabel, scroll, voiceBar].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview($0)
        }
        // The bar is always laid out at full width along the bottom; while it's hidden the list simply runs over
        // its space. (A stack view here left the bar half-width until the window was resized.)
        listToBottom = scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        listToBar = scroll.bottomAnchor.constraint(equalTo: voiceBar.topAnchor)
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            titleLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            voiceBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            voiceBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            voiceBar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            listToBottom,
        ])
        view = container
    }

    /// Keeps the column exactly the list's width, whatever AppKit decided during layout.
    override func viewDidLayout() {
        super.viewDidLayout()
        guard let column = table.tableColumns.first, let clip = table.enclosingScrollView?.contentView else { return }
        if abs(column.width - clip.bounds.width) > 0.5 { column.width = clip.bounds.width }
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
    }

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
        listToBottom.isActive = !show
        listToBar.isActive = show
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
            cell.configure(item, store: store, inCall: inCall)
        case .member(let state, let guildID):
            let user = state.member?.user ?? store.memberUser(state.userId, in: guildID)
                ?? User(id: state.userId, username: "")
            cell.configureMember(name: name(of: state, in: guildID), user: user, speaking: voice.speaking.contains(state.userId),
                                 muted: state.selfMute || state.mute, deafened: state.selfDeaf || state.deaf)
        }
    }

    @objc private func rowClicked() {
        let row = table.clickedRow
        guard row >= 0, row < rows.count, case .item(.voiceChannel(let channel)) = rows[row] else { return }
        onJoinVoice?(channel)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: ChannelCell.identifier, owner: nil) as? ChannelCell ?? ChannelCell()
        configure(cell, rows[row])
        return cell
    }

    /// Members get a little more room for their profile pictures.
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if case .member = rows[row] { return 28 }
        return 24
    }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .item(.category) = rows[row] { return true }
        return false
    }

    /// Only text channels are selected; clicking a voice channel joins it instead.
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .item(.channel) = rows[row] { return true }
        return false
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !suppressSelection, table.selectedRow >= 0, case .item(.channel(let c)) = rows[table.selectedRow] else { return }
        onSelect?(c.id)
    }
}

private final class ChannelCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("ChannelCell")
    static let avatarSize: CGFloat = 20

    /// What sits in front of the name.
    private enum Leading { case none, icon, avatar }

    private let icon = NSImageView()
    private let avatar = RemoteImageView()
    private let label = NSTextField(labelWithString: "")
    private let badge = NSTextField(labelWithString: "")
    private let status = NSImageView()
    private var labelAtStart: NSLayoutConstraint!
    private var labelAfterIcon: NSLayoutConstraint!
    private var labelAfterAvatar: NSLayoutConstraint!

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        label.lineBreakMode = .byTruncatingTail
        badge.alignment = .right
        badge.font = .boldSystemFont(ofSize: 10)
        badge.textColor = .systemRed
        icon.symbolConfiguration = .init(pointSize: 12, weight: .medium)
        status.symbolConfiguration = .init(pointSize: 10, weight: .medium)
        status.contentTintColor = .tertiaryLabelColor
        avatar.cornerRadius = Self.avatarSize / 2
        avatar.layer?.borderColor = NSColor.systemGreen.cgColor
        [icon, avatar, label, badge, status].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }
        badge.setContentCompressionResistancePriority(.required, for: .horizontal)
        status.setContentCompressionResistancePriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        labelAtStart = label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4)
        labelAfterIcon = label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6)
        labelAfterAvatar = label.leadingAnchor.constraint(equalTo: avatar.trailingAnchor, constant: 7)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            // Members sit under their channel's name, lined up with it.
            avatar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 26),
            avatar.centerYAnchor.constraint(equalTo: centerYAnchor),
            avatar.widthAnchor.constraint(equalToConstant: Self.avatarSize),
            avatar.heightAnchor.constraint(equalToConstant: Self.avatarSize),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            badge.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 4),
            badge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            badge.centerYAnchor.constraint(equalTo: centerYAnchor),
            status.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 4),
            status.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            status.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func use(_ leading: Leading) {
        icon.isHidden = leading != .icon
        avatar.isHidden = leading != .avatar
        labelAtStart.isActive = leading == .none
        labelAfterIcon.isActive = leading == .icon
        labelAfterAvatar.isActive = leading == .avatar
        if leading != .avatar { avatar.setImage(nil, pointSize: .zero) }
    }

    func configure(_ item: ChannelListItem, store: Store, inCall: Bool) {
        status.isHidden = true
        avatar.layer?.borderWidth = 0
        switch item {
        case .category(let c):
            use(.none)
            label.stringValue = c.displayName.uppercased()
            label.font = .systemFont(ofSize: 11, weight: .semibold)
            label.textColor = .secondaryLabelColor
            badge.stringValue = ""
        case .channel(let c):
            let unread = store.isUnread(c.id)
            if c.isPrivate {
                use(.none)
            } else {
                use(.icon)
                icon.image = NSImage(systemSymbolName: c.kind == .announcement ? "megaphone" : "number",
                                     accessibilityDescription: "Text channel")
                icon.contentTintColor = unread ? .labelColor : .secondaryLabelColor
            }
            label.stringValue = c.displayName
            label.font = unread ? Theme.boldFont : Theme.bodyFont
            label.textColor = unread ? .labelColor : .secondaryLabelColor
            let mentions = store.mentionCount(c.id)
            badge.stringValue = mentions > 0 ? String(mentions) : ""
        case .voiceChannel(let c):
            use(.icon)
            icon.image = NSImage(systemSymbolName: "speaker.wave.2.fill", accessibilityDescription: "Voice channel")
            icon.contentTintColor = inCall ? .systemGreen : .secondaryLabelColor
            label.stringValue = c.displayName
            label.font = inCall ? Theme.boldFont : Theme.bodyFont
            label.textColor = inCall ? .labelColor : .secondaryLabelColor
            badge.stringValue = ""
        }
    }

    /// Someone in a voice channel: picture (ringed in green while they talk), name, and mute/deafen.
    func configureMember(name: String, user: User, speaking: Bool, muted: Bool, deafened: Bool) {
        use(.avatar)
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        avatar.setImage(MediaRequest.avatarURL(for: user, pixels: Int(Self.avatarSize * scale)),
                        pointSize: NSSize(width: Self.avatarSize, height: Self.avatarSize))
        avatar.layer?.borderWidth = speaking ? 2 : 0
        label.stringValue = name
        label.font = Theme.bodyFont
        label.textColor = speaking ? .labelColor : .secondaryLabelColor
        badge.stringValue = ""
        status.isHidden = !(muted || deafened)
        status.image = NSImage(systemSymbolName: deafened ? "speaker.slash.fill" : "mic.slash.fill",
                               accessibilityDescription: deafened ? "Deafened" : "Muted")
    }
}

/// The call we're in, docked at the bottom of the channel list: where, whether it's connected and end-to-end
/// encrypted, and mute, deafen and leave. Same margins and type as the rest of the sidebar.
private final class VoiceBar: NSView {
    var onMute: (() -> Void)?
    var onDeafen: (() -> Void)?
    var onLeave: (() -> Void)?

    private let statusLabel = NSTextField(labelWithString: "")
    private let placeLabel = NSTextField(labelWithString: "")
    private let muteButton = VoiceBar.button("Mute")
    private let deafenButton = VoiceBar.button("Deafen")
    private let leaveButton = VoiceBar.button("Disconnect")

    init() {
        super.init(frame: .zero)
        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        placeLabel.font = Theme.smallFont
        placeLabel.lineBreakMode = .byTruncatingTail
        statusLabel.lineBreakMode = .byTruncatingTail
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
        let views: [NSView] = [divider, statusLabel, placeLabel, muteButton, deafenButton, leaveButton]
        views.forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }
        NSLayoutConstraint.activate([
            divider.topAnchor.constraint(equalTo: topAnchor),
            divider.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            divider.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),

            statusLabel.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: 10),
            statusLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: muteButton.leadingAnchor, constant: -8),
            placeLabel.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 2),
            placeLabel.leadingAnchor.constraint(equalTo: statusLabel.leadingAnchor),
            placeLabel.trailingAnchor.constraint(lessThanOrEqualTo: muteButton.leadingAnchor, constant: -8),
            // The same 12 pt bottom margin as the message box next to it.
            placeLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),

            leaveButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            deafenButton.trailingAnchor.constraint(equalTo: leaveButton.leadingAnchor, constant: -4),
            muteButton.trailingAnchor.constraint(equalTo: deafenButton.leadingAnchor, constant: -4),
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
            statusLabel.stringValue = "Connecting…"
            statusLabel.textColor = .secondaryLabelColor
            statusLabel.toolTip = nil
        case .connected(let encrypted):
            statusLabel.stringValue = encrypted ? "Voice Connected · End-to-End Encrypted" : "Voice Connected"
            statusLabel.textColor = .systemGreen
            statusLabel.toolTip = encrypted
                ? "Only the people in this call can hear it."
                : "Setting up end-to-end encryption. Nothing you say is sent until it's ready."
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

    @objc private func mute() { onMute?() }
    @objc private func deafen() { onDeafen?() }
    @objc private func leave() { onLeave?() }

    private static func symbol(_ name: String, _ label: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: label)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
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

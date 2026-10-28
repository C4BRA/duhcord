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

        // A hidden voice bar takes no space.
        let stack = NSStackView(views: [scroll, voiceBar])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .width

        let container = NSVisualEffectView()
        container.material = .sidebar
        container.blendingMode = .behindWindow
        [titleLabel, stack].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview($0)
        }
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            titleLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        view = container
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
            voiceBar.isHidden = true
            return
        }
        let channel = store.channel(channelID)
        let guild = voice.guildID.flatMap { store.guilds[$0] }
        voiceBar.update(status: voice.status, place: [channel?.displayName, guild?.name].compactMap { $0 }.joined(separator: " · "),
                        muted: voice.muted || voice.deafened, deafened: voice.deafened,
                        serverMuted: voice.serverMuted, serverDeafened: voice.serverDeafened)
        voiceBar.isHidden = false
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
            cell.configureMember(name: name(of: state, in: guildID), speaking: voice.speaking.contains(state.userId),
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

    private let label = NSTextField(labelWithString: "")
    private let badge = NSTextField(labelWithString: "")
    private var leading: NSLayoutConstraint!

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        label.lineBreakMode = .byTruncatingTail
        badge.alignment = .right
        [label, badge].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }
        badge.setContentCompressionResistancePriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        leading = label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4)
        NSLayoutConstraint.activate([
            leading,
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            badge.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 4),
            badge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            badge.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func configure(_ item: ChannelListItem, store: Store, inCall: Bool) {
        leading.constant = 4
        badge.font = .boldSystemFont(ofSize: 10)
        badge.textColor = .systemRed
        switch item {
        case .category(let c):
            label.stringValue = c.displayName.uppercased()
            label.font = .systemFont(ofSize: 11, weight: .semibold)
            label.textColor = .secondaryLabelColor
            badge.stringValue = ""
        case .channel(let c):
            let unread = store.isUnread(c.id)
            label.stringValue = c.isPrivate ? c.displayName : "# " + c.displayName
            label.font = unread ? Theme.boldFont : Theme.bodyFont
            label.textColor = unread ? .labelColor : .secondaryLabelColor
            let mentions = store.mentionCount(c.id)
            badge.stringValue = mentions > 0 ? String(mentions) : ""
        case .voiceChannel(let c):
            label.stringValue = "🔊 " + c.displayName
            label.font = inCall ? Theme.boldFont : Theme.bodyFont
            label.textColor = inCall ? .labelColor : .secondaryLabelColor
            badge.stringValue = ""
        }
    }

    func configureMember(name: String, speaking: Bool, muted: Bool, deafened: Bool) {
        leading.constant = 26
        label.stringValue = name
        label.font = Theme.smallFont
        label.textColor = speaking ? .systemGreen : .secondaryLabelColor
        badge.font = .systemFont(ofSize: 10)
        badge.textColor = .tertiaryLabelColor
        badge.stringValue = deafened ? "deafened" : muted ? "muted" : ""
    }
}

/// The call we're in: where, whether it's connected and end-to-end encrypted, and mute, deafen and leave.
private final class VoiceBar: NSView {
    var onMute: (() -> Void)?
    var onDeafen: (() -> Void)?
    var onLeave: (() -> Void)?

    private let statusLabel = NSTextField(labelWithString: "")
    private let placeLabel = NSTextField(labelWithString: "")
    private let muteButton = VoiceBar.button("mic.fill", "Mute")
    private let deafenButton = VoiceBar.button("headphones", "Deafen")
    private let leaveButton = VoiceBar.button("phone.down.fill", "Leave")

    init() {
        super.init(frame: .zero)
        statusLabel.font = .boldSystemFont(ofSize: 11)
        placeLabel.font = Theme.smallFont
        placeLabel.textColor = .secondaryLabelColor
        placeLabel.lineBreakMode = .byTruncatingTail
        leaveButton.contentTintColor = .systemRed
        muteButton.target = self
        muteButton.action = #selector(mute)
        deafenButton.target = self
        deafenButton.action = #selector(deafen)
        leaveButton.target = self
        leaveButton.action = #selector(leave)

        let labels = NSStackView(views: [statusLabel, placeLabel])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 1
        labels.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [labels, muteButton, deafenButton, leaveButton])
        row.orientation = .horizontal
        row.spacing = 2
        row.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 8)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        addSubview(divider)
        NSLayoutConstraint.activate([
            divider.topAnchor.constraint(equalTo: topAnchor),
            divider.leadingAnchor.constraint(equalTo: leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: divider.bottomAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
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
            statusLabel.stringValue = encrypted ? "Voice connected 🔒" : "Voice connected"
            statusLabel.textColor = .systemGreen
            statusLabel.toolTip = encrypted
                ? "End-to-end encrypted: only the people in this call can hear it."
                : "Setting up end-to-end encryption…"
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
        muteButton.image = NSImage(systemSymbolName: micOff ? "mic.slash.fill" : "mic.fill", accessibilityDescription: muted ? "Unmute" : "Mute")
        muteButton.contentTintColor = micOff ? .systemRed : nil
        muteButton.toolTip = muted ? "Unmute" : "Mute"
        deafenButton.image = NSImage(systemSymbolName: soundOff ? "speaker.slash.fill" : "headphones",
                                     accessibilityDescription: deafened ? "Undeafen" : "Deafen")
        deafenButton.contentTintColor = soundOff ? .systemRed : nil
        deafenButton.toolTip = deafened ? "Undeafen" : "Deafen"
    }

    @objc private func mute() { onMute?() }
    @objc private func deafen() { onDeafen?() }
    @objc private func leave() { onLeave?() }

    private static func button(_ symbol: String, _ label: String) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: label) ?? NSImage(),
                              target: nil, action: nil)
        button.bezelStyle = .inline
        button.isBordered = false
        button.toolTip = label
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }
}

import AppKit
import DuhcordCore

/// The middle column: text channels under their categories, or the DM list.
final class ChannelListViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    var onSelect: ((Snowflake) -> Void)?

    private let store: Store
    private let titleLabel = NSTextField(labelWithString: "")
    private let table = NSTableView()
    private var place: Place = .directMessages
    private var items: [ChannelListItem] = []
    private var suppressSelection = false

    /// Channel IDs in display order, for keyboard navigation.
    var channelIDs: [Snowflake] {
        items.compactMap { if case .channel(let c) = $0 { return c.id } else { return nil } }
    }

    init(store: Store) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        let column = NSTableColumn(identifier: .init("channel"))
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .sourceList
        table.rowHeight = 24
        table.dataSource = self
        table.delegate = self

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false

        titleLabel.font = .boldSystemFont(ofSize: 13)
        titleLabel.lineBreakMode = .byTruncatingTail

        let container = NSVisualEffectView()
        container.material = .sidebar
        container.blendingMode = .behindWindow
        [titleLabel, scroll].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview($0)
        }
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            titleLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
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
        table.reloadData()
        if let focused = store.focusedChannelID { select(focused) }
    }

    func refreshIndicators() {
        // DM order follows activity, so it can change with any new message.
        if place == .directMessages, channelIDs != store.privateChannels.map(\.id) {
            reload()
            return
        }
        table.enumerateAvailableRowViews { rowView, row in
            if let cell = rowView.view(atColumn: 0) as? ChannelCell { cell.configure(items[row], store: store) }
        }
    }

    func select(_ channelID: Snowflake) {
        guard let row = items.firstIndex(where: { if case .channel(let c) = $0 { return c.id == channelID } else { return false } })
        else { return }
        suppressSelection = true
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
        suppressSelection = false
    }

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: ChannelCell.identifier, owner: nil) as? ChannelCell ?? ChannelCell()
        cell.configure(items[row], store: store)
        return cell
    }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .category = items[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .category = items[row] { return false }
        return true
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !suppressSelection, table.selectedRow >= 0, case .channel(let c) = items[table.selectedRow] else { return }
        onSelect?(c.id)
    }
}

private final class ChannelCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("ChannelCell")

    private let label = NSTextField(labelWithString: "")
    private let badge = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        label.lineBreakMode = .byTruncatingTail
        badge.font = .boldSystemFont(ofSize: 10)
        badge.textColor = .systemRed
        badge.alignment = .right
        [label, badge].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }
        badge.setContentCompressionResistancePriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            badge.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 4),
            badge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            badge.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func configure(_ item: ChannelListItem, store: Store) {
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
        }
    }
}

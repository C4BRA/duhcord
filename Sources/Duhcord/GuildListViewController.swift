import AppKit
import DuhcordCore

/// The narrow left column: DMs, then one rounded tile of initials per guild.
final class GuildListViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    var onSelect: ((Place) -> Void)?

    private let store: Store
    private let table = NSTableView()
    private var places: [Place] = [.directMessages]
    private var suppressSelection = false

    init(store: Store) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        table.addTableColumn(NSTableColumn(identifier: .init("guild")))
        table.fitColumnToWidth()
        table.headerView = nil
        table.rowHeight = 52
        table.intercellSpacing = .zero
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .none
        table.style = .plain
        table.dataSource = self
        table.delegate = self

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = false
        scroll.drawsBackground = false
        scroll.contentInsets = NSEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)

        let column = GuildColumnView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        column.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: column.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: column.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: column.trailingAnchor, constant: -1),
        ])
        view = column
    }

    func reload() {
        places = [.directMessages] + store.guildOrder.map { .guild($0) }
        table.reloadData()
    }

    func refreshIndicators() {
        table.enumerateAvailableRowViews { rowView, row in
            (rowView.view(atColumn: 0) as? GuildCell)?.configure(place: places[row], store: store)
        }
    }

    func select(_ place: Place) {
        guard let row = places.firstIndex(of: place) else { return }
        suppressSelection = true
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
        suppressSelection = false
        refreshIndicators()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { places.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: GuildCell.identifier, owner: nil) as? GuildCell ?? GuildCell()
        cell.configure(place: places[row], store: store)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !suppressSelection, table.selectedRow >= 0 else { return }
        onSelect?(places[table.selectedRow])
    }

    /// Selection is shown by the tile itself, so refresh tiles when it changes.
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        DispatchQueue.main.async { self.refreshIndicators() }
        return true
    }
}

/// Solid darker background with a hairline on the right, so the guild strip is clearly its own column.
private final class GuildColumnView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        Theme.guildColumnBackground.setFill()
        dirtyRect.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: bounds.maxX - 1, y: 0, width: 1, height: bounds.height).fill()
    }
}

private final class GuildCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("GuildCell")

    private let tile = NSView()
    private let label = NSTextField(labelWithString: "")
    private let pill = NSView()
    private let badge = NSTextField(labelWithString: "")
    private var pillHeight: CGFloat = 8

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier

        tile.wantsLayer = true
        tile.layer?.cornerRadius = 14
        label.alignment = .center
        label.font = .boldSystemFont(ofSize: 13)
        label.lineBreakMode = .byClipping
        pill.wantsLayer = true
        pill.layer?.cornerRadius = 2
        badge.font = .boldSystemFont(ofSize: 9)
        badge.alignment = .center
        badge.textColor = .white
        badge.wantsLayer = true
        badge.layer?.backgroundColor = NSColor.systemRed.cgColor
        badge.layer?.cornerRadius = 7

        [tile, label, pill, badge].forEach(addSubview)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        let size: CGFloat = 40
        tile.frame = NSRect(x: (bounds.width - size) / 2, y: (bounds.height - size) / 2, width: size, height: size)
        let labelHeight: CGFloat = 18
        label.frame = NSRect(x: tile.frame.minX, y: tile.frame.midY - labelHeight / 2, width: size, height: labelHeight)
        pill.frame = NSRect(x: 0, y: bounds.midY - pillHeight / 2, width: 4, height: pillHeight)
        badge.frame = NSRect(x: tile.frame.maxX - 12, y: tile.frame.minY - 2, width: 16, height: 14)
    }

    private var lastPlace: Place?
    private weak var lastStore: Store?

    /// Layer colours are fixed CGColors, so they need refreshing when the appearance changes.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        if let lastPlace, let lastStore { configure(place: lastPlace, store: lastStore) }
    }

    func configure(place: Place, store: Store) {
        lastPlace = place
        lastStore = store
        let selected = (superview as? NSTableRowView)?.isSelected ?? false
        let unread: Bool
        let mentions: Int
        switch place {
        case .directMessages:
            label.stringValue = "DM"
            toolTip = "Direct Messages"
            unread = store.privateUnreadCount > 0
            mentions = store.privateChannels.reduce(0) { $0 + store.mentionCount($1.id) }
        case .guild(let id):
            let name = store.guilds[id]?.name ?? ""
            label.stringValue = Theme.initials(name)
            toolTip = name
            unread = store.guildHasUnread(id)
            mentions = store.guildMentionCount(id)
        }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            tile.layer?.backgroundColor = (selected ? NSColor.controlAccentColor : NSColor.quaternaryLabelColor).cgColor
            pill.layer?.backgroundColor = NSColor.labelColor.cgColor
        }
        tile.layer?.cornerRadius = selected ? 12 : 20
        label.textColor = selected ? .white : .labelColor
        pill.isHidden = !(unread || selected)
        // A taller pill marks the selected guild; a short one marks unread.
        pillHeight = selected ? 28 : 8
        badge.isHidden = mentions == 0
        badge.stringValue = mentions > 99 ? "99+" : String(mentions)
        needsLayout = true
    }
}

import AppKit
import DuhcordCore

/// The sidebar: Direct Messages, then every server, as a standard macOS source list (like Mail's mailboxes).
/// Rows follow System Settings → Appearance → Sidebar icon size, or the small size in compact layout.
final class GuildListViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    var onSelect: ((Place) -> Void)?
    /// "Mark as Read" on a server or on Direct Messages.
    var onMarkAllRead: ((Place) -> Void)?

    private enum Row: Equatable {
        case place(Place)
        case header(String)
    }

    private let store: Store
    private let table = NSTableView()
    private var rows: [Row] = []
    private var suppressSelection = false

    init(store: Store) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        table.addTableColumn(NSTableColumn(identifier: .init("place")))
        table.fitColumnToWidth()
        table.headerView = nil
        table.style = .sourceList
        table.rowSizeStyle = Theme.listRowSize
        table.floatsGroupRows = false
        table.dataSource = self
        table.delegate = self
        table.setAccessibilityLabel("Servers")
        let menu = NSMenu()
        menu.delegate = self
        table.menu = menu

        let scroll = VerticalScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        view = scroll
        NotificationCenter.default.addObserver(self, selector: #selector(settingsChanged), name: Settings.didChange, object: nil)
    }

    /// Keeps the column fitted to the list after layout changes. AppKit does the sizing so the source list's row
    /// insets are taken into account; setting the column to the full visible width made cells wider than their
    /// rows and clipped anything on the right (mute icons, mention badges).
    override func viewDidLayout() {
        super.viewDidLayout()
        table.sizeLastColumnToFit()
    }

    func reload() {
        rows = [.place(.directMessages)]
        if !store.guildOrder.isEmpty {
            rows.append(.header("Servers"))
            rows += store.guildOrder.map { .place(.guild($0)) }
        }
        let selected = table.selectedRow >= 0 && table.selectedRow < rows.count ? rows[table.selectedRow] : nil
        table.reloadData()
        if case .place(let place)? = selected { select(place, scroll: false) }
    }

    func refreshIndicators() {
        table.enumerateAvailableRowViews { rowView, row in
            guard row < rows.count, case .place(let place) = rows[row],
                  let cell = rowView.view(atColumn: 0) as? PlaceCell else { return }
            cell.configure(place: place, store: store, size: table.effectiveRowSizeStyle)
        }
    }

    func select(_ place: Place, scroll: Bool = true) {
        guard let row = rows.firstIndex(of: .place(place)) else { return }
        suppressSelection = true
        table.selectRowIndexes([row], byExtendingSelection: false)
        if scroll { table.scrollRowToVisible(row) }
        suppressSelection = false
    }

    @objc private func settingsChanged() {
        guard table.rowSizeStyle != Theme.listRowSize else { return }
        table.rowSizeStyle = Theme.listRowSize
        reload()
    }

    /// Right-click on a server or Direct Messages, as in the official client.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = table.clickedRow
        guard row >= 0, row < rows.count, case .place(let place) = rows[row] else { return }
        let unread: Bool
        switch place {
        case .directMessages: unread = store.privateUnreadCount > 0
        case .guild(let id): unread = store.guildHasUnread(id)
        }
        menu.addItem(ActionMenuItem("Mark as Read", enabled: unread) { [weak self] in self?.onMarkAllRead?(place) })
        if case .guild(let id) = place {
            menu.addItem(ActionMenuItem("Copy Link") { Pasteboard.copy("https://discord.com/channels/\(id)") })
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .header(let title):
            let header = tableView.makeView(withIdentifier: HeaderCell.identifier, owner: nil) as? HeaderCell ?? HeaderCell()
            header.textField?.stringValue = title
            return header
        case .place(let place):
            let cell = tableView.makeView(withIdentifier: PlaceCell.identifier, owner: nil) as? PlaceCell ?? PlaceCell()
            cell.configure(place: place, store: store, size: tableView.effectiveRowSizeStyle)
            return cell
        }
    }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .header = rows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .place = rows[row] { return true }
        return false
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !suppressSelection, table.selectedRow >= 0, case .place(let place) = rows[table.selectedRow] else { return }
        onSelect?(place)
    }
}

/// "Servers": a standard source-list section header.
private final class HeaderCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("HeaderCell")

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        let label = NSTextField(labelWithString: "")
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Spacing.tight),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}

/// One sidebar row: icon, name (bold while unread) and a mention count.
private final class PlaceCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("PlaceCell")

    private let icon = RemoteImageView()
    private let symbol = NSImageView()
    /// Shown for servers without an icon.
    private let monogram = NSTextField(labelWithString: "")
    private let name = NSTextField(labelWithString: "")
    private let badge = BadgeView()

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        icon.cornerRadius = Theme.Radius.small
        monogram.alignment = .center
        monogram.font = .systemFont(ofSize: 9, weight: .semibold)
        monogram.textColor = .secondaryLabelColor
        monogram.wantsLayer = true
        monogram.layer?.cornerRadius = Theme.Radius.small
        symbol.symbolConfiguration = .init(pointSize: 13, weight: .regular)
        symbol.contentTintColor = .controlAccentColor
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        badge.setContentCompressionResistancePriority(.required, for: .horizontal)
        [icon, symbol, monogram, name, badge].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }
        let size = Theme.IconSize.sidebar
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Spacing.tight),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: size),
            icon.heightAnchor.constraint(equalToConstant: size),
            symbol.centerXAnchor.constraint(equalTo: icon.centerXAnchor),
            symbol.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
            monogram.centerXAnchor.constraint(equalTo: icon.centerXAnchor),
            monogram.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
            monogram.widthAnchor.constraint(equalToConstant: size),
            name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: Theme.Spacing.related),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
            badge.leadingAnchor.constraint(greaterThanOrEqualTo: name.trailingAnchor, constant: Theme.Spacing.tight),
            badge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.Spacing.related),
            badge.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            monogram.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        }
    }

    func configure(place: Place, store: Store, size: NSTableView.RowSizeStyle) {
        let unread: Bool
        let mentions: Int
        let title: String
        switch place {
        case .directMessages:
            title = "Direct Messages"
            unread = store.privateUnreadCount > 0
            mentions = store.privateMentionCount
            symbol.image = NSImage(systemSymbolName: "bubble.left.and.bubble.right.fill", accessibilityDescription: nil)
            symbol.isHidden = false
            icon.setImage(nil, pointSize: .zero)
            icon.isHidden = true
            monogram.isHidden = true
        case .guild(let id):
            let guild = store.guilds[id]
            title = guild?.name ?? ""
            unread = store.guildHasUnread(id)
            mentions = store.guildMentionCount(id)
            symbol.isHidden = true
            monogram.stringValue = Theme.initials(title)
            monogram.isHidden = false
            icon.isHidden = false
            let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
            let pixels = Int(Theme.IconSize.sidebar * scale)
            icon.setImage(guild.flatMap { MediaRequest.iconURL(for: $0, pixels: pixels) },
                          pointSize: NSSize(width: Theme.IconSize.sidebar, height: Theme.IconSize.sidebar)) { [weak self] loaded in
                self?.monogram.isHidden = loaded
            }
        }
        name.stringValue = title
        name.font = Theme.listFont(for: size, bold: unread)
        name.textColor = .labelColor
        badge.count = mentions
        monogram.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor

        var spoken = title
        if mentions > 0 { spoken += ", \(mentions) mention\(mentions == 1 ? "" : "s")" } else if unread { spoken += ", unread" }
        setAccessibilityLabel(spoken)
    }
}

/// A source-list count badge (like Mail's unread counts), red because mentions need attention.
final class BadgeView: NSView {
    private let label = NSTextField(labelWithString: "")

    var count = 0 {
        didSet {
            label.stringValue = count > 99 ? "99+" : String(count)
            isHidden = count == 0
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 8
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        label.textColor = .white
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 16),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 16),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.systemRed.cgColor
    }

    override var wantsUpdateLayer: Bool { true }
}

import AppKit
import DuhcordCore

/// ⌘K: type part of a channel, server or person's name and press Return. Styled like Spotlight: a floating,
/// translucent panel with a large search field and the matches underneath.
final class QuickSwitcher: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSWindowDelegate {
    private struct Entry {
        let channelID: Snowflake
        let title: String
        let subtitle: String
        let symbol: String
        let searchText: String
    }

    /// A borderless panel still needs to take keyboard focus for the search field.
    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { true }
    }

    private static let width: CGFloat = 560
    private static let fieldHeight: CGFloat = 52
    private static let rowHeight: CGFloat = 36
    private static let maxRows = 8

    private let store: Store
    private let onPick: (Snowflake) -> Void
    private let panel: Panel
    private let field = NSTextField()
    private let table = NSTableView()
    private let separator = NSBox()
    private let allEntries: [Entry]
    private var entries: [Entry] = []

    init(store: Store, onPick: @escaping (Snowflake) -> Void) {
        self.store = store
        self.onPick = onPick
        panel = Panel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: Self.fieldHeight),
                      styleMask: [.borderless, .fullSizeContentView], backing: .buffered, defer: false)

        var list: [Entry] = store.privateChannels.map {
            Entry(channelID: $0.id, title: $0.displayName, subtitle: "Direct Message", symbol: "person.fill",
                  searchText: $0.displayName.lowercased())
        }
        for guild in store.orderedGuilds {
            for case .channel(let c) in store.channelList(guildID: guild.id) {
                list.append(Entry(channelID: c.id, title: c.displayName, subtitle: guild.name,
                                  symbol: c.kind == .announcement ? "megaphone" : "number",
                                  searchText: (c.displayName + " " + guild.name).lowercased()))
            }
        }
        allEntries = list
        super.init()
        buildUI()
        filter("")
    }

    private func buildUI() {
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.delegate = self

        let background = NSVisualEffectView()
        background.material = .popover
        background.state = .active
        background.blendingMode = .behindWindow
        background.wantsLayer = true
        background.layer?.cornerRadius = Theme.Radius.panel
        background.layer?.masksToBounds = true
        panel.contentView = background

        let glass = NSImageView(image: NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil) ?? NSImage())
        glass.symbolConfiguration = .init(pointSize: 18, weight: .regular)
        glass.contentTintColor = .secondaryLabelColor

        field.placeholderString = "Jump to a channel or person"
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 20)
        field.delegate = self
        field.setAccessibilityLabel("Jump to a channel or person")

        separator.boxType = .separator

        table.addTableColumn(NSTableColumn(identifier: .init("entry")))
        table.fitColumnToWidth()
        table.headerView = nil
        table.style = .sourceList
        table.rowHeight = Self.rowHeight
        table.backgroundColor = .clear
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(pickSelected)

        let scroll = VerticalScrollView()
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true

        [glass, field, separator, scroll].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            background.addSubview($0)
        }
        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: Theme.Spacing.edge - 2),
            glass.centerYAnchor.constraint(equalTo: background.topAnchor, constant: Self.fieldHeight / 2),
            field.leadingAnchor.constraint(equalTo: glass.trailingAnchor, constant: Theme.Spacing.group),
            field.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -Theme.Spacing.edge),
            field.centerYAnchor.constraint(equalTo: glass.centerYAnchor),
            separator.topAnchor.constraint(equalTo: background.topAnchor, constant: Self.fieldHeight),
            separator.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: Theme.Spacing.tight),
            scroll.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: Theme.Spacing.related),
            scroll.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -Theme.Spacing.related),
            scroll.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -Theme.Spacing.related),
        ])
    }

    private weak var parent: NSWindow?

    /// Centred over the window, in its upper third, like Spotlight over the screen.
    func present(over window: NSWindow) {
        parent = window
        resize()
        window.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
    }

    /// The panel grows with the number of matches, up to a limit, and keeps its top edge in place.
    private func resize() {
        let rows = min(entries.count, Self.maxRows)
        let height = Self.fieldHeight + (rows == 0 ? 0 : CGFloat(rows) * Self.rowHeight + Theme.Spacing.tight + Theme.Spacing.related + 1)
        separator.isHidden = rows == 0
        let top: CGFloat
        let x: CGFloat
        if panel.isVisible {
            top = panel.frame.maxY
            x = panel.frame.minX
        } else if let parent {
            top = parent.frame.maxY - parent.frame.height / 4
            x = parent.frame.midX - Self.width / 2
        } else {
            return
        }
        panel.setFrame(NSRect(x: x, y: top - height, width: Self.width, height: height), display: true)
    }

    private func close() {
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    private func filter(_ query: String) {
        let terms = query.lowercased().split(separator: " ")
        entries = terms.isEmpty ? allEntries : allEntries.filter { entry in terms.allSatisfy { entry.searchText.contains($0) } }
        // Channels with unread messages float to the top.
        entries = entries.filter { store.isUnread($0.channelID) } + entries.filter { !store.isUnread($0.channelID) }
        table.reloadData()
        if !entries.isEmpty { table.selectRowIndexes([0], byExtendingSelection: false) }
        resize()
    }

    @objc private func pickSelected() {
        let row = table.selectedRow
        guard row >= 0, row < entries.count else { return }
        let id = entries[row].channelID
        close()
        onPick(id)
    }

    // MARK: - Delegates

    func controlTextDidChange(_ obj: Notification) { filter(field.stringValue) }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            move(1)
        case #selector(NSResponder.moveUp(_:)):
            move(-1)
        case #selector(NSResponder.insertNewline(_:)):
            pickSelected()
        case #selector(NSResponder.cancelOperation(_:)):
            close()
        default:
            return false
        }
        return true
    }

    func windowDidResignKey(_ notification: Notification) { close() }

    private func move(_ delta: Int) {
        guard !entries.isEmpty else { return }
        let row = max(0, min(entries.count - 1, table.selectedRow + delta))
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: SwitcherCell.identifier, owner: nil) as? SwitcherCell ?? SwitcherCell()
        let entry = entries[row]
        cell.configure(title: entry.title, subtitle: entry.subtitle, symbol: entry.symbol, unread: store.isUnread(entry.channelID))
        return cell
    }
}

/// One match: icon, name (bold while unread), and where it is.
private final class SwitcherCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("SwitcherCell")

    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        icon.symbolConfiguration = .init(pointSize: 14, weight: .regular)
        icon.contentTintColor = .secondaryLabelColor
        title.lineBreakMode = .byTruncatingTail
        subtitle.font = Theme.smallFont
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        subtitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        [icon, title, subtitle].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Spacing.related),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: Theme.IconSize.sidebar),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: Theme.Spacing.related),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            subtitle.leadingAnchor.constraint(equalTo: title.trailingAnchor, constant: Theme.Spacing.related),
            subtitle.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Theme.Spacing.related),
            subtitle.firstBaselineAnchor.constraint(equalTo: title.firstBaselineAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func configure(title text: String, subtitle detail: String, symbol: String, unread: Bool) {
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        title.stringValue = text
        title.font = unread ? Theme.boldFont : Theme.bodyFont
        subtitle.stringValue = detail
        setAccessibilityLabel(text + ", " + detail + (unread ? ", unread" : ""))
    }
}

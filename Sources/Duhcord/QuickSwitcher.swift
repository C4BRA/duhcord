import AppKit
import DuhcordCore

/// ⌘K: type part of a channel, server or person's name and press Return.
final class QuickSwitcher: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSWindowDelegate {
    private struct Entry {
        let channelID: Snowflake
        let title: String
        let subtitle: String
        let searchText: String
    }

    private let store: Store
    private let onPick: (Snowflake) -> Void
    private let panel: NSPanel
    private let field = NSSearchField()
    private let table = NSTableView()
    private let allEntries: [Entry]
    private var entries: [Entry] = []

    init(store: Store, onPick: @escaping (Snowflake) -> Void) {
        self.store = store
        self.onPick = onPick
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 320),
                        styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)

        var list: [Entry] = store.privateChannels.map {
            Entry(channelID: $0.id, title: "@ " + $0.displayName, subtitle: "Direct Message", searchText: $0.displayName.lowercased())
        }
        for guild in store.orderedGuilds {
            for case .channel(let c) in store.channelList(guildID: guild.id) {
                list.append(Entry(channelID: c.id, title: "# " + c.displayName, subtitle: guild.name,
                                  searchText: (c.displayName + " " + guild.name).lowercased()))
            }
        }
        allEntries = list
        super.init()
        buildUI()
        filter("")
    }

    private func buildUI() {
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.delegate = self

        field.placeholderString = "Jump to channel or person"
        field.delegate = self
        field.font = .systemFont(ofSize: 15)

        table.addTableColumn(NSTableColumn(identifier: .init("entry")))
        table.headerView = nil
        table.rowHeight = 34
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(pickSelected)

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true

        let content = panel.contentView!
        [field, scroll].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview($0)
        }
        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: content.topAnchor, constant: 32),
            field.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            field.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
    }

    func present(over window: NSWindow) {
        let frame = window.frame
        panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.maxY - panel.frame.height - 80))
        window.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
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
        let id = NSUserInterfaceItemIdentifier("SwitcherCell")
        let label = tableView.makeView(withIdentifier: id, owner: nil) as? NSTextField ?? {
            let l = NSTextField(labelWithString: "")
            l.identifier = id
            l.lineBreakMode = .byTruncatingTail
            return l
        }()
        let entry = entries[row]
        let text = NSMutableAttributedString(string: entry.title, attributes: [
            .font: store.isUnread(entry.channelID) ? Theme.boldFont : Theme.bodyFont,
            .foregroundColor: NSColor.labelColor,
        ])
        text.append(NSAttributedString(string: "   " + entry.subtitle, attributes: [
            .font: Theme.smallFont,
            .foregroundColor: NSColor.secondaryLabelColor,
        ]))
        label.attributedStringValue = text
        return label
    }
}

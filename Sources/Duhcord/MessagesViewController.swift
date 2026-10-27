import AppKit
import DuhcordCore

/// The right column: channel title, message history and the input box.
final class MessagesViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private struct Row {
        let message: Message
        /// Same author shortly after the previous message, so the name/time line is skipped.
        let grouped: Bool
    }

    private let session: DiscordSession
    private var store: Store { session.store }

    private let titleLabel = NSTextField(labelWithString: "")
    private let emptyLabel = NSTextField(labelWithString: "")
    private let scrollView = NSScrollView()
    private let table = NSTableView()
    private let input = ComposerView()

    private var channelID: Snowflake?
    private var rows: [Row] = []
    private var bodyCache: [String: NSAttributedString] = [:]
    private var heightCache: [String: CGFloat] = [:]
    private var lastWidth: CGFloat = 0

    private static let sidePadding: CGFloat = 16
    private static var headerHeight: CGFloat { ceil(Settings.textSize.pointSize * 1.4) }
    private static let groupWindow: TimeInterval = 7 * 60

    init(session: DiscordSession) {
        self.session = session
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        let root = NSView()

        titleLabel.font = .boldSystemFont(ofSize: 14)
        titleLabel.lineBreakMode = .byTruncatingTail

        let column = NSTableColumn(identifier: .init("message"))
        table.addTableColumn(column)
        table.fitColumnToWidth()
        table.headerView = nil
        table.style = .plain
        table.selectionHighlightStyle = .none
        table.intercellSpacing = .zero
        table.backgroundColor = .textBackgroundColor
        table.dataSource = self
        table.delegate = self

        scrollView.documentView = table
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(didScroll),
                                               name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        table.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(didResize),
                                               name: NSView.frameDidChangeNotification, object: table)
        NotificationCenter.default.addObserver(self, selector: #selector(settingsChanged),
                                               name: Settings.didChange, object: nil)

        input.placeholder = "Message"
        input.font = Theme.messageFont
        input.onSend = { [weak self] text in self?.send(text) }
        // Growing the box shrinks the message list; stay pinned to the newest message if we were.
        input.onHeightChange = { [weak self] in
            guard let self, self.isAtBottom else { return }
            self.view.layoutSubtreeIfNeeded()
            self.scrollToBottom()
        }

        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center

        let divider = NSBox()
        divider.boxType = .separator

        [titleLabel, divider, scrollView, input, emptyLabel].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview($0)
        }
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            titleLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Self.sidePadding),
            titleLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Self.sidePadding),
            divider.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            divider.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: divider.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            input.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 8),
            input.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Self.sidePadding),
            input.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Self.sidePadding),
            input.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
        ])
        view = root
    }

    // MARK: - Showing a channel

    func show(channelID: Snowflake?) {
        guard channelID != self.channelID else { return }
        self.channelID = channelID
        bodyCache = [:]
        heightCache = [:]

        if let channelID, let channel = store.channel(channelID) {
            titleLabel.stringValue = channel.isPrivate ? "@ " + channel.displayName : "# " + channel.displayName
            input.placeholder = channel.isPrivate ? "Message @\(channel.displayName)" : "Message #\(channel.displayName)"
            input.isEnabled = true
        } else {
            titleLabel.stringValue = ""
            input.placeholder = ""
            input.isEnabled = false
        }
        rebuildRows()
        table.reloadData()
        scrollToBottom()
        updateEmptyState()
        input.focus()
    }

    func messagesChanged(in channelID: Snowflake) {
        guard channelID == self.channelID else { return }
        let oldFirst = rows.first?.message.id
        let wasAtBottom = isAtBottom
        let clip = scrollView.contentView
        let distanceFromBottom = table.bounds.height - clip.bounds.origin.y

        rebuildRows()
        table.reloadData()
        updateEmptyState()

        if wasAtBottom || oldFirst == nil {
            scrollToBottom()
        } else if rows.first?.message.id != oldFirst {
            // Older messages were added above: keep what the user was reading in place.
            table.layoutSubtreeIfNeeded()
            clip.scroll(to: NSPoint(x: 0, y: max(0, table.bounds.height - distanceFromBottom)))
            scrollView.reflectScrolledClipView(clip)
        }
    }

    private func rebuildRows() {
        guard let channelID, let messages = store.messages(in: channelID) else {
            rows = []
            return
        }
        var result: [Row] = []
        result.reserveCapacity(messages.count)
        var previous: Message?
        for message in messages {
            var grouped = false
            if let previous, previous.author.id == message.author.id, message.referencedMessage == nil,
               let a = previous.date, let b = message.date, b.timeIntervalSince(a) < Self.groupWindow {
                grouped = true
            }
            result.append(Row(message: message, grouped: grouped))
            previous = message
        }
        rows = result
    }

    private func updateEmptyState() {
        guard let channelID else {
            emptyLabel.stringValue = "Pick a channel"
            emptyLabel.isHidden = false
            return
        }
        if store.messages(in: channelID) == nil {
            emptyLabel.stringValue = "Loading…"
            emptyLabel.isHidden = false
        } else if rows.isEmpty {
            emptyLabel.stringValue = "No messages yet"
            emptyLabel.isHidden = false
        } else {
            emptyLabel.isHidden = true
        }
    }

    // MARK: - Scrolling

    private var isAtBottom: Bool {
        let clip = scrollView.contentView
        return clip.bounds.maxY >= table.bounds.height - 40
    }

    private func scrollToBottom() {
        guard !rows.isEmpty else { return }
        table.scrollRowToVisible(rows.count - 1)
    }

    @objc private func didScroll() {
        guard let channelID, !rows.isEmpty, scrollView.contentView.bounds.minY < 300,
              !session.isLoading(channelID) else { return }
        session.loadOlder(channelID: channelID)
    }

    /// Text size or spacing changed: re-render everything, keeping the scroll position at the bottom if it was.
    @objc private func settingsChanged() {
        input.font = Theme.messageFont
        let wasAtBottom = isAtBottom
        bodyCache = [:]
        heightCache = [:]
        table.reloadData()
        if wasAtBottom { scrollToBottom() }
    }

    @objc private func didResize() {
        let width = table.bounds.width
        guard abs(width - lastWidth) > 0.5 else { return }
        lastWidth = width
        heightCache = [:]
        guard !rows.isEmpty else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<rows.count))
        }
    }

    // MARK: - Sending

    private func send(_ text: String) {
        guard let channelID else { return }
        input.text = ""
        session.send(text, to: channelID) { [weak self] error in
            guard let self, let error else { return }
            // Put the text back so nothing is lost.
            if self.input.text.isEmpty { self.input.text = text }
            // Connection problems lock the app instead; no separate alert.
            guard !DiscordSession.isConnectivityError(error) else { return }
            let alert = NSAlert()
            alert.messageText = "Message not sent"
            alert.informativeText = error.localizedDescription
            if let window = self.view.window { alert.beginSheetModal(for: window) }
        }
    }

    // MARK: - Rendering

    private func cacheKey(_ message: Message) -> String {
        message.id + "|" + (message.editedTimestamp ?? "") + "|" + String(message.content.hashValue)
    }

    private func body(for message: Message) -> NSAttributedString {
        let key = cacheKey(message)
        if let cached = bodyCache[key] { return cached }
        let mentioned = Dictionary((message.mentions ?? []).map { ($0.id, $0.displayName) }, uniquingKeysWith: { a, _ in a })
        let resolver = Markdown.Resolver(
            user: { [store = self.store] id in mentioned[id] ?? store.user(id)?.displayName },
            channel: { [store = self.store] id in store.channel(id)?.displayName }
        )
        let rendered = Theme.body(for: message, resolver: resolver)
        bodyCache[key] = rendered
        return rendered
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        let r = rows[row]
        let key = cacheKey(r.message) + (r.grouped ? "g" : "")
        if let cached = heightCache[key] { return cached }
        let width = max(50, tableView.bounds.width - 2 * Self.sidePadding)
        let rect = body(for: r.message).boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude),
                                                     options: [.usesLineFragmentOrigin, .usesFontLeading])
        let height = MessageCell.topPadding(grouped: r.grouped) + (r.grouped ? 0 : Self.headerHeight)
            + ceil(rect.height) + MessageCell.bottomPadding
        heightCache[key] = height
        return height
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: MessageCell.identifier, owner: nil) as? MessageCell ?? MessageCell()
        let r = rows[row]
        cell.configure(header: r.grouped ? nil : Theme.header(for: r.message), body: body(for: r.message),
                       grouped: r.grouped, sidePadding: Self.sidePadding, headerHeight: Self.headerHeight)
        return cell
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }
}

/// One message. Laid out by hand: no Auto Layout, so scrolling stays cheap.
private final class MessageCell: NSTableCellView, NSTextViewDelegate {
    static let identifier = NSUserInterfaceItemIdentifier("MessageCell")
    static let bottomPadding: CGFloat = 2
    static func topPadding(grouped: Bool) -> CGFloat { grouped ? 1 : (Settings.compactMessages ? 4 : 10) }

    private let headerField = NSTextField(labelWithString: "")
    private let bodyView = NSTextView()
    private var grouped = false
    private var sidePadding: CGFloat = 16
    private var headerHeight: CGFloat = 18

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        headerField.lineBreakMode = .byTruncatingTail
        bodyView.isEditable = false
        bodyView.isSelectable = true
        bodyView.drawsBackground = false
        bodyView.textContainerInset = .zero
        bodyView.textContainer?.lineFragmentPadding = 0
        bodyView.textContainer?.widthTracksTextView = true
        bodyView.isVerticallyResizable = false
        bodyView.linkTextAttributes = [.foregroundColor: NSColor.linkColor, .cursor: NSCursor.pointingHand]
        bodyView.delegate = self
        addSubview(headerField)
        addSubview(bodyView)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func configure(header: NSAttributedString?, body: NSAttributedString, grouped: Bool, sidePadding: CGFloat, headerHeight: CGFloat) {
        self.grouped = grouped
        self.sidePadding = sidePadding
        self.headerHeight = headerHeight
        headerField.isHidden = header == nil
        if let header { headerField.attributedStringValue = header }
        bodyView.textStorage?.setAttributedString(body)
        needsLayout = true
    }

    /// Every link goes through LinkOpener's checks instead of opening directly.
    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        guard let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:)) else { return true }
        var range = NSRange()
        let storage = textView.textStorage
        _ = storage?.attribute(.link, at: charIndex, effectiveRange: &range)
        let shown = storage.map { ($0.string as NSString).substring(with: range) }
        LinkOpener.open(url, shownText: shown, from: window)
        return true
    }

    override func layout() {
        super.layout()
        var y = Self.topPadding(grouped: grouped)
        let width = bounds.width - 2 * sidePadding
        if !headerField.isHidden {
            headerField.frame = NSRect(x: sidePadding, y: y, width: width, height: headerHeight)
            y += headerHeight
        }
        bodyView.frame = NSRect(x: sidePadding, y: y, width: width, height: max(0, bounds.height - y - Self.bottomPadding))
    }
}

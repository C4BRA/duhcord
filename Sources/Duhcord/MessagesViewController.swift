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
    private let typingTabs = TypingTabsView()
    private var typingTimer: Timer?

    private var channelID: Snowflake?
    private var rows: [Row] = []
    private struct LayoutKey: Hashable {
        let id: Snowflake
        let revision: Int
        let grouped: Bool
    }

    private struct CachedLayout {
        let layout: MessageLayout
        /// Name and time line, nil for grouped rows. Built once rather than on every scroll.
        let header: NSAttributedString?
    }

    /// Layouts for the current width. Cleared when the width, the channel or a display setting changes.
    private var layoutCache: [LayoutKey: CachedLayout] = [:]
    private var lastWidth: CGFloat = 0

    private static let sidePadding: CGFloat = 16
    /// Room between the newest message and the message box.
    private static let bottomInset: CGFloat = 10
    private static var headerHeight: CGFloat { ceil(Settings.textSize.pointSize * 1.4) }
    private static let groupWindow: TimeInterval = 7 * 60

    init(session: DiscordSession) {
        self.session = session
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        let root = LiveResizeView()
        root.onEndLiveResize = { [weak self] in self?.updateAllRowHeights() }

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
        input.onTextChange = { [weak self] text in
            guard let self, Settings.sendTypingIndicator, let channelID = self.channelID,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            self.session.userIsTyping(in: channelID)
        }
        session.onTypingChange = { [weak self] in self?.refreshTyping() }
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: Self.bottomInset, right: 0)
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

        [titleLabel, divider, scrollView, typingTabs, input, emptyLabel].forEach {
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
            input.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 12),
            // The tabs' bottom edge is the message box's top edge, so they rise out from behind it.
            typingTabs.bottomAnchor.constraint(equalTo: input.topAnchor),
            typingTabs.leadingAnchor.constraint(equalTo: input.leadingAnchor, constant: 14),
            typingTabs.heightAnchor.constraint(equalToConstant: TypingTabsView.tabSize.height),
            typingTabs.widthAnchor.constraint(equalToConstant: 7 * (TypingTabsView.tabSize.width + 4)),
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
        layoutCache = [:]

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
    @objc private func settingsChanged(_ note: Notification) {
        guard let key = note.userInfo?[Settings.keyInfo] as? String, Settings.messageLayoutKeys.contains(key) else { return }
        input.font = Theme.messageFont
        let wasAtBottom = isAtBottom
        layoutCache = [:]
        table.reloadData()
        if wasAtBottom { scrollToBottom() }
    }

    @objc private func didResize() {
        let width = table.bounds.width
        guard abs(width - lastWidth) > 0.5 else { return }
        lastWidth = width
        layoutCache = [:]
        if table.inLiveResize {
            // While dragging, only the rows on screen are re-laid out; the rest catch up when the drag ends.
            noteHeights(IndexSet(integersIn: Range<Int>(table.rows(in: table.visibleRect)) ?? 0..<0))
        } else {
            updateAllRowHeights()
        }
    }

    private func updateAllRowHeights() {
        noteHeights(IndexSet(integersIn: 0..<rows.count))
    }

    private func noteHeights(_ rows: IndexSet) {
        guard !rows.isEmpty else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            table.noteHeightOfRows(withIndexesChanged: rows)
        }
    }

    // MARK: - Typing tabs

    private func refreshTyping() {
        let wasAtBottom = isAtBottom
        typingTabs.update(session.typing.entries)
        // Keep the newest message clear of the tabs while any are showing.
        let inset = Self.bottomInset + (typingTabs.hasTabs ? TypingTabsView.tabSize.height - 8 : 0)
        if scrollView.contentInsets.bottom != inset {
            scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: inset, right: 0)
            if wasAtBottom { scrollToBottom() }
        }
        // One timer, set for the next tab that needs to lower or leave. None while there are no tabs.
        typingTimer?.invalidate()
        typingTimer = nil
        if let deadline = session.typing.nextDeadline {
            let timer = Timer(fire: deadline, interval: 0, repeats: false) { [weak self] _ in
                guard let self else { return }
                self.session.typing.tick(at: Date())
                self.refreshTyping()
            }
            timer.tolerance = 0.5
            RunLoop.main.add(timer, forMode: .common)
            typingTimer = timer
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

    private func layout(for row: Row) -> CachedLayout {
        let message = row.message
        // Edits and late link previews bump the revision.
        let key = LayoutKey(id: message.id, revision: message.revision, grouped: row.grouped)
        if let cached = layoutCache[key] { return cached }
        let mentioned = Dictionary((message.mentions ?? []).map { ($0.id, $0.displayName) }, uniquingKeysWith: { a, _ in a })
        let resolver = Markdown.Resolver(
            user: { [store = self.store] id in mentioned[id] ?? store.user(id)?.displayName },
            channel: { [store = self.store] id in store.channel(id)?.displayName }
        )
        let built = MessageLayoutBuilder.build(
            message: message, grouped: row.grouped, cellWidth: table.bounds.width, sidePadding: Self.sidePadding,
            headerHeight: Self.headerHeight, topPadding: MessageCell.topPadding(grouped: row.grouped),
            bottomPadding: MessageCell.bottomPadding, resolver: resolver)
        let cached = CachedLayout(layout: built, header: row.grouped ? nil : Theme.header(for: message))
        layoutCache[key] = cached
        return cached
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        layout(for: rows[row]).layout.height
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: MessageCell.identifier, owner: nil) as? MessageCell ?? MessageCell()
        let cached = layout(for: rows[row])
        cell.configure(cached.layout, header: cached.header)
        return cell
    }

    /// Rows scrolled out of view stop their image downloads.
    func tableView(_ tableView: NSTableView, didRemove rowView: NSTableRowView, forRow row: Int) {
        (rowView.view(atColumn: 0) as? MessageCell)?.cancelMedia()
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }
}

/// Tells the messages view when a window or divider drag ends.
private final class LiveResizeView: NSView {
    var onEndLiveResize: (() -> Void)?

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        onEndLiveResize?()
    }
}

/// One message. Laid out by hand from a precomputed MessageLayout: no Auto Layout, so scrolling stays cheap.
private final class MessageCell: NSTableCellView, NSTextViewDelegate {
    static let identifier = NSUserInterfaceItemIdentifier("MessageCell")
    static let bottomPadding: CGFloat = 2
    static func topPadding(grouped: Bool) -> CGFloat { grouped ? 1 : (Settings.compactMessages ? 4 : 10) }

    private let headerField = NSTextField(labelWithString: "")
    private let avatarView = RemoteImageView()
    private let bodyView = NSTextView()
    /// Reused between rows; only as many as the busiest message needed are ever created.
    private var embedTexts: [NSTextView] = []
    private var mediaViews: [MediaView] = []
    private var current = MessageLayout()

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        headerField.lineBreakMode = .byTruncatingTail
        setUpText(bodyView)
        avatarView.cornerRadius = MessageLayoutBuilder.avatarSize / 2
        addSubview(avatarView)
        addSubview(headerField)
        addSubview(bodyView)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func setUpText(_ view: NSTextView) {
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.isVerticallyResizable = false
        view.linkTextAttributes = [.foregroundColor: NSColor.linkColor, .cursor: NSCursor.pointingHand]
        view.delegate = self
    }

    func configure(_ layout: MessageLayout, header: NSAttributedString?) {
        current = layout
        headerField.isHidden = header == nil
        if let header { headerField.attributedStringValue = header }
        avatarView.isHidden = layout.avatar == nil
        if let avatar = layout.avatar {
            avatarView.frame = avatar.frame
            avatarView.setImage(avatar.url, pointSize: avatar.frame.size)
        }
        bodyView.textStorage?.setAttributedString(layout.body.text)
        bodyView.isHidden = layout.body.text.length == 0

        while embedTexts.count < layout.texts.count {
            let view = NSTextView()
            setUpText(view)
            addSubview(view)
            embedTexts.append(view)
        }
        for (i, view) in embedTexts.enumerated() {
            view.isHidden = i >= layout.texts.count
            if i < layout.texts.count { view.textStorage?.setAttributedString(layout.texts[i].text) }
        }

        while mediaViews.count < layout.media.count {
            let view = MediaView()
            addSubview(view)
            mediaViews.append(view)
        }
        for (i, view) in mediaViews.enumerated() {
            if i < layout.media.count {
                view.isHidden = false
                view.frame = layout.media[i].frame
                view.configure(layout.media[i])
            } else {
                view.cancel()
                view.isHidden = true
            }
        }
        needsLayout = true
        needsDisplay = true
    }

    func cancelMedia() {
        mediaViews.forEach { $0.cancel() }
        avatarView.cancel()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        cancelMedia()
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
        if let header = current.header { headerField.frame = header }
        if let avatar = current.avatar { avatarView.frame = avatar.frame }
        bodyView.frame = current.body.frame
        for (i, text) in current.texts.enumerated() where i < embedTexts.count {
            embedTexts[i].frame = text.frame
        }
        for (i, media) in current.media.enumerated() where i < mediaViews.count {
            mediaViews[i].frame = media.frame
        }
    }

    /// Embed cards: a faint background and a coloured bar on the left, drawn with dynamic colours.
    override func draw(_ dirtyRect: NSRect) {
        for box in current.boxes {
            NSColor.labelColor.withAlphaComponent(0.05).setFill()
            NSBezierPath(roundedRect: box.frame, xRadius: 4, yRadius: 4).fill()
            (box.color ?? NSColor.separatorColor).setFill()
            NSBezierPath(roundedRect: NSRect(x: box.frame.minX, y: box.frame.minY, width: 4, height: box.frame.height),
                         xRadius: 2, yRadius: 2).fill()
        }
    }
}

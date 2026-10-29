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

    /// Someone's name or picture was clicked: show their profile card beside `rect` in `view`.
    var onShowProfile: ((_ userID: Snowflake, _ guildID: Snowflake?, _ rect: NSRect, _ view: NSView) -> Void)?

    private let emptyLabel = NSTextField(labelWithString: "")
    private let loadingSpinner = NSProgressIndicator()
    private let scrollView = VerticalScrollView()
    private let table = NSTableView()
    private let input = ComposerView()
    private let typingTabs = TypingTabsView()
    private var typingTimer: Timer?

    private var channelID: Snowflake?
    private var rows: [Row] = []

    /// Text from the toolbar's search field: only messages containing it are shown (by text or author).
    /// Searches what's loaded, the way Find works in a document; scrolling up loads older messages to search too.
    var filterText = "" {
        didSet {
            guard filterText != oldValue else { return }
            rebuildRows()
            table.reloadData()
            if filterText.isEmpty || !rows.isEmpty { scrollToBottom() }
            updateEmptyState()
            if !filterText.isEmpty {
                let count = rows.count
                NSAccessibility.post(element: table, notification: .announcementRequested, userInfo: [
                    .announcement: count == 0 ? "No matches" : "\(count) matching message\(count == 1 ? "" : "s")",
                    .priority: NSAccessibilityPriorityLevel.medium.rawValue,
                ])
            }
        }
    }
    /// Private messaging (encrypted DMs). Set by the window controller.
    var privateChat: PrivateChatController?
    /// Under the toolbar in a DM: the private chat's state (waiting, not verified, a request) and what to do.
    private let privateBar = BannerView()
    private var scrollToTop: NSLayoutConstraint!
    private var scrollToBar: NSLayoutConstraint!

    private var isPrivate: Bool {
        guard let channelID, let privateChat else { return false }
        return privateChat.mode(for: channelID) == .private
    }

    private struct LayoutKey: Hashable {
        let id: Snowflake
        let revision: Int
        let grouped: Bool
        /// What's shown can differ from what was sent (a private message, decrypted or folded away).
        let shown: Int
    }

    private struct CachedLayout {
        let layout: MessageLayout
        /// Name and time line, nil for grouped rows. Built once rather than on every scroll.
        let header: NSAttributedString?
    }

    /// Layouts for the current width. Cleared when the width, the channel or a display setting changes.
    private var layoutCache: [LayoutKey: CachedLayout] = [:]
    private var lastWidth: CGFloat = 0

    private static let sidePadding = Theme.Spacing.edge
    /// Room between the newest message and the message box.
    private static let bottomInset: CGFloat = 10
    private static let headerHeight = ceil(Theme.messageBoldFont.pointSize * 1.4)
    private static let groupWindow: TimeInterval = 7 * 60

    init(session: DiscordSession) {
        self.session = session
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        let root = LiveResizeView()
        root.onEndLiveResize = { [weak self] in self?.updateAllRowHeights() }

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
        loadingSpinner.style = .spinning
        loadingSpinner.controlSize = .regular
        loadingSpinner.isDisplayedWhenStopped = false
        table.setAccessibilityLabel("Messages")

        [scrollView, typingTabs, input, emptyLabel, loadingSpinner, privateBar].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview($0)
        }
        privateBar.isHidden = true
        privateBar.onAction = { [weak self] in self?.privateBarAction() }
        scrollToTop = scrollView.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor)
        scrollToBar = scrollView.topAnchor.constraint(equalTo: privateBar.bottomAnchor)
        scrollToTop.isActive = true
        NSLayoutConstraint.activate([
            // The channel's name is in the toolbar; messages start just below it.
            privateBar.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            privateBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            privateBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            input.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: Theme.Spacing.group),
            // The tabs' bottom edge is the message box's top edge, so they rise out from behind it.
            typingTabs.bottomAnchor.constraint(equalTo: input.topAnchor),
            typingTabs.leadingAnchor.constraint(equalTo: input.leadingAnchor, constant: 14),
            typingTabs.heightAnchor.constraint(equalToConstant: TypingTabsView.tabSize.height),
            typingTabs.widthAnchor.constraint(equalToConstant: 7 * (TypingTabsView.tabSize.width + 4)),
            input.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Self.sidePadding),
            input.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Self.sidePadding),
            input.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -Theme.Spacing.group),
            loadingSpinner.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            loadingSpinner.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
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

        refreshInput()
        refreshPrivateBar()
        rebuildRows()
        table.reloadData()
        scrollToBottom()
        updateEmptyState()
        input.focus()
    }

    /// The message box follows the channel: named after it, and only usable once Duhcord knows the channel.
    /// In Private, it says so, and waits for the other person's key.
    private func refreshInput() {
        if let channelID, let channel = store.channel(channelID) {
            if isPrivate {
                let ready: Bool
                if case .ready = privateChat?.status(for: channelID) { ready = true } else { ready = false }
                input.placeholder = ready ? "Private message to @\(channel.displayName)" : "Waiting for @\(channel.displayName)…"
                input.isEnabled = ready
            } else {
                input.placeholder = channel.isPrivate ? "Message @\(channel.displayName)" : "Message #\(channel.displayName)"
                input.isEnabled = true
            }
        } else {
            input.placeholder = ""
            input.isEnabled = false
        }
    }

    // MARK: - Private messaging

    /// A message as shown: private messages decrypted in the Private view and folded to one line elsewhere,
    /// handshakes as a short note. Everything else unchanged.
    private func displayed(_ message: Message) -> Message {
        var shown = message
        switch PrivateMessaging.kind(of: message.content) {
        case .plain:
            return message
        case .handshake:
            shown.content = message.author.id == store.me?.id ? "🔒 *You offered to chat privately.*" : "🔒 *Wants to chat privately.*"
        case .encrypted:
            if isPrivate {
                shown.content = privateChat?.plaintext(of: message) ?? "🔒 *This private message can't be read with this Mac's key.*"
            } else {
                shown.content = "🔒 *Private message. Switch to Private to read it.*"
            }
        }
        return shown
    }

    /// A key arrived, the mode switched or a request came in: redraw for it.
    func privateChanged() {
        layoutCache = [:]
        rebuildRows()
        table.reloadData()
        scrollToBottom()
        updateEmptyState()
        refreshInput()
        refreshPrivateBar()
    }

    private enum BarAction { case none, verify, accept }
    private var barAction = BarAction.none

    private func refreshPrivateBar() {
        guard let channelID, let privateChat, let peer = privateChat.peer(in: channelID) else {
            setPrivateBar(nil)
            return
        }
        let name = peer.displayName
        if isPrivate {
            switch privateChat.status(for: channelID) {
            case .unavailable:
                setPrivateBar(nil)
            case .waiting:
                setPrivateBar("Waiting for \(name) to set up private chat. They need Duhcord to read private messages.", tone: .info)
            case .ready(let verified, let keyChanged):
                if keyChanged {
                    setPrivateBar("\(name)'s key changed: a new Mac, a reinstall, or someone in the middle. Check before sending.",
                                  tone: .warning, action: "Verify…", then: .verify)
                } else if !verified {
                    setPrivateBar("Private chat with \(name). Compare safety numbers to make sure no one is in the middle.",
                                  tone: .secure, action: "Verify…", then: .verify)
                } else {
                    setPrivateBar("Private chat with \(name). Verified.", tone: .secure, action: "Safety Number", then: .verify)
                }
            }
        } else if privateChat.hasRequest(in: channelID) {
            setPrivateBar("\(name) wants to chat privately.", tone: .info, action: "Chat Privately", then: .accept)
        } else {
            setPrivateBar(nil)
        }
    }

    private func setPrivateBar(_ text: String?, tone: BannerView.Tone = .info, action: String? = nil, then: BarAction = .none) {
        barAction = then
        if let text { privateBar.show(text, tone: tone, action: action) }
        privateBar.isHidden = text == nil
        scrollToBar.isActive = text != nil
        scrollToTop.isActive = text == nil
    }

    private func privateBarAction() {
        guard let channelID, let privateChat else { return }
        switch barAction {
        case .none:
            break
        case .accept:
            privateChat.setMode(.private, for: channelID)
        case .verify:
            guard let number = privateChat.safetyNumber(for: channelID), let window = view.window else { return }
            let name = privateChat.peer(in: channelID)?.displayName ?? "them"
            let alert = NSAlert()
            alert.messageText = "Safety number with \(name)"
            alert.informativeText = number + "\n\nCompare this with \(name)'s, in person or in a voice call (Duhcord's calls are end-to-end "
                + "encrypted). If the numbers match, only the two of you can read your private messages."
            alert.addButton(withTitle: "Mark as Verified")
            alert.addButton(withTitle: "Cancel")
            alert.beginSheetModal(for: window) { response in
                if response == .alertFirstButtonReturn { privateChat.markVerified(in: channelID) }
            }
        }
    }

    /// Channels came, went or were renamed. If the one on screen only just became known (a DM opened a moment
    /// before Discord announced it), this switches its message box on.
    func channelsChanged() {
        refreshInput()
        refreshPrivateBar()
    }

    func messagesChanged(in channelID: Snowflake) {
        guard channelID == self.channelID else { return }
        let oldFirst = rows.first?.message.id
        let wasAtBottom = isAtBottom
        let clip = scrollView.contentView
        let distanceFromBottom = table.bounds.height - clip.bounds.origin.y

        let oldRows = rows
        rebuildRows()
        if !applyChanges(from: oldRows) { table.reloadData() }
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

    /// Updates only the rows that changed: new messages are inserted, trimmed or deleted ones removed, and edited
    /// ones redrawn. Rows that didn't change keep their views, so a text selection in them survives a new message.
    /// Returns false when the change isn't a simple one (the caller reloads everything instead).
    private func applyChanges(from old: [Row]) -> Bool {
        let new = rows
        guard !old.isEmpty, !new.isEmpty else { return false }
        let oldIDs = old.map(\.message.id), newIDs = new.map(\.message.id)
        if oldIDs == newIDs {
            let changed = IndexSet(new.indices.filter {
                new[$0].message.revision != old[$0].message.revision || new[$0].grouped != old[$0].grouped
            })
            redraw(changed)
            return true
        }
        // Rows dropped from the top (the cache keeps a fixed number), or older ones added there; then new ones at the bottom.
        let droppedFront = oldIDs.firstIndex(of: newIDs[0]) ?? 0
        let addedFront = newIDs.firstIndex(of: oldIDs[0]) ?? 0
        guard droppedFront == 0 || addedFront == 0 else { return false }
        let kept = old.count - droppedFront
        // Everything still here must be in the same order, with nothing deleted from the middle.
        guard addedFront + kept <= new.count,
              Array(oldIDs[droppedFront...]) == Array(newIDs[addedFront..<(addedFront + kept)]) else { return false }
        let addedBack = new.count - addedFront - kept
        table.beginUpdates()
        if droppedFront > 0 { table.removeRows(at: IndexSet(integersIn: 0..<droppedFront), withAnimation: []) }
        if addedFront > 0 { table.insertRows(at: IndexSet(integersIn: 0..<addedFront), withAnimation: []) }
        if addedBack > 0 { table.insertRows(at: IndexSet(integersIn: (new.count - addedBack)..<new.count), withAnimation: []) }
        table.endUpdates()
        // Kept rows can still have been edited, or have lost the message above them they were grouped with.
        let changed = IndexSet((0..<kept).compactMap { i -> Int? in
            let before = old[droppedFront + i], after = new[addedFront + i]
            return before.message.revision != after.message.revision || before.grouped != after.grouped ? addedFront + i : nil
        })
        redraw(changed)
        return true
    }

    private func redraw(_ rows: IndexSet) {
        guard !rows.isEmpty else { return }
        table.reloadData(forRowIndexes: rows, columnIndexes: [0])
        noteHeights(rows)
    }

    private func rebuildRows() {
        guard let channelID, let messages = store.messages(in: channelID) else {
            rows = []
            return
        }
        var result: [Row] = []
        result.reserveCapacity(messages.count)
        var previous: Message?
        let query = filterText.trimmingCharacters(in: .whitespaces)
        let privateView = isPrivate
        for message in messages {
            // The Private view lists only private messages; the standard view shows them folded away.
            if privateView {
                guard case .encrypted = PrivateMessaging.kind(of: message.content) else { continue }
            }
            // While searching, each match stands on its own, with its author line.
            if !query.isEmpty {
                let text = displayed(message).content + " " + message.author.displayName + " " + message.author.username
                guard text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil else { continue }
                result.append(Row(message: message, grouped: false))
                continue
            }
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
            loadingSpinner.stopAnimation(nil)
            emptyLabel.stringValue = "No Channel Selected"
            emptyLabel.isHidden = false
            return
        }
        if store.messages(in: channelID) == nil {
            // A standard spinner while history loads, like other Mac apps.
            emptyLabel.isHidden = true
            loadingSpinner.startAnimation(nil)
            return
        }
        loadingSpinner.stopAnimation(nil)
        if rows.isEmpty {
            if !filterText.isEmpty {
                emptyLabel.stringValue = "No Matches in Loaded Messages"
            } else {
                emptyLabel.stringValue = isPrivate ? "No Private Messages Yet" : "No Messages Yet"
            }
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
        var content = text
        if isPrivate, let privateChat {
            do {
                content = try privateChat.seal(text, in: channelID)
            } catch {
                let alert = NSAlert()
                alert.messageText = "Private message not sent"
                alert.informativeText = error.localizedDescription
                if let window = view.window { alert.beginSheetModal(for: window) }
                return
            }
        }
        input.text = ""
        session.send(content, to: channelID) { [weak self] error in
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
        let shown = displayed(message)
        let key = LayoutKey(id: message.id, revision: message.revision, grouped: row.grouped, shown: shown.content.hashValue)
        if let cached = layoutCache[key] { return cached }
        let resolver = store.resolver(for: message)
        let built = MessageLayoutBuilder.build(
            message: shown, grouped: row.grouped, cellWidth: table.bounds.width, sidePadding: Self.sidePadding,
            headerHeight: Self.headerHeight, topPadding: MessageCell.topPadding(grouped: row.grouped),
            bottomPadding: MessageCell.bottomPadding, resolver: resolver)
        let cached = CachedLayout(layout: built, header: row.grouped ? nil : Theme.header(for: shown))
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
        let message = rows[row].message
        cell.setAccessibilityLabel(spokenText(for: message))
        cell.authorNameWidth = row < rows.count && !rows[row].grouped
            ? ceil((message.author.displayName as NSString).size(withAttributes: [.font: Theme.messageBoldFont]).width) : 0
        cell.onAuthorClicked = { [weak self, weak cell] rect in
            guard let self, let cell else { return }
            self.onShowProfile?(message.author.id, self.store.channel(message.channelId)?.guildId, rect, cell)
        }
        cell.contextItems = { [weak self, weak cell] in
            guard let self, let cell else { return [] }
            return self.menuItems(for: message, in: cell)
        }
        // VoiceOver: VO-Command-Space on a message offers the author's profile.
        cell.setAccessibilityCustomActions([NSAccessibilityCustomAction(name: "Show \(message.author.displayName)'s Profile") {
            [weak cell] in
            guard let cell else { return false }
            cell.onAuthorClicked?(cell.authorAnchor)
            return true
        }])
        return cell
    }

    /// The right-click menu for a message, as in the official client: copy it, link to it, see who wrote it.
    private func menuItems(for message: Message, in cell: MessageCell) -> [NSMenuItem] {
        let guildID = store.channel(message.channelId)?.guildId
        return [
            ActionMenuItem("Copy Text", enabled: !message.content.isEmpty) { [weak self] in
                Pasteboard.copy(self?.displayed(message).content ?? message.content)
            },
            ActionMenuItem("Copy Message Link") {
                Pasteboard.copy(DiscordLink.message(message.id, channelID: message.channelId, guildID: guildID))
            },
            .separator(),
            ActionMenuItem("Show \(message.author.displayName)'s Profile") { [weak cell] in
                guard let cell else { return }
                cell.onAuthorClicked?(cell.authorAnchor)
            },
        ]
    }

    /// What VoiceOver reads for a message: who, when, and what.
    private func spokenText(for message: Message) -> String {
        var parts = [message.author.displayName]
        if let date = message.date { parts.append(Theme.timeFormatter.string(from: date)) }
        let content = displayed(message).content
        if !content.isEmpty { parts.append(content) }
        let attachments = message.attachments.count
        if attachments > 0 { parts.append("\(attachments) attachment\(attachments == 1 ? "" : "s")") }
        if message.editedTimestamp != nil { parts.append("edited") }
        return parts.joined(separator: ", ")
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
    static func topPadding(grouped: Bool) -> CGFloat { grouped ? 1 : (Settings.compactLayout ? Theme.Spacing.tight : Theme.Spacing.group) }

    private let headerField = NSTextField(labelWithString: "")
    private let avatarView = RemoteImageView()
    private let bodyView = NSTextView()
    /// The author's picture or name was clicked; the rect is what was clicked, in this cell.
    var onAuthorClicked: ((NSRect) -> Void)?
    /// The message's own items for the right-click menu.
    var contextItems: (() -> [NSMenuItem])?
    /// How much of the header line is the author's name, which opens their profile like the picture does.
    var authorNameWidth: CGFloat = 0
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
        window?.invalidateCursorRects(for: self)
    }

    func cancelMedia() {
        mediaViews.forEach { $0.cancel() }
        avatarView.cancel()
    }

    // MARK: Author clicks

    /// Where a profile card opened for the author points: their picture, or the start of a grouped message.
    var authorAnchor: NSRect {
        current.avatar?.frame ?? NSRect(x: 0, y: 0, width: MessageLayoutBuilder.avatarColumn, height: min(bounds.height, 24))
    }

    private var nameRect: NSRect? {
        guard let header = current.header, authorNameWidth > 0, !headerField.isHidden else { return nil }
        return NSRect(x: header.minX, y: header.minY, width: min(authorNameWidth, header.width), height: header.height)
    }

    private func authorRect(at point: NSPoint) -> NSRect? {
        if let avatar = current.avatar?.frame, !avatarView.isHidden, avatar.contains(point) { return avatar }
        if let name = nameRect, name.contains(point) { return name }
        return nil
    }

    /// The picture and name take clicks themselves, rather than the image view and label under them.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        if onAuthorClicked != nil, authorRect(at: local) != nil { return self }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let rect = authorRect(at: point) {
            onAuthorClicked?(rect)
        } else {
            super.mouseDown(with: event)
        }
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if let avatar = current.avatar?.frame, !avatarView.isHidden { addCursorRect(avatar, cursor: .pointingHand) }
        if let name = nameRect { addCursorRect(name, cursor: .pointingHand) }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        cancelMedia()
        onAuthorClicked = nil
        contextItems = nil
    }

    /// Right-click anywhere on the message.
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let items = contextItems?(), !items.isEmpty else { return super.menu(for: event) }
        let menu = NSMenu()
        items.forEach { menu.addItem($0) }
        return menu
    }

    /// Right-click on the text: the usual text items (Copy, Look Up, Services), then the message's own.
    func textView(_ view: NSTextView, menu: NSMenu, for event: NSEvent, at charIndex: Int) -> NSMenu? {
        guard let items = contextItems?(), !items.isEmpty else { return menu }
        menu.addItem(.separator())
        items.forEach { menu.addItem($0) }
        return menu
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

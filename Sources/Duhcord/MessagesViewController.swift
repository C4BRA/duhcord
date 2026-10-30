import AppKit
import AVFoundation
import DuhcordCore
import UniformTypeIdentifiers

/// The right column: channel title, message history and the input box.
@MainActor
final class MessagesViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSMenuItemValidation {
    private struct Row {
        let message: Message
        /// Same author shortly after the previous message, so the name/time line is skipped.
        let grouped: Bool
    }

    private struct RebuildState {
        let channelID: Snowflake
        let filterText: String
        let privateView: Bool
        let messageCount: Int
        let firstID: Snowflake?
        let lastID: Snowflake?
        let lastConsidered: Message?
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
    private let attachButton = NSButton(title: "", target: nil, action: nil)
    private let typingTabs = TypingTabsView()
    private var typingTimer: Timer?

    private var channelID: Snowflake?
    private var rows: [Row] = []
    private var rebuildState: RebuildState?

    /// Text from the toolbar's search field: only messages containing it are shown (by text or author).
    /// Searches what's loaded, the way Find works in a document; scrolling up loads older messages to search too.
    var filterText = "" {
        didSet {
            guard filterText != oldValue else { return }
            rebuildState = nil
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

    /// Images can be attached in any channel; in Private, once the other person's key is here (they're encrypted).
    var canAttachImages: Bool {
        guard let channelID, store.channel(channelID) != nil, !isUploading else { return false }
        if isPrivate, case .ready = privateChat?.status(for: channelID) { return true }
        return !isPrivate
    }

    // Images and videos attached to the next message, shown in a row above the message box.
    private let tray = NSStackView()
    private var trayHeight: NSLayoutConstraint!
    private var trayGap: NSLayoutConstraint!
    private var attached: [PreparedAttachment] = []
    /// Attachments still being prepared, shown as spinners (videos with their progress, and ✕ to stop).
    private struct Job {
        var progress: Double?
        let video: VideoPrep?
    }

    private var jobs: [UUID: Job] = [:]
    private var jobOrder: [UUID] = []
    private var jobIndicators: [UUID: NSProgressIndicator] = [:]
    private var preparing: Int { jobs.count }
    /// Return was pressed while images were still being prepared: send once they're ready.
    private var sendWhenReady = false

    /// What the message box holds belongs to one conversation, and to Standard or Private in it. Switching either
    /// puts it away and brings back that one's, so text written to be encrypted never ends up in a box that
    /// sends it as it is (another channel, or the same DM in Standard).
    private struct DraftKey: Hashable {
        let channelID: Snowflake
        let isPrivate: Bool
    }

    private struct Draft {
        var text = ""
        var images: [PreparedAttachment] = []
        var isEmpty: Bool { text.isEmpty && images.isEmpty }
    }

    private var drafts: [DraftKey: Draft] = [:]
    /// Whose draft the box shows now.
    private var draftKey: DraftKey?
    /// Messages with images still uploading. Their box waits (the others don't).
    private var uploading: Set<DraftKey> = []
    private var isUploading: Bool { draftKey.map(uploading.contains) ?? false }
    private static let trayItemSize: CGFloat = 56

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
        NotificationCenter.default.addObserver(self, selector: #selector(backingPropertiesChanged(_:)),
                                               name: NSWindow.didChangeBackingPropertiesNotification, object: nil)

        input.placeholder = "Message"
        input.font = Theme.messageFont
        input.onSend = { [weak self] text in self?.send(text) }
        input.acceptsImages = { [weak self] in self?.canAttachImages ?? false }
        input.onImages = { [weak self] pasteboard in
            guard let self, self.canAttachImages else { return false }
            let sources = ImagePrep.sources(from: pasteboard)
            if sources.isEmpty { NSSound.beep() }
            self.attach(sources)
            return true
        }
        input.canSendEmpty = { [weak self] in self.map { !$0.attached.isEmpty || $0.preparing > 0 } ?? false }

        // Images dropped anywhere on the messages attach too, not just on the box.
        root.registerForDraggedTypes([.fileURL, .png, .tiff])
        root.acceptsImages = { [weak self] pasteboard in
            (self?.canAttachImages ?? false) && ImagePrep.canRead(pasteboard)
        }
        root.onDropImages = { [weak self] pasteboard in self?.attach(ImagePrep.sources(from: pasteboard)) }
        attachButton.bezelStyle = .recessed
        attachButton.showsBorderOnlyWhileMouseInside = true
        attachButton.imagePosition = .imageOnly
        attachButton.image = NSImage(systemSymbolName: "paperclip", accessibilityDescription: "Attach Images or Videos")
        attachButton.setAccessibilityLabel("Attach Images or Videos")
        attachButton.toolTip = "Attach Images or Videos"
        attachButton.target = self
        attachButton.action = #selector(attachFiles(_:))
        tray.orientation = .horizontal
        tray.alignment = .centerY
        tray.spacing = Theme.Spacing.tight
        tray.setAccessibilityLabel("Attached images")
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

        [scrollView, typingTabs, input, attachButton, emptyLabel, loadingSpinner, privateBar, tray].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview($0)
        }
        privateBar.isHidden = true
        privateBar.onAction = { [weak self] in self?.privateBarAction() }
        scrollToTop = scrollView.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor)
        scrollToBar = scrollView.topAnchor.constraint(equalTo: privateBar.bottomAnchor)
        scrollToTop.isActive = true
        trayHeight = tray.heightAnchor.constraint(equalToConstant: 0)
        trayGap = input.topAnchor.constraint(equalTo: tray.bottomAnchor)
        NSLayoutConstraint.activate([
            trayHeight, trayGap,
            tray.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: Theme.Spacing.group),
            tray.leadingAnchor.constraint(equalTo: input.leadingAnchor),
            tray.trailingAnchor.constraint(lessThanOrEqualTo: input.trailingAnchor),
            attachButton.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Self.sidePadding),
            attachButton.trailingAnchor.constraint(equalTo: input.leadingAnchor, constant: -Theme.Spacing.tight),
            attachButton.widthAnchor.constraint(equalToConstant: 30),
            attachButton.heightAnchor.constraint(equalToConstant: 30),
            attachButton.bottomAnchor.constraint(equalTo: input.bottomAnchor),
            // The channel's name is in the toolbar; messages start just below it.
            privateBar.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            privateBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            privateBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            // The tabs' bottom edge is the message box's top edge, so they rise out from behind it.
            typingTabs.bottomAnchor.constraint(equalTo: input.topAnchor),
            typingTabs.leadingAnchor.constraint(equalTo: input.leadingAnchor, constant: 14),
            typingTabs.heightAnchor.constraint(equalToConstant: TypingTabsView.tabSize.height),
            typingTabs.widthAnchor.constraint(equalToConstant: 7 * (TypingTabsView.tabSize.width + 4)),
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
        rebuildState = nil
        self.channelID = channelID
        olderPagesForPrivate = 0
        layoutCache = [:]
        swapDraftIfNeeded()

        refreshInput()
        refreshPrivateBar()
        rebuildRows()
        table.reloadData()
        scrollToBottom()
        updateEmptyState()
        findOlderPrivateMessages()
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
                input.isEnabled = ready && !isUploading
            } else {
                var placeholder = channel.isPrivate ? "Message @\(channel.displayName)" : "Message #\(channel.displayName)"
                if case .ready = privateChat?.status(for: channelID) { placeholder += " (not encrypted)" }
                input.placeholder = placeholder
                input.isEnabled = !isUploading
            }
        } else {
            input.placeholder = ""
            input.isEnabled = false
        }
        attachButton.isEnabled = canAttachImages
    }

    @objc func attachFiles(_ sender: Any?) {
        guard canAttachImages, let window = view.window else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .movie]
        panel.allowsMultipleSelection = true
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self, self.canAttachImages else { return }
            let sources = ImagePrep.sources(from: panel.urls)
            if sources.isEmpty { NSSound.beep() }
            self.attach(sources)
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(attachFiles(_:)) { return canAttachImages }
        return true
    }

    // MARK: - Drafts and attached images

    /// Puts the box's text and images away for the conversation (and mode) it was showing, and brings back the
    /// ones for what's showing now.
    private func swapDraftIfNeeded() {
        let key = channelID.map { DraftKey(channelID: $0, isPrivate: isPrivate) }
        guard key != draftKey else { return }
        if let old = draftKey {
            let draft = Draft(text: input.text, images: attached)
            drafts[old] = draft.isEmpty ? nil : draft
        }
        clearAttachments()
        let draft = key.flatMap { drafts.removeValue(forKey: $0) } ?? Draft()
        draftKey = key
        input.text = draft.text
        attached = draft.images
        refreshTray()
    }

    /// A message that wasn't sent goes back where it was written: into the box if that's still showing, otherwise
    /// into that conversation's draft (never into whatever box is open now). Returns whether it's in the box.
    @discardableResult
    private func restoreUnsent(_ text: String, images: [PreparedAttachment], to key: DraftKey) -> Bool {
        if key == draftKey {
            if input.text.isEmpty { input.text = text }
            if attached.isEmpty { attached = images }
            refreshTray()
            return true
        }
        var draft = drafts[key] ?? Draft()
        if draft.text.isEmpty { draft.text = text }
        if draft.images.isEmpty { draft.images = images }
        drafts[key] = draft.isEmpty ? nil : draft
        return false
    }

    /// Prepares dropped or pasted images and videos in the background, then adds them to the row (up to the most a
    /// message can carry).
    private func attach(_ sources: [ImagePrep.Source]) {
        guard canAttachImages, !isUploading, !sources.isEmpty else { return }
        // A video waiting to be split fills the message on its own.
        if attached.contains(where: { $0.sourceURL != nil }) {
            NSSound.beep()
            return
        }
        let room = PrivateMessaging.maxFiles - attached.count - preparing
        if sources.count > room { NSSound.beep() }
        for source in sources.prefix(max(0, room)) {
            let id = UUID()
            jobOrder.append(id)
            switch source {
            case .image(let data, let name):
                jobs[id] = Job(progress: nil, video: nil)
                let bytes = Handoff(value: data)
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    let prepared = Handoff(value: ImagePrep.prepare(bytes.value, name: name))
                    Task { @MainActor [weak self] in
                        self?.finishJob(id, prepared.value, failure: prepared.value == nil
                            ? "It isn't an image Duhcord can read, or it's too large." : nil, name: name)
                    }
                }
            case .video(let url, let name):
                let prep = VideoPrep()
                jobs[id] = Job(progress: 0, video: prep)
                // Room left in the message, and in Private, for the padding encryption adds (up to 12%).
                // A private video on its own is sized to one Discord file. If it can't fit, it is split when sent.
                let used = attached.reduce(0) { $0 + $1.data.count }
                let alone = isPrivate && attached.isEmpty && jobs.count == 1
                let premium = store.premiumType
                var limit = store.uploadLimit - used
                if isPrivate {
                    limit = alone ? UploadLimit.privatePiecePlaintext(premiumType: premium)
                        : min(Int(Double(limit) / 1.13), PrivateMessaging.maxFileBytes)
                }
                let options = VideoPrep.Options(limit: limit, compress: Settings.compressVideos, forPrivate: isPrivate)
                let owner = WeakReference(self)
                Task.detached(priority: .userInitiated) {
                    do {
                        let prepared = try await prep.prepare(url, name: name, options: options) { fraction in
                            DispatchQueue.main.async { owner.object?.updateJob(id, progress: fraction) }
                        }
                        let result = Handoff(value: prepared)
                        await MainActor.run { owner.object?.finishJob(id, result.value, failure: nil, name: name) }
                    } catch is CancellationError {
                        await MainActor.run { owner.object?.finishJob(id, nil, failure: nil, name: name) }
                    } catch VideoPrep.Failure.tooLong where alone {
                        let seconds = (try? await AVURLAsset(url: url).load(.duration).seconds) ?? 0
                        let icon = NSImage(systemSymbolName: "film", accessibilityDescription: "Video") ?? NSImage()
                        let placeholder = PreparedAttachment(data: Data(), width: 16, height: 9, kind: .mp4,
                                                            thumbnail: icon, name: name, duration: seconds, sourceURL: url)
                        let result = Handoff(value: placeholder)
                        await MainActor.run { owner.object?.finishJob(id, result.value, failure: nil, name: name) }
                    } catch {
                        let message = error.localizedDescription
                        await MainActor.run { owner.object?.finishJob(id, nil, failure: message, name: name) }
                    }
                }
            }
        }
        refreshTray()
    }

    private func updateJob(_ id: UUID, progress: Double) {
        guard jobs[id] != nil else { return }
        jobs[id]?.progress = progress
        jobIndicators[id]?.doubleValue = progress
    }

    /// An attachment is ready (or failed, or was stopped). A job no longer listed was cleared meanwhile: dropped.
    private func finishJob(_ id: UUID, _ prepared: PreparedAttachment?, failure: String?, name: String) {
        guard jobs.removeValue(forKey: id) != nil else { return }
        jobOrder.removeAll { $0 == id }
        var rejectedSplit = false
        if let prepared {
            if prepared.sourceURL != nil, !attached.isEmpty || !jobs.isEmpty {
                rejectedSplit = true
                showSendError("Couldn't attach “\(name)”", detail: "A video that has to be split is sent on its own.")
            } else {
                attached.append(prepared)
            }
        } else if let failure {
            showSendError("Couldn't attach “\(name)”", detail: failure)
        }
        refreshTray()
        // Return was pressed meanwhile: now everything's ready, send what's in the box.
        if preparing == 0, sendWhenReady, !rejectedSplit {
            sendWhenReady = false
            send(input.text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    @objc private func cancelJob(_ sender: NSButton) {
        guard let id = sender.identifier.flatMap({ UUID(uuidString: $0.rawValue) }), let job = jobs.removeValue(forKey: id) else { return }
        job.video?.cancel()
        jobOrder.removeAll { $0 == id }
        refreshTray()
    }

    private func clearAttachments() {
        jobs.values.forEach { $0.video?.cancel() }
        jobs = [:]
        jobOrder = []
        attached = []
        sendWhenReady = false
        refreshTray()
    }

    private func refreshTray() {
        tray.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, image) in attached.enumerated() {
            tray.addArrangedSubview(trayItem(image, index: index))
        }
        jobIndicators = [:]
        for id in jobOrder {
            guard let job = jobs[id] else { continue }
            tray.addArrangedSubview(jobItem(id, job))
        }
        if isUploading || sendWhenReady {
            let status = isUploading ? (isPrivate ? "Encrypting and sending…" : "Sending…") : "Sends when everything's ready…"
            let label = NSTextField(labelWithString: status)
            label.textColor = .secondaryLabelColor
            label.font = Theme.messageSmallFont
            tray.addArrangedSubview(label)
        }
        let visible = !attached.isEmpty || preparing > 0
        let wasAtBottom = isAtBottom
        trayHeight.constant = visible ? Self.trayItemSize : 0
        // Room for the typing tabs between the row and the box.
        trayGap.constant = visible ? TypingTabsView.tabSize.height + 2 : 0
        if wasAtBottom {
            view.layoutSubtreeIfNeeded()
            scrollToBottom()
        }
    }

    /// An attachment being prepared: a spinner, or for a video its progress and ✕ to stop.
    private func jobItem(_ id: UUID, _ job: Job) -> NSView {
        let indicator = NSProgressIndicator()
        indicator.controlSize = .small
        guard let progress = job.progress else {
            indicator.style = .spinning
            indicator.startAnimation(nil)
            indicator.setAccessibilityLabel("Preparing image")
            return indicator
        }
        indicator.style = .bar
        indicator.isIndeterminate = false
        indicator.minValue = 0
        indicator.maxValue = 1
        indicator.doubleValue = progress
        indicator.setAccessibilityLabel(Settings.compressVideos ? "Compressing video" : "Preparing video")
        jobIndicators[id] = indicator
        let label = NSTextField(labelWithString: Settings.compressVideos ? "Compressing video…" : "Preparing video…")
        label.font = Theme.messageSmallFont
        label.textColor = .secondaryLabelColor
        let stop = NSButton(image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Stop")!,
                            target: self, action: #selector(cancelJob(_:)))
        stop.isBordered = false
        stop.identifier = NSUserInterfaceItemIdentifier(id.uuidString)
        stop.toolTip = "Stop"
        let column = NSStackView(views: [label, indicator])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 2
        indicator.widthAnchor.constraint(equalToConstant: 120).isActive = true
        let row = NSStackView(views: [column, stop])
        row.orientation = .horizontal
        row.spacing = Theme.Spacing.tight
        return row
    }

    private func trayItem(_ image: PreparedAttachment, index: Int) -> NSView {
        let size = Self.trayItemSize
        let item = NSView()
        item.translatesAutoresizingMaskIntoConstraints = false
        let picture = NSImageView(image: image.thumbnail)
        picture.imageScaling = .scaleProportionallyUpOrDown
        picture.wantsLayer = true
        picture.layer?.cornerRadius = 6
        picture.layer?.masksToBounds = true
        picture.setAccessibilityLabel(image.name)
        picture.toolTip = image.name
        let remove = NSButton(image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Remove \(image.name)")!,
                              target: self, action: #selector(removeAttachment(_:)))
        remove.isBordered = false
        remove.tag = index
        remove.isEnabled = !isUploading
        remove.toolTip = "Remove"
        var views: [NSView] = [picture, remove]
        var badgeConstraints: [NSLayoutConstraint] = []
        if image.kind.isVideo {
            let seconds = Int(image.duration.rounded())
            let badge = NSTextField(labelWithString: String(format: " ▶ %d:%02d ", seconds / 60, seconds % 60))
            badge.font = .systemFont(ofSize: 10, weight: .bold)
            badge.textColor = .white
            badge.drawsBackground = true
            badge.backgroundColor = NSColor.black.withAlphaComponent(0.55)
            badge.setAccessibilityLabel("Video, \(seconds) seconds")
            views.append(badge)
            badgeConstraints = [
                badge.leadingAnchor.constraint(equalTo: item.leadingAnchor, constant: 3),
                badge.bottomAnchor.constraint(equalTo: item.bottomAnchor, constant: -3),
            ]
        }
        views.forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            item.addSubview($0)
        }
        NSLayoutConstraint.activate([
            item.widthAnchor.constraint(equalToConstant: size),
            item.heightAnchor.constraint(equalToConstant: size),
            picture.topAnchor.constraint(equalTo: item.topAnchor),
            picture.bottomAnchor.constraint(equalTo: item.bottomAnchor),
            picture.leadingAnchor.constraint(equalTo: item.leadingAnchor),
            picture.trailingAnchor.constraint(equalTo: item.trailingAnchor),
            remove.topAnchor.constraint(equalTo: item.topAnchor, constant: 2),
            remove.trailingAnchor.constraint(equalTo: item.trailingAnchor, constant: -2),
        ] + badgeConstraints)
        return item
    }

    @objc private func removeAttachment(_ sender: NSButton) {
        guard !isUploading, attached.indices.contains(sender.tag) else { return }
        attached.remove(at: sender.tag)
        refreshTray()
    }

    private func showSendError(_ title: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        if let window = view.window { alert.beginSheetModal(for: window) }
    }

    /// Sends the attached images with the text. In Private, each image is encrypted with a key of its own, the
    /// keys go in the private message, and the encrypted images are uploaded as its attachments; otherwise they're
    /// uploaded as they were prepared. The row clears once Discord has the message.
    private func sendWithImages(_ text: String, in channelID: Snowflake) {
        guard let key = draftKey else { return }
        let images = attached
        if key.isPrivate, images.contains(where: { $0.sourceURL != nil }) {
            guard images.count == 1, let url = images[0].sourceURL, #available(macOS 14, *) else {
                showSendError("Private message not sent", detail: "A video that has to be split is sent on its own.")
                return
            }
            sendFilm(url, caption: text, placeholder: images[0], in: channelID, key: key)
            return
        }
        let content: String
        let files: [UploadFile]
        do {
            if key.isPrivate {
                guard #available(macOS 14, *), let privateChat else { return }
                let sealed = try images.map { try PrivateCrypto.sealFile($0.data, width: $0.width, height: $0.height, kind: $0.kind) }
                files = sealed.map { UploadFile(name: PrivateMessaging.fileName, data: $0.sealed, contentType: "application/octet-stream") }
                content = try privateChat.seal(text, files: sealed.map(\.file), in: channelID)
                // Each sealed file has to fit Discord's cap for one attachment. Together they stay in memory.
                let perFile = UploadLimit.discordLimit(premiumType: store.premiumType)
                guard files.allSatisfy({ $0.data.count <= perFile }),
                      files.reduce(0, { $0 + $1.data.count }) <= UploadLimit.duhcordCap else {
                    throw PrivateMessagingError.filesTooLarge
                }
            } else {
                files = images.map(\.upload)
                content = text
                guard files.reduce(0, { $0 + $1.data.count }) <= store.uploadLimit else {
                    throw PrivateMessagingError.filesTooLarge
                }
            }
        } catch {
            showSendError(key.isPrivate ? "Private message not sent" : "Message not sent", detail: error.localizedDescription)
            return
        }
        input.text = ""
        uploading.insert(key)
        refreshInput()
        refreshTray()
        session.send(content, files: files, to: channelID) { [weak self] error in
            guard let self else { return }
            self.uploading.remove(key)
            if error == nil {
                // Sent: the images leave the row, or the draft they were put away in.
                if key == self.draftKey { self.attached = [] } else { self.drafts[key]?.images = [] }
                if self.drafts[key]?.isEmpty == true { self.drafts[key] = nil }
            }
            self.refreshInput()
            self.refreshTray()
            guard let error else { return }
            self.reportUnsent(text, images: [], to: key, error: error)
        }
    }

    /// Encodes a private video into sealed pieces and sends them, four to a message. A film that fits in one
    /// piece is an ordinary private video. Each further message waits a second after the previous one was
    /// accepted. Anything already sent is left in the channel if a later piece fails.
    @available(macOS 14, *)
    private func sendFilm(_ url: URL, caption: String, placeholder: PreparedAttachment,
                          in channelID: Snowflake, key: DraftKey) {
        let limit = UploadLimit.privatePiecePlaintext(premiumType: store.premiumType)
        let options = VideoPrep.Options(limit: limit, compress: true, forPrivate: true)
        let prep = VideoPrep()
        let jobID = UUID()
        jobOrder.append(jobID)
        jobs[jobID] = Job(progress: 0, video: prep)
        let held = Handoff(value: placeholder)
        input.text = ""
        attached = []
        uploading.insert(key)
        refreshInput()
        refreshTray()
        let filmID = PrivateFilmNote.newID()
        let filmName = placeholder.name
        let owner = WeakReference(self)
        Task.detached(priority: .userInitiated) {
            var pending: [PreparedAttachment] = []
            var pendingSpans: [Double] = []
            var nextIndex = 0
            var sentAny = false
            func ship(_ items: inout [PreparedAttachment], spans: [Double], moreComing: Bool) async throws {
                if sentAny {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                    if prep.isCancelled { throw CancellationError() }
                    guard let rest = await MainActor.run(body: { owner.object?.session.rest }) else {
                        throw CancellationError()
                    }
                    try await rest.waitForMessageSlot(in: channelID)
                    if prep.isCancelled { throw CancellationError() }
                }
                let index = nextIndex
                let count = items.count
                nextIndex += count
                // Seal first and drop the plaintext, so the upload holds only the ciphertext.
                let sealed = try items.map {
                    try PrivateCrypto.sealFile($0.data, width: $0.width, height: $0.height, kind: $0.kind)
                }
                items = []
                let uploads = sealed.map {
                    UploadFile(name: PrivateMessaging.fileName, data: $0.sealed, contentType: "application/octet-stream")
                }
                let perFile = await MainActor.run { UploadLimit.discordLimit(premiumType: owner.object?.store.premiumType) }
                guard uploads.allSatisfy({ $0.data.count <= perFile }),
                      uploads.reduce(0, { $0 + $1.data.count }) <= UploadLimit.duhcordCap else {
                    throw PrivateMessagingError.filesTooLarge
                }
                let single = count == 1 && !sentAny && !moreComing
                let body = single ? caption
                    : PrivateFilmNote.text(caption: sentAny ? "" : caption,
                                           film: PrivateFilm(id: filmID, start: index, spans: spans))
                let content = try await MainActor.run { () -> String in
                    guard let chat = owner.object?.privateChat else { throw CancellationError() }
                    return try chat.seal(body, files: sealed.map(\.file), in: channelID)
                }
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    Task { @MainActor in
                        guard let session = owner.object?.session else {
                            continuation.resume(throwing: CancellationError())
                            return
                        }
                        session.send(content, files: uploads, to: channelID) { error in
                            if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                        }
                    }
                }
                sentAny = true
            }
            do {
                try await prep.preparePieces(url, name: filmName, options: options) { fraction in
                    DispatchQueue.main.async { owner.object?.updateJob(jobID, progress: fraction) }
                } piece: { made in
                    pending.append(made)
                    pendingSpans.append(made.duration)
                    if pending.count == PrivateMessaging.maxFiles {
                        var items = pending
                        let spans = pendingSpans
                        pending = []
                        pendingSpans = []
                        try await ship(&items, spans: spans, moreComing: true)
                    }
                }
                if !pending.isEmpty { try await ship(&pending, spans: pendingSpans, moreComing: false) }
                await MainActor.run {
                    guard let self = owner.object else { return }
                    self.jobs.removeValue(forKey: jobID)
                    self.jobOrder.removeAll { $0 == jobID }
                    self.uploading.remove(key)
                    self.refreshInput()
                    self.refreshTray()
                }
            } catch {
                let sent = sentAny
                await MainActor.run {
                    guard let self = owner.object else { return }
                    self.jobs.removeValue(forKey: jobID)
                    self.jobOrder.removeAll { $0 == jobID }
                    prep.cancel()
                    self.uploading.remove(key)
                    self.refreshInput()
                    self.refreshTray()
                    if sent {
                        guard !(error is CancellationError) else {
                            self.showSendError("The rest of the video didn't send", detail: "Sending stopped.")
                            return
                        }
                        self.showSendError("The rest of the video didn't send", detail: error.localizedDescription)
                    } else if error is CancellationError {
                        _ = self.restoreUnsent(caption, images: [held.value], to: key)
                    } else {
                        self.reportUnsent(caption, images: [held.value], to: key, error: error)
                    }
                }
            }
        }
    }

    /// Puts an unsent message back where it was written and says why it wasn't sent.
    private func reportUnsent(_ text: String, images: [PreparedAttachment], to key: DraftKey, error: Error) {
        let inBox = restoreUnsent(text, images: images, to: key)
        // Connection problems lock the app instead; no separate alert.
        guard !DiscordSession.isConnectivityError(error) else { return }
        var detail = error.localizedDescription
        if !inBox, let channel = store.channel(key.channelID) {
            detail += "\n\nIt's back in the message box for \(channel.isPrivate ? "@" : "#")\(channel.displayName)"
                + (key.isPrivate ? " in Private." : ".")
        }
        showSendError("Message not sent", detail: detail)
    }

    // MARK: - Private messaging

    /// Pages of older history fetched to find private messages, since this DM was opened in Private.
    private var olderPagesForPrivate = 0
    /// Enough to look through the last 300 messages (six pages) without ever loading a whole history.
    private static let maxOlderPagesForPrivate = 6

    /// In Private, private messages can be few and far between: when fewer than a screenful are loaded,
    /// older history is fetched (a page at a time, up to six pages) to find more.
    private func findOlderPrivateMessages() {
        guard isPrivate, filterText.isEmpty, rows.count < 20, let channelID, store.messages(in: channelID) != nil,
              !store.hasReachedStart(of: channelID), !session.isLoading(channelID),
              olderPagesForPrivate < Self.maxOlderPagesForPrivate else { return }
        olderPagesForPrivate += 1
        session.loadOlder(channelID: channelID)
        updateEmptyState()
    }

    /// What the Private view says when it has nothing to show.
    private var privateEmptyText: String? {
        guard isPrivate, let channelID else { return nil }
        if session.isLoading(channelID) { return "Looking for earlier private messages…" }
        if store.hasReachedStart(of: channelID) { return "No Private Messages Yet" }
        let count = store.messages(in: channelID)?.count ?? 0
        return "No private messages in the last \(count) messages"
    }

    /// A message as shown: private messages decrypted in the Private view and folded to one line elsewhere,
    /// handshakes as a short note. Everything else unchanged.
    private func displayed(_ message: Message) -> Message {
        var shown = message
        // A reply quoting a private message shows it like the message itself, not as the encrypted block.
        if let reply = message.referencedMessage {
            switch PrivateMessaging.kind(of: reply.content) {
            case .plain: break
            case .handshake: shown.referencedMessage?.content = "🔒 Offer to chat privately"
            case .encrypted:
                let text = isPrivate ? privateChat?.plaintext(content: reply.content, id: reply.id, authorID: reply.author.id,
                                                              channelID: message.channelId) : nil
                shown.referencedMessage?.content = text.map { $0.isEmpty ? "🖼 Image" : $0 } ?? "🔒 Private message"
            }
        }
        switch PrivateMessaging.kind(of: message.content) {
        case .plain:
            return shown
        case .handshake:
            shown.content = message.author.id == store.me?.id ? "🔒 *You offered to chat privately.*" : "🔒 *Wants to chat privately.*"
        case .encrypted:
            // Its attachments are the encrypted images: shown decrypted below the text in Private, never as files.
            shown.attachments = []
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
        rebuildState = nil
        swapDraftIfNeeded()
        olderPagesForPrivate = 0
        layoutCache = [:]
        rebuildRows()
        table.reloadData()
        scrollToBottom()
        updateEmptyState()
        refreshInput()
        refreshPrivateBar()
        findOlderPrivateMessages()
    }

    private enum BarAction { case none, verify, accept, reviewKey, settings }
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
            case .waiting(let newKey):
                if newKey {
                    setPrivateBar("\(name) has a new key. Accept it before it receives your messages.",
                                  tone: .warning, action: "Review…", then: .reviewKey)
                } else {
                    setPrivateBar("Waiting for \(name) to set up private chat. They need Duhcord to read private messages.", tone: .info)
                }
            case .ready(let verified, let newKey):
                if newKey {
                    setPrivateBar("\(name) has a new key: a new Mac, a reinstall, or someone in the middle. Verify it before it "
                                  + "receives your messages.", tone: .warning, action: "Review…", then: .reviewKey)
                } else if privateChat.devices.contains(where: { $0.trust == .pending }) {
                    setPrivateBar("Another Mac on your account wants to read your private messages.", tone: .warning,
                                  action: "Review in Settings…", then: .settings)
                } else if !verified {
                    setPrivateBar("Private chat with \(name). Compare safety numbers to make sure no one is in the middle.",
                                  tone: .secure, action: "Verify…", then: .verify)
                } else {
                    setPrivateBar("Private chat with \(name). Verified.", tone: .secure, action: "Safety Number", then: .verify)
                }
            }
        } else if privateChat.hasRequest(in: channelID) {
            setPrivateBar("\(name) wants to chat privately.", tone: .info, action: "Chat Privately", then: .accept)
        } else if case .ready = privateChat.status(for: channelID) {
            // Private chat is set up but this is Standard: say plainly that these messages aren't encrypted.
            setPrivateBar("Standard messages to \(name) aren't encrypted.", tone: .warning, action: "Switch to Private",
                          then: .accept)
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
        case .settings:
            NSApp.sendAction(#selector(AppDelegate.showSettings(_:)), to: nil, from: self)
        case .reviewKey:
            reviewNewKey(in: channelID)
        case .verify:
            guard let number = privateChat.safetyNumber(for: channelID), let window = view.window else { return }
            let name = privateChat.peer(in: channelID)?.displayName ?? "them"
            let alert = NSAlert()
            alert.messageText = "Safety number with \(name)"
            alert.informativeText = number + "\n\nCompare this with \(name)'s, in person or in a voice call (Duhcord's calls are end-to-end "
                + "encrypted). It covers every Mac on both sides: if the numbers match, only your Macs and theirs can read your "
                + "private messages. If either of you adds or removes a Mac, compare again."
            alert.addButton(withTitle: "Mark as Verified")
            alert.addButton(withTitle: "Cancel")
            alert.beginSheetModal(for: window) { [weak self] response in
                guard response == .alertFirstButtonReturn else { return }
                if !privateChat.markVerified(in: channelID, number: number) { self?.keysChangedWhileComparing() }
            }
        }
    }

    /// The other person has a key besides the accepted ones: compare the safety number it would make, then accept
    /// or reject it. Either way is confirmed with what it means.
    private func reviewNewKey(in channelID: Snowflake) {
        // Exactly these keys and this number: a key arriving while the sheet is open isn't accepted with them.
        guard let privateChat, let window = view.window else { return }
        let keys = privateChat.newKeys(in: channelID)
        guard !keys.isEmpty, let number = privateChat.safetyNumber(for: channelID, accepting: keys) else { return }
        let name = privateChat.peer(in: channelID)?.displayName ?? "them"
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "\(name) has a new key"
        alert.informativeText = "It could be a new Mac of theirs, a reinstall, or someone in the middle. Until you accept it, "
            + "your private messages go only to the keys you already trust.\n\nWith it, your safety number is:\n\(number)\n\n"
            + "Compare it with \(name)'s, in person or in a voice call. If it matches, the new key is theirs."
        alert.addButton(withTitle: "Numbers Match")
        alert.addButton(withTitle: "Accept Without Comparing…")
        alert.addButton(withTitle: "Reject Key…")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            switch response {
            case .alertFirstButtonReturn:
                if !privateChat.acceptNewKeys(keys, in: channelID, comparedNumber: number) { self?.keysChangedWhileComparing() }
            case .alertSecondButtonReturn:
                self?.confirm("Accept \(name)'s new key without comparing?",
                              detail: "Your private messages will go to it from now on. If it isn't really theirs, whoever "
                                + "holds it can read them. You can compare safety numbers later with Verify.",
                              button: "Accept Key", destructive: false) {
                    privateChat.acceptNewKeys(keys, in: channelID, comparedNumber: nil)
                }
            case .alertThirdButtonReturn:
                self?.confirm("Reject \(name)'s new key?",
                              detail: "It will never receive your private messages, and anything sent from it is hidden. "
                                + "If it's really a new Mac of theirs, it won't be able to read your messages. This can't be "
                                + "undone; they'd need to set up private messaging again on that Mac.",
                              button: "Reject Key", destructive: true) {
                    privateChat.rejectNewKeys(keys, in: channelID)
                }
            default:
                break
            }
        }
    }

    /// The safety number changed while it was on screen (a key arrived or was approved): what was compared no
    /// longer covers every key, so nothing was marked verified.
    private func keysChangedWhileComparing() {
        DispatchQueue.main.async { [weak self] in
            guard let window = self?.view.window else { return }
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "The keys changed while you were comparing"
            alert.informativeText = "A key was added on one side, so the safety number is different now and the chat isn't "
                + "marked verified. Use Verify to compare the new number."
            alert.beginSheetModal(for: window)
        }
    }

    /// A second sheet confirming a choice made in the first.
    private func confirm(_ title: String, detail: String, button: String, destructive: Bool, then action: @escaping () -> Void) {
        // The first sheet is still closing; start the next once it has.
        DispatchQueue.main.async { [weak self] in
            guard let window = self?.view.window else { return }
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = title
            alert.informativeText = detail
            alert.addButton(withTitle: button).hasDestructiveAction = destructive
            alert.addButton(withTitle: "Cancel")
            alert.beginSheetModal(for: window) { response in
                if response == .alertFirstButtonReturn { action() }
            }
        }
    }

    /// Channels came, went or were renamed. If the one on screen only just became known (a DM opened a moment
    /// before Discord announced it), this switches its message box on.
    func channelsChanged() {
        // A DM that only just became known can turn out to be in Private: its draft follows.
        swapDraftIfNeeded()
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
        findOlderPrivateMessages()

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
            rebuildState = nil
            return
        }
        let privateView = isPrivate
        if filterText.isEmpty,
           let previous = rebuildState,
           previous.channelID == channelID, previous.filterText == filterText, previous.privateView == privateView,
           previous.messageCount > 0, messages.count > previous.messageCount,
           messages.first?.id == previous.firstID,
           messages[previous.messageCount - 1].id == previous.lastID {
            var previousMessage = previous.lastConsidered
            for message in messages.dropFirst(previous.messageCount) {
                if privateView {
                    guard case .encrypted = PrivateMessaging.kind(of: message.content) else { continue }
                }
                var grouped = false
                if let previousMessage, previousMessage.author.id == message.author.id, message.referencedMessage == nil,
                   let a = previousMessage.date, let b = message.date, b.timeIntervalSince(a) < Self.groupWindow {
                    grouped = true
                }
                rows.append(Row(message: message, grouped: grouped))
                previousMessage = message
            }
            rebuildState = RebuildState(channelID: channelID, filterText: filterText, privateView: privateView,
                                        messageCount: messages.count, firstID: messages.first?.id, lastID: messages.last?.id,
                                        lastConsidered: previousMessage)
            return
        }

        var result: [Row] = []
        result.reserveCapacity(messages.count)
        var previous: Message?
        let query = filterText.trimmingCharacters(in: .whitespaces)
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
        rebuildState = RebuildState(channelID: channelID, filterText: filterText, privateView: privateView,
                                    messageCount: messages.count, firstID: messages.first?.id, lastID: messages.last?.id,
                                    lastConsidered: previous)
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
                emptyLabel.stringValue = privateEmptyText ?? "No Messages Yet"
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

    @objc private func backingPropertiesChanged(_ notification: Notification) {
        guard let changedWindow = notification.object as? NSWindow, changedWindow === view.window else { return }
        layoutCache = [:]
        table.reloadData()
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
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.session.typing.tick(at: Date())
                    self.refreshTyping()
                }
            }
            timer.tolerance = 0.5
            RunLoop.main.add(timer, forMode: .common)
            typingTimer = timer
        }
    }

    // MARK: - Sending

    private func send(_ text: String) {
        guard let channelID, let key = draftKey, !isUploading else { return }
        // Images still being prepared go with this message: it waits for them.
        if preparing > 0 {
            sendWhenReady = true
            refreshTray()
            return
        }
        var content = text
        if !attached.isEmpty {
            sendWithImages(text, in: channelID)
            return
        }
        guard !text.isEmpty else { return }
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
            self.reportUnsent(text, images: [], to: key, error: error)
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
            headerHeight: Self.headerHeight, scale: view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2,
            topPadding: MessageCell.topPadding(grouped: row.grouped),
            bottomPadding: MessageCell.bottomPadding, resolver: resolver,
            privateImages: isPrivate ? privateChat?.images(of: message) ?? [] : [])
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
        let message = rows[row].message
        cell.filmResolver = { [weak self] video in
            guard let self, let chat = self.privateChat else { return [] }
            return chat.playbackQueue(forFilmOf: video, in: message.channelId)
        }
        cell.configure(cached.layout, header: cached.header)
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

    /// The right-click menu for a message, as in the official client: copy it, link to it, see who wrote it, and
    /// for your own, remove an image (or other attachment) or delete it.
    private func menuItems(for message: Message, in cell: MessageCell) -> [NSMenuItem] {
        let guildID = store.channel(message.channelId)?.guildId
        var own: [NSMenuItem] = []
        if message.author.id == store.me?.id {
            own = [NSMenuItem.separator()] + removalItems(for: message)
            own.append(ActionMenuItem("Delete Message…") { [weak self] in self?.confirmDelete(message) })
        }
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
        ] + own
    }

    // MARK: - Removing images and messages

    /// "Remove Image…" for each image (or attachment) of one of our messages: one item, or a submenu for several.
    /// A private message's images are only offered in Private, where they're shown.
    private func removalItems(for message: Message) -> [NSMenuItem] {
        let isEncrypted: Bool
        if case .encrypted = PrivateMessaging.kind(of: message.content) { isEncrypted = true } else { isEncrypted = false }
        var choices: [(title: String, index: Int)] = []
        if isEncrypted {
            guard isPrivate, let privateChat else { return [] }
            // A split video is one film. Deleting the message is how a part comes out.
            if privateChat.isFilm(message) { return [] }
            let images = privateChat.images(of: message).filter { $0.attachment != nil }
            choices = images.map { ("Image \($0.index + 1)", $0.index) }
        } else {
            choices = message.attachments.enumerated().map { index, attachment in (attachment.filename, index) }
        }
        guard !choices.isEmpty else { return [] }
        let noun = isEncrypted || message.attachments.allSatisfy(\.isImage) ? "Image" : "Attachment"
        if choices.count == 1 {
            return [ActionMenuItem("Remove \(noun)…") { [weak self] in self?.confirmRemoval(of: choices[0].index, from: message) }]
        }
        let item = NSMenuItem(title: "Remove \(noun)", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for choice in choices {
            submenu.addItem(ActionMenuItem(choice.title + "…") { [weak self] in self?.confirmRemoval(of: choice.index, from: message) })
        }
        item.submenu = submenu
        return [item]
    }

    /// Takes one image out of a sent message, for everyone; deletes the message if nothing else is left.
    private func confirmRemoval(of index: Int, from message: Message) {
        guard let window = view.window, message.attachments.indices.contains(index) else { return }
        let isEncrypted: Bool
        if case .encrypted = PrivateMessaging.kind(of: message.content) { isEncrypted = true } else { isEncrypted = false }
        let remaining = message.attachments.count - 1
        let hasText = isEncrypted ? !(privateChat?.plaintext(content: message.content, id: message.id, authorID: message.author.id,
                                                              channelID: message.channelId) ?? "").isEmpty
            : !message.content.isEmpty
        let deletes = remaining == 0 && !hasText
        let alert = NSAlert()
        alert.messageText = deletes ? "Remove the image and delete the message?" : "Remove this image from the message?"
        alert.informativeText = (deletes ? "The message has nothing else in it, so it's deleted. " : "")
            + "It's removed for everyone in the conversation. Anyone who already saw it may have kept a copy."
        alert.addButton(withTitle: deletes ? "Delete Message" : "Remove Image").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.remove(index, from: message)
        }
    }

    private func remove(_ index: Int, from message: Message) {
        let keep = message.attachments.enumerated().filter { $0.offset != index }.map(\.element.id)
        var content: String?
        if case .encrypted = PrivateMessaging.kind(of: message.content) {
            // The image's key is in the message too: seal the text again without it.
            do {
                guard let privateChat else { return }
                content = try privateChat.content(of: message, removingImage: index)
            } catch {
                showSendError("Image not removed", detail: error.localizedDescription)
                return
            }
            if content == nil {
                delete(message)
                return
            }
        } else if keep.isEmpty, message.content.isEmpty {
            delete(message)
            return
        }
        session.edit(message.id, in: message.channelId, content: content, keepingAttachments: keep) { [weak self] error in
            guard let error, !DiscordSession.isConnectivityError(error) else { return }
            self?.showSendError("Image not removed", detail: error.localizedDescription)
        }
    }

    private func confirmDelete(_ message: Message) {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = "Delete this message?"
        alert.informativeText = "It's deleted for everyone in the conversation, with its images."
        alert.addButton(withTitle: "Delete").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn { self?.delete(message) }
        }
    }

    private func delete(_ message: Message) {
        session.delete(message.id, in: message.channelId) { [weak self] error in
            guard let error, !DiscordSession.isConnectivityError(error) else { return }
            self?.showSendError("Message not deleted", detail: error.localizedDescription)
        }
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
@MainActor
private final class LiveResizeView: NSView {
    var onEndLiveResize: (() -> Void)?
    /// Whether dropped images are wanted, and what to do with them.
    var acceptsImages: ((NSPasteboard) -> Bool)?
    var onDropImages: ((NSPasteboard) -> Void)?

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        acceptsImages?(sender.draggingPasteboard) == true ? .copy : []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        acceptsImages?(sender.draggingPasteboard) == true ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard acceptsImages?(sender.draggingPasteboard) == true else { return false }
        onDropImages?(sender.draggingPasteboard)
        return true
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        onEndLiveResize?()
    }
}

/// One message. Laid out by hand from a precomputed MessageLayout: no Auto Layout, so scrolling stays cheap.
@MainActor
private final class MessageCell: NSTableCellView, NSTextViewDelegate {
    static let identifier = NSUserInterfaceItemIdentifier("MessageCell")
    static let bottomPadding: CGFloat = 2
    static func topPadding(grouped: Bool) -> CGFloat { grouped ? 1 : (Settings.compactLayout ? Theme.Spacing.tight : Theme.Spacing.group) }

    private let headerField = NSTextField(labelWithString: "")
    private let avatarView = RemoteImageView()
    private let bodyView = NSTextView()
    /// The author's picture or name was clicked; the rect is what was clicked, in this cell.
    var onAuthorClicked: ((NSRect) -> Void)?
    /// Rebuilds a private film from the messages loaded now, for the video view in this row.
    var filmResolver: ((PrivateImage) -> [PrivateImage])?
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
                view.filmResolver = filmResolver
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
        filmResolver = nil
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

import AppKit
import DuhcordCore

/// What the left column has selected: the DM list or a guild.
enum Place: Hashable {
    case directMessages
    case guild(Snowflake)
}

/// The three-column window, laid out like Mail: the server sidebar, the channel list, and the messages, under a
/// unified toolbar that carries the channel's name and topic.
@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation, NSToolbarDelegate,
                                  NSSearchFieldDelegate {
    let session: DiscordSession
    let voice: VoiceController
    private let guildList: GuildListViewController
    private let channelList: ChannelListViewController
    private let messages: MessagesViewController
    private var switcher: QuickSwitcher?
    private var voiceDetails: VoiceDetailsWindowController?
    private let profiles: ProfileController
    let privateChat: PrivateChatController
    /// Standard / Private, for the DM on screen.
    private var privateModeItem: NSToolbarItemGroup?
    /// The toolbar's search field: finds messages in the conversation on screen (⌘F).
    private let searchItem = NSSearchToolbarItem(itemIdentifier: .search)
    private let connectionLock = ConnectionLock()

    private var place: Place = .directMessages
    private var lastChannel: [Place: Snowflake] = [:]

    /// The info bar under the toolbar, for things that need attention (like Safari's and Mail's).
    private let banner = BannerView()
    private let bannerAccessory = NSTitlebarAccessoryViewController()
    private var status: String?
    private var updateHandler: (() -> Void)?

    init(session: DiscordSession) {
        self.session = session
        voice = VoiceController(session: session)
        guildList = GuildListViewController(store: session.store)
        channelList = ChannelListViewController(store: session.store, voice: voice)
        messages = MessagesViewController(session: session)
        profiles = ProfileController(session: session)
        privateChat = PrivateChatController(session: session)

        let split = NSSplitViewController()
        let sidebar = NSSplitViewItem(sidebarWithViewController: guildList)
        sidebar.minimumThickness = 180
        sidebar.maximumThickness = 300
        sidebar.canCollapse = true
        let channelItem = NSSplitViewItem(contentListWithViewController: channelList)
        channelItem.minimumThickness = 200
        channelItem.maximumThickness = 340
        let messageItem = NSSplitViewItem(viewController: messages)
        messageItem.minimumThickness = 360
        [sidebar, channelItem, messageItem].forEach(split.addSplitViewItem)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "Duhcord"
        window.contentViewController = split
        window.toolbarStyle = .unified
        // Tab moves between the sidebar, the channel list, the message box and the toolbar.
        window.autorecalculatesKeyViewLoop = true
        window.setContentSize(NSSize(width: 1100, height: 700))
        window.setFrameAutosaveName("DuhcordMain")
        super.init(window: window)
        window.delegate = self

        let toolbar = NSToolbar(identifier: "DuhcordMain")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar

        bannerAccessory.layoutAttribute = .bottom
        bannerAccessory.view = banner
        bannerAccessory.isHidden = true
        window.addTitlebarAccessoryViewController(bannerAccessory)

        guildList.onSelect = { [weak self] place in self?.select(place: place) }
        channelList.onSelect = { [weak self] channelID in self?.select(channelID: channelID) }
        channelList.onJoinVoice = { [weak self] channel in self?.voice.join(channel) }
        channelList.onShowVoiceDetails = { [weak self] in self?.showVoiceDetails() }
        channelList.onShowProfile = { [weak self] userID, guildID, rect, view in
            self?.profiles.showCard(userID: userID, guildID: guildID, relativeTo: rect, of: view)
        }
        messages.onShowProfile = { [weak self] userID, guildID, rect, view in
            self?.profiles.showCard(userID: userID, guildID: guildID, relativeTo: rect, of: view)
        }
        profiles.isLocked = { [weak self] in self?.isLocked ?? false }
        messages.privateChat = privateChat
        PrivateImageLoader.shared.refreshURL = { [rest = session.rest] url in
            try? await rest.refreshAttachmentURLs([url])[url]
        }
        privateChat.onChange = { [weak self] channelID in
            guard let self else { return }
            if channelID == nil || channelID == self.session.store.focusedChannelID { self.messages.privateChanged() }
            self.refreshPrivateModeItem()
        }
        profiles.onOpenGuild = { [weak self] guildID in
            self?.select(place: .guild(guildID))
            self?.window?.makeKeyAndOrderFront(nil)
        }
        profiles.onOpenDM = { [weak self] userID in self?.openDM(with: userID) }
        channelList.onMessageUser = { [weak self] userID in self?.openDM(with: userID) }
        channelList.onMarkRead = { [weak self] channelID in self?.session.markRead(channelID: channelID) }
        guildList.onMarkAllRead = { [weak self] place in
            switch place {
            case .directMessages: self?.session.markAllRead(guildID: nil)
            case .guild(let id): self?.session.markAllRead(guildID: id)
            }
        }
        channelList.onMissingNames = { [weak session] guildID, userIDs in
            session?.requestMemberNames(guildID: guildID, userIDs: userIDs)
        }
        voice.onChange = { [weak self] in
            guard let self else { return }
            self.channelList.voiceChanged()
            self.refreshVoiceToolbar()
            // The details belong to one call; they close when it ends.
            if !self.voice.isInCall { self.voiceDetails?.close() }
        }
        voice.onProblem = { [weak self] title, detail in self?.showVoiceProblem(title: title, detail: detail) }
        session.store.onChange = { [weak self] change in self?.handle(change) }
        NotificationCenter.default.addObserver(self, selector: #selector(updateDockBadge), name: Settings.didChange, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func reload() {
        guildList.reload()
        select(place: place)
        updateDockBadge()
    }

    var isLocked: Bool { connectionLock.isShown }

    func lock(title: String, detail: String, retry: @escaping () -> Void) {
        guard let window else { return }
        switcher = nil
        // Nothing stays usable while locked: profiles (and their message boxes) and the call details close too.
        profiles.closeAll()
        voiceDetails?.close()
        // Decrypted images don't stay on screen while the rest of the app is out of reach.
        PrivateImagePreview.closeAll()
        // Without the main connection Discord drops the call anyway; don't leave it half-running.
        voice.leave()
        connectionLock.show(over: window, title: title, detail: detail, onRetry: retry)
    }

    func unlock() { connectionLock.hide() }

    /// This account is going away (switched from, logged out): its call ends and every window it opened closes.
    func closeAll() {
        switcher = nil
        profiles.closeAll()
        voiceDetails?.close()
        voice.leave()
        connectionLock.hide()
        // Decrypted private images stay with the account they belong to.
        PrivateImagePreview.closeAll()
        PrivateImageLoader.shared.reset()
        close()
    }

    /// Keyboard shortcuts are off while locked; voice commands only work in a call, and their titles follow
    /// the current state.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard !isLocked else { return false }
        switch menuItem.action {
        case #selector(findInConversation(_:)):
            return session.store.focusedChannelID != nil
        case #selector(togglePrivateMessages(_:)):
            guard let channelID = session.store.focusedChannelID else { return false }
            menuItem.state = privateChat.mode(for: channelID) == .private ? .on : .off
            return privateChat.status(for: channelID) != .unavailable
        case #selector(toggleMute(_:)):
            menuItem.title = voice.muted ? "Unmute" : "Mute"
            return voice.isInCall
        case #selector(toggleDeafen(_:)):
            menuItem.title = voice.deafened ? "Undeafen" : "Deafen"
            return voice.isInCall
        case #selector(leaveVoice(_:)):
            return voice.isInCall
        default:
            return true
        }
    }

    /// Shows the info bar under the toolbar, or hides it when `text` is nil.
    func showBanner(_ text: String?, tone: BannerView.Tone = .info, action: String? = nil, handler: (() -> Void)? = nil) {
        guard let text else {
            bannerAccessory.isHidden = true
            return
        }
        banner.show(text, tone: tone, action: action)
        banner.onAction = handler
        bannerAccessory.isHidden = false
    }

    /// An "Update" button in the toolbar while an update is waiting, the way macOS apps flag them quietly.
    func setUpdateAvailable(_ handler: (() -> Void)?) {
        updateHandler = handler
        guard let toolbar = window?.toolbar else { return }
        let index = toolbar.items.firstIndex { $0.itemIdentifier == .update }
        if handler != nil, index == nil {
            toolbar.insertItem(withItemIdentifier: .update, at: toolbar.items.count)
        } else if handler == nil, let index {
            toolbar.removeItem(at: index)
        }
    }

    @objc private func updateClicked(_ sender: Any?) { updateHandler?() }

    /// Shows the DM with someone, opening it on Discord's side first if there isn't one yet.
    private func openDM(with userID: Snowflake) {
        session.directMessageChannel(with: userID) { [weak self] channelID in
            guard let self, let channelID else { return }
            self.select(place: .directMessages)
            self.select(channelID: channelID)
            self.window?.makeKeyAndOrderFront(nil)
        }
    }

    /// The title says what happened, the detail why or what to do, as Apple's alert guidelines ask.
    private func showVoiceProblem(title: String, detail: String) {
        guard let window, window.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.beginSheetModal(for: window)
    }

    /// A connection status ("Reconnecting…") shown as the window subtitle in place of the topic.
    func setStatus(_ text: String?) {
        status = text
        updateTitle()
    }

    /// The window title is the channel's name; the subtitle is its topic, or where it is.
    private func updateTitle() {
        guard let window else { return }
        let channel = session.store.focusedChannelID.flatMap { session.store.channel($0) }
        window.title = channel?.displayName ?? "Duhcord"
        let topic = channel?.topic?.split(separator: "\n").first.map(String.init) ?? ""
        let location = channel.map { $0.isPrivate ? "Direct Message" : ($0.guildId.flatMap { session.store.guilds[$0]?.name } ?? "") } ?? ""
        window.subtitle = status ?? (topic.isEmpty ? location : topic)
    }

    private var indicatorRefreshPending = false

    private func handle(_ change: Store.Change) {
        switch change {
        case .guilds:
            guildList.reload()
        case .channels(let guildID):
            messages.channelsChanged()
            // nil means "everything" (READY) or a DM channel changed.
            if guildID == nil || place == .guild(guildID!) {
                channelList.reload()
                updateTitle()
            }
        case .voice(let guildID):
            if place == .guild(guildID) { channelList.voiceMembersChanged() }
        case .presence(let userID):
            profiles.presenceChanged(userID)
        case .messages(let channelID):
            // Handshakes in a DM set up private chat; read them before showing the messages.
            privateChat.scan(channelID: channelID)
            messages.messagesChanged(in: channelID)
        case .unread:
            // A burst of events (a busy channel, READY's backlog) becomes one refresh at the end of this run-loop turn.
            guard !indicatorRefreshPending else { return }
            indicatorRefreshPending = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                indicatorRefreshPending = false
                channelList.refreshIndicators()
                guildList.refreshIndicators()
                updateDockBadge()
            }
        }
    }

    @objc private func updateDockBadge() {
        let mentions = session.store.totalMentionCount
        NSApp.dockTile.badgeLabel = Settings.dockBadge && mentions > 0 ? String(mentions) : nil
    }

    // MARK: - Selection

    private func select(place: Place) {
        self.place = place
        guildList.select(place)
        channelList.show(place)
        if let remembered = lastChannel[place], session.store.channel(remembered) != nil {
            select(channelID: remembered)
        } else if let first = channelList.channelIDs.first {
            select(channelID: first)
        } else {
            messages.show(channelID: nil)
            updateTitle()
        }
    }

    private func select(channelID: Snowflake) {
        // A search belongs to the conversation it was typed in.
        if !searchItem.searchField.stringValue.isEmpty {
            searchItem.searchField.stringValue = ""
            messages.filterText = ""
        }
        lastChannel[place] = channelID
        channelList.select(channelID)
        messages.show(channelID: channelID)
        session.open(channelID: channelID)
        privateChat.scan(channelID: channelID)
        refreshPrivateModeItem()
        updateTitle()
    }

    /// Jumps to any channel, switching the guild column if needed.
    func jump(to channelID: Snowflake) {
        guard let channel = session.store.channel(channelID) else { return }
        let target: Place = channel.guildId.map { .guild($0) } ?? .directMessages
        lastChannel[target] = channelID
        select(place: target)
    }

    @objc func showQuickSwitcher(_ sender: Any?) {
        guard let window else { return }
        let switcher = QuickSwitcher(store: session.store) { [weak self] channelID in
            self?.jump(to: channelID)
        }
        self.switcher = switcher
        switcher.present(over: window)
    }

    // MARK: - Private messaging

    /// The toggle follows the DM on screen: off for servers and group DMs, and on macOS 13, which lacks HPKE.
    private func refreshPrivateModeItem() {
        guard let item = privateModeItem else { return }
        let channelID = session.store.focusedChannelID
        let available = channelID.map { privateChat.status(for: $0) != .unavailable } ?? false
        item.isEnabled = available
        item.subitems.forEach { $0.isEnabled = available }
        item.selectedIndex = channelID.map { privateChat.mode(for: $0) == .private ? 1 : 0 } ?? 0
        if !PrivateChatController.isSupported {
            item.toolTip = "Private messaging needs macOS 14 or later"
        } else if available {
            item.toolTip = "Standard messages, or end-to-end encrypted private messages that only Duhcord can read"
        } else {
            item.toolTip = "Private messaging is for one-to-one DMs"
        }
    }

    @objc private func privateModeChanged(_ sender: NSToolbarItemGroup) {
        setPrivateMode(sender.selectedIndex == 1)
    }

    /// View → Private Messages (⌥⌘P): the same switch from the keyboard.
    @objc func togglePrivateMessages(_ sender: Any?) {
        guard let channelID = session.store.focusedChannelID else { return }
        setPrivateMode(privateChat.mode(for: channelID) != .private)
    }

    private func setPrivateMode(_ on: Bool) {
        guard let channelID = session.store.focusedChannelID, privateChat.status(for: channelID) != .unavailable else {
            refreshPrivateModeItem()
            return
        }
        // The first time with someone, say what will happen: a visible message goes to them.
        if on, case .waiting = privateChat.status(for: channelID), !privateChat.hasRequest(in: channelID),
           let window, let name = privateChat.peer(in: channelID)?.displayName {
            let alert = NSAlert()
            alert.messageText = "Chat privately with \(name)?"
            alert.informativeText = "Duhcord sends \(name) a short message that sets up end-to-end encryption. If they use "
                + "Duhcord, their app answers it and private messaging starts. If not, they see a note asking them to."
            alert.addButton(withTitle: "Chat Privately")
            alert.addButton(withTitle: "Cancel")
            alert.beginSheetModal(for: window) { [weak self] response in
                guard let self else { return }
                if response == .alertFirstButtonReturn { self.privateChat.setMode(.private, for: channelID) }
                self.refreshPrivateModeItem()
            }
            return
        }
        privateChat.setMode(on ? .private : .standard, for: channelID)
    }

    /// ⌘F: search the messages loaded in this conversation.
    @objc func findInConversation(_ sender: Any?) {
        if !(window?.toolbar?.isVisible ?? true) { window?.toolbar?.isVisible = true }
        searchItem.beginSearchInteraction()
    }

    func controlTextDidChange(_ notification: Notification) {
        guard (notification.object as? NSSearchField) === searchItem.searchField else { return }
        messages.filterText = searchItem.searchField.stringValue
    }

    func searchFieldDidEndSearching(_ sender: NSSearchField) {
        messages.filterText = ""
    }

    @objc func selectPreviousChannel(_ sender: Any?) { step(by: -1) }
    @objc func selectNextChannel(_ sender: Any?) { step(by: 1) }

    @objc func selectNextUnread(_ sender: Any?) {
        let store = session.store
        let candidates = store.privateChannels.map(\.id)
            + store.orderedGuilds.flatMap { guild in
                store.channelList(guildID: guild.id).compactMap { item -> Snowflake? in
                    if case .channel(let c) = item { return c.id }
                    return nil
                }
            }
        if let next = candidates.first(where: { store.isUnread($0) && $0 != store.focusedChannelID }) {
            jump(to: next)
        } else {
            NSSound.beep()
        }
    }

    private func step(by delta: Int) {
        let ids = channelList.channelIDs
        guard !ids.isEmpty else { return }
        let current = session.store.focusedChannelID.flatMap { ids.firstIndex(of: $0) } ?? 0
        let next = max(0, min(ids.count - 1, current + delta))
        select(channelID: ids[next])
    }

    // MARK: - Toolbar

    private func refreshVoiceToolbar() {
        guard let toolbar = window?.toolbar else { return }
        let voiceIDs: [NSToolbarItem.Identifier] = [.voiceMute, .voiceDeafen, .voiceLeave]
        let present = toolbar.items.contains { $0.itemIdentifier == .voiceMute }
        if voice.isInCall, !present {
            let at = toolbar.items.firstIndex { $0.itemIdentifier == .jumpTo } ?? toolbar.items.count
            for (offset, id) in voiceIDs.enumerated() { toolbar.insertItem(withItemIdentifier: id, at: at + offset) }
        } else if !voice.isInCall, present {
            for index in toolbar.items.indices.reversed() where voiceIDs.contains(toolbar.items[index].itemIdentifier) {
                toolbar.removeItem(at: index)
            }
        }
        for item in toolbar.items { configureVoiceItem(item) }
    }

    private func configureVoiceItem(_ item: NSToolbarItem) {
        let micOff = voice.muted || voice.deafened || voice.serverMuted || voice.serverDeafened
        let soundOff = voice.deafened || voice.serverDeafened
        switch item.itemIdentifier {
        case .voiceMute:
            item.label = voice.muted ? "Unmute" : "Mute"
            item.image = NSImage(systemSymbolName: micOff ? "mic.slash.fill" : "mic.fill", accessibilityDescription: item.label)
        case .voiceDeafen:
            item.label = voice.deafened ? "Undeafen" : "Deafen"
            item.image = NSImage(systemSymbolName: soundOff ? "speaker.slash.fill" : "headphones", accessibilityDescription: item.label)
        case .voiceLeave:
            item.label = "Disconnect"
            item.image = NSImage(systemSymbolName: "phone.down.fill", accessibilityDescription: item.label)
        default:
            return
        }
        item.toolTip = item.label
    }

    private func showVoiceDetails() {
        guard voice.isInCall else { return }
        if voiceDetails == nil {
            let details = VoiceDetailsWindowController(voice: voice)
            details.onClose = { [weak self] in self?.voiceDetails = nil }
            voiceDetails = details
        }
        voiceDetails?.show()
    }

    @objc func toggleMute(_ sender: Any?) { voice.toggleMute() }
    @objc func toggleDeafen(_ sender: Any?) { voice.toggleDeafen() }
    @objc func leaveVoice(_ sender: Any?) { voice.leave() }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, .flexibleSpace, .privateMode, .jumpTo, .search]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar) + [.voiceMute, .voiceDeafen, .voiceLeave, .update]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        if id == .privateMode {
            let group = NSToolbarItemGroup(itemIdentifier: .privateMode, titles: ["Standard", "Private"],
                                           selectionMode: .selectOne, labels: ["Standard", "Private"],
                                           target: self, action: #selector(privateModeChanged(_:)))
            group.label = "Messages"
            group.autovalidates = false
            group.subitems.forEach { $0.autovalidates = false }
            group.subitems.last?.image = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: "Private")
            privateModeItem = group
            refreshPrivateModeItem()
            return group
        }
        if id == .search {
            searchItem.searchField.placeholderString = "Search Conversation"
            searchItem.searchField.delegate = self
            searchItem.searchField.sendsSearchStringImmediately = true
            searchItem.toolTip = "Find messages in this conversation (⌘F)"
            searchItem.label = "Search"
            return searchItem
        }
        let item = NSToolbarItem(itemIdentifier: id)
        item.target = self
        item.isBordered = true
        switch id {
        case .jumpTo:
            item.label = "Jump To"
            item.toolTip = "Jump to a channel or person (⌘K)"
            item.image = NSImage(systemSymbolName: "arrow.right.circle", accessibilityDescription: "Jump To")
            item.action = #selector(showQuickSwitcher(_:))
        case .update:
            item.label = "Update"
            item.toolTip = "A new version of Duhcord is available"
            item.image = NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: "Update")
            item.action = #selector(updateClicked(_:))
        case .voiceMute:
            item.action = #selector(toggleMute(_:))
            configureVoiceItem(item)
        case .voiceDeafen:
            item.action = #selector(toggleDeafen(_:))
            configureVoiceItem(item)
        case .voiceLeave:
            item.action = #selector(leaveVoice(_:))
            configureVoiceItem(item)
        default:
            return nil
        }
        return item
    }
}

extension NSToolbarItem.Identifier {
    static let jumpTo = Self("jumpTo")
    static let search = Self("search")
    static let privateMode = Self("privateMode")
    static let update = Self("update")
    static let voiceMute = Self("voiceMute")
    static let voiceDeafen = Self("voiceDeafen")
    static let voiceLeave = Self("voiceLeave")
}

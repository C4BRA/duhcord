import AppKit
import DuhcordCore

/// What the left column has selected: the DM list or a guild.
enum Place: Hashable {
    case directMessages
    case guild(Snowflake)
}

/// The three-column window, laid out like Mail: the server sidebar, the channel list, and the messages, under a
/// unified toolbar that carries the channel's name and topic.
final class MainWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation, NSToolbarDelegate {
    let session: DiscordSession
    let voice: VoiceController
    private let guildList: GuildListViewController
    private let channelList: ChannelListViewController
    private let messages: MessagesViewController
    private var switcher: QuickSwitcher?
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
        channelList.onMissingNames = { [weak session] guildID, userIDs in
            session?.requestMemberNames(guildID: guildID, userIDs: userIDs)
        }
        voice.onChange = { [weak self] in
            self?.channelList.voiceChanged()
            self?.refreshVoiceToolbar()
        }
        voice.onProblem = { [weak self] message in self?.showVoiceProblem(message) }
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
        // Without the main connection Discord drops the call anyway; don't leave it half-running.
        voice.leave()
        connectionLock.show(over: window, title: title, detail: detail, onRetry: retry)
    }

    func unlock() { connectionLock.hide() }

    /// Keyboard shortcuts are off while locked; voice commands only work in a call, and their titles follow
    /// the current state.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard !isLocked else { return false }
        switch menuItem.action {
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

    private func showVoiceProblem(_ message: String) {
        guard let window, window.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.messageText = "Voice"
        alert.informativeText = message
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
            // nil means "everything" (READY) or a DM channel changed.
            if guildID == nil || place == .guild(guildID!) {
                channelList.reload()
                updateTitle()
            }
        case .voice(let guildID):
            if place == .guild(guildID) { channelList.voiceMembersChanged() }
        case .messages(let channelID):
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
        lastChannel[place] = channelID
        channelList.select(channelID)
        messages.show(channelID: channelID)
        session.open(channelID: channelID)
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

    @objc func toggleMute(_ sender: Any?) { voice.toggleMute() }
    @objc func toggleDeafen(_ sender: Any?) { voice.toggleDeafen() }
    @objc func leaveVoice(_ sender: Any?) { voice.leave() }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, .flexibleSpace, .jumpTo]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar) + [.voiceMute, .voiceDeafen, .voiceLeave, .update]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: id)
        item.target = self
        item.isBordered = true
        switch id {
        case .jumpTo:
            item.label = "Jump To"
            item.toolTip = "Jump to a channel or person (⌘K)"
            item.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "Jump To")
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
    static let update = Self("update")
    static let voiceMute = Self("voiceMute")
    static let voiceDeafen = Self("voiceDeafen")
    static let voiceLeave = Self("voiceLeave")
}

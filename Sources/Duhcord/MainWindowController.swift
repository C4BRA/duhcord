import AppKit
import DuhcordCore

/// What the left column has selected: the DM list or a guild.
enum Place: Hashable {
    case directMessages
    case guild(Snowflake)
}

/// The three-column window: guilds, channels, messages.
final class MainWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    let session: DiscordSession
    private let guildList: GuildListViewController
    private let channelList: ChannelListViewController
    private let messages: MessagesViewController
    private var switcher: QuickSwitcher?
    private let connectionLock = ConnectionLock()

    private var place: Place = .directMessages
    private var lastChannel: [Place: Snowflake] = [:]

    init(session: DiscordSession) {
        self.session = session
        guildList = GuildListViewController(store: session.store)
        channelList = ChannelListViewController(store: session.store)
        messages = MessagesViewController(session: session)

        let split = NSSplitViewController()
        split.splitView.isVertical = true
        split.splitView.dividerStyle = .thin

        let guildItem = NSSplitViewItem(viewController: guildList)
        guildItem.minimumThickness = 64
        guildItem.maximumThickness = 64
        guildItem.canCollapse = false
        let channelItem = NSSplitViewItem(viewController: channelList)
        channelItem.minimumThickness = 160
        channelItem.maximumThickness = 320
        channelItem.canCollapse = true
        let messageItem = NSSplitViewItem(viewController: messages)
        messageItem.minimumThickness = 320
        [guildItem, channelItem, messageItem].forEach(split.addSplitViewItem)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 680),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Duhcord"
        window.contentViewController = split
        window.setContentSize(NSSize(width: 1000, height: 680))
        window.setFrameAutosaveName("DuhcordMain")
        super.init(window: window)
        window.delegate = self

        guildList.onSelect = { [weak self] place in self?.select(place: place) }
        channelList.onSelect = { [weak self] channelID in self?.select(channelID: channelID) }
        session.store.onChange = { [weak self] change in self?.handle(change) }
        NotificationCenter.default.addObserver(self, selector: #selector(updateDockBadge), name: Settings.didChange, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func reload() {
        guildList.reload()
        select(place: place)
    }

    var isLocked: Bool { connectionLock.isShown }

    func lock(title: String, detail: String, retry: @escaping () -> Void) {
        guard let window else { return }
        switcher = nil
        connectionLock.show(over: window, title: title, detail: detail, onRetry: retry)
    }

    func unlock() { connectionLock.hide() }

    /// Keyboard shortcuts in the Go menu are off while locked.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool { !isLocked }

    func setStatus(_ text: String?) {
        window?.subtitle = text ?? ""
    }

    private func handle(_ change: Store.Change) {
        switch change {
        case .guilds:
            guildList.reload()
        case .channels(let guildID):
            // nil means "everything" (READY) or a DM channel changed.
            if guildID == nil || place == .guild(guildID!) {
                channelList.reload()
            }
        case .messages(let channelID):
            messages.messagesChanged(in: channelID)
        case .unread:
            channelList.refreshIndicators()
            guildList.refreshIndicators()
            updateDockBadge()
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
        }
    }

    private func select(channelID: Snowflake) {
        lastChannel[place] = channelID
        channelList.select(channelID)
        messages.show(channelID: channelID)
        session.open(channelID: channelID)
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
}

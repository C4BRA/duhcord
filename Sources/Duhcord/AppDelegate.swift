import AppKit
import DuhcordCore
import UserNotifications

@main
final class AppDelegate: NSObject, NSApplicationDelegate, DiscordSessionDelegate, NSMenuItemValidation,
                         UNUserNotificationCenterDelegate, NSMenuDelegate {
    private static var shared: AppDelegate?

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        shared = delegate
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }

    private var session: DiscordSession?
    private var mainWindow: MainWindowController?
    private var loginWindow: LoginWindowController?
    /// "Add Account": a second QR login while the current account stays connected.
    private var addAccountWindow: LoginWindowController?
    /// The connected session's token and account (the account is nil until Discord's READY for a new login).
    private var sessionToken: String?
    private var sessionAccountID: Snowflake?
    /// Shown once the next account is on screen (why the previous one went away).
    private var pendingNotice: (title: String, detail: String)?
    private var settingsWindow: SettingsWindowController?
    private var updates: UpdateController?

    /// Notifications need a real app bundle; running the bare binary from the terminal has none.
    private var canNotify: Bool { Bundle.main.bundleIdentifier != nil }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Settings.registerDefaults()
        updates = UpdateController()
        NSApp.mainMenu = buildMenu()
        if canNotify { UNUserNotificationCenter.current().delegate = self }
        if let token = AccountStore.launchToken() {
            start(token: token, accountID: AccountStore.currentID)
        } else {
            showLogin()
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { (mainWindow ?? loginWindow)?.showWindow(nil) }
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) { session?.isActive = true }
    func applicationDidResignActive(_ notification: Notification) { session?.isActive = false }

    // MARK: - Login flow

    /// Opens the QR login window. With `startCode: false` it only shows a spinner (used while a saved session connects).
    private func showLogin(message: String? = nil, startCode: Bool = true) {
        mainWindow?.closeAll()
        mainWindow = nil
        let login = loginWindow ?? LoginWindowController { [weak self] token in
            // Saved under its account once Discord says whose it is (READY).
            self?.start(token: token, accountID: nil)
        }
        loginWindow = login
        if startCode {
            login.beginQR(message: message)
        } else {
            login.setBusy()
        }
        login.showWindow(nil)
    }

    private func start(token: String, accountID: Snowflake?) {
        session?.disconnect()
        sessionToken = token
        sessionAccountID = accountID
        let session = DiscordSession(token: token)
        session.delegate = self
        session.isActive = NSApp.isActive
        self.session = session
        // Show something while READY arrives, which can take a few seconds.
        if mainWindow == nil, loginWindow == nil { showLogin(startCode: false) }
        loginWindow?.setBusy()
        session.connect()
    }

    // MARK: - Accounts

    /// Disconnects the account on screen (ending any call) and connects another, as Discord's own switcher does.
    private func switchTo(token: String, accountID: Snowflake?) {
        settingsWindow?.close()
        mainWindow?.closeAll()
        mainWindow = nil
        NSApp.dockTile.badgeLabel = nil
        start(token: token, accountID: accountID)
    }

    @objc func switchAccount(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        switchToAccount(id)
    }

    private func switchToAccount(_ id: Snowflake) {
        guard id != sessionAccountID, !isLocked, let token = AccountStore.token(for: id) else { return }
        switchTo(token: token, accountID: id)
    }

    /// A QR login for another account. The current account stays connected until the new one is approved.
    @objc func addAccount(_ sender: Any?) {
        guard !AccountStore.isFull, !isLocked else { return }
        if let existing = addAccountWindow {
            existing.showWindow(nil)
            return
        }
        let window = LoginWindowController(adding: true) { [weak self] token in
            guard let self else { return }
            self.addAccountWindow?.close()
            self.addAccountWindow = nil
            self.switchTo(token: token, accountID: nil)
        }
        addAccountWindow = window
        window.showWindow(nil)
    }

    /// The Switch Account menu, built when it opens: each saved account (⌃⌘1–5), then Add Account.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for (index, account) in AccountStore.accounts.enumerated() {
            let title = account.displayName == account.username ? account.username : "\(account.displayName) (@\(account.username))"
            let item = NSMenuItem(title: title, action: #selector(switchAccount(_:)), keyEquivalent: index < 9 ? String(index + 1) : "")
            item.keyEquivalentModifierMask = [.control, .command]
            item.representedObject = account.id
            item.target = self
            item.state = account.id == sessionAccountID ? .on : .off
            menu.addItem(item)
        }
        if !AccountStore.accounts.isEmpty { menu.addItem(.separator()) }
        let add = NSMenuItem(title: "Add Account…", action: #selector(addAccount(_:)), keyEquivalent: "")
        add.target = self
        menu.addItem(add)
    }

    /// Logs out an account that isn't the one on screen: revokes its token on Discord's side, then forgets it.
    private func logOutOtherAccount(_ id: Snowflake) {
        guard let token = AccountStore.token(for: id) else {
            AccountStore.remove(id)
            refreshSettings()
            return
        }
        let name = AccountStore.accounts.first { $0.id == id }?.displayName ?? "this account"
        Task { @MainActor in
            do {
                try await RESTClient(token: token).logout()
            } catch RESTError.unauthorized {
                // Already dead on Discord's side; nothing left to revoke.
            } catch {
                let alert = NSAlert()
                alert.messageText = "Couldn't log out \(name)"
                alert.informativeText = "Duhcord can't reach Discord, so that session is still active. It stays saved until it can be logged out."
                alert.runModal()
                return
            }
            AccountStore.remove(id)
            refreshSettings()
        }
    }

    /// After the account on screen is logged out or its session ends: the next saved one, or the QR login.
    private func continueWithNextAccount(message: String) {
        if let next = AccountStore.accounts.first, let token = AccountStore.token(for: next.id) {
            pendingNotice = ("Logged in as \(next.displayName)", message)
            switchTo(token: token, accountID: next.id)
        } else {
            showLogin(message: message)
        }
    }

    /// Turns off Discord's data collection settings on the account on screen, once per account, while
    /// Settings → Privacy → "Limit what Discord collects" is on (the default). Done once rather than at every
    /// launch, so a choice made later in Discord's own app is left alone.
    private func limitDataCollectionIfNeeded(force: Bool = false) {
        guard Settings.limitDiscordData, let session, let id = sessionAccountID,
              force || AccountStore.accounts.first(where: { $0.id == id })?.dataLimited != true else { return }
        Task { @MainActor in
            do {
                try await session.rest.limitDataCollection()
                AccountStore.setDataLimited(id, true)
            } catch {
                // Tried again at the next connection.
            }
        }
    }

    private func refreshSettings() {
        guard let settingsWindow, settingsWindow.window?.isVisible == true else { return }
        settingsWindow.show(accounts: AccountStore.accounts, currentID: sessionAccountID)
    }

    @objc private func checkForUpdates(_ sender: Any?) { updates?.checkNow() }

    /// The README on GitHub: what Duhcord does, its shortcuts and how it keeps you safe.
    @objc private func showHelp(_ sender: Any?) {
        NSWorkspace.shared.open(URL(string: "https://github.com/C4BRA/duhcord#readme")!)
    }

    @objc private func showSettings(_ sender: Any?) {
        let controller = settingsWindow ?? SettingsWindowController()
        controller.onLogOut = { [weak self] id in self?.confirmLogOut(accountID: id) }
        controller.onSwitch = { [weak self] id in self?.switchToAccount(id) }
        controller.onAddAccount = { [weak self] in self?.addAccount(nil) }
        controller.onLimitData = { [weak self] in self?.limitDataCollectionIfNeeded(force: true) }
        settingsWindow = controller
        controller.show(accounts: AccountStore.accounts, currentID: sessionAccountID)
    }

    /// Logging out ends the session for good (logging back in takes a new QR scan), so it's confirmed first.
    @objc private func confirmLogOut(_ sender: Any?) {
        confirmLogOut(accountID: sessionAccountID)
    }

    private func confirmLogOut(accountID: Snowflake?) {
        let isCurrent = accountID == nil || accountID == sessionAccountID
        let name = AccountStore.accounts.first { $0.id == accountID }?.displayName
        let alert = NSAlert()
        alert.messageText = name.map { "Log out of \($0)?" } ?? "Log out of Duhcord?"
        alert.informativeText = "The session ends on Discord's side too. To log back in, you'll scan a new QR code with your phone."
        let logOutButton = alert.addButton(withTitle: "Log Out")
        logOutButton.hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        // Cancel is the default, so a stray Return doesn't log out.
        logOutButton.keyEquivalent = ""
        alert.buttons[1].keyEquivalent = "\r"
        let handle: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            if isCurrent {
                self?.logOut(nil)
            } else if let accountID {
                self?.logOutOtherAccount(accountID)
            }
        }
        if let window = mainWindow?.window, window.attachedSheet == nil {
            alert.beginSheetModal(for: window, completionHandler: handle)
        } else {
            handle(alert.runModal())
        }
    }

    /// Logs out on Discord's side first. If Discord can't be reached the app locks with only a Retry button,
    /// so the token is never dropped locally while it still works on Discord's servers.
    @objc private func logOut(_ sender: Any?) {
        guard let session else {
            showLogin()
            return
        }
        Task { @MainActor in
            do {
                try await session.logout()
            } catch RESTError.unauthorized {
                // The token was already dead on Discord's side; nothing left to revoke.
            } catch {
                lock(title: "Couldn't log out", detail: "Duhcord can't reach Discord, so your session is still active. "
                     + "Duhcord stays locked until it can finish logging you out.") { [weak self] in self?.logOut(nil) }
                return
            }
            guard self.session === session else { return }
            mainWindow?.voice.leave()
            self.session = nil
            session.disconnect()
            if let id = sessionAccountID ?? session.store.me?.id { AccountStore.remove(id) }
            sessionToken = nil
            sessionAccountID = nil
            NSApp.dockTile.badgeLabel = nil
            mainWindow?.unlock()
            continueWithNextAccount(message: "The account you logged out of was removed from this Mac.")
        }
    }

    /// Blocks the whole app until `retry` succeeds.
    private func lock(title: String = "Can't reach Discord",
                      detail: String = "Duhcord stays locked until it can talk to Discord again.",
                      retry: @escaping () -> Void) {
        settingsWindow?.close()
        if let mainWindow {
            mainWindow.lock(title: title, detail: detail, retry: retry)
        } else {
            loginWindow?.show(error: title + ". " + detail, retry: retry)
        }
    }

    private var isLocked: Bool { mainWindow?.isLocked ?? false }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(showSettings(_:)), #selector(confirmLogOut(_:)):
            return session != nil && !isLocked
        case #selector(switchAccount(_:)):
            return !isLocked
        case #selector(addAccount(_:)):
            return !isLocked && !AccountStore.isFull
        default:
            return true
        }
    }

    // MARK: - DiscordSessionDelegate

    func sessionDidBecomeReady(_ session: DiscordSession) {
        loginWindow?.close()
        loginWindow = nil
        // Now Discord has said whose token this is: save it under that account and make it the current one.
        if let me = session.store.me, let token = sessionToken {
            sessionAccountID = me.id
            if let replaced = AccountStore.remember(me, token: token) {
                // The same account logged in again: the old token is no longer needed, so it's revoked.
                Task { try? await RESTClient(token: replaced).logout() }
            }
        }
        if mainWindow == nil {
            let main = MainWindowController(session: session)
            mainWindow = main
            main.showWindow(nil)
            updates?.window = main
        }
        mainWindow?.reload()
        limitDataCollectionIfNeeded()
        if let notice = pendingNotice, let window = mainWindow?.window {
            pendingNotice = nil
            let alert = NSAlert()
            alert.messageText = notice.title
            alert.informativeText = notice.detail
            alert.beginSheetModal(for: window)
        }
    }

    func session(_ session: DiscordSession, didChangeState state: GatewayClient.State) {
        switch state {
        case .authenticationFailed:
            endSession(session, message: "A session ended on Discord's side. Scan a new code to log back in to it.")
        case .closed(let code):
            // Discord ended the session for good; reconnecting can't fix it.
            endSession(session, message: "Discord ended a session (code \(code)). Scan a new code to log back in to it.")
        case .unreachable:
            lock { [weak session] in session?.retry() }
        case .reconnecting:
            mainWindow?.setStatus("Reconnecting…")
        case .connected:
            mainWindow?.setStatus(nil)
            mainWindow?.unlock()
        case .connecting, .disconnected:
            break
        }
    }

    /// The account on screen can't be used any more: forget it and move on to the next one.
    private func endSession(_ session: DiscordSession, message: String) {
        session.disconnect()
        self.session = nil
        if let id = sessionAccountID {
            AccountStore.remove(id)
        } else if let token = sessionToken, AccountStore.launchToken() == token {
            // A token from an older build that never reached READY.
            Keychain.delete(service: "com.duhcord.token", account: "default")
        }
        sessionToken = nil
        sessionAccountID = nil
        continueWithNextAccount(message: message)
    }

    func session(_ session: DiscordSession, shouldNotifyAbout message: Message) {
        guard canNotify, !NSApp.isActive || session.store.focusedChannelID != message.channelId else { return }
        switch Settings.notifications {
        case .off:
            return
        case .mentionsOnly:
            if session.store.channel(message.channelId)?.isPrivate == true, !session.store.mentionsMe(message) { return }
        case .directMessagesAndMentions:
            break
        }
        let content = UNMutableNotificationContent()
        let channel = session.store.channel(message.channelId)
        content.title = message.author.displayName
        if let channel, !channel.isPrivate {
            content.subtitle = "#" + channel.displayName
        }
        // Names instead of <@123> tokens, and no Markdown characters; spoilers stay hidden. Private messages
        // aren't decrypted into Notification Centre, which keeps a copy.
        let text: String
        switch PrivateMessaging.kind(of: message.content) {
        case .plain: text = Markdown.plainText(message.content, resolver: session.store.resolver(for: message))
        case .handshake: text = "🔒 Wants to chat privately"
        case .encrypted: text = "🔒 Private message"
        }
        content.body = text.isEmpty ? (message.attachments.isEmpty ? "Sent a message" : "Sent an attachment") : text
        content.sound = Settings.notificationSound ? .default : nil
        content.userInfo = ["channelID": message.channelId]
        let request = UNNotificationRequest(identifier: message.id, content: content, trigger: nil)
        deliver(request)
    }

    /// Asks for permission the first time there's something to notify about, rather than at launch, so the
    /// question comes with a reason (Apple's guidance). After that macOS remembers the answer.
    private func deliver(_ request: UNNotificationRequest) {
        let center = UNUserNotificationCenter.current()
        let pending = Handoff(value: request)
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    if granted { center.add(pending.value) }
                }
            case .denied:
                break
            default:
                center.add(pending.value)
            }
        }
    }

    /// Clicking a notification opens its conversation, as in the official client.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let channelID = response.notification.request.content.userInfo["channelID"] as? String
        let done = Handoff(value: completionHandler)
        let owner = WeakReference(self)
        DispatchQueue.main.async {
            defer { done.value() }
            guard let self = owner.object, let channelID, let main = self.mainWindow, !main.isLocked else { return }
            NSApp.activate(ignoringOtherApps: true)
            main.showWindow(nil)
            main.jump(to: channelID)
        }
    }

    // MARK: - Menu

    private func buildMenu() -> NSMenu {
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Duhcord", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdates(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings…", action: #selector(showSettings(_:)), keyEquivalent: ",")
        let accounts = NSMenu(title: "Switch Account")
        accounts.delegate = self
        appMenu.addItem(submenu: accounts, title: "Switch Account")
        appMenu.addItem(withTitle: "Log Out…", action: #selector(confirmLogOut(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let services = NSMenu(title: "Services")
        appMenu.addItem(submenu: services, title: "Services")
        NSApp.servicesMenu = services
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Duhcord", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Duhcord", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(submenu: appMenu, title: "Duhcord")

        let file = NSMenu(title: "File")
        file.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        main.addItem(submenu: file, title: "File")

        // Without an Edit menu, ⌘C/⌘V don't work in text fields.
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: "")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        let find = NSMenu(title: "Find")
        find.addItem(withTitle: "Find in Conversation…", action: #selector(MainWindowController.findInConversation(_:)), keyEquivalent: "f")
        edit.addItem(submenu: find, title: "Find")
        main.addItem(submenu: edit, title: "Edit")

        let view = NSMenu(title: "View")
        let sidebar = view.addItem(withTitle: "Show Sidebar", action: #selector(NSSplitViewController.toggleSidebar(_:)), keyEquivalent: "s")
        sidebar.keyEquivalentModifierMask = [.control, .command]
        let privateItem = view.addItem(withTitle: "Private Messages", action: #selector(MainWindowController.togglePrivateMessages(_:)), keyEquivalent: "p")
        privateItem.keyEquivalentModifierMask = [.command, .option]
        view.addItem(.separator())
        let fullScreen = view.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fullScreen.keyEquivalentModifierMask = [.control, .command]
        main.addItem(submenu: view, title: "View")

        let go = NSMenu(title: "Go")
        go.addItem(withTitle: "Jump to Channel…", action: #selector(MainWindowController.showQuickSwitcher(_:)), keyEquivalent: "k")
        let prev = go.addItem(withTitle: "Previous Channel", action: #selector(MainWindowController.selectPreviousChannel(_:)), keyEquivalent: String(Character(UnicodeScalar(NSUpArrowFunctionKey)!)))
        prev.keyEquivalentModifierMask = [.option]
        let next = go.addItem(withTitle: "Next Channel", action: #selector(MainWindowController.selectNextChannel(_:)), keyEquivalent: String(Character(UnicodeScalar(NSDownArrowFunctionKey)!)))
        next.keyEquivalentModifierMask = [.option]
        let unread = go.addItem(withTitle: "Next Unread Channel", action: #selector(MainWindowController.selectNextUnread(_:)), keyEquivalent: String(Character(UnicodeScalar(NSDownArrowFunctionKey)!)))
        unread.keyEquivalentModifierMask = [.option, .shift]
        main.addItem(submenu: go, title: "Go")

        // Keyboard control of calls, so voice works without the mouse.
        let voice = NSMenu(title: "Voice")
        let mute = voice.addItem(withTitle: "Mute", action: #selector(MainWindowController.toggleMute(_:)), keyEquivalent: "m")
        mute.keyEquivalentModifierMask = [.command, .shift]
        let deafen = voice.addItem(withTitle: "Deafen", action: #selector(MainWindowController.toggleDeafen(_:)), keyEquivalent: "d")
        deafen.keyEquivalentModifierMask = [.command, .shift]
        voice.addItem(.separator())
        voice.addItem(withTitle: "Disconnect", action: #selector(MainWindowController.leaveVoice(_:)), keyEquivalent: "")
        main.addItem(submenu: voice, title: "Voice")

        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        window.addItem(.separator())
        window.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        main.addItem(submenu: window, title: "Window")
        NSApp.windowsMenu = window

        let help = NSMenu(title: "Help")
        help.addItem(withTitle: "Duhcord Help", action: #selector(showHelp(_:)), keyEquivalent: "?")
        main.addItem(submenu: help, title: "Help")
        NSApp.helpMenu = help

        return main
    }
}

private extension NSMenu {
    func addItem(submenu: NSMenu, title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        addItem(item)
    }
}

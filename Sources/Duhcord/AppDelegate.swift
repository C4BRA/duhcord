import AppKit
import DuhcordCore
import UserNotifications

@main
final class AppDelegate: NSObject, NSApplicationDelegate, DiscordSessionDelegate, NSMenuItemValidation,
                         UNUserNotificationCenterDelegate {
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
    private var settingsWindow: SettingsWindowController?
    private var updates: UpdateController?

    /// Notifications need a real app bundle; running the bare binary from the terminal has none.
    private var canNotify: Bool { Bundle.main.bundleIdentifier != nil }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Settings.registerDefaults()
        updates = UpdateController()
        NSApp.mainMenu = buildMenu()
        if canNotify { UNUserNotificationCenter.current().delegate = self }
        if let token = Keychain.loadToken() {
            start(token: token)
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
        mainWindow?.voice.leave()
        mainWindow?.close()
        mainWindow = nil
        let login = loginWindow ?? LoginWindowController { [weak self] token in
            Keychain.saveToken(token)
            self?.start(token: token)
        }
        loginWindow = login
        if startCode {
            login.beginQR(message: message)
        } else {
            login.setBusy()
        }
        login.showWindow(nil)
    }

    private func start(token: String) {
        session?.disconnect()
        let session = DiscordSession(token: token)
        session.delegate = self
        session.isActive = NSApp.isActive
        self.session = session
        // Show something while READY arrives, which can take a few seconds.
        if mainWindow == nil, loginWindow == nil { showLogin(startCode: false) }
        loginWindow?.setBusy()
        session.connect()
    }

    @objc private func checkForUpdates(_ sender: Any?) { updates?.checkNow() }

    /// The README on GitHub: what Duhcord does, its shortcuts and how it keeps you safe.
    @objc private func showHelp(_ sender: Any?) {
        NSWorkspace.shared.open(URL(string: "https://github.com/C4BRA/duhcord#readme")!)
    }

    @objc private func showSettings(_ sender: Any?) {
        let controller = settingsWindow ?? SettingsWindowController { [weak self] in self?.confirmLogOut(nil) }
        settingsWindow = controller
        controller.show(accountName: session?.store.me?.displayName)
    }

    /// Logging out ends the session for good (logging back in takes a new QR scan), so it's confirmed first.
    @objc private func confirmLogOut(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Log out of Duhcord?"
        alert.informativeText = "Your session ends on Discord's side too. To log back in, you'll scan a new QR code with your phone."
        let logOutButton = alert.addButton(withTitle: "Log Out")
        logOutButton.hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        // Cancel is the default, so a stray Return doesn't log out.
        logOutButton.keyEquivalent = ""
        alert.buttons[1].keyEquivalent = "\r"
        let handle: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            if response == .alertFirstButtonReturn { self?.logOut(nil) }
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
            Keychain.deleteToken()
            NSApp.dockTile.badgeLabel = nil
            mainWindow?.unlock()
            showLogin()
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
        default:
            return true
        }
    }

    // MARK: - DiscordSessionDelegate

    func sessionDidBecomeReady(_ session: DiscordSession) {
        loginWindow?.close()
        loginWindow = nil
        if mainWindow == nil {
            let main = MainWindowController(session: session)
            mainWindow = main
            main.showWindow(nil)
            updates?.window = main
        }
        mainWindow?.reload()
    }

    func session(_ session: DiscordSession, didChangeState state: GatewayClient.State) {
        switch state {
        case .authenticationFailed:
            session.disconnect()
            self.session = nil
            Keychain.deleteToken()
            showLogin(message: "Your session ended. Scan a new code to log back in.")
        case .closed(let code):
            // Discord ended the session for good; reconnecting can't fix it.
            session.disconnect()
            self.session = nil
            Keychain.deleteToken()
            showLogin(message: "Discord ended the session (code \(code)). Scan a new code to log back in.")
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

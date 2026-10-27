import AppKit
import DuhcordCore
import UserNotifications

@main
final class AppDelegate: NSObject, NSApplicationDelegate, DiscordSessionDelegate {
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

    /// Notifications need a real app bundle; running the bare binary from the terminal has none.
    private var canNotify: Bool { Bundle.main.bundleIdentifier != nil }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Settings.registerDefaults()
        NSApp.mainMenu = buildMenu()
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

    private func showLogin(error: String? = nil) {
        mainWindow?.close()
        mainWindow = nil
        let login = LoginWindowController { [weak self] token in
            Keychain.saveToken(token)
            self?.start(token: token)
        }
        loginWindow = login
        login.showWindow(nil)
        if let error { login.show(error: error) }
    }

    private func start(token: String) {
        session?.disconnect()
        let session = DiscordSession(token: token)
        session.delegate = self
        session.isActive = NSApp.isActive
        self.session = session
        // Show something while READY arrives, which can take a few seconds.
        if mainWindow == nil, loginWindow == nil { showLogin() }
        loginWindow?.setBusy(true)
        session.connect()
    }

    @objc private func showSettings(_ sender: Any?) {
        let controller = settingsWindow ?? SettingsWindowController { [weak self] in self?.logOut(nil) }
        settingsWindow = controller
        controller.show(accountName: session?.store.me?.displayName)
    }

    @objc private func logOut(_ sender: Any?) {
        session?.disconnect()
        session = nil
        Keychain.deleteToken()
        NSApp.dockTile.badgeLabel = nil
        showLogin()
    }

    // MARK: - DiscordSessionDelegate

    func sessionDidBecomeReady(_ session: DiscordSession) {
        loginWindow?.close()
        loginWindow = nil
        if mainWindow == nil {
            let main = MainWindowController(session: session)
            mainWindow = main
            main.showWindow(nil)
            if canNotify {
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
            }
        }
        mainWindow?.reload()
    }

    func session(_ session: DiscordSession, didChangeState state: GatewayClient.State) {
        switch state {
        case .authenticationFailed:
            session.disconnect()
            self.session = nil
            Keychain.deleteToken()
            showLogin(error: "Discord rejected that token. Paste a fresh one.")
        case .closed(let code):
            mainWindow?.setStatus("Disconnected (code \(code))")
            loginWindow?.show(error: "Discord closed the connection (code \(code)).")
        case .reconnecting:
            mainWindow?.setStatus("Reconnecting…")
        case .connected:
            mainWindow?.setStatus(nil)
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
        content.body = message.content.isEmpty ? "Sent an attachment" : message.content
        content.sound = Settings.notificationSound ? .default : nil
        let request = UNNotificationRequest(identifier: message.id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Menu

    private func buildMenu() -> NSMenu {
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Duhcord", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings…", action: #selector(showSettings(_:)), keyEquivalent: ",")
        appMenu.addItem(withTitle: "Log Out", action: #selector(logOut(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Duhcord", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Duhcord", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(submenu: appMenu, title: "Duhcord")

        // Without an Edit menu, ⌘C/⌘V don't work in text fields.
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(submenu: edit, title: "Edit")

        let go = NSMenu(title: "Go")
        go.addItem(withTitle: "Jump to Channel…", action: #selector(MainWindowController.showQuickSwitcher(_:)), keyEquivalent: "k")
        let prev = go.addItem(withTitle: "Previous Channel", action: #selector(MainWindowController.selectPreviousChannel(_:)), keyEquivalent: String(Character(UnicodeScalar(NSUpArrowFunctionKey)!)))
        prev.keyEquivalentModifierMask = [.option]
        let next = go.addItem(withTitle: "Next Channel", action: #selector(MainWindowController.selectNextChannel(_:)), keyEquivalent: String(Character(UnicodeScalar(NSDownArrowFunctionKey)!)))
        next.keyEquivalentModifierMask = [.option]
        let unread = go.addItem(withTitle: "Next Unread Channel", action: #selector(MainWindowController.selectNextUnread(_:)), keyEquivalent: String(Character(UnicodeScalar(NSDownArrowFunctionKey)!)))
        unread.keyEquivalentModifierMask = [.option, .shift]
        main.addItem(submenu: go, title: "Go")

        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        main.addItem(submenu: window, title: "Window")
        NSApp.windowsMenu = window

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

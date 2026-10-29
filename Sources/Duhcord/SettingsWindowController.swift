import AppKit
import DuhcordCore

/// ⌘, — one small window with every option.
final class SettingsWindowController: NSWindowController {
    /// Log out of the account with this ID (confirmed by the caller).
    var onLogOut: ((Snowflake) -> Void)?
    var onSwitch: ((Snowflake) -> Void)?
    var onAddAccount: (() -> Void)?
    /// "Limit what Discord collects" was switched on: apply it to the account now.
    var onLimitData: (() -> Void)?
    /// One row per saved account, rebuilt each time the window opens.
    private let accountList = NSStackView()
    private let notifications = NSPopUpButton()
    private let sound = NSButton(checkboxWithTitle: "Play a sound", target: nil, action: nil)
    private let dockBadge = NSButton(checkboxWithTitle: "Show mention count on the Dock icon", target: nil, action: nil)
    private let compact = NSButton(checkboxWithTitle: "Compact layout", target: nil, action: nil)
    private let mediaPreviews = NSPopUpButton()
    private let sendTyping = NSButton(checkboxWithTitle: "Show when I'm typing", target: nil, action: nil)
    private let limitData = NSButton(checkboxWithTitle: "Limit what Discord collects", target: nil, action: nil)
    private let animateGIFs = NSPopUpButton()
    private let checkForUpdates = NSButton(checkboxWithTitle: "Check for updates automatically", target: nil, action: nil)

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 440),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Settings"
        super.init(window: window)
        buildUI()
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show(accounts: [AccountStore.Account], currentID: Snowflake?) {
        accountList.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for account in accounts {
            let current = account.id == currentID
            let name = NSTextField(labelWithString: account.displayName + (current ? " (current)" : ""))
            name.font = current ? Theme.boldFont : Theme.bodyFont
            name.toolTip = "@" + account.username
            var views: [NSView] = [name]
            if !current { views.append(button("Switch") { [weak self] in self?.onSwitch?(account.id) }) }
            views.append(button("Log Out…") { [weak self] in self?.onLogOut?(account.id) })
            accountList.addArrangedSubview(stack(views))
        }
        let add = button("Add Account…") { [weak self] in self?.onAddAccount?() }
        add.isEnabled = accounts.count < AccountStore.maxAccounts
        add.toolTip = add.isEnabled ? nil : "Duhcord keeps up to \(AccountStore.maxAccounts) accounts"
        accountList.addArrangedSubview(add)
        syncFromSettings()
        // The window fits its contents, which grow with the number of accounts.
        if let window, let content = window.contentView {
            content.layoutSubtreeIfNeeded()
            window.setContentSize(content.fittingSize)
        }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    private func buildUI() {
        guard let content = window?.contentView else { return }

        notifications.addItems(withTitles: Settings.NotificationLevel.allCases.map(\.title))
        mediaPreviews.addItems(withTitles: Settings.MediaPreviews.allCases.map(\.title))
        mediaPreviews.target = self
        mediaPreviews.action = #selector(changed)
        animateGIFs.addItems(withTitles: Settings.AnimateGIFs.allCases.map(\.title))
        animateGIFs.target = self
        animateGIFs.action = #selector(changed)
        notifications.target = self
        notifications.action = #selector(changed)
        limitData.toolTip = "Turns off Discord's data use, tracking and marketing settings on your accounts: usage statistics, "
            + "personalisation, screen reader tracking, game and platform account detection, contact and phone number "
            + "matching, and marketing emails. Applied once per account; change them back in Discord's app if you like."
        [sound, dockBadge, compact, checkForUpdates, sendTyping, limitData].forEach {
            $0.target = self
            $0.action = #selector(changed)
        }

        accountList.orientation = .vertical
        accountList.alignment = .leading
        accountList.spacing = Theme.Spacing.tight

        let grid = NSGridView(views: [
            [label("Accounts:"), accountList],
            [label("Notifications:"), notifications],
            [NSGridCell.emptyContentView, sound],
            [NSGridCell.emptyContentView, dockBadge],
            [label("Layout:"), compact],
            [label("Images:"), mediaPreviews],
            [label("Animate GIFs:"), animateGIFs],
            [label("Privacy:"), limitData],
            [NSGridCell.emptyContentView, sendTyping],
            [label("Updates:"), checkForUpdates],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.rowSpacing = Theme.Spacing.related
        grid.columnSpacing = Theme.Spacing.related
        // Groups: account, notifications, appearance and media, privacy and updates.
        grid.row(at: 1).topPadding = Theme.Spacing.group
        grid.row(at: 4).topPadding = Theme.Spacing.group
        grid.row(at: 7).topPadding = Theme.Spacing.group
        grid.row(at: 9).topPadding = Theme.Spacing.group
        grid.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: Theme.Spacing.edge),
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: Theme.Spacing.edge),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -Theme.Spacing.edge),
            grid.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -Theme.Spacing.edge),
        ])
    }

    private func label(_ text: String) -> NSTextField { NSTextField(labelWithString: text) }

    private func stack(_ views: [NSView]) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = .horizontal
        s.spacing = 12
        return s
    }

    private func syncFromSettings() {
        notifications.selectItem(at: Settings.notifications.rawValue)
        sound.state = Settings.notificationSound ? .on : .off
        dockBadge.state = Settings.dockBadge ? .on : .off
        compact.state = Settings.compactLayout ? .on : .off
        checkForUpdates.state = Settings.checkForUpdates ? .on : .off
        mediaPreviews.selectItem(at: Settings.mediaPreviews.rawValue)
        sendTyping.state = Settings.sendTypingIndicator ? .on : .off
        limitData.state = Settings.limitDiscordData ? .on : .off
        animateGIFs.selectItem(at: Settings.animateGIFs.rawValue)
        sound.isEnabled = Settings.notifications != .off
    }

    @objc private func changed() {
        Settings.notifications = Settings.NotificationLevel(rawValue: notifications.indexOfSelectedItem) ?? .directMessagesAndMentions
        Settings.notificationSound = sound.state == .on
        Settings.dockBadge = dockBadge.state == .on
        Settings.compactLayout = compact.state == .on
        Settings.checkForUpdates = checkForUpdates.state == .on
        Settings.mediaPreviews = Settings.MediaPreviews(rawValue: mediaPreviews.indexOfSelectedItem) ?? .always
        Settings.sendTypingIndicator = sendTyping.state == .on
        let limitWasOn = Settings.limitDiscordData
        Settings.limitDiscordData = limitData.state == .on
        if Settings.limitDiscordData, !limitWasOn { onLimitData?() }
        Settings.animateGIFs = Settings.AnimateGIFs(rawValue: animateGIFs.indexOfSelectedItem) ?? .onHover
        sound.isEnabled = Settings.notifications != .off
    }

    private func button(_ title: String, action: @escaping () -> Void) -> NSButton {
        let button = ClosureButton(title: title, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .small
        return button
    }
}

/// A button that runs a closure.
private final class ClosureButton: NSButton {
    private var handler: (() -> Void)?

    convenience init(title: String, action: @escaping () -> Void) {
        self.init(title: title, target: nil, action: nil)
        handler = action
        target = self
        self.action = #selector(run)
    }

    @objc private func run() { handler?() }
}

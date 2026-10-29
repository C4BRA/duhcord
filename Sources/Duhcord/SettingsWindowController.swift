import AppKit
import DuhcordCore

/// ⌘, — one small window with every option.
@MainActor
final class SettingsWindowController: NSWindowController {
    /// Log out of the account with this ID (confirmed by the caller).
    var onLogOut: ((Snowflake) -> Void)?
    var onSwitch: ((Snowflake) -> Void)?
    var onAddAccount: (() -> Void)?
    /// "Limit what Discord collects" was switched on: apply it to the account now.
    var onLimitData: (() -> Void)?
    /// One row per saved account, rebuilt each time the window opens.
    private let accountList = NSStackView()
    /// This Mac, then the account's other Macs that private messages may go to.
    private let deviceList = NSStackView()
    private weak var privateChat: PrivateChatController?
    private let notifications = NSPopUpButton()
    private let sound = NSButton(checkboxWithTitle: "Play a sound", target: nil, action: nil)
    private let dockBadge = NSButton(checkboxWithTitle: "Show mention count on the Dock icon", target: nil, action: nil)
    private let compact = NSButton(checkboxWithTitle: "Compact layout", target: nil, action: nil)
    private let mediaPreviews = NSPopUpButton()
    private let sendTyping = NSButton(checkboxWithTitle: "Show when I'm typing", target: nil, action: nil)
    private let limitData = NSButton(checkboxWithTitle: "Limit what Discord collects", target: nil, action: nil)
    private let animateGIFs = NSPopUpButton()
    private let compressVideos = NSButton(checkboxWithTitle: "Compress to fit my upload limit", target: nil, action: nil)
    private let checkForUpdates = NSButton(checkboxWithTitle: "Check for updates automatically", target: nil, action: nil)
    private let tabs = SettingsTabViewController()
    private static let lastPaneKey = "Settings.lastPane"

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 440),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Settings"
        super.init(window: window)
        buildUI()
        window.center()
        NotificationCenter.default.addObserver(self, selector: #selector(devicesChanged),
                                               name: PrivateChatController.devicesDidChange, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// `premiumType`: the logged-in account's Nitro tier, for the upload limit videos are compressed to (nil when
    /// not logged in).
    func show(accounts: [AccountStore.Account], currentID: Snowflake?, privateChat: PrivateChatController?,
              premiumType: Int?? = nil) {
        self.privateChat = privateChat
        if let premiumType {
            let limit = min(UploadLimit.discordLimit(premiumType: premiumType), UploadLimit.duhcordCap)
            compressVideos.title = "Compress to fit my upload limit ("
                + ByteCountFormatter.string(fromByteCount: Int64(limit), countStyle: .binary) + ")"
        }
        rebuildDevices()
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
        fitWindow()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    /// The window fits the selected pane, which grows with the number of accounts and Macs.
    private func fitWindow() {
        guard let window, let item = tabs.tabView.selectedTabViewItem, let content = item.viewController?.view else { return }
        window.title = item.label
        content.layoutSubtreeIfNeeded()
        window.setContentSize(content.fittingSize)
    }

    @objc private func devicesChanged() {
        guard window?.isVisible == true else { return }
        rebuildDevices()
        fitWindow()
    }

    // MARK: - Private messaging Macs

    private func rebuildDevices() {
        deviceList.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard PrivateChatController.isSupported else {
            deviceList.addArrangedSubview(note("Private messaging needs macOS 14 or later."))
            return
        }
        guard let privateChat else {
            deviceList.addArrangedSubview(note("Log in to see the Macs your private messages go to."))
            return
        }
        guard let code = privateChat.thisMacCode else {
            deviceList.addArrangedSubview(note("Private messaging hasn't been used with this account on this Mac yet."))
            return
        }
        let main = NSTextField(labelWithString: "This Mac (main)")
        main.font = Theme.boldFont
        deviceList.addArrangedSubview(main)
        deviceList.addArrangedSubview(keyCode(code))

        let devices = privateChat.devices
        if devices.isEmpty {
            deviceList.addArrangedSubview(note("No other Macs. When you use private messaging with this account on another "
                                               + "Mac, it appears here for you to approve or deny."))
            return
        }
        for device in devices { deviceList.addArrangedSubview(deviceRow(device, privateChat: privateChat)) }
    }

    private func deviceRow(_ device: PrivateChatController.Device, privateChat: PrivateChatController) -> NSView {
        let added = DateFormatter.localizedString(from: device.added, dateStyle: .medium, timeStyle: .none)
        let title: String
        switch device.trust {
        case .pending: title = "Other Mac — waiting for approval"
        case .accepted: title = "Other Mac — approved"
        case .rejected: title = "Other Mac — denied"
        }
        let name = NSTextField(labelWithString: title)
        name.toolTip = "First seen \(added)"
        let code = keyCode(device.code)
        // Waiting and denied Macs are greyed out: they get none of your private messages.
        if device.trust != .accepted {
            name.textColor = .secondaryLabelColor
            code.textColor = .tertiaryLabelColor
        }
        let labels = NSStackView(views: [name, code])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 2

        var buttons: [NSView] = []
        let approve = button("Approve…") { [weak self] in self?.confirmApprove(device, privateChat: privateChat) }
        approve.isEnabled = privateChat.canApproveAnotherMac
        approve.toolTip = approve.isEnabled ? nil
            : "Up to \(PrivateChatController.maxOtherMacs) other Macs can be approved. Remove one first."
        switch device.trust {
        case .pending:
            buttons = [button("Deny…") { [weak self] in self?.confirmDeny(device, privateChat: privateChat) }, approve]
        case .accepted:
            buttons = [button("Remove…") { [weak self] in self?.confirmDeny(device, privateChat: privateChat) }]
        case .rejected:
            buttons = [approve]
        }
        let row = stack([labels] + buttons)
        row.alignment = .centerY
        return row
    }

    private func confirmApprove(_ device: PrivateChatController.Device, privateChat: PrivateChatController) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Approve this Mac?"
        alert.informativeText = "Only approve a Mac you own. Open Duhcord's Settings on it: the code under “This Mac” must be "
            + "exactly\n\n\(device.code)\n\nIt will be able to read every private message you send from now on. Discord "
            + "carries these keys, so a Mac you don't recognise could be Discord trying to read your messages.\n\n"
            + "Your safety number with everyone changes, so anyone who verified you will need to compare again."
        alert.addButton(withTitle: "Approve")
        alert.addButton(withTitle: "Cancel")
        present(alert) { privateChat.setTrust(.accepted, forDevice: device.key) }
    }

    private func confirmDeny(_ device: PrivateChatController.Device, privateChat: PrivateChatController) {
        let approved = device.trust == .accepted
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = approved ? "Remove this Mac?" : "Deny this Mac?"
        alert.informativeText = (approved ? "It will stop receiving the private messages you send. " : "It won't receive the "
            + "private messages you send. ") + "If it's really yours, it won't be able to read them, and what you send from "
            + "it is marked as not approved here. Duhcord remembers this; you can approve it again later in Settings."
            + (approved ? "\n\nYour safety number with everyone changes, so anyone who verified you will need to compare again." : "")
        alert.addButton(withTitle: approved ? "Remove" : "Deny").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        present(alert) { privateChat.setTrust(.rejected, forDevice: device.key) }
    }

    private func present(_ alert: NSAlert, onConfirm: @escaping () -> Void) {
        guard let window else { return }
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { onConfirm() }
        }
    }

    private func keyCode(_ code: String) -> NSTextField {
        let field = NSTextField(labelWithString: code)
        field.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        field.textColor = .secondaryLabelColor
        field.isSelectable = true
        field.setAccessibilityLabel("Key code " + code)
        return field
    }

    private func note(_ text: String) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        field.textColor = .secondaryLabelColor
        field.preferredMaxLayoutWidth = 300
        return field
    }

    private func buildUI() {
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
        compressVideos.toolTip = "Videos are re-encoded with the Mac's hardware encoder so they fit Discord's upload limit "
            + "for your account (10 MB without Nitro). One that already fits is sent at its own quality. Either way, its "
            + "location and other details are left out."
        [sound, dockBadge, compact, checkForUpdates, sendTyping, limitData, compressVideos].forEach {
            $0.target = self
            $0.action = #selector(changed)
        }

        accountList.orientation = .vertical
        accountList.alignment = .leading
        accountList.spacing = Theme.Spacing.tight
        deviceList.orientation = .vertical
        deviceList.alignment = .leading
        deviceList.spacing = Theme.Spacing.tight

        let general = grid([
            [label("Notifications:"), notifications],
            [NSGridCell.emptyContentView, sound],
            [NSGridCell.emptyContentView, dockBadge],
            [label("Layout:"), compact],
            [label("Images:"), mediaPreviews],
            [label("Animate GIFs:"), animateGIFs],
            [label("Videos:"), compressVideos],
        ])
        general.row(at: 3).topPadding = Theme.Spacing.group

        let accounts = grid([
            [label("Accounts:"), accountList],
        ])

        let privacy = grid([
            [label("Privacy:"), limitData],
            [NSGridCell.emptyContentView, sendTyping],
            [label("Private messages:"), deviceList],
        ])
        privacy.row(at: 2).topPadding = Theme.Spacing.group

        let updates = grid([
            [label("Updates:"), checkForUpdates],
        ])

        tabs.tabStyle = .toolbar
        tabs.selectionChanged = { [weak self] item in
            guard let self, let item else { return }
            self.window?.title = item.label
            UserDefaults.standard.set(item.identifier as? String, forKey: Self.lastPaneKey)
            self.fitWindow()
        }
        addPane("General", symbol: "gearshape", grid: general)
        addPane("Accounts", symbol: "person.2", grid: accounts)
        addPane("Privacy", symbol: "hand.raised", grid: privacy)
        addPane("Updates", symbol: "arrow.down.circle", grid: updates)
        if let remembered = UserDefaults.standard.string(forKey: Self.lastPaneKey),
           let index = tabs.tabViewItems.firstIndex(where: { $0.identifier as? String == remembered }) {
            tabs.selectedTabViewItemIndex = index
        }
        window?.contentViewController = tabs
    }

    private func grid(_ rows: [[NSView]]) -> NSGridView {
        let grid = NSGridView(views: rows)
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.rowSpacing = Theme.Spacing.related
        grid.columnSpacing = Theme.Spacing.related
        return grid
    }

    private func addPane(_ title: String, symbol: String, grid: NSGridView) {
        let content = NSView()
        grid.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: Theme.Spacing.edge),
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: Theme.Spacing.edge),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -Theme.Spacing.edge),
            grid.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -Theme.Spacing.edge),
        ])
        let controller = NSViewController()
        controller.view = content
        let item = NSTabViewItem(viewController: controller)
        item.label = title
        item.identifier = title.lowercased()
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        tabs.addTabViewItem(item)
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
        compressVideos.state = Settings.compressVideos ? .on : .off
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
        Settings.compressVideos = compressVideos.state == .on
        sound.isEnabled = Settings.notifications != .off
    }

    private func button(_ title: String, action: @escaping () -> Void) -> NSButton {
        let button = ClosureButton(title: title, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .small
        return button
    }
}

private final class SettingsTabViewController: NSTabViewController {
    var selectionChanged: ((NSTabViewItem?) -> Void)?

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        selectionChanged?(tabViewItem)
    }
}

/// A button that runs a closure.
@MainActor
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

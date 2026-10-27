import AppKit

/// ⌘, — one small window with every option.
final class SettingsWindowController: NSWindowController {
    private let onLogOut: () -> Void
    private let accountLabel = NSTextField(labelWithString: "")
    private let notifications = NSPopUpButton()
    private let sound = NSButton(checkboxWithTitle: "Play a sound", target: nil, action: nil)
    private let dockBadge = NSButton(checkboxWithTitle: "Show mention count on the Dock icon", target: nil, action: nil)
    private let textSize = NSSegmentedControl(labels: Settings.TextSize.allCases.map(\.title),
                                              trackingMode: .selectOne, target: nil, action: nil)
    private let compact = NSButton(checkboxWithTitle: "Compact message spacing", target: nil, action: nil)

    init(onLogOut: @escaping () -> Void) {
        self.onLogOut = onLogOut
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 300),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Settings"
        super.init(window: window)
        buildUI()
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show(accountName: String?) {
        accountLabel.stringValue = accountName.map { "Logged in as \($0)" } ?? "Not logged in"
        syncFromSettings()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    private func buildUI() {
        guard let content = window?.contentView else { return }

        notifications.addItems(withTitles: Settings.NotificationLevel.allCases.map(\.title))
        notifications.target = self
        notifications.action = #selector(changed)
        [sound, dockBadge, compact].forEach {
            $0.target = self
            $0.action = #selector(changed)
        }
        textSize.target = self
        textSize.action = #selector(changed)

        let logOut = NSButton(title: "Log Out", target: self, action: #selector(logOutClicked))
        logOut.bezelStyle = .rounded

        let grid = NSGridView(views: [
            [label("Account:"), stack([accountLabel, logOut])],
            [label("Notifications:"), notifications],
            [NSGridCell.emptyContentView, sound],
            [NSGridCell.emptyContentView, dockBadge],
            [label("Text size:"), textSize],
            [NSGridCell.emptyContentView, compact],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.rowSpacing = 10
        grid.columnSpacing = 8
        grid.row(at: 1).topPadding = 8
        grid.row(at: 4).topPadding = 8
        grid.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -20),
            grid.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -20),
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
        textSize.selectedSegment = Settings.textSize.rawValue
        compact.state = Settings.compactMessages ? .on : .off
        sound.isEnabled = Settings.notifications != .off
    }

    @objc private func changed() {
        Settings.notifications = Settings.NotificationLevel(rawValue: notifications.indexOfSelectedItem) ?? .directMessagesAndMentions
        Settings.notificationSound = sound.state == .on
        Settings.dockBadge = dockBadge.state == .on
        Settings.textSize = Settings.TextSize(rawValue: textSize.selectedSegment) ?? .medium
        Settings.compactMessages = compact.state == .on
        sound.isEnabled = Settings.notifications != .off
    }

    @objc private func logOutClicked() {
        close()
        onLogOut()
    }
}

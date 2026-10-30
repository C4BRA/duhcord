import AppKit
import DuhcordCore
import DuhcordVoiceKit

/// The signed-in account's status. Discord keeps it on the account, so a phone can change it too: we read it once
/// when the account loads, and write it only when the person picks a new one here.
@MainActor
final class OwnStatus {
    enum Choice: String, CaseIterable {
        case online, idle, dnd, invisible

        var title: String {
            switch self {
            case .online: return "Online"
            case .idle: return "Idle"
            case .dnd: return "Do Not Disturb"
            case .invisible: return "Invisible"
            }
        }

        /// What the status dot uses. Invisible is shown to other people as offline.
        var presence: Presence.Status {
            switch self {
            case .online: return .online
            case .idle: return .idle
            case .dnd: return .dnd
            case .invisible: return .offline
            }
        }

        init(discord value: String) {
            self = Choice(rawValue: value) ?? .online
        }
    }

    private(set) var choice: Choice = .online
    var onChange: (() -> Void)?

    private weak var session: DiscordSession?
    /// Bumps on every read or write, so a slow reply can't overwrite a newer choice.
    private var epoch = 0
    private var fetched = false

    init(session: DiscordSession) {
        self.session = session
    }

    /// One read per account. A failure can be tried again the next time the window reloads.
    func refresh() {
        guard !fetched, let session else { return }
        fetched = true
        epoch += 1
        let token = epoch
        Task { @MainActor [weak self] in
            do {
                let raw = try await session.rest.accountStatus()
                guard let self, token == self.epoch else { return }
                let next = Choice(discord: raw)
                guard next != self.choice else { return }
                self.choice = next
                self.onChange?()
            } catch {
                if let self, token == self.epoch { self.fetched = false }
            }
        }
    }

    func update(_ choice: Choice) {
        guard choice != self.choice else { return }
        let previous = self.choice
        self.choice = choice
        epoch += 1
        let token = epoch
        onChange?()
        guard let session else { return }
        Task { @MainActor [weak self] in
            do {
                try await session.rest.setAccountStatus(choice.rawValue)
            } catch {
                guard let self, token == self.epoch else { return }
                self.choice = previous
                self.onChange?()
            }
        }
    }
}

/// Avatar, name and status, plus mute, deafen and settings. Sits under the channel list the whole time the
/// window is open. Mute and deafen remember their state between calls; the microphone is only opened in a call.
@MainActor
final class AccountBar: NSView {
    var onShowAccount: ((NSView) -> Void)?
    var onMute: (() -> Void)?
    var onDeafen: (() -> Void)?
    var onInputOptions: ((NSView) -> Void)?
    var onOutputOptions: ((NSView) -> Void)?

    private let avatar = RemoteImageView()
    private let nameLabel = NSTextField(labelWithString: "Account")
    private let statusDot = NSView()
    private let statusLabel = NSTextField(labelWithString: OwnStatus.Choice.online.title)
    private let identityButton = NSButton(title: "", target: nil, action: nil)
    private let muteButton = AccountBar.iconButton("mic.fill", label: "Mute")
    private let inputButton = AccountBar.iconButton("chevron.down", label: "Input options", pointSize: 9)
    private let deafenButton = AccountBar.iconButton("headphones", label: "Deafen")
    private let outputButton = AccountBar.iconButton("chevron.down", label: "Output options", pointSize: 9)
    private let settingsButton = AccountBar.iconButton("gearshape", label: "Settings")
    private var shownUserID: Snowflake?
    private var shownAvatar: String?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        avatar.cornerRadius = Theme.IconSize.accountAvatar / 2
        avatar.setAccessibilityElement(false)
        nameLabel.font = Theme.boldFont
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.setAccessibilityElement(false)
        statusLabel.font = Theme.smallFont
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setAccessibilityElement(false)
        statusDot.wantsLayer = true
        statusDot.layer?.cornerRadius = 4
        statusLabel.textColor = ProfileText.statusColor(.online)
        identityButton.target = self
        identityButton.action = #selector(showAccount)
        identityButton.bezelStyle = .recessed
        identityButton.showsBorderOnlyWhileMouseInside = true
        identityButton.setAccessibilityLabel("Account, \(OwnStatus.Choice.online.title)")
        muteButton.target = self
        muteButton.action = #selector(mute)
        inputButton.target = self
        inputButton.action = #selector(inputOptions)
        deafenButton.target = self
        deafenButton.action = #selector(deafen)
        outputButton.target = self
        outputButton.action = #selector(outputOptions)
        settingsButton.target = self
        settingsButton.action = #selector(showSettings)

        let divider = NSBox()
        divider.boxType = .separator
        let views: [NSView] = [divider, avatar, nameLabel, statusDot, statusLabel, identityButton,
                               muteButton, inputButton, deafenButton, outputButton, settingsButton]
        views.forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }
        // The button sits behind the picture and labels so its hover border doesn't cover them. Clicks on those
        // still land on the button.
        addSubview(identityButton, positioned: .below, relativeTo: avatar)
        let side = Theme.IconSize.accountAvatar
        NSLayoutConstraint.activate([
            divider.topAnchor.constraint(equalTo: topAnchor),
            divider.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Spacing.group),
            divider.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.Spacing.group),

            avatar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Spacing.group),
            avatar.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: Theme.Spacing.related),
            avatar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Theme.Spacing.related),
            avatar.widthAnchor.constraint(equalToConstant: side),
            avatar.heightAnchor.constraint(equalToConstant: side),

            nameLabel.leadingAnchor.constraint(equalTo: avatar.trailingAnchor, constant: Theme.Spacing.related),
            nameLabel.topAnchor.constraint(equalTo: avatar.topAnchor),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: muteButton.leadingAnchor, constant: -Theme.Spacing.related),
            statusDot.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            statusDot.centerYAnchor.constraint(equalTo: statusLabel.centerYAnchor),
            statusDot.widthAnchor.constraint(equalToConstant: 8),
            statusDot.heightAnchor.constraint(equalToConstant: 8),
            statusLabel.leadingAnchor.constraint(equalTo: statusDot.trailingAnchor, constant: Theme.Spacing.tight),
            statusLabel.bottomAnchor.constraint(equalTo: avatar.bottomAnchor),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: muteButton.leadingAnchor, constant: -Theme.Spacing.related),

            identityButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Spacing.tight),
            identityButton.trailingAnchor.constraint(equalTo: muteButton.leadingAnchor, constant: -Theme.Spacing.tight),
            identityButton.topAnchor.constraint(equalTo: divider.bottomAnchor),
            identityButton.bottomAnchor.constraint(equalTo: bottomAnchor),

            settingsButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.Spacing.related),
            outputButton.trailingAnchor.constraint(equalTo: settingsButton.leadingAnchor, constant: -Theme.Spacing.tight),
            deafenButton.trailingAnchor.constraint(equalTo: outputButton.leadingAnchor),
            inputButton.trailingAnchor.constraint(equalTo: deafenButton.leadingAnchor, constant: -Theme.Spacing.related),
            muteButton.trailingAnchor.constraint(equalTo: inputButton.leadingAnchor),
        ])
        // The channel list can be 200pt wide, so the five controls stay narrow enough that the name still fits.
        for button in [muteButton, deafenButton, settingsButton] {
            NSLayoutConstraint.activate([
                button.centerYAnchor.constraint(equalTo: avatar.centerYAnchor),
                button.widthAnchor.constraint(equalToConstant: 24),
                button.heightAnchor.constraint(equalToConstant: 24),
            ])
        }
        for button in [inputButton, outputButton] {
            NSLayoutConstraint.activate([
                button.centerYAnchor.constraint(equalTo: avatar.centerYAnchor),
                button.widthAnchor.constraint(equalToConstant: 20),
                button.heightAnchor.constraint(equalToConstant: 24),
            ])
        }
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        updateAppearance()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        if hit === avatar || hit === nameLabel || hit === statusLabel || hit === statusDot { return identityButton }
        return hit
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }

    /// The picture and the status line. Mute is separate, so a call starting doesn't reload the picture.
    func update(user: User?, choice: OwnStatus.Choice) {
        let name = user?.displayName ?? "Account"
        nameLabel.stringValue = name
        nameLabel.toolTip = name
        statusLabel.stringValue = choice.title
        statusLabel.textColor = ProfileText.statusColor(choice.presence)
        statusDot.layer?.backgroundColor = ProfileText.statusColor(choice.presence).cgColor
        statusDot.toolTip = choice.title
        identityButton.setAccessibilityLabel("\(name), \(choice.title)")
        identityButton.toolTip = "\(name), \(choice.title)"
        let avatarChanged = user?.id != shownUserID || user?.avatar != shownAvatar
        shownUserID = user?.id
        shownAvatar = user?.avatar
        guard avatarChanged else { return }
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let side = Theme.IconSize.accountAvatar
        if let user {
            avatar.setImage(MediaRequest.avatarURL(for: user, pixels: Int(side * scale)),
                            pointSize: NSSize(width: side, height: side))
        } else {
            avatar.setImage(nil, pointSize: .zero)
        }
    }

    func updateAudio(muted: Bool, deafened: Bool, serverMuted: Bool, serverDeafened: Bool) {
        let micOff = muted || deafened || serverMuted || serverDeafened
        let soundOff = deafened || serverDeafened
        muteButton.image = Self.symbol(micOff ? "mic.slash.fill" : "mic.fill", micOff ? "Unmute" : "Mute")
        muteButton.contentTintColor = micOff ? .systemRed : .secondaryLabelColor
        deafenButton.image = Self.symbol(soundOff ? "speaker.slash.fill" : "headphones", soundOff ? "Undeafen" : "Deafen")
        deafenButton.contentTintColor = soundOff ? .systemRed : .secondaryLabelColor
        if serverDeafened {
            muteButton.toolTip = "Muted by a moderator"
            deafenButton.toolTip = "Deafened by a moderator"
        } else if serverMuted {
            muteButton.toolTip = "Muted by a moderator"
            deafenButton.toolTip = deafened ? "Undeafen" : "Deafen"
        } else {
            muteButton.toolTip = micOff ? "Unmute" : "Mute"
            deafenButton.toolTip = soundOff ? "Undeafen" : "Deafen"
        }
        muteButton.setAccessibilityLabel(muteButton.toolTip)
        deafenButton.setAccessibilityLabel(deafenButton.toolTip)
    }

    private func updateAppearance() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            avatar.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
            statusDot.layer?.borderColor = NSColor.windowBackgroundColor.cgColor
            statusDot.layer?.borderWidth = 1.5
        }
    }

    @objc private func showAccount() { onShowAccount?(identityButton) }
    @objc private func mute() { onMute?() }
    @objc private func deafen() { onDeafen?() }
    @objc private func inputOptions() { onInputOptions?(inputButton) }
    @objc private func outputOptions() { onOutputOptions?(outputButton) }

    @objc private func showSettings(_ sender: NSButton) {
        NSApp.sendAction(#selector(AppDelegate.showSettings(_:)), to: nil, from: sender)
    }

    private static func symbol(_ name: String, _ label: String, pointSize: CGFloat = 13) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: label)?
            .withSymbolConfiguration(.init(pointSize: pointSize, weight: .medium))
    }

    private static func iconButton(_ symbolName: String, label: String, pointSize: CGFloat = 13) -> NSButton {
        let button = NSButton(title: "", target: nil, action: nil)
        button.bezelStyle = .recessed
        button.showsBorderOnlyWhileMouseInside = true
        button.imagePosition = .imageOnly
        button.image = symbol(symbolName, label, pointSize: pointSize)
        button.toolTip = label
        button.setAccessibilityLabel(label)
        return button
    }
}

/// Input or output device, and that side's volume. Opened from the account bar. Devices are read when it appears.
@MainActor
final class AudioOptionsViewController: NSViewController {
    private let input: Bool
    private let devices = NSPopUpButton()
    private let volume = NSSlider(value: 1, minValue: 0, maxValue: 1, target: nil, action: nil)
    private var suppress = false

    init(input: Bool) {
        self.input = input
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        let title = NSTextField(labelWithString: input ? "Input" : "Output")
        title.font = Theme.smallFont.withWeight(.semibold)
        title.textColor = .secondaryLabelColor
        devices.target = self
        devices.action = #selector(deviceChanged)
        devices.setAccessibilityLabel(input ? "Input device" : "Output device")
        volume.target = self
        volume.action = #selector(volumeChanged)
        volume.isContinuous = true
        volume.setAccessibilityLabel(input ? "Input volume" : "Output volume")

        let stack = NSStackView(views: [title, devices, volume])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Theme.Spacing.related
        stack.edgeInsets = NSEdgeInsets(top: Theme.Spacing.group, left: Theme.Spacing.group,
                                        bottom: Theme.Spacing.group, right: Theme.Spacing.group)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            devices.widthAnchor.constraint(equalToConstant: 240),
            volume.widthAnchor.constraint(equalTo: devices.widthAnchor),
        ])
        view = container
        reloadDevices()
        view.layoutSubtreeIfNeeded()
        preferredContentSize = view.fittingSize
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        reloadDevices()
    }

    private func reloadDevices() {
        suppress = true
        devices.removeAllItems()
        devices.addItem(withTitle: "System Default")
        devices.item(at: 0)?.representedObject = ""
        let selected = input ? Settings.inputDeviceUID : Settings.outputDeviceUID
        var matched = selected == nil
        for device in AudioDevices.devices(input: input) {
            devices.addItem(withTitle: device.name)
            devices.lastItem?.representedObject = device.uid
            if device.uid == selected {
                devices.select(devices.lastItem)
                matched = true
            }
        }
        if !matched, let selected {
            devices.addItem(withTitle: "Unavailable Device")
            devices.lastItem?.representedObject = selected
            devices.select(devices.lastItem)
        } else if selected == nil {
            devices.selectItem(at: 0)
        }
        volume.doubleValue = input ? Settings.inputVolume : Settings.outputVolume
        suppress = false
    }

    @objc private func deviceChanged() {
        guard !suppress else { return }
        let raw = devices.selectedItem?.representedObject as? String
        let uid = (raw?.isEmpty == false) ? raw : nil
        if input { Settings.inputDeviceUID = uid } else { Settings.outputDeviceUID = uid }
    }

    @objc private func volumeChanged() {
        guard !suppress else { return }
        if input { Settings.inputVolume = volume.doubleValue } else { Settings.outputVolume = volume.doubleValue }
    }
}

/// Our own profile: status, badges, switching accounts and copying the user ID. There is no profile editor here.
@MainActor
final class AccountCardViewController: NSViewController {
    var onOpenProfile: (() -> Void)?

    private let session: DiscordSession
    private let status: OwnStatus
    private unowned let profiles: ProfileController
    private let header = ProfileHeaderView(avatarSize: 80, bannerHeight: 105)
    private let stack = NSStackView()
    private let statusPopup = NSPopUpButton()
    private var profile: UserProfile?
    private var suppress = false
    private static let width: CGFloat = 300

    init(session: DiscordSession, status: OwnStatus, profiles: ProfileController) {
        self.session = session
        self.status = status
        self.profiles = profiles
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        header.onAvatarClick = { [weak self] in self?.onOpenProfile?() }
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Theme.Spacing.related
        stack.edgeInsets = NSEdgeInsets(top: Theme.Spacing.group, left: Theme.Spacing.edge,
                                        bottom: Theme.Spacing.edge, right: Theme.Spacing.edge)
        for choice in OwnStatus.Choice.allCases {
            statusPopup.addItem(withTitle: choice.title)
            statusPopup.lastItem?.representedObject = choice.rawValue
        }
        statusPopup.target = self
        statusPopup.action = #selector(statusChosen)
        statusPopup.setAccessibilityLabel("Status")
        statusPopup.translatesAutoresizingMaskIntoConstraints = false
        statusPopup.widthAnchor.constraint(equalToConstant: Self.width - 2 * Theme.Spacing.edge).isActive = true

        let document = CardView()
        document.onAppearance = { [weak self] in self?.refreshStatusDots() }
        header.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(header)
        document.addSubview(stack)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: document.topAnchor),
            header.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            header.widthAnchor.constraint(equalToConstant: Self.width),
            stack.topAnchor.constraint(equalTo: header.bottomAnchor, constant: Theme.Spacing.group),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])
        view = document
        refreshStatusDots()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        render()
        guard let id = session.store.me?.id else { return }
        profiles.loadProfile(userID: id, guildID: nil) { [weak self] result in
            if case .success(let profile) = result { self?.profile = profile }
            self?.render()
        }
    }

    func render() {
        let user = session.store.me
        let choice = status.choice
        let scale = view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let presence = user.flatMap { session.store.presence(of: $0.id) }
        header.configure(
            bannerURL: profile.flatMap { MediaRequest.bannerURL(for: $0, guildID: nil, pixels: Int(Self.width * scale)) },
            accentColor: profile?.accentColor,
            avatarURL: profile.flatMap { MediaRequest.profileAvatarURL(for: $0, guildID: nil, pixels: Int(80 * scale)) }
                ?? user.flatMap { MediaRequest.avatarURL(for: $0, pixels: Int(80 * scale)) },
            status: choice.presence,
            avatarHint: "Show Profile",
            statusTitle: choice.title)

        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let contentWidth = Self.width - 2 * Theme.Spacing.edge
        var rows: [NSView] = []
        if let user {
            rows += ProfileParts.status(presence)
            rows += ProfileParts.identity(user: user, profile: profile, nameFont: Theme.titleFont.withWeight(.bold))
        }
        rows.append(statusPopup)
        rows.append(actionButton("Switch Accounts", action: #selector(switchAccounts)))
        let copy = actionButton("Copy User ID", action: #selector(copyID(_:)))
        copy.isEnabled = user?.id.isEmpty == false
        rows.append(copy)
        suppress = true
        if let item = statusPopup.itemArray.first(where: { $0.representedObject as? String == choice.rawValue }) {
            statusPopup.select(item)
        }
        suppress = false
        for row in rows {
            stack.addArrangedSubview(row)
            if row is NSTextField {
                row.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
            }
        }
        view.layoutSubtreeIfNeeded()
        preferredContentSize = view.fittingSize
    }

    private func actionButton(_ title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .push
        button.controlSize = .large
        button.setAccessibilityLabel(title)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: Self.width - 2 * Theme.Spacing.edge).isActive = true
        return button
    }

    private func refreshStatusDots() {
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            for item in statusPopup.itemArray {
                guard let raw = item.representedObject as? String, let choice = OwnStatus.Choice(rawValue: raw) else { continue }
                item.image = Self.dot(ProfileText.statusColor(choice.presence))
            }
        }
    }

    private static func dot(_ color: NSColor) -> NSImage {
        let side: CGFloat = 10
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }

    @objc private func statusChosen() {
        guard !suppress, let raw = statusPopup.selectedItem?.representedObject as? String,
              let choice = OwnStatus.Choice(rawValue: raw) else { return }
        status.update(choice)
    }

    @objc private func switchAccounts(_ sender: NSButton) {
        let menu = NSMenu()
        menu.delegate = NSApp.delegate as? NSMenuDelegate
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height), in: sender)
    }

    @objc private func copyID(_ sender: NSButton) {
        guard let id = session.store.me?.id, !id.isEmpty else { return }
        Pasteboard.copy(id)
        sender.title = "Copied"
        sender.setAccessibilityLabel("Copied user ID")
    }
}

/// The account card's root view, so status dots are redrawn when the appearance changes.
@MainActor
private final class CardView: NSView {
    var onAppearance: (() -> Void)?

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearance?()
    }
}

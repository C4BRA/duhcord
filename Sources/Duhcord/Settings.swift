import AppKit

/// User preferences, stored in UserDefaults. Posts `Settings.didChange` when one actually changes, with the
/// changed key under `keyInfo` in userInfo.
enum Settings {
    static let didChange = Notification.Name("DuhcordSettingsDidChange")
    static let keyInfo = "key"

    enum NotificationLevel: Int, CaseIterable {
        case directMessagesAndMentions = 0
        case mentionsOnly = 1
        case off = 2

        var title: String {
            switch self {
            case .directMessagesAndMentions: return "DMs and mentions"
            case .mentionsOnly: return "Mentions only"
            case .off: return "Off"
            }
        }
    }

    enum MediaPreviews: Int, CaseIterable {
        case always = 0
        case onClick = 1
        case off = 2

        var title: String {
            switch self {
            case .always: return "Always"
            case .onClick: return "Click to load"
            case .off: return "Off"
            }
        }
    }

    enum AnimateGIFs: Int, CaseIterable {
        case onHover = 0
        case whenVisible = 1
        case never = 2

        var title: String {
            switch self {
            case .onHover: return "On hover"
            case .whenVisible: return "When visible"
            case .never: return "Never"
            }
        }
    }

    private static let defaults = UserDefaults.standard

    enum Key {
        static let notifications = "notifications"
        static let sound = "notificationSound"
        static let dockBadge = "dockBadge"
        static let compact = "compactMessages"
        static let checkForUpdates = "checkForUpdates"
        static let mediaPreviews = "mediaPreviews"
        static let animateGIFs = "animateGIFs"
        static let sendTyping = "sendTypingIndicator"
    }

    static func registerDefaults() {
        defaults.register(defaults: [
            Key.notifications: NotificationLevel.directMessagesAndMentions.rawValue,
            Key.sound: true,
            Key.dockBadge: true,
            Key.compact: false,
            Key.checkForUpdates: true,
            Key.mediaPreviews: MediaPreviews.always.rawValue,
            Key.animateGIFs: AnimateGIFs.onHover.rawValue,
            Key.sendTyping: true,
        ])
    }

    static var notifications: NotificationLevel {
        get { NotificationLevel(rawValue: defaults.integer(forKey: Key.notifications)) ?? .directMessagesAndMentions }
        set { set(newValue.rawValue, for: Key.notifications) }
    }

    static var notificationSound: Bool {
        get { defaults.bool(forKey: Key.sound) }
        set { set(newValue, for: Key.sound) }
    }

    static var dockBadge: Bool {
        get { defaults.bool(forKey: Key.dockBadge) }
        set { set(newValue, for: Key.dockBadge) }
    }

    /// Tighter spacing everywhere: messages, and small sidebar and list rows.
    static var compactLayout: Bool {
        get { defaults.bool(forKey: Key.compact) }
        set { set(newValue, for: Key.compact) }
    }

    /// Images in link previews and attachments.
    static var mediaPreviews: MediaPreviews {
        get { MediaPreviews(rawValue: defaults.integer(forKey: Key.mediaPreviews)) ?? .always }
        set { set(newValue.rawValue, for: Key.mediaPreviews) }
    }

    /// When GIFs move. Videos always wait for a click.
    static var animateGIFs: AnimateGIFs {
        get { AnimateGIFs(rawValue: defaults.integer(forKey: Key.animateGIFs)) ?? .onHover }
        set { set(newValue.rawValue, for: Key.animateGIFs) }
    }

    /// Let others see "… is typing" while you write a message.
    static var sendTypingIndicator: Bool {
        get { defaults.bool(forKey: Key.sendTyping) }
        set { set(newValue, for: Key.sendTyping) }
    }

    /// Check GitHub for a new release at launch and once a day.
    static var checkForUpdates: Bool {
        get { defaults.bool(forKey: Key.checkForUpdates) }
        set { set(newValue, for: Key.checkForUpdates) }
    }

    /// Settings that change how messages are laid out.
    static let messageLayoutKeys: Set<String> = [Key.compact, Key.mediaPreviews, Key.animateGIFs]

    private static func set<T: Equatable>(_ value: T, for key: String) {
        guard defaults.object(forKey: key) as? T != value else { return }
        defaults.set(value, forKey: key)
        NotificationCenter.default.post(name: didChange, object: nil, userInfo: [keyInfo: key])
    }
}

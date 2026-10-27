import AppKit

/// User preferences, stored in UserDefaults. Posts `Settings.didChange` whenever one changes.
enum Settings {
    static let didChange = Notification.Name("DuhcordSettingsDidChange")

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

    enum TextSize: Int, CaseIterable {
        case small = 0
        case medium = 1
        case large = 2

        var title: String {
            switch self {
            case .small: return "Small"
            case .medium: return "Medium"
            case .large: return "Large"
            }
        }

        var pointSize: CGFloat {
            switch self {
            case .small: return 12
            case .medium: return 13
            case .large: return 15
            }
        }
    }

    private static let defaults = UserDefaults.standard

    private enum Key {
        static let notifications = "notifications"
        static let sound = "notificationSound"
        static let dockBadge = "dockBadge"
        static let textSize = "textSize"
        static let compact = "compactMessages"
    }

    static func registerDefaults() {
        defaults.register(defaults: [
            Key.notifications: NotificationLevel.directMessagesAndMentions.rawValue,
            Key.sound: true,
            Key.dockBadge: true,
            Key.textSize: TextSize.medium.rawValue,
            Key.compact: false,
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

    static var textSize: TextSize {
        get { TextSize(rawValue: defaults.integer(forKey: Key.textSize)) ?? .medium }
        set { set(newValue.rawValue, for: Key.textSize) }
    }

    /// Tighter spacing between messages.
    static var compactMessages: Bool {
        get { defaults.bool(forKey: Key.compact) }
        set { set(newValue, for: Key.compact) }
    }

    private static func set(_ value: Any, for key: String) {
        defaults.set(value, forKey: key)
        NotificationCenter.default.post(name: didChange, object: nil)
    }
}

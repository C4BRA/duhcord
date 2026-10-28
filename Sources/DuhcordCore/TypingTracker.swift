import Foundation

/// Who is typing in the channel on screen, for the typing tabs.
///
/// A tab is raised while someone types. It lowers halfway when their message arrives or after 10 seconds without
/// a typing event (they stopped without sending), and goes away a minute after lowering. Pure logic with an
/// injected clock, so it's unit tested; the UI schedules one timer for `nextDeadline`.
public final class TypingTracker {
    public struct Entry: Equatable {
        public let userID: Snowflake
        public var user: User
        public var name: String
        public var raised: Bool
        public var lastTyping: Date
        public var loweredAt: Date?
    }

    public static let typingTimeout: TimeInterval = 10
    public static let linger: TimeInterval = 60

    public private(set) var channelID: Snowflake?
    /// In order of first appearance, so tabs don't shuffle around.
    public private(set) var entries: [Entry] = []

    public init() {}

    /// Switching channels clears the tabs; typing events only arrive for the channel on screen anyway.
    @discardableResult
    public func focus(_ channelID: Snowflake?) -> Bool {
        guard channelID != self.channelID else { return false }
        self.channelID = channelID
        let hadEntries = !entries.isEmpty
        entries = []
        return hadEntries
    }

    @discardableResult
    public func typing(_ user: User, name: String, in channel: Snowflake, at now: Date) -> Bool {
        guard channel == channelID else { return false }
        if let i = entries.firstIndex(where: { $0.userID == user.id }) {
            let wasRaised = entries[i].raised
            entries[i].raised = true
            entries[i].lastTyping = now
            entries[i].loweredAt = nil
            entries[i].user = user
            entries[i].name = name
            return !wasRaised
        }
        entries.append(Entry(userID: user.id, user: user, name: name, raised: true, lastTyping: now, loweredAt: nil))
        return true
    }

    /// Their message arrived: they finished typing.
    @discardableResult
    public func messageArrived(from userID: Snowflake, in channel: Snowflake, at now: Date) -> Bool {
        guard channel == channelID, let i = entries.firstIndex(where: { $0.userID == userID }), entries[i].raised else { return false }
        entries[i].raised = false
        entries[i].loweredAt = now
        return true
    }

    /// Lowers people who stopped typing and removes tabs that have lingered a minute. Returns whether anything changed.
    @discardableResult
    public func tick(at now: Date) -> Bool {
        var changed = false
        for i in entries.indices where entries[i].raised && now.timeIntervalSince(entries[i].lastTyping) >= Self.typingTimeout {
            entries[i].raised = false
            entries[i].loweredAt = now
            changed = true
        }
        let before = entries.count
        entries.removeAll { entry in
            guard let lowered = entry.loweredAt else { return false }
            return now.timeIntervalSince(lowered) >= Self.linger
        }
        return changed || entries.count != before
    }

    /// When `tick` next has something to do, or nil when there are no tabs.
    public var nextDeadline: Date? {
        entries.map { $0.raised ? $0.lastTyping.addingTimeInterval(Self.typingTimeout) : ($0.loweredAt ?? $0.lastTyping).addingTimeInterval(Self.linger) }.min()
    }
}

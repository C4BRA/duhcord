import Foundation

/// Discord IDs are 64-bit integers sent as strings.
public typealias Snowflake = String

extension Snowflake {
    /// Numeric value for ordering. IDs grow over time, so a larger ID is newer.
    public var snowflakeValue: UInt64 { UInt64(self) ?? 0 }
}

/// Decoder used for everything Discord sends us.
public func makeDiscordDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return decoder
}

public struct User: Codable, Hashable {
    public let id: Snowflake
    public let username: String
    public let globalName: String?
    public let avatar: String?
    public let bot: Bool?

    public init(id: Snowflake, username: String, globalName: String? = nil, avatar: String? = nil, bot: Bool? = nil) {
        self.id = id
        self.username = username
        self.globalName = globalName
        self.avatar = avatar
        self.bot = bot
    }

    public var displayName: String {
        if let globalName, !globalName.isEmpty { return globalName }
        return username
    }
}

public struct PermissionOverwrite: Codable, Hashable {
    public let id: Snowflake
    /// 0 = role, 1 = member.
    public let type: Int
    public let allow: String
    public let deny: String

    public init(id: Snowflake, type: Int, allow: String, deny: String) {
        self.id = id
        self.type = type
        self.allow = allow
        self.deny = deny
    }
}

public enum ChannelKind: Int {
    case text = 0
    case dm = 1
    case voice = 2
    case groupDM = 3
    case category = 4
    case announcement = 5
    case announcementThread = 10
    case publicThread = 11
    case privateThread = 12
    case stage = 13
    case directory = 14
    case forum = 15
    case media = 16
}

public struct Channel: Codable, Hashable {
    public let id: Snowflake
    public let type: Int
    public var guildId: Snowflake?
    public let name: String?
    public let position: Int?
    public let parentId: Snowflake?
    public var lastMessageId: Snowflake?
    public let recipients: [User]?
    public let permissionOverwrites: [PermissionOverwrite]?

    public init(id: Snowflake, type: Int, guildId: Snowflake? = nil, name: String? = nil, position: Int? = nil,
                parentId: Snowflake? = nil, lastMessageId: Snowflake? = nil, recipients: [User]? = nil,
                permissionOverwrites: [PermissionOverwrite]? = nil) {
        self.id = id
        self.type = type
        self.guildId = guildId
        self.name = name
        self.position = position
        self.parentId = parentId
        self.lastMessageId = lastMessageId
        self.recipients = recipients
        self.permissionOverwrites = permissionOverwrites
    }

    public var kind: ChannelKind? { ChannelKind(rawValue: type) }

    public var isPrivate: Bool { kind == .dm || kind == .groupDM }

    /// Channels we can show and type into. Voice, forum and similar channels are left out.
    public var isTextLike: Bool { kind == .text || kind == .announcement }

    public var displayName: String {
        if let name, !name.isEmpty { return name }
        if let recipients, !recipients.isEmpty {
            return recipients.map(\.displayName).joined(separator: ", ")
        }
        return "Unnamed"
    }
}

public struct Role: Codable, Hashable {
    public let id: Snowflake
    public let permissions: String
}

public struct Member: Codable, Hashable {
    public let user: User?
    public let userId: Snowflake?
    public let roles: [Snowflake]

    public var resolvedUserId: Snowflake? { user?.id ?? userId }
}

public struct Guild: Decodable, Hashable {
    public let id: Snowflake
    public let name: String
    public let icon: String?
    public let ownerId: Snowflake?
    public let roles: [Role]
    public var channels: [Channel]
    public let members: [Member]
    public let unavailable: Bool

    private enum CodingKeys: String, CodingKey {
        case id, name, icon, ownerId, roles, channels, members, unavailable, properties
    }

    private enum PropertyKeys: String, CodingKey {
        case name, icon, ownerId
    }

    public init(id: Snowflake, name: String, icon: String? = nil, ownerId: Snowflake? = nil, roles: [Role] = [],
                channels: [Channel] = [], members: [Member] = [], unavailable: Bool = false) {
        self.id = id
        self.name = name
        self.icon = icon
        self.ownerId = ownerId
        self.roles = roles
        self.channels = channels
        self.members = members
        self.unavailable = unavailable
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Snowflake.self, forKey: .id)
        // Newer gateway payloads nest name/icon/owner under "properties"; older ones keep them at the top.
        let props = try? c.nestedContainer(keyedBy: PropertyKeys.self, forKey: .properties)
        let topName = try c.decodeIfPresent(String.self, forKey: .name)
        let topIcon = try c.decodeIfPresent(String.self, forKey: .icon)
        let topOwner = try c.decodeIfPresent(Snowflake.self, forKey: .ownerId)
        name = (try? props?.decode(String.self, forKey: .name)) ?? topName ?? ""
        icon = (try? props?.decodeIfPresent(String.self, forKey: .icon)) ?? topIcon
        ownerId = (try? props?.decodeIfPresent(Snowflake.self, forKey: .ownerId)) ?? topOwner
        roles = try c.decodeIfPresent([Role].self, forKey: .roles) ?? []
        members = try c.decodeIfPresent([Member].self, forKey: .members) ?? []
        unavailable = try c.decodeIfPresent(Bool.self, forKey: .unavailable) ?? false
        let decodedChannels = (try? c.decodeIfPresent(LossyArray<Channel>.self, forKey: .channels))?.elements ?? []
        let guildID = id
        channels = decodedChannels.map { var ch = $0; ch.guildId = guildID; return ch }
    }
}

public struct Attachment: Codable, Hashable {
    public let id: Snowflake
    public let filename: String
    public let url: String
    public let size: Int?
    public let contentType: String?
}

public struct MessageReference: Codable, Hashable {
    public let messageId: Snowflake?
    public let channelId: Snowflake?
}

/// The message a reply points at. Kept shallow so replies can't nest forever.
public struct ReferencedMessage: Codable, Hashable {
    public let id: Snowflake
    public let author: User
    public let content: String
}

public struct Message: Codable, Hashable {
    public let id: Snowflake
    public let channelId: Snowflake
    public let guildId: Snowflake?
    public let author: User
    public var content: String
    public let timestamp: String
    public var editedTimestamp: String?
    public var attachments: [Attachment]
    public let mentions: [User]?
    public let mentionEveryone: Bool?
    public let referencedMessage: ReferencedMessage?
    public let nonce: String?
    public let type: Int?

    public init(id: Snowflake, channelId: Snowflake, guildId: Snowflake? = nil, author: User, content: String,
                timestamp: String, editedTimestamp: String? = nil, attachments: [Attachment] = [],
                mentions: [User]? = nil, mentionEveryone: Bool? = nil, referencedMessage: ReferencedMessage? = nil,
                nonce: String? = nil, type: Int? = nil) {
        self.id = id
        self.channelId = channelId
        self.guildId = guildId
        self.author = author
        self.content = content
        self.timestamp = timestamp
        self.editedTimestamp = editedTimestamp
        self.attachments = attachments
        self.mentions = mentions
        self.mentionEveryone = mentionEveryone
        self.referencedMessage = referencedMessage
        self.nonce = nonce
        self.type = type
    }

    private enum CodingKeys: String, CodingKey {
        case id, channelId, guildId, author, content, timestamp, editedTimestamp, attachments
        case mentions, mentionEveryone, referencedMessage, nonce, type
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Snowflake.self, forKey: .id)
        channelId = try c.decode(Snowflake.self, forKey: .channelId)
        guildId = try c.decodeIfPresent(Snowflake.self, forKey: .guildId)
        author = try c.decode(User.self, forKey: .author)
        content = try c.decodeIfPresent(String.self, forKey: .content) ?? ""
        timestamp = try c.decodeIfPresent(String.self, forKey: .timestamp) ?? ""
        editedTimestamp = try c.decodeIfPresent(String.self, forKey: .editedTimestamp)
        attachments = try c.decodeIfPresent([Attachment].self, forKey: .attachments) ?? []
        mentions = try c.decodeIfPresent([User].self, forKey: .mentions)
        mentionEveryone = try c.decodeIfPresent(Bool.self, forKey: .mentionEveryone)
        // A reply's target can be null (deleted) or fail to decode; neither should drop the message.
        referencedMessage = try? c.decodeIfPresent(ReferencedMessage.self, forKey: .referencedMessage)
        // Nonces arrive as either strings or numbers.
        if let s = try? c.decodeIfPresent(String.self, forKey: .nonce) {
            nonce = s
        } else if let n = try? c.decodeIfPresent(Int64.self, forKey: .nonce) {
            nonce = String(n)
        } else {
            nonce = nil
        }
        type = try c.decodeIfPresent(Int.self, forKey: .type)
    }

    public var date: Date? { DiscordDate.parse(timestamp) }
}

/// MESSAGE_UPDATE can carry only the changed fields.
public struct MessageUpdate: Decodable {
    public let id: Snowflake
    public let channelId: Snowflake
    public let content: String?
    public let editedTimestamp: String?
    public let attachments: [Attachment]?
}

public struct MessageDelete: Decodable {
    public let id: Snowflake
    public let channelId: Snowflake
}

public struct MessageAck: Decodable {
    public let channelId: Snowflake
    public let messageId: Snowflake
}

/// Sent periodically for servers we aren't subscribed to (large servers we haven't opened), so their
/// unread markers stay right without receiving every message.
public struct ChannelUnreadUpdate: Decodable {
    public struct Entry: Decodable {
        public let id: Snowflake
        public let lastMessageId: Snowflake?
    }

    public let guildId: Snowflake
    public let channelUnreadUpdates: [Entry]
}

public struct ReadState: Codable, Hashable {
    public let id: Snowflake
    public var lastMessageId: Snowflake?
    public var mentionCount: Int?

    public init(id: Snowflake, lastMessageId: Snowflake?, mentionCount: Int? = nil) {
        self.id = id
        self.lastMessageId = lastMessageId
        self.mentionCount = mentionCount
    }

    private enum CodingKeys: String, CodingKey { case id, lastMessageId, mentionCount }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Snowflake.self, forKey: .id)
        // Some read states store the last message ID as a number.
        if let s = try? c.decodeIfPresent(String.self, forKey: .lastMessageId) {
            lastMessageId = s
        } else if let n = try? c.decodeIfPresent(UInt64.self, forKey: .lastMessageId) {
            lastMessageId = String(n)
        } else {
            lastMessageId = nil
        }
        mentionCount = try c.decodeIfPresent(Int.self, forKey: .mentionCount)
    }
}

public struct ReadyEvent: Decodable {
    public let user: User
    public let sessionId: String
    public let resumeGatewayUrl: String?
    public let guilds: [Guild]
    public let privateChannels: [Channel]
    public let readStates: [ReadState]
    /// Our own member object for each guild, in the same order as `guilds`.
    public let mergedMembers: [[Member]]?
    /// Users referenced by ID elsewhere in READY (for example DM recipients).
    public let users: [User]?

    private enum CodingKeys: String, CodingKey {
        case user, sessionId, resumeGatewayUrl, guilds, privateChannels, readState, mergedMembers, users
    }

    private struct ReadStateContainer: Decodable { let entries: [ReadState] }

    /// DM channels sometimes list recipients only by ID.
    private struct RawPrivateChannel: Decodable {
        let id: Snowflake
        let type: Int
        let name: String?
        let lastMessageId: Snowflake?
        let recipients: [User]?
        let recipientIds: [Snowflake]?
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        user = try c.decode(User.self, forKey: .user)
        sessionId = try c.decode(String.self, forKey: .sessionId)
        resumeGatewayUrl = try c.decodeIfPresent(String.self, forKey: .resumeGatewayUrl)
        guilds = (try? c.decodeIfPresent(LossyArray<Guild>.self, forKey: .guilds))?.elements ?? []
        mergedMembers = try? c.decodeIfPresent([[Member]].self, forKey: .mergedMembers)
        users = try? c.decodeIfPresent([User].self, forKey: .users)

        let usersByID = Dictionary((users ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let raw = (try? c.decodeIfPresent(LossyArray<RawPrivateChannel>.self, forKey: .privateChannels))?.elements ?? []
        privateChannels = raw.map { r in
            let recipients = r.recipients ?? (r.recipientIds ?? []).compactMap { usersByID[$0] }
            return Channel(id: r.id, type: r.type, name: r.name, lastMessageId: r.lastMessageId, recipients: recipients)
        }

        if let list = try? c.decodeIfPresent([ReadState].self, forKey: .readState) {
            readStates = list
        } else if let container = try? c.decodeIfPresent(ReadStateContainer.self, forKey: .readState) {
            readStates = container.entries
        } else {
            readStates = []
        }
    }
}

/// Decodes an array, skipping elements that fail instead of failing the whole array.
struct LossyArray<Element: Decodable>: Decodable {
    let elements: [Element]

    private struct Skip: Decodable {}

    init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        var result: [Element] = []
        while !c.isAtEnd {
            if let e = try? c.decode(Element.self) {
                result.append(e)
            } else if (try? c.decode(Skip.self)) == nil {
                break
            }
        }
        elements = result
    }
}

public enum DiscordDate {
    private static let withFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Discord sends microseconds ("…:00.123456+00:00"); the formatter is only reliable with milliseconds.
    public static func parse(_ string: String) -> Date? {
        var s = string
        if let dot = s.firstIndex(of: ".") {
            let digitsEnd = s[s.index(after: dot)...].firstIndex(where: { !$0.isNumber }) ?? s.endIndex
            let fraction = s[s.index(after: dot)..<digitsEnd].prefix(3)
            s = String(s[..<dot]) + "." + String(fraction).padding(toLength: 3, withPad: "0", startingAt: 0) + String(s[digitsEnd...])
        }
        return withFraction.date(from: s) ?? plain.date(from: s)
    }
}

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

public struct User: Decodable, Hashable {
    public let id: Snowflake
    public let username: String
    public let globalName: String?
    public let avatar: String?
    public let bot: Bool?
    /// "0" for accounts on the new username system; older accounts still have a four-digit tag.
    public let discriminator: String?

    public init(id: Snowflake, username: String, globalName: String? = nil, avatar: String? = nil, bot: Bool? = nil,
                discriminator: String? = nil) {
        self.id = id
        self.username = username
        self.globalName = globalName
        self.avatar = avatar
        self.bot = bot
        self.discriminator = discriminator
    }

    public var displayName: String {
        if let globalName, !globalName.isEmpty { return globalName }
        return username
    }
}

public struct PermissionOverwrite: Decodable, Hashable {
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

public struct Channel: Decodable, Hashable {
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

    /// Voice channels we can join. Stage channels work differently and aren't supported.
    public var isVoice: Bool { kind == .voice }

    public var displayName: String {
        if let name, !name.isEmpty { return name }
        if let recipients, !recipients.isEmpty {
            return recipients.map(\.displayName).joined(separator: ", ")
        }
        return "Unnamed"
    }
}

public struct Role: Decodable, Hashable {
    public let id: Snowflake
    public let permissions: String
}

public struct Member: Decodable, Hashable {
    public let user: User?
    public let userId: Snowflake?
    public let roles: [Snowflake]
    public let nick: String?

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
    /// Who is in which voice channel right now.
    public let voiceStates: [VoiceState]

    private enum CodingKeys: String, CodingKey {
        case id, name, icon, ownerId, roles, channels, members, unavailable, properties, voiceStates
    }

    private enum PropertyKeys: String, CodingKey {
        case name, icon, ownerId
    }

    public init(id: Snowflake, name: String, icon: String? = nil, ownerId: Snowflake? = nil, roles: [Role] = [],
                channels: [Channel] = [], members: [Member] = [], unavailable: Bool = false, voiceStates: [VoiceState] = []) {
        self.id = id
        self.name = name
        self.icon = icon
        self.ownerId = ownerId
        self.roles = roles
        self.channels = channels
        self.members = members
        self.unavailable = unavailable
        self.voiceStates = voiceStates
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
        voiceStates = (try? c.decodeIfPresent(LossyArray<VoiceState>.self, forKey: .voiceStates))?.elements ?? []
    }
}

/// Someone's place in a voice channel. `channelId` is nil when they left.
public struct VoiceState: Decodable, Hashable {
    public let guildId: Snowflake?
    public let channelId: Snowflake?
    public let userId: Snowflake
    public let sessionId: String?
    public let member: Member?
    public let selfMute: Bool
    public let selfDeaf: Bool
    /// Muted or deafened by a moderator.
    public let mute: Bool
    public let deaf: Bool

    private enum CodingKeys: String, CodingKey {
        case guildId, channelId, userId, sessionId, member, selfMute, selfDeaf, mute, deaf
    }

    public init(guildId: Snowflake?, channelId: Snowflake?, userId: Snowflake, sessionId: String? = nil, member: Member? = nil,
                selfMute: Bool = false, selfDeaf: Bool = false, mute: Bool = false, deaf: Bool = false) {
        self.guildId = guildId
        self.channelId = channelId
        self.userId = userId
        self.sessionId = sessionId
        self.member = member
        self.selfMute = selfMute
        self.selfDeaf = selfDeaf
        self.mute = mute
        self.deaf = deaf
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guildId = try c.decodeIfPresent(Snowflake.self, forKey: .guildId)
        channelId = try c.decodeIfPresent(Snowflake.self, forKey: .channelId)
        userId = try c.decode(Snowflake.self, forKey: .userId)
        sessionId = try c.decodeIfPresent(String.self, forKey: .sessionId)
        // A member object we can't read shouldn't hide that the person is in the channel.
        member = try? c.decodeIfPresent(Member.self, forKey: .member)
        selfMute = try c.decodeIfPresent(Bool.self, forKey: .selfMute) ?? false
        selfDeaf = try c.decodeIfPresent(Bool.self, forKey: .selfDeaf) ?? false
        mute = try c.decodeIfPresent(Bool.self, forKey: .mute) ?? false
        deaf = try c.decodeIfPresent(Bool.self, forKey: .deaf) ?? false
    }

    /// Server nickname, else the account's display name.
    public var displayName: String? {
        if let nick = member?.nick, !nick.isEmpty { return nick }
        return member?.user?.displayName
    }
}

/// Where to connect for voice in a guild. `endpoint` is nil while Discord picks a server.
public struct VoiceServerUpdate: Decodable {
    public let token: String
    public let guildId: Snowflake?
    public let endpoint: String?
}

public struct Attachment: Decodable, Hashable {
    public let id: Snowflake
    public let filename: String
    public let url: String
    /// Discord's media proxy copy, which can be resized on request.
    public let proxyUrl: String?
    public let size: Int?
    public let contentType: String?
    public let width: Int?
    public let height: Int?

    public init(id: Snowflake, filename: String, url: String, proxyUrl: String? = nil, size: Int? = nil,
                contentType: String? = nil, width: Int? = nil, height: Int? = nil) {
        self.id = id
        self.filename = filename
        self.url = url
        self.proxyUrl = proxyUrl
        self.size = size
        self.contentType = contentType
        self.width = width
        self.height = height
    }

    public var isImage: Bool { (contentType ?? "").hasPrefix("image/") && width != nil && height != nil }
    public var isGIF: Bool { contentType == "image/gif" }
    /// Videos macOS can play (MP4 and QuickTime). WebM and others stay links.
    public var isPlayableVideo: Bool {
        ["video/mp4", "video/quicktime", "video/x-m4v"].contains(contentType ?? "") && width != nil && height != nil
    }
    /// Discord hides attachments named SPOILER_… until clicked.
    public var isSpoiler: Bool { filename.hasPrefix("SPOILER_") }
}

/// An image, thumbnail or video inside an embed. `proxyUrl` is Discord's re-encoding proxy.
public struct EmbedMedia: Decodable, Hashable {
    public let url: String?
    public let proxyUrl: String?
    public let width: Int?
    public let height: Int?

    public init(url: String?, proxyUrl: String?, width: Int?, height: Int?) {
        self.url = url
        self.proxyUrl = proxyUrl
        self.width = width
        self.height = height
    }
}

public struct EmbedField: Decodable, Hashable {
    public let name: String
    public let value: String
    public let inline: Bool?
}

/// A link preview or rich card. Discord builds these on its servers and sends them inside the message,
/// so showing the text costs nothing extra; only images are ever fetched, and only from Discord's proxy.
public struct Embed: Decodable, Hashable {
    public struct Named: Decodable, Hashable {
        public let name: String?
        public let url: String?
    }

    public struct Footer: Decodable, Hashable {
        public let text: String
    }

    public let type: String?
    public let title: String?
    public let description: String?
    public let url: String?
    public let color: Int?
    public let author: Named?
    public let provider: Named?
    public let footer: Footer?
    public let fields: [EmbedField]?
    public let thumbnail: EmbedMedia?
    public let image: EmbedMedia?
    public let video: EmbedMedia?

    public init(type: String? = "rich", title: String? = nil, description: String? = nil, url: String? = nil,
                color: Int? = nil, author: Named? = nil, provider: Named? = nil, footer: Footer? = nil,
                fields: [EmbedField]? = nil, thumbnail: EmbedMedia? = nil, image: EmbedMedia? = nil, video: EmbedMedia? = nil) {
        self.type = type
        self.title = title
        self.description = description
        self.url = url
        self.color = color
        self.author = author
        self.provider = provider
        self.footer = footer
        self.fields = fields
        self.thumbnail = thumbnail
        self.image = image
        self.video = video
    }

    /// A video Duhcord can stream itself: one Discord proxies (Tenor/Giphy GIFs, direct video links).
    /// YouTube and similar players have no such stream and open in the browser instead.
    public var playableVideoURL: String? {
        guard let proxy = video?.proxyUrl, let host = URL(string: proxy)?.host, MediaRequest.isAllowedHost(host) else { return nil }
        return proxy
    }

    /// A bare image or GIF link, which Discord shows as just the picture.
    public var isMediaOnly: Bool { type == "image" || type == "gifv" }
    public var isVideo: Bool { type == "gifv" || type == "video" || video != nil }
    public var hasText: Bool {
        [title, description, author?.name, provider?.name, footer?.text].contains { !($0 ?? "").isEmpty } || !(fields ?? []).isEmpty
    }
}

/// The message a reply points at. Kept shallow so replies can't nest forever.
public struct ReferencedMessage: Decodable, Hashable {
    public let id: Snowflake
    public let author: User
    public let content: String
}

public struct Message: Decodable, Equatable {
    public let id: Snowflake
    public let channelId: Snowflake
    public let author: User
    public var content: String
    /// When it was sent, parsed once at decode time rather than every time rows are grouped.
    public let date: Date?
    public var editedTimestamp: String?
    public var attachments: [Attachment]
    public var embeds: [Embed]
    public let mentions: [User]?
    public let mentionEveryone: Bool?
    public let referencedMessage: ReferencedMessage?
    /// Bumped by the store whenever an edit or a late link preview changes the message, so the UI can key its
    /// layout cache on (id, revision) instead of hashing the content.
    public internal(set) var revision = 0

    public init(id: Snowflake, channelId: Snowflake, author: User, content: String, timestamp: String,
                editedTimestamp: String? = nil, attachments: [Attachment] = [], embeds: [Embed] = [],
                mentions: [User]? = nil, mentionEveryone: Bool? = nil, referencedMessage: ReferencedMessage? = nil) {
        self.id = id
        self.channelId = channelId
        self.author = author
        self.content = content
        date = DiscordDate.parse(timestamp)
        self.editedTimestamp = editedTimestamp
        self.attachments = attachments
        self.embeds = embeds
        self.mentions = mentions
        self.mentionEveryone = mentionEveryone
        self.referencedMessage = referencedMessage
    }

    private enum CodingKeys: String, CodingKey {
        case id, channelId, author, content, timestamp, editedTimestamp, attachments, embeds
        case mentions, mentionEveryone, referencedMessage
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Snowflake.self, forKey: .id)
        channelId = try c.decode(Snowflake.self, forKey: .channelId)
        author = try c.decode(User.self, forKey: .author)
        content = try c.decodeIfPresent(String.self, forKey: .content) ?? ""
        date = try c.decodeIfPresent(String.self, forKey: .timestamp).flatMap(DiscordDate.parse)
        editedTimestamp = try c.decodeIfPresent(String.self, forKey: .editedTimestamp)
        attachments = (try? c.decodeIfPresent(LossyArray<Attachment>.self, forKey: .attachments))?.elements ?? []
        // A malformed embed is skipped rather than dropping the whole message.
        embeds = (try? c.decodeIfPresent(LossyArray<Embed>.self, forKey: .embeds))?.elements ?? []
        mentions = try c.decodeIfPresent([User].self, forKey: .mentions)
        mentionEveryone = try c.decodeIfPresent(Bool.self, forKey: .mentionEveryone)
        // A reply's target can be null (deleted) or fail to decode; neither should drop the message.
        referencedMessage = try? c.decodeIfPresent(ReferencedMessage.self, forKey: .referencedMessage)
    }
}

/// MESSAGE_UPDATE can carry only the changed fields.
public struct MessageUpdate: Decodable {
    public let id: Snowflake
    public let channelId: Snowflake
    public let content: String?
    public let editedTimestamp: String?
    public let attachments: [Attachment]?
    /// Discord fetches link previews after the message is sent and delivers them as an update.
    public let embeds: [Embed]?
}

/// Someone started typing. Discord repeats it every ~8–10 seconds while they keep going.
public struct TypingStart: Decodable {
    public struct Member: Decodable {
        public let user: User?
        public let nick: String?
    }

    public let channelId: Snowflake
    public let userId: Snowflake
    public let member: Member?
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

public struct ReadState: Decodable, Hashable {
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
        // Users referenced by ID elsewhere in READY (DM recipients); only needed to fill those in.
        let users = (try? c.decodeIfPresent([User].self, forKey: .users)) ?? []
        let usersByID = Dictionary(users.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
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

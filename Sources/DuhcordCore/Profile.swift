import Foundation

/// Someone's profile, from `GET /users/{id}/profile` (what the official client's profile popout and full
/// profile load). In a server, the server profile (nickname, bio, banner, pronouns) takes priority, as there.
public struct UserProfile: Decodable, Sendable {
    public struct Metadata: Decodable, Hashable, Sendable {
        public let bio: String?
        public let pronouns: String?
        public let banner: String?
        public let accentColor: Int?
        public let themeColors: [Int]?
    }

    public struct Badge: Decodable, Hashable, Sendable {
        public let id: String
        public let description: String
        public let icon: String
    }

    public struct MutualGuild: Decodable, Hashable, Sendable {
        public let id: Snowflake
        public let nick: String?
    }

    /// The server member in the server the profile was asked for.
    public struct GuildMember: Decodable, Hashable, Sendable {
        public let roles: [Snowflake]
        public let nick: String?
        public let avatar: String?
        public let banner: String?
        public let joinedAt: String?
    }

    public let user: User
    public let userProfile: Metadata?
    public let guildMember: GuildMember?
    public let guildMemberProfile: Metadata?
    public let badges: [Badge]
    public let mutualGuilds: [MutualGuild]?
    public let mutualFriends: [User]?
    public let mutualFriendsCount: Int?
    public let widgets: [ProfileWidget]
    public let premiumSince: String?
    /// The pre-2023 "name#1234", when the person chose to show it.
    public let legacyUsername: String?

    private enum CodingKeys: String, CodingKey {
        case user, userProfile, guildMember, guildMemberProfile, badges, mutualGuilds, mutualFriends,
             mutualFriendsCount, widgets, premiumSince, legacyUsername
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        user = try c.decode(User.self, forKey: .user)
        // Everything else is missing or null for someone who blocked us, or redacted for private profiles.
        userProfile = try? c.decodeIfPresent(Metadata.self, forKey: .userProfile)
        guildMember = try? c.decodeIfPresent(GuildMember.self, forKey: .guildMember)
        guildMemberProfile = try? c.decodeIfPresent(Metadata.self, forKey: .guildMemberProfile)
        badges = (try? c.decodeIfPresent(LossyArray<Badge>.self, forKey: .badges))?.elements ?? []
        mutualGuilds = (try? c.decodeIfPresent(LossyArray<MutualGuild>.self, forKey: .mutualGuilds))?.elements
        mutualFriends = (try? c.decodeIfPresent(LossyArray<User>.self, forKey: .mutualFriends))?.elements
        mutualFriendsCount = try? c.decodeIfPresent(Int.self, forKey: .mutualFriendsCount)
        widgets = (try? c.decodeIfPresent(LossyArray<ProfileWidget>.self, forKey: .widgets))?.elements ?? []
        premiumSince = try? c.decodeIfPresent(String.self, forKey: .premiumSince)
        legacyUsername = try? c.decodeIfPresent(String.self, forKey: .legacyUsername)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }

    /// Server bio first, then the account's.
    public var bio: String? { Self.nonEmpty(guildMemberProfile?.bio) ?? Self.nonEmpty(userProfile?.bio) }
    public var pronouns: String? { Self.nonEmpty(guildMemberProfile?.pronouns) ?? Self.nonEmpty(userProfile?.pronouns) }
    /// The server nickname, else the account's display name.
    public var displayName: String { Self.nonEmpty(guildMember?.nick) ?? user.displayName }
    /// The banner colour when there's no banner image. Server profiles don't have their own.
    public var accentColor: Int? { userProfile?.accentColor ?? userProfile?.themeColors?.first }
    public var friendsInCommon: Int? { mutualFriendsCount ?? mutualFriends?.count }
}

/// A tile on someone's profile board (Discord's profile widgets): favourite games, games in rotation and so on.
public struct ProfileWidget: Decodable, Hashable, Sendable {
    public struct Game: Decodable, Hashable, Sendable {
        public let gameId: Snowflake
        public let comment: String?
        public let tags: [String]?
    }

    public let id: Snowflake
    public let type: String
    public let games: [Game]
    /// For game stats widgets: the game they're for.
    public let applicationId: Snowflake?

    private enum CodingKeys: String, CodingKey { case id, data }
    private enum DataKeys: String, CodingKey { case type, games, applicationId }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Snowflake.self, forKey: .id)
        let data = try c.nestedContainer(keyedBy: DataKeys.self, forKey: .data)
        type = try data.decode(String.self, forKey: .type)
        games = (try? data.decodeIfPresent(LossyArray<Game>.self, forKey: .games))?.elements ?? []
        applicationId = try? data.decodeIfPresent(Snowflake.self, forKey: .applicationId)
    }

    /// The heading the official client shows for this kind of widget.
    public var title: String {
        switch type {
        case "favorite_games": return "Favorite Game"
        case "current_games": return "Games in Rotation"
        case "played_games": return "Games I Like"
        case "want_to_play_games": return "Want to Play"
        case "application": return "Game Stats"
        default: return "Games"
        }
    }

    /// Favourite game and games in rotation show each game in detail, with its comment and tags.
    public var isDetailed: Bool { type == "favorite_games" || type == "current_games" }

    /// "looking_for_group" → "Looking For Group".
    public static func tagTitle(_ tag: String) -> String {
        tag.split(separator: "_").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }
}

/// A game or app, for widget and activity names and icons (`GET /applications/public`).
public struct PartialApplication: Decodable, Hashable, Sendable {
    public let id: Snowflake
    public let name: String
    public let icon: String?
}

/// Someone's online status and what they're doing. Kept only for people who aren't offline.
public struct Presence: Hashable, Sendable {
    public enum Status: String, Sendable {
        case online, idle, dnd, offline
    }

    public let userID: Snowflake
    public let status: Status
    public let activities: [Activity]

    public init(userID: Snowflake, status: Status, activities: [Activity]) {
        self.userID = userID
        self.status = status
        self.activities = activities
    }

    /// Their custom status ("😃 I am cool"), if they set one.
    public var customStatus: Activity? { activities.first { $0.type == .custom } }
    /// Games, music and the like: everything but the custom status.
    public var shownActivities: [Activity] { activities.filter { $0.type != .custom && $0.type != .hang } }
}

/// The presence payload as Discord sends it (PRESENCE_UPDATE, READY, GUILD_CREATE, member chunks).
/// Discord warns that any field can be missing or the wrong type, so everything but the user ID is lenient.
struct RawPresence: Decodable, Sendable {
    let presence: Presence

    private enum CodingKeys: String, CodingKey { case user, userId, status, activities }
    private struct UserID: Decodable { let id: Snowflake }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let id = try (try? c.decode(UserID.self, forKey: .user))?.id ?? c.decode(Snowflake.self, forKey: .userId)
        let statusText: String? = (try? c.decodeIfPresent(String.self, forKey: .status)) ?? nil
        // "invisible" never reaches others; anything unknown counts as offline.
        let status = statusText.flatMap(Presence.Status.init(rawValue:)) ?? .offline
        let activities = (try? c.decodeIfPresent(LossyArray<Activity>.self, forKey: .activities))?.elements ?? []
        presence = Presence(userID: id, status: status, activities: activities)
    }
}

public struct Activity: Decodable, Hashable, Sendable {
    public enum Kind: Int, Sendable {
        case playing = 0, streaming, listening, watching, custom, competing, hang
    }

    public struct Timestamps: Decodable, Hashable, Sendable {
        public let start: Double?
        public let end: Double?

        private enum CodingKeys: String, CodingKey { case start, end }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            // Documented as numbers, sometimes sent as strings.
            func millis(_ key: CodingKeys) -> Double? {
                (try? c.decode(Double.self, forKey: key)) ?? (try? c.decode(String.self, forKey: key)).flatMap(Double.init)
            }
            start = millis(.start)
            end = millis(.end)
        }
    }

    public struct Assets: Decodable, Hashable, Sendable {
        public let largeImage: String?
        public let largeText: String?
    }

    public struct Emoji: Decodable, Hashable, Sendable {
        public let name: String
        public let id: Snowflake?
    }

    public let name: String
    public let typeValue: Int
    public let details: String?
    public let state: String?
    public let applicationId: Snowflake?
    public let timestamps: Timestamps?
    public let assets: Assets?
    public let emoji: Emoji?

    private enum CodingKeys: String, CodingKey {
        case name, type, details, state, applicationId, timestamps, assets, emoji
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        typeValue = (try? c.decodeIfPresent(Int.self, forKey: .type)) ?? 0
        details = try? c.decodeIfPresent(String.self, forKey: .details)
        state = try? c.decodeIfPresent(String.self, forKey: .state)
        applicationId = try? c.decodeIfPresent(Snowflake.self, forKey: .applicationId)
        timestamps = try? c.decodeIfPresent(Timestamps.self, forKey: .timestamps)
        assets = try? c.decodeIfPresent(Assets.self, forKey: .assets)
        emoji = try? c.decodeIfPresent(Emoji.self, forKey: .emoji)
    }

    public var type: Kind? { Kind(rawValue: typeValue) }

    /// The line the official client shows: "Playing Rocket League", "Listening to Spotify", or the custom status.
    public var headline: String {
        switch type {
        case .playing?: return "Playing \(name)"
        case .streaming?: return "Streaming \(details ?? name)"
        case .listening?: return "Listening to \(name)"
        case .watching?: return "Watching \(name)"
        case .competing?: return "Competing in \(name)"
        // Custom emoji show as :name:, as they do in messages.
        case .custom?: return [emoji.map { $0.id == nil ? $0.name : ":\($0.name):" }, state].compactMap { $0 }.joined(separator: " ")
        default: return name
        }
    }

    public var startDate: Date? { timestamps?.start.map { Date(timeIntervalSince1970: $0 / 1000) } }
}

extension MediaRequest {
    /// A profile banner at roughly `pixels` across: the server banner in that server, else the account's.
    public static func bannerURL(for profile: UserProfile, guildID: Snowflake?, pixels: Int) -> URL? {
        let size = cdnSize(forPixels: pixels)
        if let guildID, let hash = profile.guildMember?.banner ?? profile.guildMemberProfile?.banner, !hash.isEmpty {
            return URL(string: "https://cdn.discordapp.com/guilds/\(guildID)/users/\(profile.user.id)/banners/\(hash).webp?size=\(size)")
        }
        guard let hash = profile.userProfile?.banner, !hash.isEmpty else { return nil }
        return URL(string: "https://cdn.discordapp.com/banners/\(profile.user.id)/\(hash).webp?size=\(size)")
    }

    /// The server profile picture in that server, else the account's.
    public static func profileAvatarURL(for profile: UserProfile, guildID: Snowflake?, pixels: Int) -> URL? {
        if let guildID, let hash = profile.guildMember?.avatar, !hash.isEmpty {
            return URL(string: "https://cdn.discordapp.com/guilds/\(guildID)/users/\(profile.user.id)/avatars/\(hash).webp?size=\(cdnSize(forPixels: pixels))")
        }
        return avatarURL(for: profile.user, pixels: pixels)
    }

    public static func applicationIconURL(_ application: PartialApplication, pixels: Int) -> URL? {
        guard let icon = application.icon, !icon.isEmpty else { return nil }
        return URL(string: "https://cdn.discordapp.com/app-icons/\(application.id)/\(icon).webp?size=\(cdnSize(forPixels: pixels))")
    }

    public static func badgeIconURL(_ badge: UserProfile.Badge) -> URL? {
        URL(string: "https://cdn.discordapp.com/badge-icons/\(badge.icon).png")
    }

    /// An activity's large image, when it's one Discord hosts: an app asset, or an image behind Discord's
    /// media proxy ("mp:"). Spotify, YouTube and Twitch images would come from those sites, so they're skipped.
    public static func activityImageURL(_ activity: Activity, pixels: Int) -> URL? {
        guard let image = activity.assets?.largeImage, !image.isEmpty else { return nil }
        if image.hasPrefix("mp:") {
            let path = image.dropFirst(3)
            guard !path.contains(".."), let url = URL(string: "https://media.discordapp.net/\(path)") else { return nil }
            return url
        }
        guard !image.contains(":"), image.allSatisfy(\.isNumber), let app = activity.applicationId else { return nil }
        return URL(string: "https://cdn.discordapp.com/app-assets/\(app)/\(image).webp?size=\(cdnSize(forPixels: pixels))")
    }
}

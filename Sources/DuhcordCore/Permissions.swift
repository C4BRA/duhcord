import Foundation

/// The small part of Discord's permission system we need: can we see a channel?
public enum Permissions {
    public static let administrator: UInt64 = 1 << 3
    public static let viewChannel: UInt64 = 1 << 10

    /// Computes whether `userID` can view `channel` in `guild`, given the roles they hold.
    public static func canView(channel: Channel, guild: Guild, userID: Snowflake, memberRoles: [Snowflake]) -> Bool {
        canView(channel: channel, guildID: guild.id, base: base(in: guild, userID: userID, memberRoles: memberRoles),
                userID: userID, memberRoles: Set(memberRoles))
    }

    /// The guild-wide permissions from @everyone and the user's roles; everything for the owner. The same for every
    /// channel, so it's worked out once per guild.
    public static func base(in guild: Guild, userID: Snowflake, memberRoles: [Snowflake]) -> UInt64 {
        if guild.ownerId == userID { return .max }
        let rolesByID = Dictionary(guild.roles.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        // The @everyone role shares the guild's ID.
        var base = UInt64(rolesByID[guild.id]?.permissions ?? "0") ?? 0
        for roleID in memberRoles {
            base |= UInt64(rolesByID[roleID]?.permissions ?? "0") ?? 0
        }
        return base
    }

    /// Applies `channel`'s overwrites to a guild-wide `base` from `base(in:userID:memberRoles:)`.
    public static func canView(channel: Channel, guildID: Snowflake, base: UInt64, userID: Snowflake,
                               memberRoles: Set<Snowflake>) -> Bool {
        if base & administrator != 0 { return true }

        var perms = base
        let overwrites = channel.permissionOverwrites ?? []

        if let everyone = overwrites.first(where: { $0.id == guildID }) {
            perms &= ~(UInt64(everyone.deny) ?? 0)
            perms |= UInt64(everyone.allow) ?? 0
        }

        var roleAllow: UInt64 = 0
        var roleDeny: UInt64 = 0
        for ow in overwrites where ow.type == 0 && memberRoles.contains(ow.id) {
            roleAllow |= UInt64(ow.allow) ?? 0
            roleDeny |= UInt64(ow.deny) ?? 0
        }
        perms &= ~roleDeny
        perms |= roleAllow

        if let member = overwrites.first(where: { $0.type == 1 && $0.id == userID }) {
            perms &= ~(UInt64(member.deny) ?? 0)
            perms |= UInt64(member.allow) ?? 0
        }

        return perms & viewChannel != 0
    }
}

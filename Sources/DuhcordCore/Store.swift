import Foundation

public enum ChannelListItem: Equatable {
    case category(Channel)
    case channel(Channel)
    case voiceChannel(Channel)
}

/// In-memory state for the session. Main-thread only.
///
/// Only a few channels' messages are kept at a time, so memory stays flat no matter how long the app runs.
public final class Store {
    public enum Change: Equatable {
        case guilds
        case channels(guildID: Snowflake?)
        case messages(channelID: Snowflake)
        case unread(channelID: Snowflake)
        /// Someone joined, left or changed mute/deafen in one of the guild's voice channels.
        case voice(guildID: Snowflake)
        /// Someone's status or activities changed.
        case presence(userID: Snowflake)
    }

    public var onChange: ((Change) -> Void)?

    public private(set) var me: User?
    public private(set) var guilds: [Snowflake: Guild] = [:]
    public private(set) var guildOrder: [Snowflake] = []
    /// The channel the user is looking at. New messages there don't count as unread.
    public var focusedChannelID: Snowflake? {
        // Reopening a cached channel makes it the most recent, so the cache evicts the least recently viewed.
        didSet { if let id = focusedChannelID, messageCache[id] != nil { touch(id) } }
    }

    private var channels: [Snowflake: Channel] = [:]
    private var myRoles: [Snowflake: [Snowflake]] = [:]
    private var readStates: [Snowflake: ReadState] = [:]
    private var messageCache: [Snowflake: [Message]] = [:]
    /// Voice channel occupants: guild → user → state.
    private var voiceByGuild: [Snowflake: [Snowflake: VoiceState]] = [:]
    /// Members we've learned about (from voice states and member requests): guild → user → member.
    private var knownMembers: [Snowflake: [Snowflake: Member]] = [:]
    /// Status and activities for everyone we've been told is online. Offline people are dropped, so this only
    /// grows with the number of people online at once.
    private var presences: [Snowflake: Presence] = [:]
    private var cacheOrder: [Snowflake] = []
    private var fullyLoaded: Set<Snowflake> = []
    /// Computed channel lists, since permission checks run on every unread refresh.
    private var channelListCache: [Snowflake: [ChannelListItem]] = [:]
    /// The sorted DM list, rebuilt only when a DM changes rather than on every sidebar refresh.
    private var privateChannelCache: [Channel]?
    /// Mention totals per guild (DMs under `directMessagesKey`), counted in one pass and kept until a read state
    /// or the channel set changes.
    private var mentionTotals: [Snowflake: Int]?
    private static let directMessagesKey: Snowflake = "@me"

    public let maxCachedChannels: Int
    public let maxMessagesPerChannel: Int

    public init(maxCachedChannels: Int = 8, maxMessagesPerChannel: Int = 300) {
        self.maxCachedChannels = maxCachedChannels
        self.maxMessagesPerChannel = maxMessagesPerChannel
    }

    // MARK: - Queries

    public var orderedGuilds: [Guild] { guildOrder.compactMap { guilds[$0] } }

    public func channel(_ id: Snowflake) -> Channel? { channels[id] }

    /// DMs and group DMs, most recently active first.
    public var privateChannels: [Channel] {
        if let cached = privateChannelCache { return cached }
        let sorted = channels.values
            .filter(\.isPrivate)
            .sorted { ($0.lastMessageId ?? "0").snowflakeValue > ($1.lastMessageId ?? "0").snowflakeValue }
        privateChannelCache = sorted
        return sorted
    }

    /// The text channels we can see in a guild, grouped under their categories in Discord's order.
    public func channelList(guildID: Snowflake) -> [ChannelListItem] {
        if let cached = channelListCache[guildID] { return cached }
        let items = computeChannelList(guildID: guildID)
        channelListCache[guildID] = items
        return items
    }

    private func computeChannelList(guildID: Snowflake) -> [ChannelListItem] {
        guard let guild = guilds[guildID], let me else { return [] }
        let roles = myRoles[guildID] ?? []
        let base = Permissions.base(in: guild, userID: me.id, memberRoles: roles)
        let roleSet = Set(roles)
        let visible = channels.values.filter {
            $0.guildId == guildID
                && Permissions.canView(channel: $0, guildID: guildID, base: base, userID: me.id, memberRoles: roleSet)
        }

        func byPosition(_ a: Channel, _ b: Channel) -> Bool {
            let pa = a.position ?? 0, pb = b.position ?? 0
            return pa != pb ? pa < pb : a.id.snowflakeValue < b.id.snowflakeValue
        }

        // Discord lists text channels above voice channels within each group.
        func byKindThenPosition(_ a: Channel, _ b: Channel) -> Bool {
            a.isVoice != b.isVoice ? !a.isVoice : byPosition(a, b)
        }
        func item(_ channel: Channel) -> ChannelListItem { channel.isVoice ? .voiceChannel(channel) : .channel(channel) }

        let listed = visible.filter { $0.isTextLike || $0.isVoice }
        var items: [ChannelListItem] = listed.filter { $0.parentId == nil }.sorted(by: byKindThenPosition).map(item)

        let categories = visible.filter { $0.kind == .category }.sorted(by: byPosition)
        for category in categories {
            let children = listed.filter { $0.parentId == category.id }.sorted(by: byKindThenPosition)
            guard !children.isEmpty else { continue }
            items.append(.category(category))
            items.append(contentsOf: children.map(item))
        }
        return items
    }

    public func isUnread(_ channelID: Snowflake) -> Bool {
        guard let last = channels[channelID]?.lastMessageId else { return false }
        // With no read state we treat the channel as read, so servers you've never opened don't all light up.
        guard let read = readStates[channelID] else { return false }
        return last.snowflakeValue > (read.lastMessageId ?? "0").snowflakeValue
    }

    public func mentionCount(_ channelID: Snowflake) -> Int {
        readStates[channelID]?.mentionCount ?? 0
    }

    public func guildHasUnread(_ guildID: Snowflake) -> Bool {
        channelList(guildID: guildID).contains {
            if case .channel(let c) = $0 { return isUnread(c.id) }
            return false
        }
    }

    public func guildMentionCount(_ guildID: Snowflake) -> Int {
        computedMentionTotals[guildID] ?? 0
    }

    public var privateMentionCount: Int {
        computedMentionTotals[Self.directMessagesKey] ?? 0
    }

    public var privateUnreadCount: Int {
        privateChannels.filter { isUnread($0.id) }.count
    }

    public var totalMentionCount: Int {
        computedMentionTotals.values.reduce(0, +)
    }

    private var computedMentionTotals: [Snowflake: Int] {
        if let cached = mentionTotals { return cached }
        var totals: [Snowflake: Int] = [:]
        for state in readStates.values {
            guard let count = state.mentionCount, count > 0, let channel = channels[state.id] else { continue }
            totals[channel.isPrivate ? Self.directMessagesKey : channel.guildId ?? Self.directMessagesKey, default: 0] += count
        }
        mentionTotals = totals
        return totals
    }

    /// Who is in a voice channel.
    public func voiceStates(in channelID: Snowflake, guildID: Snowflake) -> [VoiceState] {
        (voiceByGuild[guildID] ?? [:]).values.filter { $0.channelId == channelID }
    }

    /// A member's server nickname or display name, if we've seen it.
    public func memberName(_ userID: Snowflake, in guildID: Snowflake) -> String? {
        knownMembers[guildID]?[userID]?.displayName
    }

    /// The account behind a member, for their profile picture.
    public func memberUser(_ userID: Snowflake, in guildID: Snowflake) -> User? {
        knownMembers[guildID]?[userID]?.user ?? user(userID)
    }

    /// Our own voice state in a guild, if we're in one of its voice channels.
    /// Someone's status and activities, if they're online and Discord has told us about them.
    public func presence(of userID: Snowflake) -> Presence? { presences[userID] }

    private func setPresence(_ presence: Presence) {
        presences[presence.userID] = presence.status == .offline ? nil : presence
    }

    public func myVoiceState(in guildID: Snowflake) -> VoiceState? {
        me.flatMap { voiceByGuild[guildID]?[$0.id] }
    }

    /// Cached messages for a channel, oldest first, or nil if we haven't loaded it.
    public func messages(in channelID: Snowflake) -> [Message]? { messageCache[channelID] }

    /// True once we've scrolled back to the very first message.
    public func hasReachedStart(of channelID: Snowflake) -> Bool { fullyLoaded.contains(channelID) }

    public func user(_ id: Snowflake) -> User? {
        if me?.id == id { return me }
        for list in messageCache.values {
            if let u = list.last(where: { $0.author.id == id })?.author { return u }
        }
        for c in channels.values where c.isPrivate {
            if let u = c.recipients?.first(where: { $0.id == id }) { return u }
        }
        return nil
    }

    /// Whether a new message deserves a desktop notification.
    public func shouldNotify(_ message: Message) -> Bool {
        guard let me, message.author.id != me.id else { return false }
        if channels[message.channelId]?.isPrivate == true { return true }
        return mentionsMe(message)
    }

    // MARK: - Loading messages

    /// Stores a page fetched over REST. `newestFirst` is the order Discord returns.
    public func addHistory(_ newestFirst: [Message], for channelID: Snowflake, requestedLimit: Int) {
        let page = Array(newestFirst.reversed())
        var existing = messageCache[channelID] ?? []
        let known = Set(existing.map(\.id))
        existing = page.filter { !known.contains($0.id) } + existing
        existing.sort { $0.id.snowflakeValue < $1.id.snowflakeValue }
        messageCache[channelID] = existing
        if newestFirst.count < requestedLimit { fullyLoaded.insert(channelID) }
        touch(channelID)
        onChange?(.messages(channelID: channelID))
    }

    /// Records that the user has read a channel. Returns the message ID to acknowledge, or nil if nothing changed.
    public func markRead(_ channelID: Snowflake) -> Snowflake? {
        guard let last = channels[channelID]?.lastMessageId ?? messageCache[channelID]?.last?.id else { return nil }
        let current = readStates[channelID]
        let wasUnread = (current?.lastMessageId ?? "0").snowflakeValue < last.snowflakeValue || (current?.mentionCount ?? 0) > 0
        guard wasUnread else { return nil }
        readStates[channelID] = ReadState(id: channelID, lastMessageId: last, mentionCount: 0)
        mentionTotals = nil
        onChange?(.unread(channelID: channelID))
        return last
    }

    // MARK: - Gateway events

    public func apply(_ event: GatewayEvent) {
        switch event {
        case .ready(let ready):
            reset()
            me = ready.user
            for (index, guild) in ready.guilds.enumerated() {
                let merged = ready.mergedMembers.flatMap { index < $0.count ? $0[index] : nil }
                addGuild(guild, mergedMembers: merged)
            }
            for channel in ready.privateChannels { channels[channel.id] = channel }
            ready.presences.forEach(setPresence)
            for state in ready.readStates { readStates[state.id] = state }
            // No change events: the session reports READY itself, and the UI reloads everything once then.

        case .resumed:
            break

        case .guildCreate(let guild):
            addGuild(guild, mergedMembers: nil)
            onChange?(.guilds)
            onChange?(.channels(guildID: guild.id))

        case .guildDelete(let id):
            guilds[id] = nil
            channelListCache[id] = nil
            voiceByGuild[id] = nil
            knownMembers[id] = nil
            guildOrder.removeAll { $0 == id }
            channels = channels.filter { $0.value.guildId != id }
            mentionTotals = nil
            onChange?(.guilds)

        case .channelCreate(let channel), .channelUpdate(let channel):
            var updated = channel
            // Updates don't always repeat the last message ID.
            if updated.lastMessageId == nil { updated.lastMessageId = channels[channel.id]?.lastMessageId }
            channels[channel.id] = updated
            if let guildID = channel.guildId { channelListCache[guildID] = nil }
            if channel.isPrivate { privateChannelCache = nil }
            mentionTotals = nil
            onChange?(.channels(guildID: channel.guildId))

        case .channelDelete(let channel):
            channels[channel.id] = nil
            if let guildID = channel.guildId { channelListCache[guildID] = nil }
            if channel.isPrivate { privateChannelCache = nil }
            mentionTotals = nil
            evict(channel.id)
            onChange?(.channels(guildID: channel.guildId))

        case .messageCreate(let message):
            handleNewMessage(message)

        case .messageUpdate(let update):
            guard var list = messageCache[update.channelId],
                  let i = list.firstIndex(where: { $0.id == update.id }) else { return }
            if let content = update.content { list[i].content = content }
            if let edited = update.editedTimestamp { list[i].editedTimestamp = edited }
            if let attachments = update.attachments { list[i].attachments = attachments }
            if let embeds = update.embeds { list[i].embeds = embeds }
            list[i].revision += 1
            messageCache[update.channelId] = list
            onChange?(.messages(channelID: update.channelId))

        case .messageDelete(let deleted):
            guard var list = messageCache[deleted.channelId] else { return }
            list.removeAll { $0.id == deleted.id }
            messageCache[deleted.channelId] = list
            onChange?(.messages(channelID: deleted.channelId))

        case .channelUnreadUpdate(let update):
            var changed: Snowflake?
            for entry in update.channelUnreadUpdates {
                guard var channel = channels[entry.id], let last = entry.lastMessageId,
                      last.snowflakeValue > (channel.lastMessageId ?? "0").snowflakeValue else { continue }
                channel.lastMessageId = last
                channels[entry.id] = channel
                if channel.isPrivate { privateChannelCache = nil }
                changed = entry.id
            }
            if let changed { onChange?(.unread(channelID: changed)) }

        case .typingStart, .voiceServerUpdate:
            break

        case .presenceUpdate(let presence):
            // Our own presence is never sent; everything else updates the table.
            guard presences[presence.userID] != presence || presence.status == .offline else { return }
            setPresence(presence)
            onChange?(.presence(userID: presence.userID))

        case .voiceStateUpdate(let state):
            // Calls outside guilds (DMs) aren't supported.
            guard let guildID = state.guildId else { return }
            voiceByGuild[guildID, default: [:]][state.userId] = state.channelId == nil ? nil : state
            if let member = state.member, member.user != nil { knownMembers[guildID, default: [:]][state.userId] = member }
            onChange?(.voice(guildID: guildID))

        case .guildMembersChunk(let chunk):
            for member in chunk.members {
                guard let userID = member.resolvedUserId, member.user != nil else { continue }
                knownMembers[chunk.guildId, default: [:]][userID] = member
            }
            for presence in chunk.presences {
                setPresence(presence)
                onChange?(.presence(userID: presence.userID))
            }
            // Names are only shown under voice channels for now.
            onChange?(.voice(guildID: chunk.guildId))

        case .messageAck(let ack):
            // Read on another device.
            readStates[ack.channelId] = ReadState(id: ack.channelId, lastMessageId: ack.messageId, mentionCount: 0)
            mentionTotals = nil
            onChange?(.unread(channelID: ack.channelId))
        }
    }

    // MARK: - Internals

    private func reset() {
        me = nil
        guilds = [:]
        guildOrder = []
        channels = [:]
        myRoles = [:]
        readStates = [:]
        messageCache = [:]
        voiceByGuild = [:]
        knownMembers = [:]
        presences = [:]
        cacheOrder = []
        fullyLoaded = []
        channelListCache = [:]
        privateChannelCache = nil
        mentionTotals = nil
    }

    private func addGuild(_ guild: Guild, mergedMembers: [Member]?) {
        guard !guild.unavailable else { return }
        channelListCache[guild.id] = nil
        mentionTotals = nil
        if guilds[guild.id] == nil { guildOrder.append(guild.id) }
        guild.presences.forEach(setPresence)
        var stored = guild
        stored.presences = []
        guilds[guild.id] = stored
        for channel in guild.channels {
            var c = channel
            c.guildId = guild.id
            channels[c.id] = c
        }
        voiceByGuild[guild.id] = Dictionary(guild.voiceStates.filter { $0.channelId != nil }.map { ($0.userId, $0) },
                                           uniquingKeysWith: { _, latest in latest })
        let selfMember = (mergedMembers ?? []).first { $0.resolvedUserId == me?.id }
            ?? guild.members.first { $0.resolvedUserId == me?.id }
        if let selfMember { myRoles[guild.id] = selfMember.roles }
    }

    public func mentionsMe(_ message: Message) -> Bool {
        guard let me else { return false }
        if message.mentionEveryone == true { return true }
        return message.mentions?.contains { $0.id == me.id } ?? false
    }

    private func handleNewMessage(_ message: Message) {
        let id = message.channelId
        if var channel = channels[id] {
            channel.lastMessageId = message.id
            channels[id] = channel
            if channel.isPrivate { privateChannelCache = nil }
        }

        if var list = messageCache[id], !list.contains(where: { $0.id == message.id }) {
            list.append(message)
            if list.count > maxMessagesPerChannel {
                list.removeFirst(list.count - maxMessagesPerChannel)
                fullyLoaded.remove(id)
            }
            messageCache[id] = list
            onChange?(.messages(channelID: id))
        }

        if message.author.id == me?.id {
            // Our own messages are read by definition.
            readStates[id] = ReadState(id: id, lastMessageId: message.id, mentionCount: 0)
            mentionTotals = nil
        } else if id != focusedChannelID {
            var state = readStates[id] ?? ReadState(id: id, lastMessageId: nil, mentionCount: 0)
            if mentionsMe(message) || channels[id]?.isPrivate == true {
                state.mentionCount = (state.mentionCount ?? 0) + 1
            }
            readStates[id] = state
            mentionTotals = nil
        }
        onChange?(.unread(channelID: id))
    }

    private func touch(_ channelID: Snowflake) {
        cacheOrder.removeAll { $0 == channelID }
        cacheOrder.append(channelID)
        while cacheOrder.count > maxCachedChannels {
            guard let victim = cacheOrder.first(where: { $0 != focusedChannelID }) else { break }
            evict(victim)
        }
    }

    private func evict(_ channelID: Snowflake) {
        cacheOrder.removeAll { $0 == channelID }
        messageCache[channelID] = nil
        fullyLoaded.remove(channelID)
    }
}

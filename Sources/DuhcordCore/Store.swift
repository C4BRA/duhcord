import Foundation

public enum ChannelListItem: Equatable {
    case category(Channel)
    case channel(Channel)
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
    }

    public var onChange: ((Change) -> Void)?

    public private(set) var me: User?
    public private(set) var guilds: [Snowflake: Guild] = [:]
    public private(set) var guildOrder: [Snowflake] = []
    /// The channel the user is looking at. New messages there don't count as unread.
    public var focusedChannelID: Snowflake?

    private var channels: [Snowflake: Channel] = [:]
    private var myRoles: [Snowflake: [Snowflake]] = [:]
    private var readStates: [Snowflake: ReadState] = [:]
    private var messageCache: [Snowflake: [Message]] = [:]
    private var cacheOrder: [Snowflake] = []
    private var fullyLoaded: Set<Snowflake> = []
    /// Computed channel lists, since permission checks run on every unread refresh.
    private var channelListCache: [Snowflake: [ChannelListItem]] = [:]

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
        channels.values
            .filter(\.isPrivate)
            .sorted { ($0.lastMessageId ?? "0").snowflakeValue > ($1.lastMessageId ?? "0").snowflakeValue }
    }

    /// The text channels we can see in a guild, grouped under their categories in Discord's order.
    public func channelList(guildID: Snowflake) -> [ChannelListItem] {
        if let cached = channelListCache[guildID] { return cached }
        let items = computeChannelList(guildID: guildID)
        channelListCache[guildID] = items
        return items
    }

    private func computeChannelList(guildID: Snowflake) -> [ChannelListItem] {
        guard let guild = guilds[guildID] else { return [] }
        let all = channels.values.filter { $0.guildId == guildID }
        let visible = all.filter { canView($0, in: guild) }

        func byPosition(_ a: Channel, _ b: Channel) -> Bool {
            let pa = a.position ?? 0, pb = b.position ?? 0
            return pa != pb ? pa < pb : a.id.snowflakeValue < b.id.snowflakeValue
        }

        let text = visible.filter(\.isTextLike)
        var items: [ChannelListItem] = text.filter { $0.parentId == nil }.sorted(by: byPosition).map { .channel($0) }

        let categories = visible.filter { $0.kind == .category }.sorted(by: byPosition)
        for category in categories {
            let children = text.filter { $0.parentId == category.id }.sorted(by: byPosition)
            guard !children.isEmpty else { continue }
            items.append(.category(category))
            items.append(contentsOf: children.map { .channel($0) })
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
        channels.values.filter { $0.guildId == guildID }.reduce(0) { $0 + mentionCount($1.id) }
    }

    public var privateUnreadCount: Int {
        privateChannels.filter { isUnread($0.id) }.count
    }

    public var totalMentionCount: Int {
        readStates.values.reduce(0) { $0 + ($1.mentionCount ?? 0) }
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
            for state in ready.readStates { readStates[state.id] = state }
            onChange?(.guilds)
            onChange?(.channels(guildID: nil))

        case .resumed:
            break

        case .guildCreate(let guild):
            addGuild(guild, mergedMembers: nil)
            onChange?(.guilds)
            onChange?(.channels(guildID: guild.id))

        case .guildDelete(let id):
            guilds[id] = nil
            channelListCache[id] = nil
            guildOrder.removeAll { $0 == id }
            channels = channels.filter { $0.value.guildId != id }
            onChange?(.guilds)

        case .channelCreate(let channel), .channelUpdate(let channel):
            var updated = channel
            // Updates don't always repeat the last message ID.
            if updated.lastMessageId == nil { updated.lastMessageId = channels[channel.id]?.lastMessageId }
            channels[channel.id] = updated
            if let guildID = channel.guildId { channelListCache[guildID] = nil }
            onChange?(.channels(guildID: channel.guildId))

        case .channelDelete(let channel):
            channels[channel.id] = nil
            if let guildID = channel.guildId { channelListCache[guildID] = nil }
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
                changed = entry.id
            }
            if let changed { onChange?(.unread(channelID: changed)) }

        case .messageAck(let ack):
            // Read on another device.
            readStates[ack.channelId] = ReadState(id: ack.channelId, lastMessageId: ack.messageId, mentionCount: 0)
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
        cacheOrder = []
        fullyLoaded = []
        channelListCache = [:]
    }

    private func addGuild(_ guild: Guild, mergedMembers: [Member]?) {
        guard !guild.unavailable else { return }
        channelListCache[guild.id] = nil
        if guilds[guild.id] == nil { guildOrder.append(guild.id) }
        guilds[guild.id] = guild
        for channel in guild.channels {
            var c = channel
            c.guildId = guild.id
            channels[c.id] = c
        }
        let selfMember = (mergedMembers ?? []).first { $0.resolvedUserId == me?.id }
            ?? guild.members.first { $0.resolvedUserId == me?.id }
        if let selfMember { myRoles[guild.id] = selfMember.roles }
    }

    private func canView(_ channel: Channel, in guild: Guild) -> Bool {
        guard let me else { return false }
        return Permissions.canView(channel: channel, guild: guild, userID: me.id, memberRoles: myRoles[guild.id] ?? [])
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
        } else if id != focusedChannelID {
            var state = readStates[id] ?? ReadState(id: id, lastMessageId: nil, mentionCount: 0)
            if mentionsMe(message) || channels[id]?.isPrivate == true {
                state.mentionCount = (state.mentionCount ?? 0) + 1
            }
            readStates[id] = state
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

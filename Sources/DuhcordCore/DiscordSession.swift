import Foundation

public protocol DiscordSessionDelegate: AnyObject {
    func sessionDidBecomeReady(_ session: DiscordSession)
    func session(_ session: DiscordSession, didChangeState state: GatewayClient.State)
    func session(_ session: DiscordSession, shouldNotifyAbout message: Message)
}

/// Ties the gateway, REST client and store together. Main-thread only.
public final class DiscordSession: GatewayClientDelegate {
    public let store = Store()
    public let rest: RESTClient
    public weak var delegate: DiscordSessionDelegate?
    /// While false, new messages in the focused channel are left unread.
    public var isActive = true {
        didSet {
            if isActive, let focused = store.focusedChannelID { markRead(channelID: focused) }
        }
    }

    /// Who is typing in the channel on screen.
    public let typing = TypingTracker()
    /// Called on the main thread whenever `typing` changes.
    public var onTypingChange: (() -> Void)?
    /// This connection's gateway session. Voice states carrying another session ID belong to another device.
    public private(set) var sessionID: String?
    /// Our own voice state changed (joined, moved, left, muted).
    public var onOwnVoiceState: ((VoiceState) -> Void)?
    /// Discord told us which voice server to use.
    public var onVoiceServer: ((VoiceServerUpdate) -> Void)?
    private var lastTypingSent: [Snowflake: Date] = [:]

    private let gateway: GatewayClient
    private var lastGatewayState: GatewayClient.State = .disconnected
    private var loading: Set<Snowflake> = []
    private var subscribedGuilds: Set<Snowflake> = []
    /// "guild/user" pairs already asked for, so a name Discord can't give isn't asked for again and again.
    private var requestedMembers: Set<String> = []
    /// When each "guild/user" presence was last asked for, so reopening a profile doesn't ask again right away.
    private var presenceRequests: [String: Date] = [:]
    private static let presenceRequestInterval: TimeInterval = 60
    private var pendingAck: [Snowflake: Snowflake] = [:]
    private var ackTimer: Timer?

    public static let pageSize = 50

    public init(token: String) {
        rest = RESTClient(token: token)
        gateway = GatewayClient(token: token)
        gateway.delegate = self
    }

    public func connect() { gateway.connect() }

    public func disconnect() {
        ackTimer?.invalidate()
        gateway.disconnect()
    }

    /// Joins or leaves (nil channel) a voice channel, or changes our mute and deafen.
    public func updateVoiceState(guildID: Snowflake, channelID: Snowflake?, muted: Bool, deafened: Bool) {
        gateway.updateVoiceState(guildID: guildID, channelID: channelID, selfMute: muted, selfDeaf: deafened)
    }

    /// Fetches names for members we don't know yet. Each one is asked for once per connection.
    public func requestMemberNames(guildID: Snowflake, userIDs: [Snowflake]) {
        let missing = userIDs.filter { requestedMembers.insert(guildID + "/" + $0).inserted }
        guard !missing.isEmpty else { return }
        gateway.requestMembers(guildID: guildID, userIDs: missing)
    }

    /// Asks for someone's status and activities in a server, for their profile. Friends' presences arrive
    /// on their own; for anyone else, the official client asks the same way when it opens a profile.
    public func requestPresence(of userID: Snowflake, guildID: Snowflake) {
        guard userID != store.me?.id else { return }
        let key = guildID + "/" + userID, now = Date()
        // Presence updates keep arriving once Discord has sent it; asking again within a minute adds nothing
        // and counts against the gateway's rate limit.
        if let last = presenceRequests[key], now.timeIntervalSince(last) < Self.presenceRequestInterval { return }
        if presenceRequests.count > 500 { presenceRequests = presenceRequests.filter { now.timeIntervalSince($0.value) < Self.presenceRequestInterval } }
        presenceRequests[key] = now
        gateway.requestMembers(guildID: guildID, userIDs: [userID], presences: true)
    }

    /// The DM channel with someone, opened on Discord's side first if there isn't one yet.
    public func directMessageChannel(with userID: Snowflake, completion: @escaping (Snowflake?) -> Void) {
        if let existing = store.privateChannels.first(where: { $0.kind == .dm && $0.recipients?.first?.id == userID }) {
            completion(existing.id)
            return
        }
        Task { @MainActor in
            do {
                completion(try await openedDM(with: userID).id)
            } catch {
                reportIfUnreachable(error)
                completion(nil)
            }
        }
    }

    /// Opens the DM on Discord's side and adds it to the store straight away. Discord also announces it over the
    /// gateway (CHANNEL_CREATE), but a moment later; without this the DM would be shown before Duhcord knew of it.
    /// Adding it twice is harmless: the announcement takes the same path and just updates it.
    private func openedDM(with userID: Snowflake) async throws -> Channel {
        let channel = try await rest.openDM(with: userID)
        store.apply(.channelCreate(channel))
        return channel
    }

    /// Sends a direct message, opening the DM first if there isn't one yet (a profile's message field).
    public func sendDirectMessage(_ content: String, to userID: Snowflake, completion: @escaping (Error?) -> Void) {
        if let existing = store.privateChannels.first(where: { $0.kind == .dm && $0.recipients?.first?.id == userID }) {
            send(content, to: existing.id, completion: completion)
            return
        }
        Task { @MainActor in
            do {
                let channel = try await openedDM(with: userID)
                send(content, to: channel.id, completion: completion)
            } catch {
                reportIfUnreachable(error)
                completion(error)
            }
        }
    }

    /// Reconnects after the app was locked because Discord couldn't be reached.
    public func retry() { gateway.retry() }

    /// Logs the token out on Discord's side first. Throws (and changes nothing) if Discord can't be reached,
    /// so a logout never leaves a still-valid token behind.
    public func logout() async throws {
        try await rest.logout()
        disconnect()
    }

    /// True for errors that mean "Discord can't be reached", as opposed to Discord answering with an error.
    /// A connection our certificate checks refused counts too: we couldn't reach the real Discord.
    public static func isConnectivityError(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost, .cannotConnectToHost,
             .dnsLookupFailed, .dataNotAllowed, .internationalRoamingOff, .secureConnectionFailed,
             .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateNotYetValid,
             .serverCertificateHasUnknownRoot, .cancelled:
            return true
        default:
            return false
        }
    }

    private func reportIfUnreachable(_ error: Error) {
        guard Self.isConnectivityError(error), lastGatewayState != .connected else { return }
        delegate?.session(self, didChangeState: .unreachable)
    }

    /// Switches the focused channel, loading its latest messages if they aren't cached.
    public func open(channelID: Snowflake) {
        store.focusedChannelID = channelID
        if typing.focus(channelID) { onTypingChange?() }
        if let guildID = store.channel(channelID)?.guildId, !subscribedGuilds.contains(guildID) {
            subscribedGuilds.insert(guildID)
            gateway.subscribe(toGuild: guildID)
        }
        if store.messages(in: channelID) == nil {
            loadHistory(channelID: channelID, before: nil)
        }
        markRead(channelID: channelID)
    }

    /// Fetches the page of messages before the oldest one we have. Only ever called in response to scrolling.
    public func loadOlder(channelID: Snowflake) {
        guard !store.hasReachedStart(of: channelID), let oldest = store.messages(in: channelID)?.first?.id else { return }
        loadHistory(channelID: channelID, before: oldest)
    }

    public func isLoading(_ channelID: Snowflake) -> Bool { loading.contains(channelID) }

    /// Tells the channel we're typing: on the first keystroke, then at most every 8 seconds, since Discord shows
    /// it for about 10. Failures are ignored: a missed typing notice isn't worth interrupting anyone for.
    public func userIsTyping(in channelID: Snowflake) {
        let now = Date()
        if let last = lastTypingSent[channelID], now.timeIntervalSince(last) < 8 { return }
        lastTypingSent[channelID] = now
        Task { try? await rest.sendTyping(channelID: channelID) }
    }

    /// Sends a message, with `files` as its attachments.
    public func send(_ content: String, files: [UploadFile] = [], to channelID: Snowflake, completion: @escaping (Error?) -> Void) {
        // Sending ends our typing indicator on Discord's side; the next keystroke starts a fresh one.
        lastTypingSent[channelID] = nil
        // A snowflake-shaped nonce from the current time; clamped so a clock set before 2015 can't trap.
        let nonce = String(UInt64(max(0, Date().timeIntervalSince1970 * 1000 - 1_420_070_400_000)) << 22)
        Task { @MainActor in
            do {
                // The gateway echoes the message back as MESSAGE_CREATE, which adds it to the store.
                try await rest.sendMessage(content, to: channelID, nonce: nonce, files: files)
                completion(nil)
            } catch {
                reportIfUnreachable(error)
                completion(error)
            }
        }
    }

    /// Edits one of our messages (see RESTClient.editMessage). The change comes back over the gateway.
    public func edit(_ messageID: Snowflake, in channelID: Snowflake, content: String?, keepingAttachments: [Snowflake],
                     completion: @escaping (Error?) -> Void) {
        Task { @MainActor in
            do {
                try await rest.editMessage(messageID, in: channelID, content: content, keepingAttachments: keepingAttachments)
                completion(nil)
            } catch {
                reportIfUnreachable(error)
                completion(error)
            }
        }
    }

    public func delete(_ messageID: Snowflake, in channelID: Snowflake, completion: @escaping (Error?) -> Void) {
        Task { @MainActor in
            do {
                try await rest.deleteMessage(messageID, in: channelID)
                completion(nil)
            } catch {
                reportIfUnreachable(error)
                completion(error)
            }
        }
    }

    /// Marks a channel read now locally, and tells Discord shortly after so quick channel hopping costs one request.
    public func markRead(channelID: Snowflake) {
        guard let messageID = store.markRead(channelID) else { return }
        pendingAck[channelID] = messageID
        ackTimer?.invalidate()
        ackTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
            self?.flushAcks()
        }
    }

    /// "Mark as Read" on a server, or on Direct Messages with nil: one request for all of its channels.
    public func markAllRead(guildID: Snowflake?) {
        let acks = store.markAllRead(guildID: guildID)
        for ack in acks { pendingAck[ack.channelID] = nil }
        Task {
            // A few large requests rather than one per channel.
            for start in stride(from: 0, to: acks.count, by: 100) {
                try? await rest.ackBulk(Array(acks[start..<min(start + 100, acks.count)]))
            }
        }
    }

    private func flushAcks() {
        let acks = pendingAck
        pendingAck = [:]
        for (channelID, messageID) in acks {
            Task { try? await rest.ack(channelID: channelID, messageID: messageID) }
        }
    }

    private func loadHistory(channelID: Snowflake, before: Snowflake?) {
        guard !loading.contains(channelID) else { return }
        loading.insert(channelID)
        Task { @MainActor in
            defer { loading.remove(channelID) }
            do {
                let page = try await rest.messages(in: channelID, before: before, limit: Self.pageSize)
                store.addHistory(page, for: channelID, requestedLimit: Self.pageSize)
            } catch {
                reportIfUnreachable(error)
                #if DEBUG
                print("[rest] failed to load messages for \(channelID): \(error)")
                #endif
            }
        }
    }

    // MARK: - GatewayClientDelegate

    public func gateway(_ gateway: GatewayClient, didReceive event: GatewayEvent) {
        store.apply(event)
        switch event {
        case .ready(let ready):
            sessionID = ready.sessionId
            subscribedGuilds = []
            requestedMembers = []
            presenceRequests = [:]
            delegate?.sessionDidBecomeReady(self)
        case .typingStart(let event):
            guard event.userId != store.me?.id else { break }
            let user = event.member?.user ?? store.user(event.userId) ?? User(id: event.userId, username: "Someone")
            let name = event.member?.nick.flatMap { $0.isEmpty ? nil : $0 } ?? user.displayName
            if typing.typing(user, name: name, in: event.channelId, at: Date()) { onTypingChange?() }
        case .voiceStateUpdate(let state):
            if state.userId == store.me?.id { onOwnVoiceState?(state) }
        case .voiceServerUpdate(let update):
            onVoiceServer?(update)
        case .messageCreate(let message):
            if typing.messageArrived(from: message.author.id, in: message.channelId, at: Date()) { onTypingChange?() }
            if isActive, message.channelId == store.focusedChannelID {
                markRead(channelID: message.channelId)
            }
            if store.shouldNotify(message) {
                delegate?.session(self, shouldNotifyAbout: message)
            }
        default:
            break
        }
    }

    public func gateway(_ gateway: GatewayClient, didChangeState state: GatewayClient.State) {
        lastGatewayState = state
        delegate?.session(self, didChangeState: state)
    }
}

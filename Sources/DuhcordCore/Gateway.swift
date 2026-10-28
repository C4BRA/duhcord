import Foundation

public enum GatewayEvent {
    case ready(ReadyEvent)
    case resumed
    case guildCreate(Guild)
    case guildDelete(Snowflake)
    case channelCreate(Channel)
    case channelUpdate(Channel)
    case channelDelete(Channel)
    case messageCreate(Message)
    case messageUpdate(MessageUpdate)
    case messageDelete(MessageDelete)
    case messageAck(MessageAck)
    case channelUnreadUpdate(ChannelUnreadUpdate)
    case typingStart(TypingStart)
    case voiceStateUpdate(VoiceState)
    case voiceServerUpdate(VoiceServerUpdate)
    case guildMembersChunk(GuildMembersChunk)
    /// Someone's status or activities changed.
    case presenceUpdate(Presence)
}

public protocol GatewayClientDelegate: AnyObject {
    func gateway(_ gateway: GatewayClient, didReceive event: GatewayEvent)
    func gateway(_ gateway: GatewayClient, didChangeState state: GatewayClient.State)
}

/// The Discord gateway connection: a WebSocket that streams events to us.
///
/// All internal state lives on a private serial queue. Delegate callbacks are delivered on the main queue.
public final class GatewayClient: NSObject {
    public enum State: Equatable {
        case disconnected
        case connecting
        case connected
        /// A routine reconnect (Discord asked for one, or the socket dropped once). Happens silently.
        case reconnecting
        /// Couldn't reach Discord. Nothing happens until `retry()` is called.
        case unreachable
        /// The token was rejected. We will not reconnect.
        case authenticationFailed
        /// Discord closed the connection with a code that means reconnecting won't help.
        case closed(code: Int)
    }

    private enum Op {
        static let dispatch = 0
        static let heartbeat = 1
        static let identify = 2
        static let resume = 6
        static let reconnect = 7
        static let invalidSession = 9
        static let hello = 10
        static let heartbeatAck = 11
        static let voiceStateUpdate = 4
        static let requestGuildMembers = 8
        static let guildSubscriptionsBulk = 37
    }

    /// Close codes after which reconnecting is pointless.
    /// Cap on one decompressed message. The largest READY is tens of MB; this stops a decompression bomb.
    static let maxMessageSize = 128 * 1024 * 1024
    private static let fatalCloseCodes: Set<Int> = [4004, 4010, 4011, 4012, 4013, 4014]

    public weak var delegate: GatewayClientDelegate?

    private let token: String
    private let queue = DispatchQueue(label: "duhcord.gateway")
    private let decoder = makeDiscordDecoder()
    private let session = SecureSession.shared.session

    private var task: URLSessionWebSocketTask?
    /// Decompresses the current socket's stream; replaced with every new socket.
    private var inflater: ZlibStream?
    private var heartbeatTimer: DispatchSourceTimer?
    private var awaitingAck = false
    private var sequence: Int?
    private var sessionID: String?
    private var resumeURL: URL?
    /// Reconnects tried since the last successful READY/RESUMED. One silent attempt is allowed; after that we stop.
    private var reconnectAttempt = 0
    private var stopped = false

    /// Where to reconnect: the resume address while a session can be resumed, else the main gateway.
    private var reconnectURL: URL { (sessionID != nil ? resumeURL : nil) ?? ClientIdentity.gatewayURL }

    public init(token: String) {
        self.token = token
        super.init()
    }

    public func connect() {
        queue.async {
            self.stopped = false
            self.open(url: ClientIdentity.gatewayURL)
            self.publish(state: .connecting)
        }
    }

    /// Tries again after `unreachable`, resuming the previous session if Discord still has it.
    public func retry() {
        queue.async {
            guard !self.stopped else { return }
            self.reconnectAttempt = 0
            let url = self.reconnectURL
            self.open(url: url)
            self.publish(state: .connecting)
        }
    }

    public func disconnect() {
        queue.async {
            self.stopped = true
            self.teardown(closeCode: .normalClosure)
            self.sessionID = nil
            self.sequence = nil
            self.publish(state: .disconnected)
        }
    }

    /// Tells Discord we are looking at a guild so it sends us that guild's live events. Large guilds don't
    /// stream messages to user accounts until this is sent.
    ///
    /// Uses opcode 37 (bulk guild subscriptions), as the official client does; opcode 14 is deprecated.
    /// `typing` must be true or Discord ignores the subscription for very large guilds. Only the fields
    /// listed are changed on Discord's side; threads, activities and member updates stay off.
    public func subscribe(toGuild guildID: Snowflake) {
        let payload = Self.subscriptionPayload(guildID: guildID)
        queue.async { self.send(payload) }
    }

    /// Joins, moves between or (with a nil channel) leaves voice channels, and sets our mute and deafen.
    public func updateVoiceState(guildID: Snowflake, channelID: Snowflake?, selfMute: Bool, selfDeaf: Bool) {
        let payload: [String: Any] = [
            "op": Op.voiceStateUpdate,
            "d": [
                "guild_id": guildID,
                "channel_id": channelID.map { $0 as Any } ?? NSNull(),
                "self_mute": selfMute,
                "self_deaf": selfDeaf,
                "self_video": false,
            ] as [String: Any],
        ]
        queue.async { self.send(payload) }
    }

    /// Asks for specific members (at most 100), as the official client does to show names it hasn't seen.
    public func requestMembers(guildID: Snowflake, userIDs: [Snowflake], presences: Bool = false) {
        let payload: [String: Any] = [
            "op": Op.requestGuildMembers,
            "d": ["guild_id": guildID, "user_ids": Array(userIDs.prefix(100)), "presences": presences] as [String: Any],
        ]
        queue.async { self.send(payload) }
    }

    static func subscriptionPayload(guildID: Snowflake) -> [String: Any] {
        let options: [String: Any] = ["typing": true, "threads": false, "activities": false, "member_updates": false]
        return [
            "op": Op.guildSubscriptionsBulk,
            "d": ["subscriptions": [guildID: options]] as [String: Any],
        ]
    }

    // MARK: - Connection lifecycle

    private func open(url: URL) {
        teardown(closeCode: .goingAway)
        var request = URLRequest(url: url)
        request.setValue(ClientIdentity.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://discord.com", forHTTPHeaderField: "Origin")
        let task = session.webSocketTask(with: request)
        // READY for a user account can be several megabytes, even compressed.
        task.maximumMessageSize = 64 * 1024 * 1024
        inflater = ZlibStream(maxMessageSize: Self.maxMessageSize)
        self.task = task
        task.resume()
        receive(on: task)
    }

    private func teardown(closeCode: URLSessionWebSocketTask.CloseCode) {
        heartbeatTimer?.cancel()
        heartbeatTimer = nil
        awaitingAck = false
        task?.cancel(with: closeCode, reason: nil)
        task = nil
        inflater = nil
    }

    private func scheduleReconnect(closeCode: Int?) {
        guard !stopped else { return }
        if let closeCode {
            if Self.fatalCloseCodes.contains(closeCode) {
                stopped = true
                teardown(closeCode: .normalClosure)
                // 4004: the token was rejected.
                publish(state: closeCode == 4004 ? .authenticationFailed : .closed(code: closeCode))
                return
            }
            // These codes invalidate the session, so we must identify from scratch.
            if closeCode == 4007 || closeCode == 4009 {
                sessionID = nil
                sequence = nil
            }
        }

        teardown(closeCode: .goingAway)
        // Discord routinely asks clients to reconnect, so one quiet attempt is fine. If that attempt also fails
        // we can't reach Discord: stop and wait for the user to press Retry instead of retrying in the background.
        guard reconnectAttempt == 0 else {
            publish(state: .unreachable)
            return
        }
        reconnectAttempt += 1
        publish(state: .reconnecting)
        queue.asyncAfter(deadline: .now() + Double.random(in: 1...3)) { [weak self] in
            guard let self, !self.stopped, self.task == nil else { return }
            let url = self.reconnectURL
            self.open(url: url)
        }
    }

    // MARK: - Receiving

    private func receive(on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self else { return }
            self.queue.async {
                // Ignore callbacks from a socket we have already replaced.
                guard task === self.task else { return }
                switch result {
                case .success(let message):
                    switch message {
                    case .string(let text):
                        self.handle(Data(text.utf8))
                    case .data(let data):
                        // Compressed frames. A stream that fails to decompress can't be picked up mid-way,
                        // so drop the socket and resume on a fresh one.
                        do {
                            guard let inflater = self.inflater else { throw ZlibStream.Failure.corrupt }
                            if let message = try inflater.push(data) { self.handle(message) }
                        } catch {
                            #if DEBUG
                            print("[gateway] couldn't decompress: \(error)")
                            #endif
                            self.scheduleReconnect(closeCode: nil)
                            return
                        }
                    @unknown default:
                        break
                    }
                    self.receive(on: task)
                case .failure:
                    let code = task.closeCode == .invalid ? nil : task.closeCode.rawValue
                    self.scheduleReconnect(closeCode: code)
                }
            }
        }
    }

    /// One gateway frame, parsed once: op/s/t are read, then `d` is decoded as the type `t` calls for.
    /// Event types Duhcord doesn't use never have their `d` decoded.
    private struct Payload: Decodable {
        let op: Int
        let s: Int?
        let event: GatewayEvent?
        let heartbeatInterval: Double?
        let resumable: Bool?

        private enum Keys: String, CodingKey { case op, s, t, d }
        private struct Hello: Decodable { let heartbeatInterval: Double }
        private struct Deleted: Decodable { let id: Snowflake }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            // Locals rather than the properties, so the helper below doesn't capture self before init finishes.
            let opcode = try c.decode(Int.self, forKey: .op)
            op = opcode
            s = try c.decodeIfPresent(Int.self, forKey: .s)
            let type = try c.decodeIfPresent(String.self, forKey: .t)

            func d<T: Decodable>(_: T.Type) -> T? {
                do {
                    return try c.decode(T.self, forKey: .d)
                } catch {
                    #if DEBUG
                    print("[gateway] failed to decode \(type ?? "op \(opcode)"): \(error)")
                    #endif
                    return nil
                }
            }

            heartbeatInterval = opcode == Op.hello ? d(Hello.self)?.heartbeatInterval : nil
            resumable = opcode == Op.invalidSession ? d(Bool.self) : nil
            switch opcode == Op.dispatch ? (type ?? "") : "" {
            case "READY": event = d(ReadyEvent.self).map { .ready($0) }
            case "RESUMED": event = .resumed
            case "GUILD_CREATE": event = d(Guild.self).map { .guildCreate($0) }
            case "GUILD_DELETE": event = d(Deleted.self).map { .guildDelete($0.id) }
            case "CHANNEL_CREATE": event = d(Channel.self).map { .channelCreate($0) }
            case "CHANNEL_UPDATE": event = d(Channel.self).map { .channelUpdate($0) }
            case "CHANNEL_DELETE": event = d(Channel.self).map { .channelDelete($0) }
            case "MESSAGE_CREATE": event = d(Message.self).map { .messageCreate($0) }
            case "MESSAGE_UPDATE": event = d(MessageUpdate.self).map { .messageUpdate($0) }
            case "MESSAGE_DELETE": event = d(MessageDelete.self).map { .messageDelete($0) }
            case "MESSAGE_ACK": event = d(MessageAck.self).map { .messageAck($0) }
            case "TYPING_START": event = d(TypingStart.self).map { .typingStart($0) }
            case "CHANNEL_UNREAD_UPDATE": event = d(ChannelUnreadUpdate.self).map { .channelUnreadUpdate($0) }
            case "VOICE_STATE_UPDATE": event = d(VoiceState.self).map { .voiceStateUpdate($0) }
            case "VOICE_SERVER_UPDATE": event = d(VoiceServerUpdate.self).map { .voiceServerUpdate($0) }
            case "GUILD_MEMBERS_CHUNK": event = d(GuildMembersChunk.self).map { .guildMembersChunk($0) }
            case "PRESENCE_UPDATE": event = d(RawPresence.self).map { .presenceUpdate($0.presence) }
            default: event = nil
            }
        }
    }

    private func handle(_ data: Data) {
        guard let payload = try? decoder.decode(Payload.self, from: data) else { return }
        if let s = payload.s { sequence = s }

        switch payload.op {
        case Op.hello:
            guard let interval = payload.heartbeatInterval else { return }
            startHeartbeat(intervalMS: interval)
            if let sessionID, let sequence {
                sendResume(sessionID: sessionID, sequence: sequence)
            } else {
                sendIdentify()
            }
        case Op.heartbeat:
            sendHeartbeat()
        case Op.heartbeatAck:
            awaitingAck = false
        case Op.reconnect:
            // Discord itself asked, so it's reachable: this doesn't count against the one quiet attempt.
            reconnectAttempt = 0
            scheduleReconnect(closeCode: nil)
        case Op.invalidSession:
            if payload.resumable != true {
                sessionID = nil
                sequence = nil
            }
            reconnectAttempt = 0
            scheduleReconnect(closeCode: nil)
        case Op.dispatch:
            if let event = payload.event { dispatch(event) }
        default:
            break
        }
    }

    private func dispatch(_ event: GatewayEvent) {
        switch event {
        case .ready(let ready):
            sessionID = ready.sessionId
            // The resume URL comes from the server and our token is sent to it, so only accept Discord hosts.
            if let urlString = ready.resumeGatewayUrl, let url = URL(string: urlString + ClientIdentity.gatewayQuery),
               url.scheme == "wss", SecureSession.isAllowed(host: url.host) {
                resumeURL = url
            } else {
                resumeURL = nil
            }
            reconnectAttempt = 0
            publish(state: .connected)
        case .resumed:
            reconnectAttempt = 0
            publish(state: .connected)
        default:
            break
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.gateway(self, didReceive: event)
        }
    }

    // MARK: - Sending

    private func send(_ payload: [String: Any]) {
        guard let task,
              let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8) else { return }
        task.send(.string(text)) { _ in }
    }

    private func sendIdentify() {
        let payload: [String: Any] = [
            "op": Op.identify,
            "d": [
                "token": token,
                "properties": ClientIdentity.properties,
                "presence": [
                    "status": "online",
                    "since": 0,
                    "activities": [] as [Any],
                    "afk": false,
                ] as [String: Any],
                "compress": false,
            ] as [String: Any],
        ]
        send(payload)
    }

    private func sendResume(sessionID: String, sequence: Int) {
        send([
            "op": Op.resume,
            "d": ["token": token, "session_id": sessionID, "seq": sequence] as [String: Any],
        ])
    }

    private func sendHeartbeat() {
        let d: Any = sequence ?? NSNull()
        send(["op": Op.heartbeat, "d": d])
    }

    private func startHeartbeat(intervalMS: Double) {
        heartbeatTimer?.cancel()
        // Clamped: a nonsensical value from the server must not be able to trap the timer.
        let interval = min(max(intervalMS / 1000, 1), 300)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        // Discord asks for a random delay before the first heartbeat.
        timer.schedule(deadline: .now() + interval * Double.random(in: 0...1), repeating: interval)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            if self.awaitingAck {
                // No ack since the last beat: the connection is dead even if the socket hasn't noticed.
                self.scheduleReconnect(closeCode: nil)
                return
            }
            self.awaitingAck = true
            self.sendHeartbeat()
        }
        heartbeatTimer = timer
        timer.resume()
    }

    private func publish(state: State) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.gateway(self, didChangeState: state)
        }
    }
}

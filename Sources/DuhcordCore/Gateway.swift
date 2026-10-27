import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

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
        case reconnecting(attempt: Int)
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
        static let guildSubscriptions = 14
    }

    /// Close codes after which reconnecting is pointless.
    private static let fatalCloseCodes: Set<Int> = [4004, 4010, 4011, 4012, 4013, 4014]

    public weak var delegate: GatewayClientDelegate?

    private let token: String
    private let queue = DispatchQueue(label: "duhcord.gateway")
    private let decoder = makeDiscordDecoder()
    private let session = SecureSession.shared.session

    private var task: URLSessionWebSocketTask?
    private var heartbeatTimer: DispatchSourceTimer?
    private var awaitingAck = false
    private var sequence: Int?
    private var sessionID: String?
    private var resumeURL: URL?
    private var reconnectAttempt = 0
    private var stopped = false

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

    public func disconnect() {
        queue.async {
            self.stopped = true
            self.teardown(closeCode: .normalClosure)
            self.sessionID = nil
            self.sequence = nil
            self.publish(state: .disconnected)
        }
    }

    /// Tells Discord we are looking at a guild so it sends us that guild's live events.
    /// Large guilds don't stream messages to user accounts until this is sent.
    public func subscribe(toGuild guildID: Snowflake) {
        let payload: [String: Any] = [
            "op": Op.guildSubscriptions,
            "d": [
                "guild_id": guildID,
                "typing": false,
                "threads": false,
                "activities": false,
            ] as [String: Any],
        ]
        queue.async { self.send(payload) }
    }

    // MARK: - Connection lifecycle

    private func open(url: URL) {
        teardown(closeCode: .goingAway)
        var request = URLRequest(url: url)
        request.setValue(ClientIdentity.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://discord.com", forHTTPHeaderField: "Origin")
        let task = session.webSocketTask(with: request)
        // READY for a user account can be several megabytes.
        task.maximumMessageSize = 64 * 1024 * 1024
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
    }

    private func scheduleReconnect(closeCode: Int?) {
        guard !stopped else { return }
        if let closeCode {
            if closeCode == 4004 {
                stopped = true
                teardown(closeCode: .normalClosure)
                publish(state: .authenticationFailed)
                return
            }
            if Self.fatalCloseCodes.contains(closeCode) {
                stopped = true
                teardown(closeCode: .normalClosure)
                publish(state: .closed(code: closeCode))
                return
            }
            // These codes invalidate the session, so we must identify from scratch.
            if closeCode == 4007 || closeCode == 4009 {
                sessionID = nil
                sequence = nil
            }
        }

        teardown(closeCode: .goingAway)
        reconnectAttempt += 1
        publish(state: .reconnecting(attempt: reconnectAttempt))
        let delay = min(30.0, pow(2.0, Double(reconnectAttempt - 1))) + Double.random(in: 0...1)
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.stopped, self.task == nil else { return }
            let url = (self.sessionID != nil ? self.resumeURL : nil) ?? ClientIdentity.gatewayURL
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
                        self.handle(data)
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

    private struct Header: Decodable {
        let op: Int
        let s: Int?
        let t: String?
    }

    private struct Frame<D: Decodable>: Decodable {
        let d: D
    }

    private struct Hello: Decodable {
        let heartbeatInterval: Double
    }

    private func handle(_ data: Data) {
        guard let header = try? decoder.decode(Header.self, from: data) else { return }
        if let s = header.s { sequence = s }

        switch header.op {
        case Op.hello:
            guard let hello = try? decoder.decode(Frame<Hello>.self, from: data).d else { return }
            startHeartbeat(intervalMS: hello.heartbeatInterval)
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
            scheduleReconnect(closeCode: nil)
        case Op.invalidSession:
            let resumable = (try? decoder.decode(Frame<Bool>.self, from: data).d) ?? false
            if !resumable {
                sessionID = nil
                sequence = nil
            }
            scheduleReconnect(closeCode: nil)
        case Op.dispatch:
            if let t = header.t { dispatch(type: t, data: data) }
        default:
            break
        }
    }

    /// Decodes only the event types we use. Everything else is dropped after reading the header.
    private func dispatch(type: String, data: Data) {
        func decode<T: Decodable>(_: T.Type) -> T? {
            do {
                return try decoder.decode(Frame<T>.self, from: data).d
            } catch {
                #if DEBUG
                print("[gateway] failed to decode \(type): \(error)")
                #endif
                return nil
            }
        }

        let event: GatewayEvent?
        switch type {
        case "READY":
            if let ready = decode(ReadyEvent.self) {
                sessionID = ready.sessionId
                // The resume URL comes from the server and our token is sent to it, so only accept Discord hosts.
                if let urlString = ready.resumeGatewayUrl, let url = URL(string: urlString + "/?v=9&encoding=json"),
                   url.scheme == "wss", SecureSession.isAllowed(host: url.host) {
                    resumeURL = url
                } else {
                    resumeURL = nil
                }
                reconnectAttempt = 0
                publish(state: .connected)
                event = .ready(ready)
            } else {
                event = nil
            }
        case "RESUMED":
            reconnectAttempt = 0
            publish(state: .connected)
            event = .resumed
        case "GUILD_CREATE":
            event = decode(Guild.self).map { .guildCreate($0) }
        case "GUILD_DELETE":
            struct Deleted: Decodable { let id: Snowflake }
            event = decode(Deleted.self).map { .guildDelete($0.id) }
        case "CHANNEL_CREATE":
            event = decode(Channel.self).map { .channelCreate($0) }
        case "CHANNEL_UPDATE":
            event = decode(Channel.self).map { .channelUpdate($0) }
        case "CHANNEL_DELETE":
            event = decode(Channel.self).map { .channelDelete($0) }
        case "MESSAGE_CREATE":
            event = decode(Message.self).map { .messageCreate($0) }
        case "MESSAGE_UPDATE":
            event = decode(MessageUpdate.self).map { .messageUpdate($0) }
        case "MESSAGE_DELETE":
            event = decode(MessageDelete.self).map { .messageDelete($0) }
        case "MESSAGE_ACK":
            event = decode(MessageAck.self).map { .messageAck($0) }
        default:
            event = nil
        }

        guard let event else { return }
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
        let interval = intervalMS / 1000
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

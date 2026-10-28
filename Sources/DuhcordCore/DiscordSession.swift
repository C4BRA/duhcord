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
    private var lastTypingSent: [Snowflake: Date] = [:]

    private let gateway: GatewayClient
    private var loading: Set<Snowflake> = []
    private var subscribedGuilds: Set<Snowflake> = []
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
        guard Self.isConnectivityError(error) else { return }
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

    public func send(_ content: String, to channelID: Snowflake, completion: @escaping (Error?) -> Void) {
        // Sending ends our typing indicator on Discord's side; the next keystroke starts a fresh one.
        lastTypingSent[channelID] = nil
        // A snowflake-shaped nonce from the current time; clamped so a clock set before 2015 can't trap.
        let nonce = String(UInt64(max(0, Date().timeIntervalSince1970 * 1000 - 1_420_070_400_000)) << 22)
        Task { @MainActor in
            do {
                // The gateway echoes the message back as MESSAGE_CREATE, which adds it to the store.
                try await rest.sendMessage(content, to: channelID, nonce: nonce)
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
        case .ready:
            subscribedGuilds = []
            delegate?.sessionDidBecomeReady(self)
        case .typingStart(let event):
            guard event.userId != store.me?.id else { break }
            let user = event.member?.user ?? store.user(event.userId) ?? User(id: event.userId, username: "Someone")
            let name = event.member?.nick.flatMap { $0.isEmpty ? nil : $0 } ?? user.displayName
            if typing.typing(user, name: name, in: event.channelId, at: Date()) { onTypingChange?() }
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
        delegate?.session(self, didChangeState: state)
    }
}

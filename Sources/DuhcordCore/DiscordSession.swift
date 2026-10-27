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

    /// Switches the focused channel, loading its latest messages if they aren't cached.
    public func open(channelID: Snowflake) {
        store.focusedChannelID = channelID
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

    public func send(_ content: String, to channelID: Snowflake, completion: @escaping (Error?) -> Void) {
        let nonce = String(UInt64(Date().timeIntervalSince1970 * 1000 - 1_420_070_400_000) << 22)
        Task { @MainActor in
            do {
                // The gateway echoes the message back as MESSAGE_CREATE, which adds it to the store.
                try await rest.sendMessage(content, to: channelID, nonce: nonce)
                completion(nil)
            } catch {
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
        case .messageCreate(let message):
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

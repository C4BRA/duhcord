import CryptoKit
import Foundation

/// The private-messaging trust state machine, protocol v3 (spec/PROTOCOL.md §3, §6–§8).
///
/// One engine per account. It reads a DM's messages (handshakes and encrypted messages), decides which keys are
/// trusted and what state the DM is in, opens messages with the right warnings, and says which handshakes to send.
/// It never touches the network or the Keychain: `PrivateChatController` does that around it.
///
/// The Duhcord Private Companion runs the same rules (companion/crates/engine). The shared scenarios in
/// spec/scenarios drive both with the same scripts (`PrivateScenarioTests`), so the two apps decide identically. The
/// engine can play either kind of client (`Config`) so those scripts can simulate both sides.
///
/// Opening and sealing need HPKE (macOS 14); the rest works everywhere, so Duhcord can hold an engine on macOS 13.
public final class PrivateTrustEngine {
    public enum Trust: String, Codable, Sendable {
        case accepted, pending, rejected
    }

    /// One key of the other person.
    public struct PeerKey: Codable, Equatable, Sendable {
        public var key: Data
        public var added: Date
        public var trust: Trust
        public var client: PeerClient
        public var features: PeerFeatures
    }

    /// One of the user's own other installs (spec §7).
    public struct Device: Codable, Equatable, Sendable {
        public var key: Data
        public var added: Date
        public var trust: Trust
        public var client: PeerClient
    }

    /// The newest evidence of whether the other person has accepted our current key (spec §6 "Receipts").
    public struct Receipt: Codable, Equatable, Sendable {
        public var messageID: Snowflake
        public var hasOurKey: Bool
    }

    /// Everything kept per account (in the Keychain).
    public struct Directory: Codable, Sendable {
        public var people: [Snowflake: [PeerKey]] = [:]
        public var devices: [Device] = []
        public var consented: Set<Snowflake> = []
        public var privateChannels: Set<Snowflake> = []
        /// A hash of the safety number each person was verified with.
        public var verified: [Snowflake: Data] = [:]
        /// Which message first carried each salt (hex): a later one with the same salt is a copy.
        public var firstWithSalt: [String: Snowflake] = [:]
        /// People whose Companion keys are left out (spec §6 "Which keys count").
        public var companionExcluded: Set<Snowflake> = []
        public var receipts: [Snowflake: Receipt] = [:]
        /// DMs where our current key's handshake has been echoed back at least once (spec §3 rule 1).
        public var handshakeSent: Set<Snowflake> = []

        public init() {}

        private enum CodingKeys: String, CodingKey {
            case people, devices, consented, privateChannels, verified, firstWithSalt, companionExcluded, receipts,
                 handshakeSent
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            people = try c.decodeIfPresent([Snowflake: [PeerKey]].self, forKey: .people) ?? [:]
            devices = try c.decodeIfPresent([Device].self, forKey: .devices) ?? []
            consented = try c.decodeIfPresent(Set<Snowflake>.self, forKey: .consented) ?? []
            privateChannels = try c.decodeIfPresent(Set<Snowflake>.self, forKey: .privateChannels) ?? []
            verified = try c.decodeIfPresent([Snowflake: Data].self, forKey: .verified) ?? [:]
            firstWithSalt = try c.decodeIfPresent([String: Snowflake].self, forKey: .firstWithSalt) ?? [:]
            companionExcluded = try c.decodeIfPresent(Set<Snowflake>.self, forKey: .companionExcluded) ?? []
            receipts = try c.decodeIfPresent([Snowflake: Receipt].self, forKey: .receipts) ?? [:]
            handshakeSent = try c.decodeIfPresent(Set<Snowflake>.self, forKey: .handshakeSent) ?? []
        }
    }

    /// What kind of client this engine plays (spec §3 `client`, `host`, `features`).
    public struct Config: Sendable {
        public var client: PeerClient
        public var host: UInt8
        public var features: PeerFeatures
        /// Duhcord's "Private chat with Duhcord Companion" (spec §6). Always true for a Companion.
        public var allowCompanionChat: Bool

        public static func duhcord(allowCompanionChat: Bool) -> Config {
            Config(client: .duhcord, host: 0, features: .duhcord, allowCompanionChat: allowCompanionChat)
        }

        public static func companion(host: UInt8) -> Config {
            Config(client: .companion, host: host, features: [.text, .openImages], allowCompanionChat: true)
        }
    }

    /// A DM's private-messaging state (spec §6, the same in both clients and on the bridge).
    public enum State: String, Sendable {
        case off, request, waiting, unconfirmed, ready, outdated, locked
    }

    public struct Status: Equatable, Sendable {
        public var state: State
        public var verified: Bool
        public var newKey: Bool
        public var peerClient: PeerClient?
        /// The composer is enabled only when ready (spec §6, §11 decision 2).
        public var canSend: Bool { state == .ready }
    }

    /// A warning line under a private message (spec §6).
    public enum Warning: Equatable, Sendable {
        case untrustedSender
        case unapprovedDevice
        case copy
        case writtenEarlier(Date)

        public var code: String {
            switch self {
            case .untrustedSender: return "untrusted-sender"
            case .unapprovedDevice: return "unapproved-device"
            case .copy: return "copy"
            case .writtenEarlier: return "written-earlier"
            }
        }
    }

    /// A Discord message as the engine reads it.
    public struct Message: Sendable {
        public var id: Snowflake
        public var authorID: Snowflake
        public var content: String
        /// When its current content appeared: the edit time if edited, else nil (the snowflake time is used).
        public var editedAt: Date?

        public init(id: Snowflake, authorID: Snowflake, content: String, editedAt: Date? = nil) {
            self.id = id
            self.authorID = authorID
            self.content = content
            self.editedAt = editedAt
        }
    }

    /// A private message as opened.
    @available(macOS 14, *)
    public struct Opened: Sendable {
        public var message: PrivateCrypto.Opened
        /// The key it opened with: theirs, ours, or one of our devices.
        public var senderKey: Data
        public var fromMe: Bool
        public var trusted: Bool
        public var warnings: [Warning]
    }

    /// A handshake the caller must post in a DM.
    public struct Outgoing: Equatable, Sendable {
        public var channelID: Snowflake
        public var content: String
    }

    public enum SendError: Error, Equatable {
        case notReady
        case tooManyRecipients
    }

    public enum AcceptError: Error, Equatable {
        case nothingPending
        case mismatch
    }

    public static let maxPendingKeys = 4
    public static let maxApprovedDevices = 3
    static let replayTolerance: TimeInterval = 10 * 60

    private struct ChannelState {
        var lastOwnHandshake: Snowflake?
        var inFlight = false
        /// A handshake to send once the in-flight one is echoed (its `wantsReply`).
        var followup: Bool?
        var unansweredRequest: Snowflake?
        /// Their newest handshake, and whether it was from a newer protocol version.
        var newestPeerHandshake: (id: Snowflake, outdated: Bool)?
        var seen: Set<Snowflake> = []
    }

    public let userID: Snowflake
    private let privateKey: Curve25519.KeyAgreement.PrivateKey
    public private(set) var directory: Directory
    public private(set) var config: Config
    /// The directory changed since it was last saved.
    public var isDirty = false
    public var locked = false
    /// Fixes "now" (simulations and tests); nil uses the system clock.
    public var clock: Date?

    private var peers: [Snowflake: Snowflake] = [:]
    private var messages: [Snowflake: [Snowflake: Message]] = [:]
    private var requests: Set<Snowflake> = []
    private var channels: [Snowflake: ChannelState] = [:]
    /// Opened messages (`Opened?`, stored untyped because `Opened` needs macOS 14).
    private var openedCache: [Snowflake: (generation: Int, content: String, value: Any?)] = [:]
    private var generation = 0

    public init(privateKey: Curve25519.KeyAgreement.PrivateKey, userID: Snowflake, directory: Directory = Directory(),
                config: Config) {
        self.privateKey = privateKey
        self.userID = userID
        self.directory = directory
        self.config = config
    }

    public var publicKey: Data { privateKey.publicKey.rawRepresentation }

    private var now: Date { clock ?? Date() }

    // MARK: - DMs and keys

    /// A one-to-one DM with `peerID`. Group DMs and servers are never private.
    public func setDM(channelID: Snowflake, peerID: Snowflake) {
        guard peerID != userID else { return }
        peers[channelID] = peerID
    }

    public func peer(in channelID: Snowflake) -> Snowflake? { peers[channelID] }

    public func peerKeys(in channelID: Snowflake) -> [PeerKey] {
        peers[channelID].flatMap { directory.people[$0] } ?? []
    }

    public func pendingKeys(in channelID: Snowflake) -> [PeerKey] {
        peerKeys(in: channelID).filter { $0.trust == .pending }
    }

    /// Accepted, but left out because it's a Companion key the user (or Duhcord's setting) excludes.
    public func excluded(_ key: PeerKey, peerID: Snowflake) -> Bool {
        key.client == .companion && (directory.companionExcluded.contains(peerID) || !config.allowCompanionChat)
    }

    /// Whether this key of theirs counts (spec §6): accepted and not excluded.
    public func counts(_ key: PeerKey, peerID: Snowflake) -> Bool {
        key.trust == .accepted && !excluded(key, peerID: peerID)
    }

    public func countedKeys(in channelID: Snowflake) -> [PeerKey] {
        guard let peerID = peers[channelID] else { return [] }
        return countedKeys(of: peerID)
    }

    private func countedKeys(of peerID: Snowflake) -> [PeerKey] {
        (directory.people[peerID] ?? []).filter { counts($0, peerID: peerID) }
    }

    private func countedKeySet(of peerID: Snowflake) -> [Data] {
        countedKeys(of: peerID).map(\.key).sorted(by: { $0.lexicographicallyPrecedes($1) })
    }

    public func companionExcluded(in channelID: Snowflake) -> Bool {
        peers[channelID].map { directory.companionExcluded.contains($0) } ?? false
    }

    /// The receipt (spec §6): whether the other person has accepted our current key.
    public func hasOurKey(in channelID: Snowflake) -> Bool {
        peers[channelID].flatMap { directory.receipts[$0]?.hasOurKey } ?? false
    }

    public var devices: [Device] { directory.devices }

    /// Their newest handshake is from a newer protocol version (the `outdated` state, even outside Private).
    public func peerUsesNewerVersion(in channelID: Snowflake) -> Bool {
        channels[channelID]?.newestPeerHandshake?.outdated ?? false
    }

    public func status(for channelID: Snowflake) -> Status {
        guard let peerID = peers[channelID] else {
            return Status(state: .off, verified: false, newKey: false, peerClient: nil)
        }
        let counted = countedKeys(of: peerID)
        let pending = pendingKeys(in: channelID)
        let peerClient: PeerClient? = (counted + pending).contains(where: { $0.client == .companion }) ? .companion
            : (counted.isEmpty && pending.isEmpty ? nil : .duhcord)
        let verified = safetyNumber(for: channelID).map { directory.verified[peerID] == Self.fingerprint($0) } ?? false
        let outdated = channels[channelID]?.newestPeerHandshake?.outdated ?? false
        let state: State
        if locked {
            state = .locked
        } else if requests.contains(peerID) {
            state = .request
        } else if !directory.privateChannels.contains(channelID) {
            state = .off
        } else if outdated {
            state = .outdated
        } else if counted.isEmpty {
            state = .waiting
        } else if !hasOurKey(in: channelID) {
            state = .unconfirmed
        } else {
            state = .ready
        }
        return Status(state: state, verified: verified, newKey: !pending.isEmpty, peerClient: peerClient)
    }

    /// Our side of the safety number: this install and our approved devices, each with its client.
    public var ourSide: [(key: Data, client: PeerClient)] {
        [(key: publicKey, client: config.client)]
            + directory.devices.filter { $0.trust == .accepted }.map { (key: $0.key, client: $0.client) }
    }

    /// The safety number (spec §8), optionally as it would be with `accepting` (pending keys) counted too.
    public func safetyNumber(for channelID: Snowflake, accepting: [Data] = []) -> String? {
        guard let peerID = peers[channelID], let known = directory.people[peerID] else { return nil }
        var theirs = countedKeys(of: peerID).map { (key: $0.key, client: $0.client) }
        for key in accepting {
            if let peerKey = known.first(where: { $0.key == key && $0.trust == .pending }),
               !theirs.contains(where: { $0.key == key }) {
                theirs.append((key: peerKey.key, client: peerKey.client))
            }
        }
        guard !theirs.isEmpty else { return nil }
        return PrivateMessaging.safetyNumber(ourSide, theirs)
    }

    // MARK: - Reading Discord

    /// Reads a DM's loaded messages (any order, any overlap with earlier calls). Returns the handshakes to send and
    /// whether anything the UI shows changed.
    public func read(channelID: Snowflake, messages incoming: [Message]) -> (sends: [Outgoing], changed: Bool) {
        guard let peerID = peers[channelID] else { return ([], false) }
        var sends: [Outgoing] = []
        var changed = false
        let countedBefore = countedKeySet(of: peerID)
        let ownID = PrivateMessaging.keyID(publicKey)
        var state = channels[channelID] ?? ChannelState()

        for message in incoming.sorted(by: { $0.id.snowflakeValue < $1.id.snowflakeValue }) {
            guard state.seen.insert(message.id).inserted else { continue }
            let fromMe = message.authorID == userID
            let fromPeer = message.authorID == peerID
            switch PrivateMessaging.kind(of: message.content) {
            case .handshake(let handshake) where fromMe:
                if handshake.key == publicKey {
                    if state.lastOwnHandshake.map({ $0.snowflakeValue < message.id.snowflakeValue }) ?? true {
                        state.lastOwnHandshake = message.id
                        if let request = state.unansweredRequest, request.snowflakeValue < message.id.snowflakeValue {
                            state.unansweredRequest = nil
                        }
                    }
                    state.inFlight = false
                    if directory.handshakeSent.insert(channelID).inserted { isDirty = true }
                    if let wantsReply = state.followup {
                        state.followup = nil
                        channels[channelID] = state
                        sends += sendHandshake(in: channelID, wantsReply: wantsReply)
                        state = channels[channelID] ?? state
                    }
                } else if learnDevice(handshake) {
                    changed = true
                }
            case .handshake(let handshake) where fromPeer:
                if learnPeerKey(handshake, peerID: peerID) { changed = true }
                if state.newestPeerHandshake.map({ $0.id.snowflakeValue < message.id.snowflakeValue }) ?? true {
                    state.newestPeerHandshake = (message.id, false)
                }
                if handshake.wantsReply,
                   state.lastOwnHandshake.map({ $0.snowflakeValue < message.id.snowflakeValue }) ?? true {
                    state.unansweredRequest = message.id
                }
                if recordReceipt(peerID: peerID, messageID: message.id, hasOurKey: handshake.acceptedKeyIDs.contains(ownID)) {
                    changed = true
                }
            case .newerHandshake where fromPeer:
                if state.newestPeerHandshake.map({ $0.id.snowflakeValue < message.id.snowflakeValue }) ?? true {
                    state.newestPeerHandshake = (message.id, true)
                    changed = true
                }
            case .encrypted where fromMe || fromPeer:
                messages[channelID, default: [:]][message.id] = message
            default:
                break
            }
        }
        channels[channelID] = state

        // An open request: answer it if the user agreed, else show it (rule 2). And if the keys of theirs we count
        // changed, tell them (rule 3). One handshake covers both.
        let countedChanged = countedKeySet(of: peerID) != countedBefore
        if countedChanged { generation += 1 }
        var answer = false
        if channels[channelID]?.unansweredRequest != nil {
            if directory.consented.contains(peerID), !locked {
                answer = true
                channels[channelID]?.unansweredRequest = nil
            } else if requests.insert(peerID).inserted {
                changed = true
            }
        } else if requests.remove(peerID) != nil {
            changed = true
        }
        let tell = countedChanged && directory.privateChannels.contains(channelID) && !locked
        if answer || tell { sends += queueHandshake(in: channelID, wantsReply: false) }
        if #available(macOS 14, *), scanReceipts(in: channelID) { changed = true }
        if changed || countedChanged { isDirty = true }
        return (sends, changed || countedChanged || !sends.isEmpty)
    }

    /// Our handshake couldn't be posted: it's no longer in flight.
    public func handshakeSendFailed(in channelID: Snowflake) {
        channels[channelID]?.inFlight = false
    }

    // MARK: - User actions

    /// Switches the DM to Private (agreeing to a request): spec §3 rule 1.
    public func agree(in channelID: Snowflake) -> [Outgoing] {
        guard let peerID = peers[channelID], !locked else { return [] }
        let firstConsent = directory.consented.insert(peerID).inserted
        let firstPrivate = directory.privateChannels.insert(channelID).inserted
        requests.remove(peerID)
        channels[channelID]?.unansweredRequest = nil
        if firstConsent || firstPrivate { isDirty = true }
        let haveTheirs = !countedKeys(of: peerID).isEmpty
        if !directory.handshakeSent.contains(channelID) || !haveTheirs {
            return queueHandshake(in: channelID, wantsReply: !haveTheirs)
        }
        return []
    }

    public func setPrivate(_ enabled: Bool, in channelID: Snowflake) -> [Outgoing] {
        if enabled { return agree(in: channelID) }
        if directory.privateChannels.remove(channelID) != nil { isDirty = true }
        return []
    }

    /// "Re-send my key" (rule 4). Always goes out, even with a handshake still in flight.
    public func resendKey(in channelID: Snowflake) -> [Outgoing] {
        guard peers[channelID] != nil, !locked else { return [] }
        return sendHandshake(in: channelID, wantsReply: true)
    }

    /// Accepts exactly the pending `keys` shown. With `compared`, it must equal the safety number shown with them
    /// (and the DM becomes verified); otherwise nothing changes.
    public func accept(_ keys: [Data], in channelID: Snowflake, compared: String?) -> Result<[Outgoing], AcceptError> {
        guard let peerID = peers[channelID] else { return .failure(.nothingPending) }
        let shown = pendingKeys(in: channelID).map(\.key).filter { keys.contains($0) }
        guard !shown.isEmpty else { return .failure(.nothingPending) }
        if let compared, safetyNumber(for: channelID, accepting: shown) != compared { return .failure(.mismatch) }
        var list = directory.people[peerID] ?? []
        for index in list.indices where list[index].trust == .pending && shown.contains(list[index].key) {
            list[index].trust = .accepted
        }
        directory.people[peerID] = list
        directory.verified[peerID] = nil
        isDirty = true
        generation += 1
        if compared != nil { _ = markVerified(in: channelID) }
        return .success(acceptanceChanged(in: channelID))
    }

    public func reject(_ keys: [Data], in channelID: Snowflake) -> [Outgoing] {
        guard let peerID = peers[channelID], var list = directory.people[peerID] else { return [] }
        var changed = false
        for index in list.indices where list[index].trust == .pending && keys.contains(list[index].key) {
            list[index].trust = .rejected
            changed = true
        }
        guard changed else { return [] }
        directory.people[peerID] = list
        directory.verified[peerID] = nil
        isDirty = true
        generation += 1
        return acceptanceChanged(in: channelID)
    }

    public func setCompanionExcluded(_ excluded: Bool, in channelID: Snowflake) -> [Outgoing] {
        guard let peerID = peers[channelID] else { return [] }
        let changed = excluded ? directory.companionExcluded.insert(peerID).inserted
            : directory.companionExcluded.remove(peerID) != nil
        guard changed else { return [] }
        isDirty = true
        generation += 1
        return acceptanceChanged(in: channelID)
    }

    /// Duhcord's setting. Changing it is an acceptance change in every DM (rule 3).
    public func setAllowCompanionChat(_ allowed: Bool) -> [Outgoing] {
        guard config.allowCompanionChat != allowed else { return [] }
        config.allowCompanionChat = allowed
        generation += 1
        return peers.keys.sorted().flatMap { acceptanceChanged(in: $0) }
    }

    /// The user confirms the current safety number.
    @discardableResult
    public func markVerified(in channelID: Snowflake) -> Bool {
        guard let peerID = peers[channelID], let number = safetyNumber(for: channelID) else { return false }
        directory.verified[peerID] = Self.fingerprint(number)
        isDirty = true
        return true
    }

    /// Approves or denies one of our own other devices (spec §7). At most 3 approved.
    @discardableResult
    public func setDevice(_ key: Data, trust: Trust) -> Bool {
        guard trust != .pending, let index = directory.devices.firstIndex(where: { $0.key == key }),
              directory.devices[index].trust != trust else { return false }
        if trust == .accepted,
           directory.devices.filter({ $0.trust == .accepted && $0.key != key }).count >= Self.maxApprovedDevices {
            return false
        }
        directory.devices[index].trust = trust
        directory.verified = [:]
        isDirty = true
        generation += 1
        if #available(macOS 14, *) {
            for channelID in peers.keys { _ = scanReceipts(in: channelID) }
        }
        return true
    }

    public var canApproveAnotherDevice: Bool {
        directory.devices.filter { $0.trust == .accepted }.count < Self.maxApprovedDevices
    }

    /// The keys a message we seal now goes to, besides our own: their counted keys and our approved devices. Only
    /// in `ready`, and never more than 8 (spec §4, §6).
    public func recipients(in channelID: Snowflake) throws -> [Data] {
        guard status(for: channelID).canSend, let peerID = peers[channelID] else { throw SendError.notReady }
        var keys: [Data] = []
        for key in countedKeys(of: peerID).map(\.key) + directory.devices.filter({ $0.trust == .accepted }).map(\.key)
        where key != publicKey && !keys.contains(key) {
            keys.append(key)
        }
        guard keys.count <= PrivateMessaging.maxRecipients else { throw SendError.tooManyRecipients }
        return keys
    }

    /// Seals text (and files) typed by the user.
    @available(macOS 14, *)
    public func seal(_ text: String, files: [PrivateFile] = [], in channelID: Snowflake) throws -> String {
        let keys = try recipients(in: channelID)
        let recipients = keys.compactMap { try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: $0) }
        return try PrivateCrypto.seal(text, files: files, channelID: channelID, sender: privateKey,
                                      recipients: recipients + [privateKey.publicKey], now: now)
    }

    // MARK: - Opening

    /// Opens a private message in this DM: with counted senders first, then pending ones (with a warning), and
    /// with the replay checks (spec §6). Nil if it isn't one, or rejected/excluded keys sent it, or it can't be read.
    @available(macOS 14, *)
    public func open(_ message: Message, in channelID: Snowflake) -> Opened? {
        if let cached = openedCache[message.id], cached.content == message.content, cached.generation == generation {
            return cached.value as? Opened
        }
        let value = openUncached(message, in: channelID)
        if openedCache.count > 4000 { openedCache = [:] }
        openedCache[message.id] = (generation, message.content, value)
        return value
    }

    @available(macOS 14, *)
    private func openUncached(_ message: Message, in channelID: Snowflake) -> Opened? {
        guard let peerID = peers[channelID], case .encrypted(let payload) = PrivateMessaging.kind(of: message.content)
        else { return nil }
        let fromMe = message.authorID == userID
        guard fromMe || message.authorID == peerID else { return nil }
        let ownID = PrivateMessaging.keyID(publicKey)
        let senderID = Data(payload[2..<6])
        let keys = directory.people[peerID] ?? []
        let trusted = fromMe ? directory.devices.filter { $0.trust == .accepted }.map(\.key)
            : keys.filter { counts($0, peerID: peerID) }.map(\.key)
        let untrusted = fromMe ? directory.devices.filter { $0.trust == .pending }.map(\.key)
            : keys.filter { $0.trust == .pending }.map(\.key)

        var result: (opened: PrivateCrypto.Opened, sender: Data, trusted: Bool)?
        if fromMe, senderID == ownID,
           let opened = PrivateCrypto.open(payload, channelID: channelID, recipient: privateKey, senders: [],
                                           fromSelf: true) {
            result = (opened, publicKey, true)
        }
        if result == nil, let found = openWith(payload, channelID: channelID, senders: trusted) {
            result = (found.opened, found.sender, true)
        }
        if result == nil, let found = openWith(payload, channelID: channelID, senders: untrusted) {
            result = (found.opened, found.sender, false)
        }
        guard let result else { return nil }

        var warnings: [Warning] = []
        if !result.trusted { warnings.append(fromMe ? .unapprovedDevice : .untrustedSender) }
        let saltKey = result.opened.salt.map { String(format: "%02x", $0) }.joined()
        var copy = false
        if let first = directory.firstWithSalt[saltKey], first.snowflakeValue < message.id.snowflakeValue {
            copy = true
        } else if directory.firstWithSalt[saltKey] != message.id {
            if let later = directory.firstWithSalt[saltKey] { openedCache[later] = nil }
            directory.firstWithSalt[saltKey] = message.id
            isDirty = true
        }
        if copy {
            warnings.append(.copy)
        } else {
            let posted = message.editedAt ?? Self.date(of: message.id)
            if abs(posted.timeIntervalSince(result.opened.sentAt)) > Self.replayTolerance {
                warnings.append(.writtenEarlier(result.opened.sentAt))
            }
        }
        return Opened(message: result.opened, senderKey: result.sender, fromMe: fromMe, trusted: result.trusted,
                      warnings: warnings)
    }

    @available(macOS 14, *)
    private func openWith(_ payload: Data, channelID: Snowflake,
                          senders: [Data]) -> (opened: PrivateCrypto.Opened, sender: Data)? {
        for sender in senders {
            guard let key = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: sender),
                  let opened = PrivateCrypto.open(payload, channelID: channelID, recipient: privateKey,
                                                  senders: [key], fromSelf: false) else { continue }
            return (opened, sender)
        }
        return nil
    }

    /// The private messages read in this DM, opened, oldest first.
    @available(macOS 14, *)
    public func openedMessages(in channelID: Snowflake) -> [(message: Message, opened: Opened)] {
        (messages[channelID] ?? [:]).values
            .sorted(by: { $0.id.snowflakeValue < $1.id.snowflakeValue })
            .compactMap { message in open(message, in: channelID).map { (message, $0) } }
    }

    // MARK: - Internals

    /// After the keys of theirs we count changed: tell them (rule 3), if the DM is in Private.
    private func acceptanceChanged(in channelID: Snowflake) -> [Outgoing] {
        if #available(macOS 14, *) { _ = scanReceipts(in: channelID) }
        guard directory.privateChannels.contains(channelID), !locked else { return [] }
        return queueHandshake(in: channelID, wantsReply: false)
    }

    /// Sends a handshake now, or once the in-flight one is echoed (one in flight per DM).
    private func queueHandshake(in channelID: Snowflake, wantsReply: Bool) -> [Outgoing] {
        var state = channels[channelID] ?? ChannelState()
        if state.inFlight {
            state.followup = (state.followup ?? false) || wantsReply
            channels[channelID] = state
            return []
        }
        channels[channelID] = state
        return sendHandshake(in: channelID, wantsReply: wantsReply)
    }

    private func sendHandshake(in channelID: Snowflake, wantsReply: Bool) -> [Outgoing] {
        guard let peerID = peers[channelID] else { return [] }
        let ids = Array(Set(countedKeys(of: peerID).map { PrivateMessaging.keyID($0.key) })
            .sorted(by: { $0.lexicographicallyPrecedes($1) }).prefix(PrivateMessaging.maxAcceptedKeyIDs))
        let content = PrivateMessaging.handshake(PrivateHandshake(
            key: publicKey, wantsReply: wantsReply, client: config.client, host: config.host,
            features: config.features, acceptedKeyIDs: ids))
        var state = channels[channelID] ?? ChannelState()
        state.inFlight = true
        state.followup = nil
        channels[channelID] = state
        return [Outgoing(channelID: channelID, content: content)]
    }

    /// Records evidence about whether they have our key, if newer than what we had. True if it changed.
    private func recordReceipt(peerID: Snowflake, messageID: Snowflake, hasOurKey: Bool) -> Bool {
        let existing = directory.receipts[peerID]
        if let existing, existing.messageID.snowflakeValue >= messageID.snowflakeValue { return false }
        directory.receipts[peerID] = Receipt(messageID: messageID, hasOurKey: hasOurKey)
        isDirty = true
        return existing?.hasOurKey != hasOurKey
    }

    /// Trusted messages of theirs that include our key are receipts too. Only messages newer than the current
    /// receipt can change it.
    @available(macOS 14, *)
    private func scanReceipts(in channelID: Snowflake) -> Bool {
        guard let peerID = peers[channelID] else { return false }
        let ownID = PrivateMessaging.keyID(publicKey)
        let since = directory.receipts[peerID]?.messageID.snowflakeValue ?? 0
        var changed = false
        let candidates = (messages[channelID] ?? [:]).values
            .filter { $0.authorID == peerID && $0.id.snowflakeValue > since }
            .sorted(by: { $0.id.snowflakeValue < $1.id.snowflakeValue })
        for message in candidates {
            guard let opened = open(message, in: channelID), opened.trusted,
                  opened.message.recipientKeyIDs.contains(ownID) else { continue }
            if recordReceipt(peerID: peerID, messageID: message.id, hasOurKey: true) { changed = true }
        }
        return changed
    }

    /// A key from the other person's handshake (spec §6 "Learning a key").
    private func learnPeerKey(_ handshake: PrivateHandshake, peerID: Snowflake) -> Bool {
        guard Self.isValid(handshake.key) else { return false }
        var list = directory.people[peerID] ?? []
        if let index = list.firstIndex(where: { $0.key == handshake.key }) {
            var changed = false
            // A Duhcord key now claiming to be a Companion needs its own approval. A Companion key claiming Duhcord
            // changes nothing: a key never gains Duhcord's label.
            if list[index].client == .duhcord, handshake.client == .companion {
                list[index].client = .companion
                if list[index].trust == .accepted { list[index].trust = .pending }
                directory.verified[peerID] = nil
                changed = true
            }
            if list[index].features != handshake.features {
                list[index].features = handshake.features
                changed = true
            }
            if changed {
                directory.people[peerID] = list
                isDirty = true
                generation += 1
            }
            return changed
        }
        let trust: Trust = list.isEmpty && handshake.client == .duhcord ? .accepted : .pending
        if trust == .pending, list.filter({ $0.trust == .pending }).count >= Self.maxPendingKeys { return false }
        list.append(PeerKey(key: handshake.key, added: now, trust: trust, client: handshake.client,
                            features: handshake.features))
        directory.people[peerID] = list
        directory.verified[peerID] = nil
        isDirty = true
        generation += 1
        return true
    }

    /// Our own handshake with another key: a candidate device (spec §7).
    private func learnDevice(_ handshake: PrivateHandshake) -> Bool {
        guard Self.isValid(handshake.key), !directory.devices.contains(where: { $0.key == handshake.key }),
              directory.devices.filter({ $0.trust == .pending }).count < Self.maxPendingKeys else { return false }
        directory.devices.append(Device(key: handshake.key, added: now, trust: .pending, client: handshake.client))
        isDirty = true
        return true
    }

    static func fingerprint(_ safetyNumber: String) -> Data {
        Data(SHA256.hash(data: Data(safetyNumber.utf8)))
    }

    /// When a message was sent, from its ID.
    public static func date(of id: Snowflake) -> Date {
        Date(timeIntervalSince1970: TimeInterval((id.snowflakeValue >> 22) + 1_420_070_400_000) / 1000)
    }

    /// A usable X25519 public key: 32 bytes and contributory (not a low-order point).
    static func isValid(_ key: Data) -> Bool {
        guard let publicKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: key),
              let probe = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: 0x42, count: 32)),
              let shared = try? probe.sharedSecretFromKeyAgreement(with: publicKey) else { return false }
        return shared.withUnsafeBytes { bytes in bytes.contains(where: { $0 != 0 }) }
    }
}

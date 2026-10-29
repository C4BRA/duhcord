import AppKit
import CryptoKit
import DuhcordCore

/// Private messaging in DMs (see PrivateMessaging for the cryptography).
///
/// - Every Duhcord install has one key pair, made the first time it's needed and kept in the login keychain.
/// - Keys reach the other person in a handshake message. Their Duhcord picks it up from the DM, and answers with
///   its own once its user has agreed to chat privately with them (by switching the DM to Private, or accepting
///   the request). After that, handshakes between the two are answered automatically.
/// - Keys learned from handshakes are kept in the keychain too, marked verified once the safety numbers matched.
///   A new key for someone who was verified is flagged, since that's what an interception would look like.
/// - Private messages are sealed to the other person's keys and to ours (so we can read what we sent).
///
/// Main thread only. Private messaging needs macOS 14 (HPKE); on macOS 13 the toggle stays switched off.
final class PrivateChatController {
    enum Mode { case standard, `private` }

    enum Status: Equatable {
        /// macOS 13, a server channel or a group DM.
        case unavailable
        /// Switched to Private, but the other person's key hasn't arrived.
        case waiting
        case ready(verified: Bool, keyChanged: Bool)
    }

    /// Something about a DM's private chat changed (a key arrived, a mode switched): nil for every DM.
    var onChange: ((Snowflake?) -> Void)?

    static var isSupported: Bool {
        if #available(macOS 14, *) { return true }
        return false
    }

    private struct PeerKey: Codable {
        var key: Data
        var verified: Bool
        var added: Date
    }

    /// What's kept in the keychain besides our private key: everyone's public keys, who we agreed to chat with,
    /// and which DMs are in Private (so a relaunch doesn't quietly switch a DM back to unencrypted messages).
    private struct Directory: Codable {
        var people: [Snowflake: [PeerKey]] = [:]
        /// Our own other Duhcord installs (other Macs), so they can read what we send too.
        var ownDevices: [Data] = []
        var consented: Set<Snowflake> = []
        var keyChanged: Set<Snowflake> = []
        var privateChannels: Set<Snowflake> = []

        init() {}

        // Fields added later are optional when reading, so an older directory keeps its keys.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            people = try c.decodeIfPresent([Snowflake: [PeerKey]].self, forKey: .people) ?? [:]
            ownDevices = try c.decodeIfPresent([Data].self, forKey: .ownDevices) ?? []
            consented = try c.decodeIfPresent(Set<Snowflake>.self, forKey: .consented) ?? []
            keyChanged = try c.decodeIfPresent(Set<Snowflake>.self, forKey: .keyChanged) ?? []
            privateChannels = try c.decodeIfPresent(Set<Snowflake>.self, forKey: .privateChannels) ?? []
        }
    }

    /// Where the handshake scan of a DM got to, so a new message is read on its own instead of the whole history.
    private struct ScanState {
        var oldest: Snowflake
        var newest: Snowflake
        var lastOwnHandshake: Snowflake?
        var unansweredRequest = false
    }

    private static let keyService = "com.duhcord.private-key"
    private static let directoryService = "com.duhcord.private-directory"
    private static let maxKeysPerPerson = 4

    private let session: DiscordSession
    private var store: Store { session.store }
    private var directory = Directory()
    private var scans: [Snowflake: ScanState] = [:]
    /// Which message first carried each private message's salt: a later one with the same salt is a copy.
    private var firstWithSalt: [Data: Snowflake] = [:]
    private var loadedFor: Snowflake?
    private var privateKey: Curve25519.KeyAgreement.PrivateKey?
    /// Decrypted text by message ID (nil: couldn't be read). Cleared when keys change.
    private var plaintexts: [Snowflake: String?] = [:]
    private var seenHandshakes: Set<Snowflake> = []
    /// People who sent a handshake we haven't agreed to yet.
    private(set) var requests: Set<Snowflake> = []
    /// Handshakes we've sent that Discord hasn't echoed back yet, by channel, so a request isn't answered twice.
    private var pendingHandshakes: [Snowflake: Date] = [:]

    init(session: DiscordSession) {
        self.session = session
    }

    // MARK: - Keys

    /// Loads (or, with `create`, makes) our key and the directory for the logged-in account.
    private func loadIfNeeded(create: Bool = false) -> Curve25519.KeyAgreement.PrivateKey? {
        guard let me = store.me?.id else { return nil }
        if loadedFor != me {
            loadedFor = me
            privateKey = Keychain.data(service: Self.keyService, account: me)
                .flatMap { try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: $0) }
            directory = Keychain.data(service: Self.directoryService, account: me)
                .flatMap { try? JSONDecoder().decode(Directory.self, from: $0) } ?? Directory()
        }
        if privateKey == nil, create {
            let key = Curve25519.KeyAgreement.PrivateKey()
            if Keychain.setData(key.rawRepresentation, service: Self.keyService, account: me) { privateKey = key }
        }
        return privateKey
    }

    private func saveDirectory() {
        guard let me = loadedFor, let data = try? JSONEncoder().encode(directory) else { return }
        Keychain.setData(data, service: Self.directoryService, account: me)
    }

    private var myPublicKey: Data? { loadIfNeeded()?.publicKey.rawRepresentation }

    // MARK: - Per DM

    /// The other person in a one-to-one DM. Private messaging is only for those.
    func peer(in channelID: Snowflake) -> User? {
        guard let channel = store.channel(channelID), channel.kind == .dm, channel.recipients?.count == 1 else { return nil }
        return channel.recipients?.first
    }

    func mode(for channelID: Snowflake) -> Mode {
        guard status(for: channelID) != .unavailable else { return .standard }
        return directory.privateChannels.contains(channelID) ? .private : .standard
    }

    func status(for channelID: Snowflake) -> Status {
        guard Self.isSupported, let peer = peer(in: channelID) else { return .unavailable }
        _ = loadIfNeeded()
        guard let keys = directory.people[peer.id], !keys.isEmpty else { return .waiting }
        return .ready(verified: keys.allSatisfy(\.verified), keyChanged: directory.keyChanged.contains(peer.id))
    }

    /// Whether the other person has asked to chat privately and we haven't answered.
    func hasRequest(in channelID: Snowflake) -> Bool {
        guard let peer = peer(in: channelID) else { return false }
        return requests.contains(peer.id)
    }

    /// Switches a DM to Private, sending our handshake first if the other person doesn't have our key yet.
    func setMode(_ mode: Mode, for channelID: Snowflake) {
        guard status(for: channelID) != .unavailable else { return }
        if mode == .private {
            directory.privateChannels.insert(channelID)
        } else {
            directory.privateChannels.remove(channelID)
        }
        saveDirectory()
        if mode == .private { agree(in: channelID) }
        onChange?(channelID)
    }

    /// Agrees to chat privately: sends our handshake, asking for theirs if we don't have it.
    private func agree(in channelID: Snowflake) {
        guard let peer = peer(in: channelID), loadIfNeeded(create: true) != nil else { return }
        let firstTime = !directory.consented.contains(peer.id)
        directory.consented.insert(peer.id)
        requests.remove(peer.id)
        saveDirectory()
        let haveTheirKey = !(directory.people[peer.id] ?? []).isEmpty
        if firstTime || !haveTheirKey { sendHandshake(in: channelID, wantsReply: !haveTheirKey) }
    }

    private func sendHandshake(in channelID: Snowflake, wantsReply: Bool) {
        guard let key = myPublicKey, pendingHandshakes[channelID] == nil else { return }
        pendingHandshakes[channelID] = Date()
        session.send(PrivateMessaging.handshake(publicKey: key, wantsReply: wantsReply), to: channelID) { [weak self] error in
            // Not sent: allow another try.
            if error != nil { self?.pendingHandshakes[channelID] = nil }
        }
    }

    /// The 60-digit number to compare with the other person, or nil before their key arrives.
    func safetyNumber(for channelID: Snowflake) -> String? {
        guard let peer = peer(in: channelID), let mine = myPublicKey,
              let theirs = directory.people[peer.id]?.last?.key else { return nil }
        return PrivateMessaging.safetyNumber(mine, theirs)
    }

    func markVerified(in channelID: Snowflake) {
        guard let peer = peer(in: channelID), var keys = directory.people[peer.id] else { return }
        for i in keys.indices { keys[i].verified = true }
        directory.people[peer.id] = keys
        directory.keyChanged.remove(peer.id)
        saveDirectory()
        onChange?(channelID)
    }

    // MARK: - Handshakes

    /// Reads the handshakes in a DM's loaded messages: learns keys, notes requests, answers where agreed.
    /// New messages at the bottom are read on their own; the whole history only when older messages were loaded.
    func scan(channelID: Snowflake) {
        guard Self.isSupported, let peer = peer(in: channelID), let messages = store.messages(in: channelID),
              let first = messages.first, let last = messages.last, let me = store.me?.id else { return }
        _ = loadIfNeeded()
        var state: ScanState
        let fresh: ArraySlice<Message>
        if let previous = scans[channelID], previous.oldest == first.id {
            guard previous.newest != last.id else { return }
            state = previous
            fresh = messages.drop { $0.id.snowflakeValue <= previous.newest.snowflakeValue }
        } else {
            state = ScanState(oldest: first.id, newest: first.id)
            fresh = messages[...]
        }
        state.newest = last.id
        var changed = false
        for message in fresh {
            guard case .handshake(let key, let wantsReply) = PrivateMessaging.kind(of: message.content) else { continue }
            if message.author.id == me {
                state.lastOwnHandshake = message.id
                // Our handshake came back from Discord: no longer pending.
                if let sent = pendingHandshakes[channelID], Self.date(of: message.id) >= sent.addingTimeInterval(-30) {
                    pendingHandshakes[channelID] = nil
                }
                state.unansweredRequest = false
                if key != myPublicKey, !directory.ownDevices.contains(key), key.count == 32 {
                    directory.ownDevices.append(key)
                    changed = true
                }
                continue
            }
            guard message.author.id == peer.id else { continue }
            if seenHandshakes.insert(message.id).inserted, learn(key, for: peer.id) { changed = true }
            // A request still open: theirs came after our last handshake.
            if wantsReply, state.lastOwnHandshake.map({ $0.snowflakeValue < message.id.snowflakeValue }) ?? true {
                state.unansweredRequest = true
            }
        }
        scans[channelID] = state
        if state.unansweredRequest, pendingHandshakes[channelID] == nil {
            if directory.consented.contains(peer.id), loadIfNeeded(create: true) != nil {
                sendHandshake(in: channelID, wantsReply: false)
            } else if requests.insert(peer.id).inserted {
                changed = true
            }
        }
        if changed {
            saveDirectory()
            plaintexts = [:]
            onChange?(channelID)
        }
    }

    /// When a message was sent, from its ID.
    private static func date(of id: Snowflake) -> Date {
        Date(timeIntervalSince1970: TimeInterval((id.snowflakeValue >> 22) + 1_420_070_400_000) / 1000)
    }

    /// Adds a key for someone. Returns true if it was new.
    private func learn(_ key: Data, for userID: Snowflake) -> Bool {
        guard key.count == 32, (try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: key)) != nil else { return false }
        var keys = directory.people[userID] ?? []
        guard !keys.contains(where: { $0.key == key }) else { return false }
        // A new key for someone already verified: a new Mac, a reinstall, or someone in the middle.
        if keys.contains(where: \.verified) { directory.keyChanged.insert(userID) }
        keys.append(PeerKey(key: key, verified: false, added: Date()))
        directory.people[userID] = Array(keys.suffix(Self.maxKeysPerPerson))
        return true
    }

    // MARK: - Messages

    /// The message content for `text`, sealed to the other person and to us.
    func seal(_ text: String, in channelID: Snowflake) throws -> String {
        guard #available(macOS 14, *), let peer = peer(in: channelID), let key = loadIfNeeded(create: true) else {
            throw PrivateMessagingError.noRecipients
        }
        let theirs = (directory.people[peer.id] ?? []).map(\.key)
        guard !theirs.isEmpty else { throw PrivateMessagingError.noRecipients }
        let recipients = (theirs + [key.publicKey.rawRepresentation] + directory.ownDevices)
            .compactMap { try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: $0) }
        return try PrivateCrypto.seal(text, channelID: channelID, sender: key, recipients: recipients)
    }

    /// The text of a private message, or nil if it isn't one or can't be read with our key. A copy that Discord
    /// could have reposted (sealed long before it appeared, or carrying an earlier message's salt) starts with a
    /// warning line.
    func plaintext(of message: Message) -> String? {
        plaintext(content: message.content, id: message.id, authorID: message.author.id, channelID: message.channelId)
    }

    /// The same for a message known only by its parts (the message a reply quotes).
    func plaintext(content: String, id: Snowflake, authorID: Snowflake, channelID: Snowflake) -> String? {
        if let cached = plaintexts[id] { return cached }
        guard #available(macOS 14, *), case .encrypted(let payload) = PrivateMessaging.kind(of: content),
              let key = loadIfNeeded() else { return nil }
        let senderKeys: [Data]
        if authorID == store.me?.id {
            senderKeys = [key.publicKey.rawRepresentation] + directory.ownDevices
        } else {
            senderKeys = (directory.people[authorID] ?? []).map(\.key)
        }
        let opened = PrivateCrypto.open(payload, channelID: channelID, recipient: key,
                                        senders: senderKeys.compactMap { try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: $0) })
        var text = opened?.text
        if let opened {
            if let warning = replayWarning(opened, id: id) { text = warning + "\n" + opened.text }
        }
        if plaintexts.count > 2000 { plaintexts = [:] }
        plaintexts[id] = text
        return text
    }

    /// Ten minutes covers clocks that are a little off and messages that took a while to send.
    private static let replayTolerance: TimeInterval = 10 * 60

    @available(macOS 14, *)
    private func replayWarning(_ opened: PrivateCrypto.Opened, id: Snowflake) -> String? {
        if let first = firstWithSalt[opened.salt], first != id {
            if first.snowflakeValue < id.snowflakeValue {
                return "⚠️ *A copy of an earlier private message. Discord may have resent it.*"
            }
            // This one is older: it's the original, and the one seen first is the copy; redraw that one.
            plaintexts[first] = nil
        }
        firstWithSalt[opened.salt] = id
        let posted = Self.date(of: id)
        if abs(posted.timeIntervalSince(opened.sentAt)) > Self.replayTolerance {
            return "⚠️ *Written \(ProfileText.clockFormatter.string(from: opened.sentAt)), not when it appeared. "
                + "Discord may have resent it.*"
        }
        return nil
    }
}

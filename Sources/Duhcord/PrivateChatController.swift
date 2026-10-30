import AppKit
import CryptoKit
import DuhcordCore

/// Private messaging in DMs (see PrivateMessaging for the cryptography).
///
/// - Every Duhcord install has one key pair, made the first time it's needed and kept in the login keychain.
/// - Keys reach the other person in a handshake message. Their Duhcord picks it up from the DM, and answers with
///   its own once its user has agreed to chat privately with them (by switching the DM to Private, or accepting
///   the request). After that, handshakes between the two are answered automatically.
/// - Keys learned from handshakes are kept in the keychain too. Discord carries the handshakes, so it could slip in
///   a key of its own; no key receives messages until it's trusted:
///   - The other person's first key is trusted on first use. Any later one waits until it's accepted, after
///     comparing safety numbers; until then messages go only to the keys already accepted.
///   - A key that seems to be another of our own Macs waits for approval in Settings (rejections are remembered).
/// - The safety number covers every key on both sides, and "verified" holds only for the exact keys compared.
/// - Private messages are sealed to the other person's accepted keys, to ours (so we can read what we sent) and
///   to our approved Macs.
///
/// Main thread only. Private messaging needs macOS 14 (HPKE); on macOS 13 the toggle stays switched off.
@MainActor
final class PrivateChatController {
    enum Mode { case standard, `private` }

    enum Status: Equatable {
        /// macOS 13, a server channel or a group DM.
        case unavailable
        /// Switched to Private, but no key of the other person's is trusted yet. `newKey`: one is waiting to be accepted.
        case waiting(newKey: Bool)
        /// `newKey`: a key besides the accepted ones is waiting (a new Mac of theirs, or someone in the middle).
        case ready(verified: Bool, newKey: Bool)
    }

    /// Whether a key may receive our messages.
    enum Trust: String, Codable {
        case accepted, pending, rejected
    }

    /// One of our other Macs, as listed in Settings.
    struct Device {
        let key: Data
        let code: String
        let trust: Trust
        let added: Date
    }

    /// Our Macs or anyone's keys changed (Settings lists them).
    static let devicesDidChange = Notification.Name("DuhcordPrivateDevicesDidChange")
    /// Other Macs that may be approved besides this one, leaving room in each message for the other person's.
    static let maxOtherMacs = 3

    /// Something about a DM's private chat changed (a key arrived, a mode switched): nil for every DM.
    var onChange: ((Snowflake?) -> Void)?

    static var isSupported: Bool {
        if #available(macOS 14, *) { return true }
        return false
    }

    private struct PeerKey: Codable {
        var key: Data
        var added: Date
        /// Missing in directories from before keys needed accepting: those were already in use.
        var state: Trust?

        var trust: Trust { state ?? .accepted }
    }

    private struct OwnDevice: Codable {
        var key: Data
        var added: Date
        var trust: Trust
    }

    /// What's kept in the keychain besides our private key: everyone's public keys, our other Macs, who we agreed
    /// to chat with, which DMs are in Private (so a relaunch doesn't quietly switch a DM back to unencrypted
    /// messages), and which safety numbers were compared.
    private struct Directory: Codable {
        var people: [Snowflake: [PeerKey]] = [:]
        /// Our own other Duhcord installs (other Macs). Approved ones can read what we send.
        var devices: [OwnDevice] = []
        var consented: Set<Snowflake> = []
        var privateChannels: Set<Snowflake> = []
        /// A hash of the safety number each person was verified with: it no longer matches once a key changes.
        var verified: [Snowflake: Data] = [:]

        init() {}

        private enum CodingKeys: String, CodingKey {
            case people, devices, consented, privateChannels, verified
            /// Before approval, other Macs were added as soon as their handshake appeared.
            case ownDevices
        }

        // Fields added later are optional when reading, so an older directory keeps its keys.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            people = try c.decodeIfPresent([Snowflake: [PeerKey]].self, forKey: .people) ?? [:]
            devices = try c.decodeIfPresent([OwnDevice].self, forKey: .devices) ?? []
            consented = try c.decodeIfPresent(Set<Snowflake>.self, forKey: .consented) ?? []
            privateChannels = try c.decodeIfPresent(Set<Snowflake>.self, forKey: .privateChannels) ?? []
            verified = try c.decodeIfPresent([Snowflake: Data].self, forKey: .verified) ?? [:]
            // Macs added without approval wait for it now.
            for key in try c.decodeIfPresent([Data].self, forKey: .ownDevices) ?? []
            where !devices.contains(where: { $0.key == key }) {
                devices.append(OwnDevice(key: key, added: Date(), trust: .pending))
            }
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(people, forKey: .people)
            try c.encode(devices, forKey: .devices)
            try c.encode(consented, forKey: .consented)
            try c.encode(privateChannels, forKey: .privateChannels)
            try c.encode(verified, forKey: .verified)
        }

        func keys(of userID: Snowflake, _ trust: Trust) -> [Data] {
            (people[userID] ?? []).filter { $0.trust == trust }.map(\.key)
        }

        func deviceKeys(_ trust: Trust) -> [Data] {
            devices.filter { $0.trust == trust }.map(\.key)
        }
    }

    /// Where the handshake scan of a DM got to, so a new message is read on its own instead of the whole history.
    private struct ScanState {
        var oldest: Snowflake
        var newest: Snowflake
        var lastOwnHandshake: Snowflake?
        var unansweredRequest = false
    }

    private static let keyService = Keychain.privateKeyService
    private static let directoryService = Keychain.privateDirectoryService
    /// New keys waiting per person; more are ignored rather than pushing out the ones already there.
    private static let maxPendingKeys = 4

    private let session: DiscordSession
    private var store: Store { session.store }
    private var directory = Directory()
    private var scans: [Snowflake: ScanState] = [:]
    /// Which message first carried each private message's salt: a later one with the same salt is a copy.
    private var firstWithSalt: [Data: Snowflake] = [:]
    private var loadedFor: Snowflake?
    private var privateKey: Curve25519.KeyAgreement.PrivateKey?
    /// A private message as opened: its text (with any warning lines), its images, and whether its sender's key
    /// is trusted (images from a key that isn't aren't decoded).
    private struct Opened {
        let text: String
        /// The text as sent, without warning lines or a film note.
        let original: String
        let files: [PrivateFile]
        let trusted: Bool
        /// Set when this message is one stretch of a video split across attachments or messages.
        let film: PrivateFilm?
        /// The salt the message was sealed with, so a copy of a film part is not played as another part.
        let salt: Data
    }

    /// Opened private messages by ID, with the content they were opened from (an edit replaces it), nil when it
    /// couldn't be read. Cleared when keys change.
    private var opened: [Snowflake: (content: String, value: Opened?)] = [:]
    /// Whether each person's current safety number is the one that was verified. Checked often (menus, the
    /// toolbar, every mouse move of a drag), so it's remembered until the keys or the directory change.
    private var verifiedCache: [Snowflake: Bool] = [:]
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
            verifiedCache = [:]
            privateKey = Keychain.data(service: Self.keyService, account: me)
                .flatMap { try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: $0) }
            directory = Keychain.data(service: Self.directoryService, account: me)
                .flatMap { try? JSONDecoder().decode(Directory.self, from: $0) } ?? Directory()
        }
        if privateKey == nil, create {
            let key = Curve25519.KeyAgreement.PrivateKey()
            if Keychain.setData(key.rawRepresentation, service: Self.keyService, account: me) { privateKey = key }
            verifiedCache = [:]
        }
        return privateKey
    }

    /// Every change to the directory is saved, so this is also where remembered verification goes stale.
    private func saveDirectory() {
        verifiedCache = [:]
        guard let me = loadedFor, let data = try? JSONEncoder().encode(directory) else { return }
        Keychain.setData(data, service: Self.directoryService, account: me)
    }

    /// After keys were accepted, rejected or approved: messages are read again with the new set.
    private func keysChanged(in channelID: Snowflake?) {
        saveDirectory()
        opened = [:]
        firstWithSalt = [:]
        onChange?(channelID)
        NotificationCenter.default.post(name: Self.devicesDidChange, object: self)
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
        let newKey = !directory.keys(of: peer.id, .pending).isEmpty
        guard !directory.keys(of: peer.id, .accepted).isEmpty else { return .waiting(newKey: newKey) }
        let verified: Bool
        if let cached = verifiedCache[peer.id] {
            verified = cached
        } else {
            verified = safetyNumber(for: channelID).map { directory.verified[peer.id] == Self.fingerprint($0) } ?? false
            verifiedCache[peer.id] = verified
        }
        return .ready(verified: verified, newKey: newKey)
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
        let haveTheirKey = !directory.keys(of: peer.id, .accepted).isEmpty
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

    /// Our keys: this Mac's and the other Macs we approved. Messages we send go to all of them.
    private var ownKeys: [Data] {
        guard let mine = myPublicKey else { return [] }
        return [mine] + directory.deviceKeys(.accepted)
    }

    /// The 60-digit number to compare with the other person, over every key each side encrypts to, or nil before
    /// their key arrives.
    func safetyNumber(for channelID: Snowflake) -> String? {
        safetyNumber(for: channelID, accepting: [])
    }

    private static func fingerprint(_ safetyNumber: String) -> Data {
        Data(SHA256.hash(data: Data(safetyNumber.utf8)))
    }

    /// The safety number `number`, which the person compared, matched. Verified until a key on either side
    /// changes. Returns false (and verifies nothing) if the keys changed since `number` was shown.
    @discardableResult
    func markVerified(in channelID: Snowflake, number: String) -> Bool {
        guard let peer = peer(in: channelID), safetyNumber(for: channelID) == number else { return false }
        directory.verified[peer.id] = Self.fingerprint(number)
        saveDirectory()
        onChange?(channelID)
        return true
    }

    /// The other person's keys waiting to be accepted, as shown for review.
    func newKeys(in channelID: Snowflake) -> [Data] {
        guard let peer = peer(in: channelID) else { return [] }
        return directory.keys(of: peer.id, .pending)
    }

    /// The safety number if `keys` (waiting ones) were accepted too.
    func safetyNumber(for channelID: Snowflake, accepting keys: [Data]) -> String? {
        guard let peer = peer(in: channelID), myPublicKey != nil else { return nil }
        let theirs = directory.keys(of: peer.id, .accepted) + keys
        return theirs.isEmpty ? nil : PrivateMessaging.safetyNumber(ownKeys, theirs)
    }

    /// Trusts exactly `keys`, the waiting keys that were shown, so they receive messages from now on. A key that
    /// arrived while they were being reviewed stays waiting. With `comparedNumber`, the safety number shown with
    /// them matched; returns false if it no longer applies (the keys changed meanwhile), and nothing is verified.
    @discardableResult
    func acceptNewKeys(_ keys: [Data], in channelID: Snowflake, comparedNumber: String?) -> Bool {
        setTrust(.accepted, forKeys: keys, in: channelID)
        guard let comparedNumber else { return true }
        return markVerified(in: channelID, number: comparedNumber)
    }

    /// Refuses `keys` for good: they never receive messages, and what was sent from them isn't shown.
    func rejectNewKeys(_ keys: [Data], in channelID: Snowflake) {
        setTrust(.rejected, forKeys: keys, in: channelID)
    }

    private func setTrust(_ trust: Trust, forKeys chosen: [Data], in channelID: Snowflake) {
        guard let peer = peer(in: channelID), var keys = directory.people[peer.id] else { return }
        for i in keys.indices where keys[i].trust == .pending && chosen.contains(keys[i].key) { keys[i].state = trust }
        directory.people[peer.id] = keys
        keysChanged(in: channelID)
    }

    // MARK: - Our other Macs

    /// The code for this Mac's key, to compare with the list on another Mac; nil before private messaging is used.
    var thisMacCode: String? { myPublicKey.map(PrivateMessaging.keyCode) }

    /// Our other Macs, waiting ones first.
    var devices: [Device] {
        _ = loadIfNeeded()
        let order: [Trust] = [.pending, .accepted, .rejected]
        return directory.devices
            .map { Device(key: $0.key, code: PrivateMessaging.keyCode($0.key), trust: $0.trust, added: $0.added) }
            .sorted { (order.firstIndex(of: $0.trust)!, $0.added) < (order.firstIndex(of: $1.trust)!, $1.added) }
    }

    var canApproveAnotherMac: Bool { directory.deviceKeys(.accepted).count < Self.maxOtherMacs }

    /// Approves or denies one of our other Macs. Approved ones receive every private message we send from now on.
    func setTrust(_ trust: Trust, forDevice key: Data) {
        guard let index = directory.devices.firstIndex(where: { $0.key == key }) else { return }
        if trust == .accepted, directory.devices[index].trust != .accepted, !canApproveAnotherMac { return }
        directory.devices[index].trust = trust
        keysChanged(in: nil)
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
                // Another Mac of ours, or Discord pretending to be one: it waits for approval in Settings.
                if key != myPublicKey, !directory.devices.contains(where: { $0.key == key }),
                   (try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: key)) != nil,
                   directory.deviceKeys(.pending).count < Self.maxPendingKeys {
                    directory.devices.append(OwnDevice(key: key, added: Date(), trust: .pending))
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
        if changed { keysChanged(in: channelID) }
    }

    /// When a message was sent, from its ID.
    private static func date(of id: Snowflake) -> Date {
        Date(timeIntervalSince1970: TimeInterval((id.snowflakeValue >> 22) + 1_420_070_400_000) / 1000)
    }

    /// Adds a key for someone: trusted if it's the first we've seen from them, else waiting to be accepted (a new
    /// Mac, a reinstall, or someone in the middle). Returns true if it was new.
    private func learn(_ key: Data, for userID: Snowflake) -> Bool {
        guard (try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: key)) != nil else { return false }
        var keys = directory.people[userID] ?? []
        guard !keys.contains(where: { $0.key == key }) else { return false }
        let trust: Trust = keys.isEmpty ? .accepted : .pending
        if trust == .pending, keys.filter({ $0.trust == .pending }).count >= Self.maxPendingKeys { return false }
        keys.append(PeerKey(key: key, added: Date(), state: trust))
        directory.people[userID] = keys
        return true
    }

    // MARK: - Messages

    /// The message content for `text`, sealed to the other person's accepted keys, to us and our approved Macs.
    /// Keys still waiting to be accepted or approved get nothing.
    func seal(_ text: String, files: [PrivateFile] = [], in channelID: Snowflake) throws -> String {
        guard #available(macOS 14, *), let peer = peer(in: channelID), let key = loadIfNeeded(create: true) else {
            throw PrivateMessagingError.noRecipients
        }
        let theirs = directory.keys(of: peer.id, .accepted)
        guard !theirs.isEmpty else { throw PrivateMessagingError.noRecipients }
        let recipients = (theirs + ownKeys)
            .compactMap { try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: $0) }
        return try PrivateCrypto.seal(text, files: files, channelID: channelID, sender: key, recipients: recipients)
    }

    /// One of our private messages without its image at `index`, sealed again (to the keys trusted now) for an
    /// edit that also deletes that attachment. Nil when nothing would be left, so the message should be deleted.
    func content(of message: Message, removingImage index: Int) throws -> String? {
        guard let opened = open(content: message.content, id: message.id, authorID: message.author.id,
                                channelID: message.channelId, postedAt: Self.postedAt(message)),
              opened.files.indices.contains(index) else { throw PrivateMessagingError.noRecipients }
        // A split video's pieces are one film. Resealing without one of them would leave a hole that still played.
        if opened.film != nil { return nil }
        var files = opened.files
        files.remove(at: index)
        if files.isEmpty, opened.original.isEmpty { return nil }
        return try seal(opened.original, files: files, in: message.channelId)
    }

    /// Whether this private message is one part of a split video. Removing a single piece would break the film.
    func isFilm(_ message: Message) -> Bool {
        open(content: message.content, id: message.id, authorID: message.author.id,
             channelID: message.channelId, postedAt: Self.postedAt(message))?.film != nil
    }

    /// The text of a private message, or nil if it isn't one or can't be read with our key. A copy that Discord
    /// could have reposted (sealed long before it appeared, or carrying an earlier message's salt), or one sent
    /// from a key that isn't trusted yet, starts with a warning line. Rejected keys' messages aren't shown.
    func plaintext(of message: Message) -> String? {
        open(content: message.content, id: message.id, authorID: message.author.id, channelID: message.channelId,
             postedAt: Self.postedAt(message))?.text
    }

    /// When a message's current content appeared: an edit replaces it (removing an image re-seals the text).
    private static func postedAt(_ message: Message) -> Date {
        message.editedTimestamp.flatMap(DiscordDate.parse) ?? date(of: message.id)
    }

    /// The same for a message known only by its parts (the message a reply quotes).
    /// The text of a quoted private message, for a reply's preview line: as sent, without warnings (the message
    /// itself shows those).
    func plaintext(content: String, id: Snowflake, authorID: Snowflake, channelID: Snowflake) -> String? {
        open(content: content, id: id, authorID: authorID, channelID: channelID)?.original
    }

    /// The images in a private message, matched to its attachments. Empty if it has none or can't be read.
    func images(of message: Message) -> [PrivateImage] {
        guard let opened = open(content: message.content, id: message.id, authorID: message.author.id,
                                channelID: message.channelId, postedAt: Self.postedAt(message)) else { return [] }
        let film = opened.film
        var images = opened.files.enumerated().map { index, file in
            // The attachment at the same position, if it's the size this image's attachment must be.
            let attachment = message.attachments.indices.contains(index) ? message.attachments[index] : nil
            let matches = attachment.map { $0.size == nil || $0.size == file.sealedLength } ?? false
            let span: Double = film?.spans.count == opened.files.count ? (film?.spans[index] ?? 0) : 0
            return PrivateImage(messageID: message.id, index: index, file: file,
                                attachment: matches ? attachment : nil, trusted: opened.trusted,
                                filmID: film?.id, filmPart: (film?.start ?? 0) + index, filmSpan: span)
        }
        // Only the oldest message that holds piece 0 offers the rest, in order, and only while nothing is missing.
        if let film, film.start == 0, opened.trusted, images.first?.attachment != nil {
            let chain = filmChain(of: film.id, author: message.author.id, channelID: message.channelId)
            if chain.owner == message.id {
                images[0].follows = chain.follows
            } else {
                for index in images.indices { images[index].filmPart = max(images[index].filmPart, 1) }
            }
        }
        return images
    }

    /// The pieces of a film in order, rebuilt from the messages currently loaded. Empty when this message is
    /// not the one that holds piece 0.
    func playbackQueue(forFilmOf image: PrivateImage, in channelID: Snowflake) -> [PrivateImage] {
        guard image.filmID != nil,
              let message = store.messages(in: channelID)?.first(where: { $0.id == image.messageID }),
              let opened = open(content: message.content, id: message.id, authorID: message.author.id,
                                channelID: channelID, postedAt: Self.postedAt(message)),
              let film = opened.film, film.start == 0 else { return [] }
        let chain = filmChain(of: film.id, author: message.author.id, channelID: channelID)
        guard chain.owner == message.id, let start = chain.start else { return [] }
        return [start] + chain.follows
    }

    /// Piece 0's message, and the pieces after it. Same author only. The oldest message wins an index, a copy or
    /// an untrusted key or a wrong-sized attachment is a gap, and playback stops at the first missing index.
    private func filmChain(of film: Data, author: Snowflake, channelID: Snowflake) -> (owner: Snowflake?, start: PrivateImage?, follows: [PrivateImage]) {
        guard #available(macOS 14, *) else { return (nil, nil, []) }
        var chosen: [Int: (snowflake: UInt64, image: PrivateImage)] = [:]
        for message in store.messages(in: channelID) ?? [] where message.author.id == author {
            guard let opened = open(content: message.content, id: message.id, authorID: author,
                                    channelID: channelID, postedAt: Self.postedAt(message)),
                  let part = opened.film, part.id == film, opened.trusted,
                  firstWithSalt[opened.salt] == message.id else { continue }
            for (offset, file) in opened.files.enumerated() {
                let index = part.start + offset
                guard file.kind.isVideo else { continue }
                guard let attachment = message.attachments.indices.contains(offset) ? message.attachments[offset] : nil,
                      attachment.size == nil || attachment.size == file.sealedLength else { continue }
                let span = part.spans.count == opened.files.count ? part.spans[offset] : 0
                let image = PrivateImage(messageID: message.id, index: offset, file: file, attachment: attachment,
                                         trusted: true, filmID: film, filmPart: index, filmSpan: span)
                let snow = message.id.snowflakeValue
                if let existing = chosen[index], existing.snowflake <= snow { continue }
                chosen[index] = (snow, image)
            }
        }
        var follows: [PrivateImage] = []
        var index = 1
        while follows.count < 47, let image = chosen[index]?.image {
            follows.append(image)
            index += 1
        }
        return (chosen[0]?.image.messageID, chosen[0]?.image, follows)
    }

    private func open(content: String, id: Snowflake, authorID: Snowflake, channelID: Snowflake,
                      postedAt: Date? = nil) -> Opened? {
        if let cached = opened[id], cached.content == content { return cached.value }
        guard #available(macOS 14, *), case .encrypted(let payload) = PrivateMessaging.kind(of: content),
              let key = loadIfNeeded() else { return nil }
        let fromMe = authorID == store.me?.id
        let trusted = fromMe ? ownKeys : directory.keys(of: authorID, .accepted)
        let waiting = fromMe ? directory.deviceKeys(.pending) : directory.keys(of: authorID, .pending)
        func attempt(_ senders: [Data]) -> PrivateCrypto.Opened? {
            PrivateCrypto.open(payload, channelID: channelID, recipient: key,
                               senders: senders.compactMap { try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: $0) },
                               fromSelf: fromMe)
        }
        var warnings: [String] = []
        var result = attempt(trusted)
        let isTrusted = result != nil
        if result == nil, !waiting.isEmpty, let fromWaiting = attempt(waiting) {
            result = fromWaiting
            warnings.append(fromMe ? "⚠️ *Sent from a Mac you haven't approved in Settings.*"
                                   : "⚠️ *Sent from a new key you haven't accepted. It may not be them.*")
        }
        var shown: Opened?
        if let result {
            if let warning = replayWarning(result, id: id, postedAt: postedAt ?? Self.date(of: id)) { warnings.append(warning) }
            var caption = result.text
            var film: PrivateFilm?
            if PrivateFilmNote.begins(result.text) {
                // A film note that isn't well formed, or that isn't all video, is not shown.
                if let parsed = PrivateFilmNote.parse(result.text),
                   !result.files.isEmpty, result.files.allSatisfy({ $0.kind.isVideo }) {
                    film = parsed.film
                    caption = parsed.caption
                } else {
                    shown = Opened(text: "This private video's description was rejected, so it isn't shown.",
                                   original: "", files: [], trusted: false, film: nil, salt: result.salt)
                }
            }
            if shown == nil {
                let body = (film?.start ?? 0) > 0 && caption.isEmpty ? "Continues a private video." : caption
                let lines = warnings + (body.isEmpty ? [] : [body])
                shown = Opened(text: lines.joined(separator: "\n"), original: caption, files: result.files,
                               trusted: isTrusted, film: film, salt: result.salt)
            }
        }
        if opened.count > 2000 { opened = [:] }
        opened[id] = (content, shown)
        return shown
    }

    /// Ten minutes covers clocks that are a little off and messages that took a while to send.
    private static let replayTolerance: TimeInterval = 10 * 60

    @available(macOS 14, *)
    private func replayWarning(_ opened: PrivateCrypto.Opened, id: Snowflake, postedAt posted: Date) -> String? {
        if let first = firstWithSalt[opened.salt], first != id {
            if first.snowflakeValue < id.snowflakeValue {
                return "⚠️ *A copy of an earlier private message. Discord may have resent it.*"
            }
            // This one is older: it's the original, and the one seen first is the copy; redraw that one.
            self.opened[first] = nil
        }
        firstWithSalt[opened.salt] = id
        if abs(posted.timeIntervalSince(opened.sentAt)) > Self.replayTolerance {
            return "⚠️ *Written \(ProfileText.clockFormatter.string(from: opened.sentAt)), not when it appeared. "
                + "Discord may have resent it.*"
        }
        return nil
    }
}

/// An encrypted image in a private message, as the message list shows it.
struct PrivateImage: Sendable {
    let messageID: Snowflake
    /// Its position among the message's images (and attachments).
    let index: Int
    let file: PrivateFile
    /// The attachment carrying it, or nil if the message has none of the right size there.
    let attachment: Attachment?
    /// Sent from an accepted key (or one of our approved Macs). Others' images aren't downloaded or decoded.
    let trusted: Bool
    /// Set on every piece of a video that was split. Nil for an ordinary attachment.
    var filmID: Data? = nil
    /// This piece's index in the film. The piece at 0 is the one the row plays.
    var filmPart: Int = 0
    /// How long this piece plays, in seconds. Zero when the message was sent before lengths were kept.
    var filmSpan: Double = 0
    /// The pieces after this one, with no gaps. Only the piece at 0 carries them.
    var follows: [PrivateImage] = []

    /// By its attachment, which is unique to this image: removing an earlier image shifts the positions.
    var cacheKey: String { attachment.map { "attachment/\($0.id)" } ?? "\(messageID)/\(index)" }
    /// Stands for the image where the message list keys things by URL; never fetched.
    var placeholderURL: URL { URL(string: "duhcord-private://image/" + cacheKey)! }
}

import AppKit
import CryptoKit
import DuhcordCore

/// Private messaging in DMs, protocol v3 (spec/PROTOCOL.md; cryptography in PrivateMessaging).
///
/// Every trust decision is made by `PrivateTrustEngine` (DuhcordCore), the same rules the Duhcord Private Companion
/// runs; the shared scenarios in spec/scenarios check both. This controller adds what the engine doesn't do:
/// - the account's key and the engine's directory live in the login keychain (one vault item, see Keychain);
/// - it feeds the engine the DM's loaded messages and posts the handshakes the engine asks for;
/// - it shapes opened messages for the message list: warning lines, images, split videos and reels.
///
/// Main thread only. Private messaging needs macOS 14 (HPKE); on macOS 13 the toggle stays switched off.
@MainActor
final class PrivateChatController {
    enum Mode { case standard, `private`, locked }

    enum Status: Equatable {
        /// macOS 13, a server channel or a group DM.
        case unavailable
        /// The login keychain couldn't be opened, so the saved mode is unknown.
        case locked
        /// No key of the other person's counts yet. `newKey`: one is waiting to be accepted.
        case waiting(newKey: Bool)
        /// We have their key, but they haven't accepted ours yet (no receipt), so they can't read us.
        case unconfirmed(newKey: Bool)
        /// Both sides have each other's key. `newKey`: another key of theirs is waiting.
        case ready(verified: Bool, newKey: Bool)
        /// Their newest handshake is from a newer version of private messaging.
        case outdated
    }

    typealias Trust = PrivateTrustEngine.Trust

    /// One of our other devices (a Mac, or a Companion), as listed in Settings.
    struct Device {
        let key: Data
        let code: String
        let trust: Trust
        let client: PeerClient
        let added: Date
    }

    /// Our devices or anyone's keys changed (Settings lists them).
    static let devicesDidChange = Notification.Name("DuhcordPrivateDevicesDidChange")
    /// Other devices that may be approved besides this Mac, leaving room in each message for the other person's.
    static let maxOtherMacs = PrivateTrustEngine.maxApprovedDevices

    /// Something about a DM's private chat changed (a key arrived, a mode switched): nil for every DM.
    var onChange: ((Snowflake?) -> Void)?

    static var isSupported: Bool {
        if #available(macOS 14, *) { return true }
        return false
    }

    /// v3 is a clean break: v2 keys and directories (com.duhcord.private-key / -directory) are never read again.
    private static let keyService = Keychain.privateKeyService
    private static let directoryService = Keychain.privateDirectoryService

    private let session: DiscordSession
    private var store: Store { session.store }
    private var engine: PrivateTrustEngine?
    private var loadedFor: Snowflake?
    private var savedDirectory: PrivateTrustEngine.Directory?
    private(set) var keychainLocked = false
    private var standardWhileLocked: Set<Snowflake> = []

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
        /// Set when this message contains encrypted chunks of a whole-film MP4.
        let reel: PrivateReel?
        /// The salt the message was sealed with, so a copy of a film part is not played as another part.
        let salt: Data
    }

    /// Opened private messages by ID, with the content they were opened from (an edit replaces it), nil when it
    /// couldn't be read. Cleared when keys change.
    private var opened: [Snowflake: (content: String, value: Opened?)] = [:]
    private var openedGeneration: UInt64 = 0
    private struct FilmChainStamp: Equatable {
        let channelID: Snowflake
        let author: Snowflake
        let messageCount: Int
        let lastMessageID: Snowflake?
        let openedGeneration: UInt64
    }
    private typealias FilmChainResult = (owner: Snowflake?, start: PrivateImage?, follows: [PrivateImage])
    private var filmChainCache: [Data: (stamp: FilmChainStamp, result: FilmChainResult)] = [:]
    private var settingsObserver: NSObjectProtocol?

    init(session: DiscordSession) {
        self.session = session
        let settingKey = Settings.Key.allowCompanionChat
        let settingInfo = Settings.keyInfo
        settingsObserver = NotificationCenter.default.addObserver(
            forName: Settings.didChange, object: nil, queue: .main
        ) { [weak self] notification in
            guard notification.userInfo?[settingInfo] as? String == settingKey else { return }
            Task { @MainActor [weak self] in
                guard let self, let engine = self.loadIfNeeded() else { return }
                self.post(engine.setAllowCompanionChat(Settings.allowCompanionChat))
                self.keysChanged(in: nil)
            }
        }
    }

    // MARK: - Keys

    /// Loads (or, with `create`, makes) our key and the engine for the logged-in account.
    @discardableResult
    private func loadIfNeeded(create: Bool = false) -> PrivateTrustEngine? {
        guard Self.isSupported, let me = store.me?.id else { return nil }
        if loadedFor != me {
            loadedFor = me
            keychainLocked = false
            standardWhileLocked = []
            engine = nil
            savedDirectory = nil
            var key: Curve25519.KeyAgreement.PrivateKey?
            switch Keychain.read(service: Self.keyService, account: me) {
            case .value(let data):
                key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: data)
            case .missing:
                key = nil
            case .denied:
                keychainLocked = true
            }
            switch Keychain.read(service: Self.directoryService, account: me) {
            case .value(let data):
                savedDirectory = (try? JSONDecoder().decode(PrivateTrustEngine.Directory.self, from: data))
            case .missing:
                savedDirectory = nil
            case .denied:
                keychainLocked = true
            }
            if let key, !keychainLocked { makeEngine(key: key, me: me) }
        }
        guard !keychainLocked else { return nil }
        if engine == nil, create {
            let key = Curve25519.KeyAgreement.PrivateKey()
            if Keychain.setData(key.rawRepresentation, service: Self.keyService, account: me) {
                // A new key: anything kept for an older one no longer applies.
                savedDirectory = nil
                makeEngine(key: key, me: me)
            }
        }
        return engine
    }

    private func makeEngine(key: Curve25519.KeyAgreement.PrivateKey, me: Snowflake) {
        engine = PrivateTrustEngine(privateKey: key, userID: me,
                                    directory: savedDirectory ?? PrivateTrustEngine.Directory(),
                                    config: .duhcord(allowCompanionChat: Settings.allowCompanionChat))
        clearOpened()
    }

    /// Saves the directory if the engine changed it.
    private func saveIfNeeded() {
        guard !keychainLocked, let engine, engine.isDirty, let me = loadedFor,
              let data = try? JSONEncoder().encode(engine.directory) else { return }
        if Keychain.setData(data, service: Self.directoryService, account: me) { engine.isDirty = false }
    }

    func retryKeychain() {
        AccountStore.retry()
        loadedFor = nil
        keychainLocked = false
        engine = nil
        standardWhileLocked = []
        clearOpened()
        loadIfNeeded()
        onChange?(nil)
    }

    private func clearOpened() {
        opened = [:]
        openedGeneration &+= 1
        filmChainCache = [:]
    }

    /// After keys were accepted, rejected or approved: messages are read again with the new set.
    private func keysChanged(in channelID: Snowflake?) {
        guard !keychainLocked else { return }
        saveIfNeeded()
        clearOpened()
        onChange?(channelID)
        NotificationCenter.default.post(name: Self.devicesDidChange, object: self)
    }

    /// Posts the handshakes the engine asked for. A failed post frees the DM for another try.
    private func post(_ sends: [PrivateTrustEngine.Outgoing]) {
        for send in sends {
            session.send(send.content, to: send.channelID) { [weak self] error in
                guard error != nil else { return }
                Task { @MainActor [weak self] in self?.engine?.handshakeSendFailed(in: send.channelID) }
            }
        }
    }

    /// The engine with this DM registered, if it's a one-to-one DM and we have a key.
    private func trust(in channelID: Snowflake, create: Bool = false) -> PrivateTrustEngine? {
        guard let peer = peer(in: channelID), let engine = loadIfNeeded(create: create) else { return nil }
        engine.setDM(channelID: channelID, peerID: peer.id)
        return engine
    }

    // MARK: - Per DM

    /// The other person in a one-to-one DM. Private messaging is only for those.
    func peer(in channelID: Snowflake) -> User? {
        guard let channel = store.channel(channelID), channel.kind == .dm, channel.recipients?.count == 1 else { return nil }
        return channel.recipients?.first
    }

    func mode(for channelID: Snowflake) -> Mode {
        let state = status(for: channelID)
        guard state != .unavailable else { return .standard }
        if standardWhileLocked.contains(channelID) { return .standard }
        if state == .locked { return .locked }
        return trust(in: channelID)?.directory.privateChannels.contains(channelID) == true ? .private : .standard
    }

    func status(for channelID: Snowflake) -> Status {
        guard Self.isSupported, peer(in: channelID) != nil else { return .unavailable }
        loadIfNeeded()
        if keychainLocked { return .locked }
        guard let engine = trust(in: channelID) else { return .waiting(newKey: false) }
        if engine.peerUsesNewerVersion(in: channelID) { return .outdated }
        let status = engine.status(for: channelID)
        if engine.countedKeys(in: channelID).isEmpty { return .waiting(newKey: status.newKey) }
        if !engine.hasOurKey(in: channelID) { return .unconfirmed(newKey: status.newKey) }
        return .ready(verified: status.verified, newKey: status.newKey)
    }

    /// Whether the other person has asked to chat privately and we haven't answered.
    func hasRequest(in channelID: Snowflake) -> Bool {
        trust(in: channelID)?.status(for: channelID).state == .request
    }

    func usesCompanion(in channelID: Snowflake) -> Bool {
        trust(in: channelID)?.countedKeys(in: channelID).contains { $0.client == .companion } ?? false
    }

    /// They use the Companion, but Companion chat is off in Settings.
    func hasCompanionNotice(in channelID: Snowflake) -> Bool {
        guard !Settings.allowCompanionChat, let engine = trust(in: channelID) else { return false }
        return engine.peerKeys(in: channelID).contains { $0.client == .companion && $0.trust != .rejected }
    }

    /// "Only their Duhcord Macs": their Companion keys are left out of this chat (spec §6).
    func isDuhcordOnly(in channelID: Snowflake) -> Bool {
        trust(in: channelID)?.companionExcluded(in: channelID) ?? false
    }

    func setDuhcordOnly(_ on: Bool, in channelID: Snowflake) {
        guard let engine = trust(in: channelID) else { return }
        post(engine.setCompanionExcluded(on, in: channelID))
        keysChanged(in: channelID)
    }

    func recipientsCanOpen(_ features: PeerFeatures, in channelID: Snowflake) -> Bool {
        let keys = trust(in: channelID)?.countedKeys(in: channelID) ?? []
        return !keys.isEmpty && keys.allSatisfy { $0.features.isSuperset(of: features) }
    }

    func newKeysIncludeCompanion(in channelID: Snowflake) -> Bool {
        trust(in: channelID)?.pendingKeys(in: channelID).contains { $0.client == .companion } ?? false
    }

    func hasDuhcordAndCompanionKeys(in channelID: Snowflake) -> Bool {
        let accepted = trust(in: channelID)?.peerKeys(in: channelID).filter { $0.trust == .accepted } ?? []
        return accepted.contains { $0.client != .companion } && accepted.contains { $0.client == .companion }
    }

    /// Switches a DM to Private, sending our handshake first if needed (spec §3 rule 1).
    func setMode(_ mode: Mode, for channelID: Snowflake) {
        let state = status(for: channelID)
        guard !keychainLocked, mode != .locked, state != .unavailable, state != .locked,
              let engine = trust(in: channelID, create: mode == .private) else { return }
        post(engine.setPrivate(mode == .private, in: channelID))
        saveIfNeeded()
        onChange?(channelID)
    }

    /// "Re-send my key" (spec §3 rule 4): the way out of any confusion about who has whose key.
    func resendKey(in channelID: Snowflake) {
        guard let engine = trust(in: channelID, create: true) else { return }
        post(engine.resendKey(in: channelID))
        saveIfNeeded()
        onChange?(channelID)
    }

    func useStandardWhileLocked(in channelID: Snowflake) {
        guard keychainLocked, peer(in: channelID) != nil else { return }
        standardWhileLocked.insert(channelID)
        onChange?(channelID)
    }

    /// The 60-digit number to compare with the other person, over every key each side encrypts to, or nil before
    /// their key arrives.
    func safetyNumber(for channelID: Snowflake) -> String? {
        trust(in: channelID)?.safetyNumber(for: channelID)
    }

    /// The key codes behind the safety number: ours (this Mac first, then approved devices) and theirs, each with
    /// its client. When two numbers differ, these show which key does.
    func keyCodes(for channelID: Snowflake) -> (ours: [(code: String, client: PeerClient)],
                                               theirs: [(code: String, client: PeerClient)]) {
        guard let engine = trust(in: channelID) else { return ([], []) }
        return (engine.ourSide.map { (PrivateMessaging.keyCode($0.key), $0.client) },
                engine.countedKeys(in: channelID).map { (PrivateMessaging.keyCode($0.key), $0.client) })
    }

    /// The safety number `number`, which the person compared, matched. Returns false (and verifies nothing) if
    /// the keys changed since `number` was shown.
    @discardableResult
    func markVerified(in channelID: Snowflake, number: String) -> Bool {
        guard !keychainLocked, let engine = trust(in: channelID), engine.safetyNumber(for: channelID) == number,
              engine.markVerified(in: channelID) else { return false }
        saveIfNeeded()
        onChange?(channelID)
        return true
    }

    /// The other person's keys waiting to be accepted, as shown for review.
    func newKeys(in channelID: Snowflake) -> [Data] {
        trust(in: channelID)?.pendingKeys(in: channelID).map(\.key) ?? []
    }

    /// The safety number if `keys` (waiting ones) were accepted too.
    func safetyNumber(for channelID: Snowflake, accepting keys: [Data]) -> String? {
        trust(in: channelID)?.safetyNumber(for: channelID, accepting: keys)
    }

    /// Trusts exactly `keys`, the waiting keys that were shown. With `comparedNumber`, the safety number shown with
    /// them matched; returns false if it no longer applies (the keys changed meanwhile), and nothing changes.
    @discardableResult
    func acceptNewKeys(_ keys: [Data], in channelID: Snowflake, comparedNumber: String?) -> Bool {
        guard !keychainLocked, let engine = trust(in: channelID) else { return false }
        switch engine.accept(keys, in: channelID, compared: comparedNumber) {
        case .success(let sends):
            post(sends)
            keysChanged(in: channelID)
            return true
        case .failure:
            return false
        }
    }

    /// Refuses `keys` for good: they never receive messages, and what was sent from them isn't shown.
    func rejectNewKeys(_ keys: [Data], in channelID: Snowflake) {
        guard let engine = trust(in: channelID) else { return }
        post(engine.reject(keys, in: channelID))
        keysChanged(in: channelID)
    }

    // MARK: - Our other devices

    /// The code for this Mac's key, to compare with the list on another device; nil before private messaging is used.
    var thisMacCode: String? { loadIfNeeded().map { PrivateMessaging.keyCode($0.publicKey) } }

    /// Our other devices, waiting ones first.
    var devices: [Device] {
        let order: [Trust] = [.pending, .accepted, .rejected]
        return (loadIfNeeded()?.devices ?? [])
            .map { Device(key: $0.key, code: PrivateMessaging.keyCode($0.key), trust: $0.trust, client: $0.client,
                          added: $0.added) }
            .sorted { (order.firstIndex(of: $0.trust)!, $0.added) < (order.firstIndex(of: $1.trust)!, $1.added) }
    }

    var canApproveAnotherMac: Bool { loadIfNeeded()?.canApproveAnotherDevice ?? false }

    /// Approves or denies one of our other devices. Approved ones receive every private message we send from now on.
    func setTrust(_ trust: Trust, forDevice key: Data) {
        guard !keychainLocked, let engine = loadIfNeeded(), engine.setDevice(key, trust: trust) else { return }
        keysChanged(in: nil)
    }

    // MARK: - Reading the DM

    /// Feeds the DM's loaded messages to the engine: it learns keys, notes requests and receipts, and says which
    /// handshakes to send.
    func scan(channelID: Snowflake) {
        guard Self.isSupported, let messages = store.messages(in: channelID), !messages.isEmpty else { return }
        // Someone's request has to show even before we used private messaging, so a DM with private content makes
        // our key.
        let hasPrivate = messages.contains { PrivateMessaging.kind(of: $0.content) != .plain }
        guard let engine = trust(in: channelID, create: hasPrivate) else { return }
        let (sends, changed) = engine.read(channelID: channelID, messages: messages.map(Self.engineMessage))
        post(sends)
        if changed { keysChanged(in: channelID) } else { saveIfNeeded() }
    }

    private static func engineMessage(_ message: Message) -> PrivateTrustEngine.Message {
        PrivateTrustEngine.Message(id: message.id, authorID: message.author.id, content: message.content,
                                   editedAt: message.editedTimestamp.flatMap(DiscordDate.parse))
    }

    // MARK: - Messages

    /// The message content for `text`, sealed to the other person's counted keys, to us and our approved devices.
    /// Only once they have our key (spec §6).
    func seal(_ text: String, files: [PrivateFile] = [], in channelID: Snowflake) throws -> String {
        guard #available(macOS 14, *), let engine = trust(in: channelID, create: true) else {
            throw PrivateMessagingError.noRecipients
        }
        do {
            return try engine.seal(text, files: files, in: channelID)
        } catch PrivateTrustEngine.SendError.notReady {
            throw PrivateMessagingError.notReady
        } catch PrivateTrustEngine.SendError.tooManyRecipients {
            throw PrivateMessagingError.tooManyRecipients
        }
    }

    /// One of our private messages without its image at `index`, sealed again (to the keys trusted now) for an
    /// edit that also deletes that attachment. Nil when nothing would be left, so the message should be deleted.
    func content(of message: Message, removingImage index: Int) throws -> String? {
        guard let opened = open(message), opened.files.indices.contains(index) else {
            throw PrivateMessagingError.noRecipients
        }
        // A split video's pieces are one film. Resealing without one of them would leave a hole that still played.
        if opened.film != nil { return nil }
        var files = opened.files
        files.remove(at: index)
        if files.isEmpty, opened.original.isEmpty { return nil }
        return try seal(opened.original, files: files, in: message.channelId)
    }

    /// Whether this private message is one part of a split video. Removing a single piece would break the film.
    func isFilm(_ message: Message) -> Bool {
        open(message)?.film != nil
    }

    /// The text of a private message, or nil if it isn't one or can't be read with our key. A copy that Discord
    /// could have reposted, or one sent from a key that isn't trusted yet, starts with a warning line. Rejected
    /// and excluded keys' messages aren't shown.
    func plaintext(of message: Message) -> String? {
        open(message)?.text
    }

    /// The text of a quoted private message, for a reply's preview line: as sent, without warnings (the message
    /// itself shows those).
    func plaintext(content: String, id: Snowflake, authorID: Snowflake, channelID: Snowflake) -> String? {
        open(PrivateTrustEngine.Message(id: id, authorID: authorID, content: content), in: channelID)?.original
    }

    /// Whether `id` is the first message that carried this salt (so not a copy).
    private func isFirst(salt: Data, id: Snowflake) -> Bool {
        let hex = salt.map { String(format: "%02x", $0) }.joined()
        return engine?.directory.firstWithSalt[hex] == id
    }

    /// The images in a private message, matched to its attachments. Empty if it has none or can't be read.
    func images(of message: Message) -> [PrivateImage] {
        guard let opened = open(message) else { return [] }
        let film = opened.film
        var images = opened.files.enumerated().map { index, file in
            // The attachment at the same position, if it's the size this image's attachment must be.
            let attachment = message.attachments.indices.contains(index) ? message.attachments[index] : nil
            let matches = attachment.map { $0.size == nil || $0.size == file.sealedLength } ?? false
            let span: Double = film?.spans.count == opened.files.count ? (film?.spans[index] ?? 0) : 0
            return PrivateImage(messageID: message.id, index: index, file: file,
                                attachment: matches ? attachment : nil, trusted: opened.trusted,
                                filmID: film?.id, filmPart: (film?.start ?? 0) + index, filmSpan: span,
                                reel: opened.reel, reelPart: (opened.reel?.start ?? 0) + index)
        }
        if let reel = opened.reel, reel.start == 0, opened.trusted, images.first?.attachment != nil {
            let parts = reelParts(reel, author: message.author.id, channelID: message.channelId)
            if parts[0]?.messageID != message.id {
                for index in images.indices { images[index].reelPart = max(images[index].reelPart, 1) }
            }
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

    /// The chunks of a reel in order, or nil while any chunk is missing or invalid.
    func reelChunks(for image: PrivateImage, in channelID: Snowflake) -> [PrivateImage]? {
        guard image.reel != nil, image.reelPart == 0,
              let message = store.messages(in: channelID)?.first(where: { $0.id == image.messageID }),
              let opened = open(message),
              let reel = opened.reel, reel.start == 0 else { return nil }
        let parts = reelParts(reel, author: message.author.id, channelID: channelID)
        guard parts.count == reel.count,
              (0..<reel.count).allSatisfy({ parts[$0] != nil }),
              parts.values.reduce(0, { $0 + $1.file.length }) == reel.bytes else { return nil }
        return (0..<reel.count).compactMap { parts[$0] }
    }

    private func reelParts(_ reel: PrivateReel, author: Snowflake, channelID: Snowflake) -> [Int: PrivateImage] {
        guard #available(macOS 14, *) else { return [:] }
        var chosen: [Int: (snowflake: UInt64, image: PrivateImage)] = [:]
        for message in store.messages(in: channelID) ?? [] where message.author.id == author {
            guard let opened = open(message),
                  let part = opened.reel, part.id == reel.id, part.count == reel.count,
                  part.bytes == reel.bytes, opened.trusted, isFirst(salt: opened.salt, id: message.id),
                  part.start + opened.files.count <= part.count else { continue }
            for (offset, file) in opened.files.enumerated() {
                let index = part.start + offset
                guard file.kind.isReelChunk,
                      let attachment = message.attachments.indices.contains(offset) ? message.attachments[offset] : nil,
                      attachment.size == nil || attachment.size == file.sealedLength else { continue }
                let image = PrivateImage(messageID: message.id, index: offset, file: file, attachment: attachment,
                                         trusted: true, reel: part, reelPart: index)
                let snowflake = message.id.snowflakeValue
                if let existing = chosen[index], existing.snowflake <= snowflake { continue }
                chosen[index] = (snowflake, image)
            }
        }
        return chosen.mapValues(\.image)
    }

    /// The pieces of a film in order, rebuilt from the messages currently loaded. Empty when this message is
    /// not the one that holds piece 0.
    func playbackQueue(forFilmOf image: PrivateImage, in channelID: Snowflake) -> [PrivateImage] {
        guard image.filmID != nil,
              let message = store.messages(in: channelID)?.first(where: { $0.id == image.messageID }),
              let opened = open(message),
              let film = opened.film, film.start == 0 else { return [] }
        let chain = filmChain(of: film.id, author: message.author.id, channelID: channelID)
        guard chain.owner == message.id, let start = chain.start else { return [] }
        return [start] + chain.follows
    }

    /// Piece 0's message, and the pieces after it. Same author only. The oldest message wins an index, a copy or
    /// an untrusted key or a wrong-sized attachment is a gap, and playback stops at the first missing index.
    private func filmChain(of film: Data, author: Snowflake, channelID: Snowflake) -> (owner: Snowflake?, start: PrivateImage?, follows: [PrivateImage]) {
        guard #available(macOS 14, *) else { return (nil, nil, []) }
        let messages = store.messages(in: channelID) ?? []
        let stamp = FilmChainStamp(channelID: channelID, author: author, messageCount: messages.count,
                                   lastMessageID: messages.last?.id, openedGeneration: openedGeneration)
        if let cached = filmChainCache[film], cached.stamp == stamp { return cached.result }
        var chosen: [Int: (snowflake: UInt64, image: PrivateImage)] = [:]
        for message in messages where message.author.id == author {
            guard let opened = open(message),
                  let part = opened.film, part.id == film, opened.trusted,
                  isFirst(salt: opened.salt, id: message.id) else { continue }
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
        let result: FilmChainResult = (owner: chosen[0]?.image.messageID, start: chosen[0]?.image, follows: follows)
        filmChainCache[film] = (stamp, result)
        return result
    }

    private func open(_ message: Message) -> Opened? {
        open(Self.engineMessage(message), in: message.channelId)
    }

    private func open(_ message: PrivateTrustEngine.Message, in channelID: Snowflake) -> Opened? {
        if let cached = opened[message.id], cached.content == message.content { return cached.value }
        guard #available(macOS 14, *), case .encrypted = PrivateMessaging.kind(of: message.content),
              let engine = trust(in: channelID) else { return nil }
        let shown = engine.open(message, in: channelID).map {
            openedResult($0.message, trusted: $0.trusted, warnings: $0.warnings.map(Self.warningText))
        }
        if opened.count > 2000 { clearOpened() }
        opened[message.id] = (message.content, shown)
        return shown
    }

    private static func warningText(_ warning: PrivateTrustEngine.Warning) -> String {
        switch warning {
        case .untrustedSender: return "⚠️ *Sent from a new key you haven't accepted. It may not be them.*"
        case .unapprovedDevice: return "⚠️ *Sent from a device you haven't approved in Settings.*"
        case .copy: return "⚠️ *A copy of an earlier private message. Discord may have resent it.*"
        case .writtenEarlier(let sentAt):
            return "⚠️ *Written \(ProfileText.clockFormatter.string(from: sentAt)), not when it appeared. "
                + "Discord may have resent it.*"
        }
    }

    @available(macOS 14, *)
    private func openedResult(_ result: PrivateCrypto.Opened, trusted: Bool, warnings: [String]) -> Opened {
        var caption = result.text
        var film: PrivateFilm?
        var reel: PrivateReel?
        if PrivateFilmNote.begins(result.text) {
            if let parsed = PrivateFilmNote.parse(result.text),
               !result.files.isEmpty, result.files.allSatisfy({ $0.kind.isVideo }) {
                film = parsed.film
                caption = parsed.caption
            } else {
                return rejectedVideo(result.salt)
            }
        } else if PrivateReelNote.begins(result.text) {
            if let parsed = PrivateReelNote.parse(result.text),
               !result.files.isEmpty, result.files.allSatisfy(\.kind.isReelChunk),
               parsed.reel.start + result.files.count <= parsed.reel.count {
                reel = parsed.reel
                caption = parsed.caption
            } else {
                return rejectedVideo(result.salt)
            }
        } else if result.files.contains(where: \.kind.isReelChunk) {
            return rejectedVideo(result.salt)
        }
        let continues = (film?.start ?? 0) > 0 || (reel?.start ?? 0) > 0
        let body = continues && caption.isEmpty ? "Continues a private video." : caption
        let lines = warnings + (body.isEmpty ? [] : [body])
        return Opened(text: lines.joined(separator: "\n"), original: caption, files: result.files,
                      trusted: trusted, film: film, reel: reel, salt: result.salt)
    }

    private func rejectedVideo(_ salt: Data) -> Opened {
        Opened(text: "This private video's description was rejected, so it isn't shown.",
               original: "", files: [], trusted: false, film: nil, reel: nil, salt: salt)
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
    var reel: PrivateReel?
    var reelPart: Int = 0

    /// By its attachment, which is unique to this image: removing an earlier image shifts the positions.
    var cacheKey: String { attachment.map { "attachment/\($0.id)" } ?? "\(messageID)/\(index)" }
    /// Stands for the image where the message list keys things by URL; never fetched.
    var placeholderURL: URL { URL(string: "duhcord-private://image/" + cacheKey)! }
}

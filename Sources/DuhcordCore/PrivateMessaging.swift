import Compression
import CryptoKit
import Foundation

/// Private messaging: end-to-end encrypted DMs between Duhcord users, carried as ordinary Discord messages.
///
/// The adversary is Discord (and anyone reading what it stores), so the design is PGP-like and stateless:
/// every Duhcord install has one long-term X25519 key, announced in the DM by a handshake message, and each
/// private message's key reaches the recipients through HPKE (RFC 9180) in authenticated mode, so it can only
/// have come from the sender's key. Nothing but the keys has to be kept: history fetched from Discord later
/// decrypts again. Discord relays the keys, so a safety number lets two people check they have each other's.
///
/// Both kinds of message are a styled note line for people on other clients, then one line of data:
///
///     -# encrypted messaging by C4BRA/duhcord 🤫
///     dhc2:<DenseText>
///
/// Discord limits messages by their JavaScript string length (UTF-16 code units), so DenseText packs 15 bits
/// into each character, about 2.5 times what base64 fits, and the text is compressed before it's encrypted.
public enum PrivateMessaging {
    public static let prefix = "dhc2:"
    /// Shown as small grey text ("-#" is Discord's subtext Markdown) on other clients.
    public static let notice = "-# encrypted messaging by C4BRA/duhcord 🤫"

    /// Discord's message limit, counted the way Discord counts it.
    static let maxContentLength = 2000
    /// Plaintext is padded up to a multiple of this, so a message's length says little about its text.
    static let paddingBlock = 128
    /// Recipient devices per message, besides the sender's own.
    public static let maxRecipients = 8
    /// The most a private message may decompress to, so a crafted one can't balloon in memory.
    static let maxPlaintext = 64 * 1024
    /// Images and videos per message.
    public static let maxFiles = 4
    /// Discord's upload limit without Nitro, less room for the rest of the request: what images are sized for, so
    /// four of them fit whatever the account.
    public static let maxUploadBytes = 20 * 1024 * 1024 - 64 * 1024
    /// One encrypted file at most. It's decrypted in memory, so it's capped whatever the account could upload.
    public static let maxFileBytes = 50 * 1024 * 1024
    /// What an encrypted image is called on Discord. It says nothing about what's inside.
    public static let fileName = "encrypted.bin"

    static let messageType: UInt8 = 0x21
    static let handshakeType: UInt8 = 0x22

    public enum Kind: Equatable {
        case plain
        /// A handshake announcing `key`; `wantsReply` when the sender doesn't have our key yet.
        case handshake(key: Data, wantsReply: Bool)
        case encrypted(payload: Data)
    }

    /// What a message is, from its last line. Cheap for ordinary messages: only the last line is looked at, and
    /// nothing is decoded unless it starts with the prefix.
    public static func kind(of content: String) -> Kind {
        let start = content.lastIndex(of: "\n").map { content.index(after: $0) } ?? content.startIndex
        let last = content[start...]
        guard last.hasPrefix(prefix), let data = DenseText.decode(last.dropFirst(prefix.count)),
              let type = data.first else { return .plain }
        switch type {
        case handshakeType where data.count == 34:
            return .handshake(key: Data(data[2..<34]), wantsReply: data[1] & 1 != 0)
        case messageType:
            return .encrypted(payload: data)
        default:
            return .plain
        }
    }

    /// The handshake message announcing `publicKey` (32 raw bytes).
    public static func handshake(publicKey: Data, wantsReply: Bool) -> String {
        var data = Data([handshakeType, wantsReply ? 1 : 0])
        data.append(publicKey)
        return content(for: data)
    }

    static func content(for data: Data) -> String {
        notice + "\n" + prefix + DenseText.encode(data)
    }

    /// The attachment's size for an image of `length` bytes: padded, plus the tag.
    static func sealedLength(forFileOf length: Int) -> Int { padme(length) + 16 }

    /// The most plaintext whose padded, tagged attachment still fits in `budget` bytes, and in what we will decrypt.
    public static func largestPlaintext(sealingWithin budget: Int) -> Int {
        guard budget > 16 else { return 0 }
        var low = 0
        var high = min(maxFileBytes, budget - 16)
        var best = 0
        while low <= high {
            let mid = (low + high) / 2
            if sealedLength(forFileOf: mid) <= budget {
                best = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return best
    }

    /// Padmé: rounds a length up so only about log log of it shows, at most 12% larger.
    static func padme(_ length: Int) -> Int {
        guard length > 1 else { return max(length, 1) }
        let e = Int.bitWidth - 1 - length.leadingZeroBitCount
        let s = Int.bitWidth - e.leadingZeroBitCount
        let mask = (1 << (e - s)) - 1
        return (length + mask) & ~mask
    }

    /// Four bytes identifying a public key in messages.
    public static func keyID(_ publicKey: Data) -> Data {
        Data(SHA256.hash(data: publicKey).prefix(4))
    }

    /// A 60-digit number both people see for the same pair of keys, compared out of band (Duhcord's voice
    /// calls are end-to-end encrypted, so reading it aloud in a call works). Same digits on both sides
    /// whichever way round the keys are given, in twelve groups of five.
    public static func safetyNumber(_ a: Data, _ b: Data) -> String {
        safetyNumber([a], [b])
    }

    /// The same over every key on each side: one person's Macs, and the other's. It only matches when both
    /// people's Duhcord encrypt to exactly the same keys, so a key slipped in on either side changes it.
    public static func safetyNumber(_ a: [Data], _ b: [Data]) -> String {
        func side(_ keys: [Data]) -> Data {
            var data = Data([UInt8(clamping: Set(keys).count)])
            for key in Set(keys).sorted(by: { $0.lexicographicallyPrecedes($1) }) { data.append(key) }
            return data
        }
        let (x, y) = (side(a), side(b))
        let (first, second) = x.lexicographicallyPrecedes(y) ? (x, y) : (y, x)
        var input = Data("duhcord-safety-number-v2".utf8)
        input.append(first)
        input.append(second)
        return digits(of: input, groups: 12)
    }

    /// Thirty digits naming one key, to check that a Mac listed in Settings is really yours: the code under
    /// "This Mac" on that Mac should be the same.
    public static func keyCode(_ key: Data) -> String {
        var input = Data("duhcord-key-code-v1".utf8)
        input.append(key)
        return digits(of: input, groups: 6)
    }

    /// Groups of five digits from a hash of `input` (up to 25 groups).
    private static func digits(of input: Data, groups: Int) -> String {
        // Two hashes give 128 bytes; each group of five digits comes from five of them.
        var bytes = Data(SHA512.hash(data: input))
        bytes.append(contentsOf: SHA512.hash(data: bytes))
        return (0..<groups).map { group -> String in
            let value = bytes[(group * 5)..<(group * 5 + 5)].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            let digits = String(value % 100_000)
            return String(repeating: "0", count: 5 - digits.count) + digits
        }.joined(separator: " ")
    }
}

/// An encrypted image that came with a private message: its key and what it is. Listed inside the message, so
/// only the recipients see it; the encrypted bytes are the message's attachment at the same position.
public struct PrivateFile: Equatable, Sendable {
    public enum Kind: UInt8, Sendable {
        case jpeg = 1, png = 2, mp4 = 3

        public var isVideo: Bool { self == .mp4 }
    }

    /// The image's own key (ChaCha20-Poly1305), random and used once.
    public let key: Data
    /// The image's size in bytes, before padding.
    public let length: Int
    /// The attachment's size: padded, plus the tag. An attachment of any other size isn't this image.
    public let sealedLength: Int
    public let width: Int
    public let height: Int
    public let kind: Kind

    static let encodedSize = 32 + 4 + 4 + 2 + 2 + 1

    public init(key: Data, length: Int, sealedLength: Int, width: Int, height: Int, kind: Kind) {
        self.key = key
        self.length = length
        self.sealedLength = sealedLength
        self.width = width
        self.height = height
        self.kind = kind
    }

    func encoded() -> Data {
        var data = key
        data.append(contentsOf: [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: UInt32(clamping: length) >> $0) })
        data.append(contentsOf: [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: UInt32(clamping: sealedLength) >> $0) })
        data.append(contentsOf: [8, 0].map { UInt8(truncatingIfNeeded: UInt16(clamping: width) >> $0) })
        data.append(contentsOf: [8, 0].map { UInt8(truncatingIfNeeded: UInt16(clamping: height) >> $0) })
        data.append(kind.rawValue)
        return data
    }

    init?(_ data: Data) {
        let d = Data(data)
        guard d.count == Self.encodedSize, let kind = Kind(rawValue: d[44]) else { return nil }
        func number(_ range: Range<Int>) -> Int { d[range].reduce(0) { $0 << 8 | Int($1) } }
        self.init(key: Data(d[0..<32]), length: number(32..<36), sealedLength: number(36..<40),
                  width: number(40..<42), height: number(42..<44), kind: kind)
        guard width > 0, height > 0, length <= PrivateMessaging.maxFileBytes,
              sealedLength == PrivateMessaging.sealedLength(forFileOf: length) else { return nil }
    }
}

/// One stretch of a private video that was split so each attachment stays under Discord's file cap.
/// The id and the index sit in the encrypted message, so they are authenticated with the text and the file keys.
public struct PrivateFilm: Equatable, Sendable {
    /// 16 random bytes, shared by every message of this film and by no other.
    public var id: Data
    /// The index of this message's first piece. The next piece is the next attachment.
    public var start: Int
    /// How long each piece in this message plays, in seconds. Empty when a message was sent before lengths were kept.
    public var spans: [Double]

    public init(id: Data, start: Int, spans: [Double] = []) {
        self.id = id
        self.start = start
        self.spans = spans
    }
}

/// The line a split video puts in front of its caption. It is inside the encrypted body, never in the clear.
public enum PrivateFilmNote {
    static let mark = "\u{1E}film/"

    /// Whether `text` starts with a film note, well formed or not. A broken one is rejected, not shown.
    public static func begins(_ text: String) -> Bool { text.hasPrefix(mark) }

    public static func newID() -> Data {
        SymmetricKey(size: SymmetricKeySize(bitCount: 128)).withUnsafeBytes { Data($0) }
    }

    public static func text(caption: String, film: PrivateFilm) -> String {
        var head = mark + film.id.map { String(format: "%02x", $0) }.joined() + "/\(film.start)"
        if !film.spans.isEmpty {
            head += "/" + film.spans.map { String(Int(($0 * 1000).rounded())) }.joined(separator: ",")
        }
        return head + "\n" + caption
    }

    /// Nil unless `text` begins with a well-formed note. Anything else is left for the caller to reject.
    /// A note from before piece lengths were kept has no third field, and still parses.
    public static func parse(_ text: String) -> (film: PrivateFilm, caption: String)? {
        guard text.hasPrefix(mark) else { return nil }
        let body = text.dropFirst(mark.count)
        guard let newline = body.firstIndex(of: "\n") else { return nil }
        let header = body[..<newline]
        let fields = header.split(separator: "/", omittingEmptySubsequences: false)
        guard fields.count == 2 || fields.count == 3 else { return nil }
        let hex = fields[0]
        let startText = fields[1]
        guard hex.count == 32, hex.allSatisfy(isHex), startText.allSatisfy(isDigit),
              let start = Int(startText), (0...100_000).contains(start) else { return nil }
        var spans: [Double] = []
        if fields.count == 3 {
            let parts = fields[2].split(separator: ",", omittingEmptySubsequences: false)
            guard (1...PrivateMessaging.maxFiles).contains(parts.count) else { return nil }
            for part in parts {
                guard part.allSatisfy(isDigit), let ms = Int(part), (1...86_400_000).contains(ms) else { return nil }
                spans.append(Double(ms) / 1000)
            }
        }
        var id = Data()
        var cursor = hex.startIndex
        while cursor < hex.endIndex {
            let next = hex.index(cursor, offsetBy: 2)
            guard let byte = UInt8(hex[cursor..<next], radix: 16) else { return nil }
            id.append(byte)
            cursor = next
        }
        guard id.count == 16 else { return nil }
        return (PrivateFilm(id: id, start: start, spans: spans), String(body[body.index(after: newline)...]))
    }

    private static func isDigit(_ character: Character) -> Bool {
        character.isASCII && character.isNumber
    }

    private static func isHex(_ character: Character) -> Bool {
        isDigit(character) || ("a"..."f").contains(character)
    }
}

public enum PrivateMessagingError: Error, LocalizedError, Equatable {
    case tooLong
    case noRecipients
    case tooManyRecipients
    case tooManyFiles
    case filesTooLarge

    public var errorDescription: String? {
        switch self {
        case .tooLong: return "This private message is too long to fit in one Discord message, even encrypted and compressed."
        case .noRecipients: return "There's no key to encrypt this message to yet."
        case .tooManyRecipients:
            return "This message would go to more than \(PrivateMessaging.maxRecipients) keys. Remove a Mac in Settings, "
                + "or ask the other person to."
        case .tooManyFiles: return "A message can carry up to \(PrivateMessaging.maxFiles) images and videos."
        case .filesTooLarge: return "These files are too large to send together. Send fewer at a time."
        }
    }
}

/// Sealing and opening private messages. HPKE needs macOS 14.
///
/// Wire format (then DenseText):
///
///     21 | flags (1) | sender key ID (4) | sent at (4) | salt (16) | n (1)
///        | n × [key ID (4) | encapsulated key (32) | wrapped key (32)] | ChaCha20-Poly1305 ciphertext | tag (16)
///
/// - The message key is derived from the sender's own private key and the random salt (HKDF-SHA256), so the
///   sender can always re-derive it to read what they sent, and it's different for every message.
/// - Each recipient gets it through HPKE (X25519, HKDF-SHA256, auth mode): the key XORed with a secret
///   exported from an HPKE context that only that recipient and the sender's key can produce. HPKE's info binds
///   the channel, so Discord can't move a message into another DM.
/// - The body is encrypted with the message key. The key is never reused, so the nonce is fixed (zero), and
///   everything before the body is authenticated with it, so the recipient list and flags can't be altered.
/// - Flags bit 0: the text was compressed (raw DEFLATE) before being padded and encrypted.
/// - Flags bit 1: the message carries images. The text then starts with a list of them, `count (1) | count ×
///   [key (32) | length (4) | sealed length (4) | width (2) | height (2) | kind (1)]`, and the rest is the text.
///   Each image is encrypted on its own with its key and uploaded as the message's attachment at the same
///   position, padded (Padmé) so its size says little about the picture.
/// - "Sent at" is when the sender sealed it (Unix seconds), authenticated with the rest, so a copy Discord
///   reposts later can be recognised by the gap between this and the copy's own time.
@available(macOS 14, *)
public enum PrivateCrypto {
    private static let suite = HPKE.Ciphersuite.Curve25519_SHA256_ChachaPoly
    private static let entrySize = 4 + 32 + 32
    private static let fixedHeader = 1 + 1 + 4 + 4 + 16 + 1

    /// An opened private message.
    public struct Opened: Equatable {
        public let text: String
        /// When the sender sealed it.
        public let sentAt: Date
        /// Unique to the message: a second message with the same salt is a copy of the first.
        public let salt: Data
        /// Images, in the order of the message's attachments.
        public var files: [PrivateFile] = []
    }
    private static let exportContext = Data("duhcord-message-key".utf8)
    private static let zeroNonce = try! ChaChaPoly.Nonce(data: Data(count: 12))

    private static func info(channelID: Snowflake) -> Data { Data("duhcord-private-v2/\(channelID)".utf8) }

    /// The message key: only the sender's private key and the salt can produce it.
    private static func messageKey(_ sender: Curve25519.KeyAgreement.PrivateKey, salt: Data, channelID: Snowflake) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: sender.rawRepresentation), salt: salt,
                               info: Data("duhcord-message-key-v2/\(channelID)".utf8), outputByteCount: 32)
    }

    /// The full message content for `text`: the note line and the sealed data. The sender's own key in
    /// `recipients` is skipped (the sender re-derives the message key instead).
    public static func seal(_ text: String, files: [PrivateFile] = [], channelID: Snowflake,
                            sender: Curve25519.KeyAgreement.PrivateKey, recipients: [Curve25519.KeyAgreement.PublicKey],
                            now: Date = Date()) throws -> String {
        let own = sender.publicKey.rawRepresentation
        var unique: [Data: Curve25519.KeyAgreement.PublicKey] = [:]
        for key in recipients where key.rawRepresentation != own { unique[key.rawRepresentation] = key }
        // Never leave a key out quietly: whoever it belongs to would get messages they can't read.
        guard unique.count <= PrivateMessaging.maxRecipients else { throw PrivateMessagingError.tooManyRecipients }
        let keys = Array(unique.values)
        guard !keys.isEmpty else { throw PrivateMessagingError.noRecipients }

        guard files.count <= PrivateMessaging.maxFiles else { throw PrivateMessagingError.tooManyFiles }
        var raw = Data()
        if !files.isEmpty {
            raw.append(UInt8(files.count))
            for file in files { raw.append(file.encoded()) }
        }
        raw.append(Data(text.utf8))
        guard raw.count <= PrivateMessaging.maxPlaintext else { throw PrivateMessagingError.tooLong }
        let compressed = Deflate.compress(raw)
        let salt = SymmetricKey(size: SymmetricKeySize(bitCount: 128)).withUnsafeBytes { Data($0) }
        let key = messageKey(sender, salt: salt, channelID: channelID)
        let keyBytes = key.withUnsafeBytes { Data($0) }

        let flags: UInt8 = (compressed == nil ? 0 : 1) | (files.isEmpty ? 0 : 2)
        var header = Data([PrivateMessaging.messageType, flags])
        header.append(PrivateMessaging.keyID(own))
        let seconds = UInt32(clamping: Int(now.timeIntervalSince1970))
        header.append(contentsOf: [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: seconds >> $0) })
        header.append(salt)
        header.append(UInt8(keys.count))
        for recipient in keys {
            let hpke = try HPKE.Sender(recipientKey: recipient, ciphersuite: suite, info: info(channelID: channelID),
                                       authenticatedBy: sender)
            let mask = try hpke.exportSecret(context: exportContext, outputByteCount: 32).withUnsafeBytes { Data($0) }
            header.append(PrivateMessaging.keyID(recipient.rawRepresentation))
            header.append(hpke.encapsulatedKey)
            header.append(Data(zip(keyBytes, mask).map { $0 ^ $1 }))
        }
        let box = try ChaChaPoly.seal(pad(compressed ?? raw), using: key, nonce: zeroNonce, authenticating: header)
        let content = PrivateMessaging.content(for: header + box.ciphertext + box.tag)
        guard content.utf16.count <= PrivateMessaging.maxContentLength else { throw PrivateMessagingError.tooLong }
        return content
    }

    /// The text of a private message, if it was sealed to `recipient` by one of `senders`
    /// or by `recipient` when `fromSelf` is true.
    public static func open(_ payload: Data, channelID: Snowflake, recipient: Curve25519.KeyAgreement.PrivateKey,
                            senders: [Curve25519.KeyAgreement.PublicKey], fromSelf: Bool) -> Opened? {
        let data = Data(payload)
        guard data.count > fixedHeader, data[0] == PrivateMessaging.messageType else { return nil }
        let flags = data[1]
        let senderID = data[2..<6]
        let sentAt = data[6..<10].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        let salt = data[10..<26]
        let count = Int(data[26])
        let headerEnd = fixedHeader + count * entrySize
        guard count <= PrivateMessaging.maxRecipients, data.count >= headerEnd + 16 else { return nil }

        let myID = PrivateMessaging.keyID(recipient.publicKey.rawRepresentation)
        // Possible message keys: re-derived for our own message, else one per sender key with this ID (an ID
        // shared by a planted key can't hide the real sender's key).
        var keys: [SymmetricKey] = []
        if fromSelf && senderID == myID { keys.append(messageKey(recipient, salt: salt, channelID: channelID)) }
        if let start = (0..<count).map({ fixedHeader + $0 * entrySize }).first(where: { data[$0..<($0 + 4)] == myID }) {
            for sender in senders where PrivateMessaging.keyID(sender.rawRepresentation) == senderID {
                guard let hpke = try? HPKE.Recipient(privateKey: recipient, ciphersuite: suite, info: info(channelID: channelID),
                                                     encapsulatedKey: data[(start + 4)..<(start + 36)], authenticatedBy: sender),
                      let mask = try? hpke.exportSecret(context: exportContext, outputByteCount: 32).withUnsafeBytes({ Data($0) })
                else { continue }
                keys.append(SymmetricKey(data: Data(zip(data[(start + 36)..<(start + entrySize)], mask).map { $0 ^ $1 })))
            }
        }
        guard let box = try? ChaChaPoly.SealedBox(nonce: zeroNonce, ciphertext: data[headerEnd..<(data.count - 16)],
                                                  tag: data[(data.count - 16)...]),
              let padded = keys.lazy.compactMap({ try? ChaChaPoly.open(box, using: $0, authenticating: data[0..<headerEnd]) }).first,
              let inner = unpad(padded) else { return nil }
        guard var bytes = flags & 1 != 0 ? Deflate.decompress(inner, limit: PrivateMessaging.maxPlaintext) : Data(inner)
        else { return nil }
        var files: [PrivateFile] = []
        if flags & 2 != 0 {
            guard let count = bytes.first.map(Int.init), (1...PrivateMessaging.maxFiles).contains(count),
                  bytes.count >= 1 + count * PrivateFile.encodedSize else { return nil }
            for i in 0..<count {
                let start = bytes.startIndex + 1 + i * PrivateFile.encodedSize
                guard let file = PrivateFile(bytes[start..<(start + PrivateFile.encodedSize)]) else { return nil }
                files.append(file)
            }
            bytes = Data(bytes.dropFirst(1 + count * PrivateFile.encodedSize))
        }
        guard let text = String(data: bytes, encoding: .utf8) else { return nil }
        return Opened(text: text, sentAt: Date(timeIntervalSince1970: TimeInterval(sentAt)), salt: Data(salt), files: files)
    }

    // MARK: - Images

    private static let fileContext = Data("duhcord-file-v1".utf8)

    /// Encrypts an image with a new key of its own. The returned file goes in the message (`seal(_:files:…)`);
    /// the data is uploaded as its attachment.
    public static func sealFile(_ image: Data, width: Int, height: Int, kind: PrivateFile.Kind) throws -> (file: PrivateFile, sealed: Data) {
        guard image.count <= PrivateMessaging.maxFileBytes else { throw PrivateMessagingError.filesTooLarge }
        let key = SymmetricKey(size: .bits256)
        var padded = image
        padded.append(Data(count: PrivateMessaging.padme(image.count) - image.count))
        let box = try ChaChaPoly.seal(padded, using: key, nonce: zeroNonce, authenticating: fileContext)
        let file = PrivateFile(key: key.withUnsafeBytes { Data($0) }, length: image.count, sealedLength: padded.count + 16,
                               width: width, height: height, kind: kind)
        return (file, box.ciphertext + box.tag)
    }

    /// The image from its attachment's bytes, or nil if they aren't the image this file describes.
    public static func openFile(_ sealed: Data, file: PrivateFile) -> Data? {
        guard sealed.count == file.sealedLength, file.key.count == 32,
              let box = try? ChaChaPoly.SealedBox(nonce: zeroNonce, ciphertext: sealed.prefix(sealed.count - 16),
                                                  tag: sealed.suffix(16)),
              let padded = try? ChaChaPoly.open(box, using: SymmetricKey(data: file.key), authenticating: fileContext)
        else { return nil }
        return padded.prefix(file.length)
    }

    /// Two-byte length, then zero padding to the next block.
    static func pad(_ data: Data) -> Data {
        var out = Data([UInt8(data.count >> 8 & 0xFF), UInt8(data.count & 0xFF)])
        out.append(data)
        let block = PrivateMessaging.paddingBlock
        out.append(Data(count: (block - out.count % block) % block))
        return out
    }

    static func unpad(_ data: Data) -> Data? {
        guard data.count >= 2 else { return nil }
        let length = Int(data[data.startIndex]) << 8 | Int(data[data.startIndex + 1])
        guard length <= data.count - 2 else { return nil }
        return data.dropFirst(2).prefix(length)
    }
}

/// Raw DEFLATE through Apple's Compression framework.
enum Deflate {
    /// The compressed bytes, or nil when compressing wouldn't make them smaller.
    static func compress(_ data: Data) -> Data? {
        guard data.count > 16 else { return nil }
        var out = Data(count: data.count)
        let written = out.withUnsafeMutableBytes { dst in
            data.withUnsafeBytes { src in
                compression_encode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, dst.count,
                                          src.bindMemory(to: UInt8.self).baseAddress!, src.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0, written < data.count else { return nil }
        return out.prefix(written)
    }

    /// Nil if it isn't valid DEFLATE or would come to more than `limit` bytes.
    static func decompress(_ data: Data, limit: Int) -> Data? {
        guard !data.isEmpty else { return nil }
        var out = Data(count: limit + 1)
        let written = out.withUnsafeMutableBytes { dst in
            data.withUnsafeBytes { src in
                compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, dst.count,
                                          src.bindMemory(to: UInt8.self).baseAddress!, src.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0, written <= limit else { return nil }
        return out.prefix(written)
    }
}

/// 15 bits per character. Discord counts a message's length in UTF-16 code units, and every character here is
/// one: CJK Extension A (U+3400–U+4DBF), the CJK Unified Ideographs (U+4E00–U+9FFF) and the first Hangul
/// syllables (U+AC00–U+C03F), 32,768 assigned characters that Unicode normalisation leaves alone. A final group of
/// up to 7 bits uses the next 128 Hangul syllables (U+C040–U+C0BF), so the decoder knows where the data ends.
enum DenseText {
    private static func character(_ value: UInt32) -> Unicode.Scalar {
        let code: UInt32
        switch value {
        case 0..<6592: code = 0x3400 + value
        case 6592..<27584: code = 0x4E00 + value - 6592
        default: code = 0xAC00 + value - 27584
        }
        return Unicode.Scalar(code)!
    }

    private static func value(_ scalar: Unicode.Scalar) -> UInt32? {
        switch scalar.value {
        case 0x3400...0x4DBF: return scalar.value - 0x3400
        case 0x4E00...0x9FFF: return scalar.value - 0x4E00 + 6592
        case 0xAC00...0xC03F: return scalar.value - 0xAC00 + 27584
        default: return nil
        }
    }

    static func encode(_ data: Data) -> String {
        var scalars = String.UnicodeScalarView()
        var acc: UInt32 = 0
        var bits = 0
        for byte in data {
            acc = acc << 8 | UInt32(byte)
            bits += 8
            while bits >= 15 {
                bits -= 15
                scalars.append(character(acc >> UInt32(bits) & 0x7FFF))
            }
            acc &= (1 << UInt32(bits)) - 1
        }
        if bits > 7 {
            scalars.append(character(acc << UInt32(15 - bits) & 0x7FFF))
        } else if bits > 0 {
            scalars.append(Unicode.Scalar(0xC040 + (acc << UInt32(7 - bits) & 0x7F))!)
        }
        return String(scalars)
    }

    static func decode<S: StringProtocol>(_ text: S) -> Data? {
        let scalars = Array(text.unicodeScalars)
        var out = Data()
        out.reserveCapacity(scalars.count * 15 / 8)
        var acc: UInt32 = 0
        var bits = 0
        for (index, scalar) in scalars.enumerated() {
            if let v = value(scalar) {
                acc = acc << 15 | v
                bits += 15
            } else if index == scalars.count - 1, (0xC040...0xC0BF).contains(scalar.value) {
                acc = acc << 7 | (scalar.value - 0xC040)
                bits += 7
            } else {
                return nil
            }
            while bits >= 8 {
                bits -= 8
                out.append(UInt8(acc >> UInt32(bits) & 0xFF))
            }
            acc &= (1 << UInt32(bits)) - 1
        }
        return out
    }
}

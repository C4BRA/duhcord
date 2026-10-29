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
    static let maxRecipients = 8
    /// The most a private message may decompress to, so a crafted one can't balloon in memory.
    static let maxPlaintext = 64 * 1024

    static let messageType: UInt8 = 0x21
    static let handshakeType: UInt8 = 0x22

    public enum Kind: Equatable {
        case plain
        /// A handshake announcing `key`; `wantsReply` when the sender doesn't have our key yet.
        case handshake(key: Data, wantsReply: Bool)
        case encrypted(payload: Data)
    }

    /// What a message is, from its last line.
    public static func kind(of content: String) -> Kind {
        guard let last = content.split(separator: "\n", omittingEmptySubsequences: true).last, last.hasPrefix(prefix),
              let data = DenseText.decode(last.dropFirst(prefix.count)), let type = data.first else { return .plain }
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

    /// Four bytes identifying a public key in messages.
    public static func keyID(_ publicKey: Data) -> Data {
        Data(SHA256.hash(data: publicKey).prefix(4))
    }

    /// A 60-digit number both people see for the same pair of keys, compared out of band (Duhcord's voice
    /// calls are end-to-end encrypted, so reading it aloud in a call works). Same digits on both sides
    /// whichever way round the keys are given, in twelve groups of five.
    public static func safetyNumber(_ a: Data, _ b: Data) -> String {
        let (first, second) = a.lexicographicallyPrecedes(b) ? (a, b) : (b, a)
        var input = Data("duhcord-safety-number-v1".utf8)
        input.append(first)
        input.append(second)
        // Two hashes give 128 bytes; each group of five digits comes from five of them.
        var bytes = Data(SHA512.hash(data: input))
        bytes.append(contentsOf: SHA512.hash(data: bytes))
        return (0..<12).map { group -> String in
            let value = bytes[(group * 5)..<(group * 5 + 5)].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            let digits = String(value % 100_000)
            return String(repeating: "0", count: 5 - digits.count) + digits
        }.joined(separator: " ")
    }
}

public enum PrivateMessagingError: Error, LocalizedError, Equatable {
    case tooLong
    case noRecipients

    public var errorDescription: String? {
        switch self {
        case .tooLong: return "This private message is too long to fit in one Discord message, even encrypted and compressed."
        case .noRecipients: return "There's no key to encrypt this message to yet."
        }
    }
}

/// Sealing and opening private messages. HPKE needs macOS 14.
///
/// Wire format (then DenseText):
///
///     21 | flags (1) | sender key ID (4) | salt (16) | n (1) | n × [key ID (4) | encapsulated key (32) | wrapped key (32)]
///        | ChaCha20-Poly1305 ciphertext | tag (16)
///
/// - The message key is derived from the sender's own private key and the random salt (HKDF-SHA256), so the
///   sender can always re-derive it to read what they sent, and it's different for every message.
/// - Each recipient gets it through HPKE (X25519, HKDF-SHA256, auth mode): the key XORed with a secret
///   exported from an HPKE context that only that recipient and the sender's key can produce. HPKE's info binds
///   the channel, so Discord can't move a message into another DM.
/// - The body is encrypted with the message key. The key is never reused, so the nonce is fixed (zero), and
///   everything before the body is authenticated with it, so the recipient list and flags can't be altered.
/// - Flags bit 0: the text was compressed (raw DEFLATE) before being padded and encrypted.
@available(macOS 14, *)
public enum PrivateCrypto {
    private static let suite = HPKE.Ciphersuite.Curve25519_SHA256_ChachaPoly
    private static let entrySize = 4 + 32 + 32
    private static let fixedHeader = 1 + 1 + 4 + 16 + 1
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
    public static func seal(_ text: String, channelID: Snowflake, sender: Curve25519.KeyAgreement.PrivateKey,
                            recipients: [Curve25519.KeyAgreement.PublicKey]) throws -> String {
        let own = sender.publicKey.rawRepresentation
        var unique: [Data: Curve25519.KeyAgreement.PublicKey] = [:]
        for key in recipients where key.rawRepresentation != own { unique[key.rawRepresentation] = key }
        let keys = Array(unique.values.prefix(PrivateMessaging.maxRecipients))
        guard !keys.isEmpty else { throw PrivateMessagingError.noRecipients }

        let raw = Data(text.utf8)
        guard raw.count <= PrivateMessaging.maxPlaintext else { throw PrivateMessagingError.tooLong }
        let compressed = Deflate.compress(raw)
        let salt = SymmetricKey(size: SymmetricKeySize(bitCount: 128)).withUnsafeBytes { Data($0) }
        let key = messageKey(sender, salt: salt, channelID: channelID)
        let keyBytes = key.withUnsafeBytes { Data($0) }

        var header = Data([PrivateMessaging.messageType, compressed == nil ? 0 : 1])
        header.append(PrivateMessaging.keyID(own))
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

    /// The text of a private message, if it was sealed to `recipient` (or by it) by one of `senders` in this channel.
    public static func open(_ payload: Data, channelID: Snowflake, recipient: Curve25519.KeyAgreement.PrivateKey,
                            senders: [Curve25519.KeyAgreement.PublicKey]) -> String? {
        let data = Data(payload)
        guard data.count > fixedHeader, data[0] == PrivateMessaging.messageType else { return nil }
        let flags = data[1]
        let senderID = data[2..<6]
        let salt = data[6..<22]
        let count = Int(data[22])
        let headerEnd = fixedHeader + count * entrySize
        guard count <= PrivateMessaging.maxRecipients, data.count >= headerEnd + 16 else { return nil }

        let myID = PrivateMessaging.keyID(recipient.publicKey.rawRepresentation)
        let key: SymmetricKey
        if senderID == myID {
            // Our own message: re-derive its key.
            key = messageKey(recipient, salt: salt, channelID: channelID)
        } else {
            guard let sender = senders.first(where: { PrivateMessaging.keyID($0.rawRepresentation) == senderID }),
                  let start = (0..<count).map({ fixedHeader + $0 * entrySize }).first(where: { data[$0..<($0 + 4)] == myID }),
                  let hpke = try? HPKE.Recipient(privateKey: recipient, ciphersuite: suite, info: info(channelID: channelID),
                                                 encapsulatedKey: data[(start + 4)..<(start + 36)], authenticatedBy: sender),
                  let mask = try? hpke.exportSecret(context: exportContext, outputByteCount: 32).withUnsafeBytes({ Data($0) })
            else { return nil }
            key = SymmetricKey(data: Data(zip(data[(start + 36)..<(start + entrySize)], mask).map { $0 ^ $1 }))
        }
        guard let box = try? ChaChaPoly.SealedBox(nonce: zeroNonce, ciphertext: data[headerEnd..<(data.count - 16)],
                                                  tag: data[(data.count - 16)...]),
              let padded = try? ChaChaPoly.open(box, using: key, authenticating: data[0..<headerEnd]),
              let inner = unpad(padded) else { return nil }
        let text = flags & 1 != 0 ? Deflate.decompress(inner, limit: PrivateMessaging.maxPlaintext) : inner
        return text.flatMap { String(data: $0, encoding: .utf8) }
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
/// syllables (U+AC00–U+BC3F), 32,768 assigned characters that Unicode normalisation leaves alone. A final group of
/// up to 7 bits uses the next 128 Hangul syllables (U+BC40–U+BCBF), so the decoder knows where the data ends.
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
        case 0xAC00...0xBC3F: return scalar.value - 0xAC00 + 27584
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
            scalars.append(Unicode.Scalar(0xBC40 + (acc << UInt32(7 - bits) & 0x7F))!)
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
            } else if index == scalars.count - 1, (0xBC40...0xBCBF).contains(scalar.value) {
                acc = acc << 7 | (scalar.value - 0xBC40)
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

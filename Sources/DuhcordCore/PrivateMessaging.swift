import CryptoKit
import Foundation

/// Private messaging: end-to-end encrypted DMs between Duhcord users, carried as ordinary Discord messages.
///
/// The adversary is Discord (and anyone reading what it stores), so the design is PGP-like and stateless:
/// every Duhcord install has one long-term X25519 key, announced in the DM by a handshake message, and each
/// private message is sealed to the recipients' keys with HPKE (RFC 9180) in authenticated mode, so it can only
/// have come from the sender's key. Nothing but the keys has to be kept: history fetched from Discord later
/// decrypts again. Discord relays the keys, so a safety number lets two people check they have each other's.
///
/// Both kinds of message start with a line people on other clients can read, then one line of data:
///
///     🔒 Private message. Open it in Duhcord to read it.
///     dhc1:<base64url>
public enum PrivateMessaging {
    public static let messagePrefix = "dhc1:"
    public static let handshakePrefix = "dhk1:"
    public static let messageNotice = "🔒 Private message. Open it in Duhcord to read it."
    public static let handshakeNotice = "🔒 I'd like to chat privately. In Duhcord, this sets up end-to-end encryption."

    /// Discord's message limit.
    static let maxContentLength = 2000
    /// Plaintext is padded up to a multiple of this, so a message's length says little about its text.
    static let paddingBlock = 128
    /// Recipient devices per message (theirs and ours). More than enough for a few Macs each.
    static let maxRecipients = 8

    public enum Kind: Equatable {
        case plain
        /// A handshake announcing `key`; `wantsReply` when the sender doesn't have our key yet.
        case handshake(key: Data, wantsReply: Bool)
        case encrypted(payload: Data)
    }

    /// What a message is, from its last line.
    public static func kind(of content: String) -> Kind {
        guard let last = content.split(separator: "\n", omittingEmptySubsequences: true).last else { return .plain }
        if last.hasPrefix(handshakePrefix), let data = Base64URL.decode(String(last.dropFirst(handshakePrefix.count))),
           data.count == 34, data[0] == 1 {
            return .handshake(key: Data(data[2..<34]), wantsReply: data[1] & 1 != 0)
        }
        if last.hasPrefix(messagePrefix), let data = Base64URL.decode(String(last.dropFirst(messagePrefix.count))) {
            return .encrypted(payload: data)
        }
        return .plain
    }

    /// The handshake message announcing `publicKey` (32 raw bytes).
    public static func handshake(publicKey: Data, wantsReply: Bool) -> String {
        var data = Data([1, wantsReply ? 1 : 0])
        data.append(publicKey)
        return handshakeNotice + "\n" + handshakePrefix + Base64URL.encode(data)
    }

    /// Eight bytes identifying a public key in messages.
    public static func keyID(_ publicKey: Data) -> Data {
        Data(SHA256.hash(data: publicKey).prefix(8))
    }

    /// A 60-digit number both people see for the same pair of keys, compared out of band (Duhcord's voice
    /// calls are end-to-end encrypted, so reading it aloud in a call works). Same digits on both sides
    /// whichever way round the keys are given, in twelve groups of five.
    public static func safetyNumber(_ a: Data, _ b: Data) -> String {
        let (first, second) = a.lexicographicallyPrecedes(b) ? (a, b) : (b, a)
        var input = Data("duhcord-safety-number-v1".utf8)
        input.append(first)
        input.append(second)
        // Two hashes give 64 bytes; each group of five digits comes from five of them.
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
        case .tooLong: return "This private message is too long. Private messages can be up to about 1,000 characters."
        case .noRecipients: return "There's no key to encrypt this message to yet."
        }
    }
}

/// Sealing and opening private messages. HPKE needs macOS 14.
///
/// Wire format (then base64url):
///
///     01 | sender key ID (8) | n (1) | n × [recipient key ID (8) | encapsulated key (32) | sealed content key (48)]
///        | ChaChaPoly-sealed body (nonce 12 | ciphertext | tag 16)
///
/// A random content key encrypts the body once; HPKE (X25519, HKDF-SHA256, ChaCha20-Poly1305, auth mode) seals
/// that key to each recipient. HPKE's info binds the channel, so Discord can't move a message to another DM, and
/// the body's associated data is everything before it, so the recipient list can't be altered either.
@available(macOS 14, *)
public enum PrivateCrypto {
    private static let suite = HPKE.Ciphersuite.Curve25519_SHA256_ChachaPoly
    private static let entrySize = 8 + 32 + 48

    private static func info(channelID: Snowflake) -> Data { Data("duhcord-private-v1/\(channelID)".utf8) }

    /// The full message content for `text`: the notice line and the sealed data.
    public static func seal(_ text: String, channelID: Snowflake, sender: Curve25519.KeyAgreement.PrivateKey,
                            recipients: [Curve25519.KeyAgreement.PublicKey]) throws -> String {
        var unique: [Data: Curve25519.KeyAgreement.PublicKey] = [:]
        for key in recipients { unique[key.rawRepresentation] = key }
        let keys = Array(unique.values.prefix(PrivateMessaging.maxRecipients))
        guard !keys.isEmpty else { throw PrivateMessagingError.noRecipients }

        let contentKey = SymmetricKey(size: .bits256)
        let keyBytes = contentKey.withUnsafeBytes { Data($0) }
        var header = Data([1])
        header.append(PrivateMessaging.keyID(sender.publicKey.rawRepresentation))
        header.append(UInt8(keys.count))
        for key in keys {
            var hpke = try HPKE.Sender(recipientKey: key, ciphersuite: suite, info: info(channelID: channelID),
                                       authenticatedBy: sender)
            let sealedKey = try hpke.seal(keyBytes)
            header.append(PrivateMessaging.keyID(key.rawRepresentation))
            header.append(hpke.encapsulatedKey)
            header.append(sealedKey)
        }
        let body = try ChaChaPoly.seal(pad(Data(text.utf8)), using: contentKey, authenticating: header).combined
        let content = PrivateMessaging.messageNotice + "\n" + PrivateMessaging.messagePrefix + Base64URL.encode(header + body)
        guard content.count <= PrivateMessaging.maxContentLength else { throw PrivateMessagingError.tooLong }
        return content
    }

    /// The text of a private message, if it was sealed to `recipient` by one of `senders` in this channel.
    public static func open(_ payload: Data, channelID: Snowflake, recipient: Curve25519.KeyAgreement.PrivateKey,
                            senders: [Curve25519.KeyAgreement.PublicKey]) -> String? {
        let data = Data(payload)
        guard data.count > 10, data[data.startIndex] == 1 else { return nil }
        let base = data.startIndex
        let senderID = data[(base + 1)..<(base + 9)]
        let count = Int(data[base + 9])
        let headerEnd = base + 10 + count * entrySize
        guard count > 0, count <= PrivateMessaging.maxRecipients, data.count >= headerEnd - base + 28,
              let sender = senders.first(where: { PrivateMessaging.keyID($0.rawRepresentation) == senderID }) else { return nil }
        let myID = PrivateMessaging.keyID(recipient.publicKey.rawRepresentation)
        for index in 0..<count {
            let start = base + 10 + index * entrySize
            guard data[start..<(start + 8)] == myID else { continue }
            do {
                var hpke = try HPKE.Recipient(privateKey: recipient, ciphersuite: suite, info: info(channelID: channelID),
                                              encapsulatedKey: data[(start + 8)..<(start + 40)], authenticatedBy: sender)
                let keyBytes = try hpke.open(data[(start + 40)..<(start + entrySize)])
                let box = try ChaChaPoly.SealedBox(combined: data[headerEnd...])
                let padded = try ChaChaPoly.open(box, using: SymmetricKey(data: keyBytes),
                                                 authenticating: data[base..<headerEnd])
                return unpad(padded).flatMap { String(data: $0, encoding: .utf8) }
            } catch {
                return nil
            }
        }
        return nil
    }

    /// Length-prefixed, then zero-padded to the next block.
    static func pad(_ data: Data) -> Data {
        var out = withUnsafeBytes(of: UInt32(data.count).bigEndian) { Data($0) }
        out.append(data)
        let block = PrivateMessaging.paddingBlock
        out.append(Data(count: (block - out.count % block) % block))
        return out
    }

    static func unpad(_ data: Data) -> Data? {
        guard data.count >= 4 else { return nil }
        let length = data.prefix(4).reduce(0) { $0 << 8 | Int($1) }
        guard length <= data.count - 4 else { return nil }
        return data.dropFirst(4).prefix(length)
    }
}

/// URL-safe base64 without padding, so the data line has no characters Markdown or links would touch.
enum Base64URL {
    static func encode(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decode(_ string: String) -> Data? {
        var s = string.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        guard s.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "+" || $0 == "/" }) else { return nil }
        s += String(repeating: "=", count: (4 - s.count % 4) % 4)
        return Data(base64Encoded: s)
    }
}

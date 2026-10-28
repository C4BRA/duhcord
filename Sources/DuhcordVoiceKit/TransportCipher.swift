import CryptoKit
import Foundation

/// Packet encryption between us and Discord's voice server (the "rtpsize" AEAD modes). This sits underneath
/// DAVE: the voice server can strip this layer, but not the end-to-end one inside it.
///
/// Every packet carries a 32-bit counter as its nonce, appended after the tag. The RTP header (and the
/// extension preamble, when present) is authenticated but not encrypted.
public struct TransportCipher {
    public enum Mode: String, CaseIterable {
        /// Preferred: hardware AES on Apple silicon.
        case aes256GCM = "aead_aes256_gcm_rtpsize"
        /// Always offered by Discord; used when the server has no AES mode.
        case xChaCha20Poly1305 = "aead_xchacha20_poly1305_rtpsize"

        /// The best mode the server offers that we support.
        public static func preferred(from offered: [String]) -> Mode? {
            allCases.first { offered.contains($0.rawValue) }
        }
    }

    public static let tagSize = 16
    public static let nonceSize = 4

    public let mode: Mode
    private let key: SymmetricKey

    /// `secretKey` is the 32-byte key from the voice server's session description.
    public init?(mode: Mode, secretKey: [UInt8]) {
        guard secretKey.count == 32 else { return nil }
        self.mode = mode
        key = SymmetricKey(data: secretKey)
    }

    /// Returns ciphertext, tag and the 4-byte nonce, ready to follow `header`.
    public func seal(_ payload: [UInt8], header: [UInt8], nonce: UInt32) throws -> [UInt8] {
        let counter = Self.bigEndian(nonce)
        switch mode {
        case .aes256GCM:
            let box = try AES.GCM.seal(payload, using: key, nonce: AES.GCM.Nonce(data: counter + [UInt8](repeating: 0, count: 8)),
                                       authenticating: header)
            return [UInt8](box.ciphertext) + [UInt8](box.tag) + counter
        case .xChaCha20Poly1305:
            let (subkey, nonce) = xChaChaKeyAndNonce(counter)
            let box = try ChaChaPoly.seal(payload, using: subkey, nonce: nonce, authenticating: header)
            return [UInt8](box.ciphertext) + [UInt8](box.tag) + counter
        }
    }

    /// Opens `body` (ciphertext, tag, nonce) authenticated with `header`. Nil if anything doesn't check out.
    public func open(_ body: ArraySlice<UInt8>, header: ArraySlice<UInt8>) -> [UInt8]? {
        guard body.count >= Self.tagSize + Self.nonceSize else { return nil }
        let counter = [UInt8](body.suffix(Self.nonceSize))
        let tagStart = body.endIndex - Self.nonceSize - Self.tagSize
        let ciphertext = body[body.startIndex..<tagStart]
        let tag = body[tagStart..<(body.endIndex - Self.nonceSize)]
        do {
            switch mode {
            case .aes256GCM:
                let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: counter + [UInt8](repeating: 0, count: 8)),
                                                ciphertext: ciphertext, tag: tag)
                return [UInt8](try AES.GCM.open(box, using: key, authenticating: header))
            case .xChaCha20Poly1305:
                let (subkey, nonce) = xChaChaKeyAndNonce(counter)
                let box = try ChaChaPoly.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
                return [UInt8](try ChaChaPoly.open(box, using: subkey, authenticating: header))
            }
        } catch {
            return nil
        }
    }

    /// XChaCha20-Poly1305 from CryptoKit's ChaCha20-Poly1305: HChaCha20 turns the key and the first 16 bytes of
    /// the 24-byte nonce into a subkey, and the last 8 bytes become the regular nonce. Here the 24-byte nonce is
    /// the counter followed by zeros.
    private func xChaChaKeyAndNonce(_ counter: [UInt8]) -> (SymmetricKey, ChaChaPoly.Nonce) {
        let keyBytes = key.withUnsafeBytes { [UInt8]($0) }
        let subkey = Self.hChaCha20(key: keyBytes, nonce: counter + [UInt8](repeating: 0, count: 12))
        return (SymmetricKey(data: subkey), Self.zeroNonce)
    }

    /// The 24-byte nonce's last 8 bytes are always zero here, so the regular nonce is too.
    private static let zeroNonce = try! ChaChaPoly.Nonce(data: [UInt8](repeating: 0, count: 12))

    /// HChaCha20 (draft-irtf-cfrg-xchacha): 20 ChaCha rounds over the key and a 16-byte nonce, keeping words 0–3
    /// and 12–15.
    static func hChaCha20(key: [UInt8], nonce: [UInt8]) -> [UInt8] {
        precondition(key.count == 32 && nonce.count == 16)
        func word(_ bytes: [UInt8], _ i: Int) -> UInt32 {
            UInt32(bytes[i]) | UInt32(bytes[i + 1]) << 8 | UInt32(bytes[i + 2]) << 16 | UInt32(bytes[i + 3]) << 24
        }
        var s: [UInt32] = [0x6170_7865, 0x3320_646E, 0x7962_2D32, 0x6B20_6574]
        for i in 0..<8 { s.append(word(key, 4 * i)) }
        for i in 0..<4 { s.append(word(nonce, 4 * i)) }

        func quarterRound(_ a: Int, _ b: Int, _ c: Int, _ d: Int) {
            s[a] = s[a] &+ s[b]; s[d] ^= s[a]; s[d] = s[d] << 16 | s[d] >> 16
            s[c] = s[c] &+ s[d]; s[b] ^= s[c]; s[b] = s[b] << 12 | s[b] >> 20
            s[a] = s[a] &+ s[b]; s[d] ^= s[a]; s[d] = s[d] << 8 | s[d] >> 24
            s[c] = s[c] &+ s[d]; s[b] ^= s[c]; s[b] = s[b] << 7 | s[b] >> 25
        }
        for _ in 0..<10 {
            quarterRound(0, 4, 8, 12); quarterRound(1, 5, 9, 13); quarterRound(2, 6, 10, 14); quarterRound(3, 7, 11, 15)
            quarterRound(0, 5, 10, 15); quarterRound(1, 6, 11, 12); quarterRound(2, 7, 8, 13); quarterRound(3, 4, 9, 14)
        }
        return (Array(s[0..<4]) + Array(s[12..<16])).flatMap { w in (0..<4).map { UInt8(truncatingIfNeeded: w >> (8 * $0)) } }
    }

    static func bigEndian(_ value: UInt32) -> [UInt8] {
        [UInt8(value >> 24), UInt8(truncatingIfNeeded: value >> 16), UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)]
    }
}

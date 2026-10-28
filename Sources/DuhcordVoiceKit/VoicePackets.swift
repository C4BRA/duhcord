import Foundation

/// RTP packets carrying Opus audio, sealed with a `TransportCipher`.
public enum RTP {
    /// Discord's payload type for Opus.
    static let opusPayloadType: UInt8 = 0x78

    public struct Packet: Equatable {
        public let sequence: UInt16
        public let timestamp: UInt32
        public let ssrc: UInt32
        /// The (still end-to-end encrypted) Opus frame.
        public let payload: [UInt8]
    }

    /// Builds one outgoing packet: the 12-byte header, then the sealed payload.
    public static func seal(_ payload: [UInt8], sequence: UInt16, timestamp: UInt32, ssrc: UInt32, nonce: UInt32,
                            cipher: TransportCipher) throws -> [UInt8] {
        var header: [UInt8] = [0x80, opusPayloadType]
        header += [UInt8(sequence >> 8), UInt8(truncatingIfNeeded: sequence)]
        header += TransportCipher.bigEndian(timestamp)
        header += TransportCipher.bigEndian(ssrc)
        return header + (try cipher.seal(payload, header: header, nonce: nonce))
    }

    /// Opens an incoming packet. Nil for RTCP, other payload types, and anything malformed or forged.
    public static func open(_ data: [UInt8], cipher: TransportCipher) -> Packet? {
        guard data.count >= 12 + TransportCipher.tagSize + TransportCipher.nonceSize,
              data[0] >> 6 == 2,                      // RTP version 2
              data[1] & 0x7F == opusPayloadType else { return nil }
        let csrcCount = Int(data[0] & 0x0F)
        let hasExtension = data[0] & 0x10 != 0
        let hasPadding = data[0] & 0x20 != 0

        // "rtpsize": the header, its CSRCs and the extension preamble are authenticated in the clear;
        // the extension body is encrypted along with the payload.
        let headerSize = 12 + 4 * csrcCount
        let clearSize = headerSize + (hasExtension ? 4 : 0)
        guard data.count >= clearSize + TransportCipher.tagSize + TransportCipher.nonceSize,
              var plain = cipher.open(data[clearSize...], header: data[..<clearSize]) else { return nil }

        if hasExtension {
            let extensionSize = 4 * (Int(data[headerSize + 2]) << 8 | Int(data[headerSize + 3]))
            guard plain.count >= extensionSize else { return nil }
            plain.removeFirst(extensionSize)
        }
        if hasPadding {
            guard let padding = plain.last, Int(padding) >= 1, Int(padding) <= plain.count else { return nil }
            plain.removeLast(Int(padding))
        }
        return Packet(sequence: UInt16(data[2]) << 8 | UInt16(data[3]),
                      timestamp: readUInt32(data, at: 4),
                      ssrc: readUInt32(data, at: 8),
                      payload: plain)
    }

    static func readUInt32(_ data: [UInt8], at i: Int) -> UInt32 {
        UInt32(data[i]) << 24 | UInt32(data[i + 1]) << 16 | UInt32(data[i + 2]) << 8 | UInt32(data[i + 3])
    }
}

/// Discord's UDP IP discovery: learns the public address and port the voice server sees for us.
public enum IPDiscovery {
    public static func request(ssrc: UInt32) -> [UInt8] {
        // Type 1 (request), length 70, SSRC, then 64 bytes of address and 2 of port, all zero.
        let typeAndLength: [UInt8] = [0x00, 0x01, 0x00, 70]
        return typeAndLength + TransportCipher.bigEndian(ssrc) + [UInt8](repeating: 0, count: 66)
    }

    public static func parse(_ data: [UInt8]) -> (address: String, port: UInt16)? {
        guard data.count >= 74, data[0] == 0x00, data[1] == 0x02 else { return nil }
        let addressBytes = data[8..<72].prefix { $0 != 0 }
        guard !addressBytes.isEmpty, let address = String(bytes: addressBytes, encoding: .ascii) else { return nil }
        let port = UInt16(data[72]) << 8 | UInt16(data[73])
        return (address, port)
    }
}

/// The voice gateway's binary messages (the DAVE MLS opcodes). Server messages start with a big-endian sequence
/// number; client messages don't.
public struct VoiceBinaryMessage: Equatable {
    public let sequence: UInt16
    public let opcode: UInt8
    public let payload: [UInt8]

    public init?(_ data: [UInt8]) {
        guard data.count >= 3 else { return nil }
        sequence = UInt16(data[0]) << 8 | UInt16(data[1])
        opcode = data[2]
        payload = Array(data[3...])
    }

    /// For messages that start with a transition ID (opcodes 29 and 30): the ID and the MLS message after it.
    public var transition: (id: UInt16, body: [UInt8])? {
        guard payload.count >= 2 else { return nil }
        return (UInt16(payload[0]) << 8 | UInt16(payload[1]), Array(payload[2...]))
    }

    public static func outgoing(opcode: UInt8, payload: [UInt8]) -> Data {
        Data([opcode] + payload)
    }
}

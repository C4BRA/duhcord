import DuhcordUpdateKit
import Foundation

/// What the app and the voice helper agree on. The helper is an XPC service inside Duhcord.app that runs voice
/// calls in its own sandbox: it gets a call's voice token, never the account token.
public enum VoiceKit {
    public static let serviceName = UpdateKit.voiceServiceName
}

/// Asks the helper to join a call. Built from the main gateway's VOICE_STATE_UPDATE and VOICE_SERVER_UPDATE.
public struct VoiceJoinRequest: Codable, Equatable, Sendable {
    public var guildID: String
    public var channelID: String
    public var userID: String
    public var sessionID: String
    /// The per-call voice token, good for this call only. The account token never crosses into the helper.
    public var token: String
    /// The voice server, "host" or "host:port", from VOICE_SERVER_UPDATE.
    public var endpoint: String
    public var muted: Bool
    public var deafened: Bool

    public init(guildID: String, channelID: String, userID: String, sessionID: String, token: String, endpoint: String,
                muted: Bool, deafened: Bool) {
        self.guildID = guildID
        self.channelID = channelID
        self.userID = userID
        self.sessionID = sessionID
        self.token = token
        self.endpoint = endpoint
        self.muted = muted
        self.deafened = deafened
    }
}

/// What the helper reports back.
public enum VoiceEvent: Codable, Equatable, Sendable {
    case connecting
    /// Audio is flowing. `endToEndEncrypted` is true once the call's DAVE group is set up.
    case connected(endToEndEncrypted: Bool)
    /// Who is talking right now (user IDs), including us.
    case speaking([String])
    /// macOS didn't allow the microphone; the call continues without it.
    case microphoneDenied
    /// The call is over. `reason` is nil when we left on purpose.
    case ended(reason: String?)
    /// Connection details, sent about once a second while the app has its details panel open.
    case stats(VoiceStats)
}

/// What the connection details panel shows. Counts and settings only: no tokens, keys or audio.
public struct VoiceStats: Codable, Equatable, Sendable {
    /// The voice server, e.g. "c-ord12-816a989c".
    public var server: String
    /// Round trips to the voice server over the last five minutes: seconds ago (newest last) and milliseconds.
    public var pings: [PingSample]
    public var packetsReceived: Int
    public var packetsLost: Int
    public var packetsSent: Int
    /// Packets that failed transport decryption, or end-to-end decryption.
    public var unreadable: Int
    public var undecryptable: Int
    public var endToEndEncrypted: Bool
    /// Transport encryption between us and the voice server, e.g. "AES-256-GCM".
    public var transport: String
    public var daveProtocolVersion: Int
    /// The call's privacy code: 30 digits that match what the official app shows for the same call.
    public var privacyCode: String?
    public var microphone: String?
    public var output: String?

    public struct PingSample: Codable, Equatable, Sendable {
        public var age: Double
        public var milliseconds: Double

        public init(age: Double, milliseconds: Double) {
            self.age = age
            self.milliseconds = milliseconds
        }
    }

    public init(server: String, pings: [PingSample], packetsReceived: Int, packetsLost: Int, packetsSent: Int,
                unreadable: Int, undecryptable: Int, endToEndEncrypted: Bool, transport: String,
                daveProtocolVersion: Int, privacyCode: String?, microphone: String?, output: String?) {
        self.server = server
        self.pings = pings
        self.packetsReceived = packetsReceived
        self.packetsLost = packetsLost
        self.packetsSent = packetsSent
        self.unreadable = unreadable
        self.undecryptable = undecryptable
        self.endToEndEncrypted = endToEndEncrypted
        self.transport = transport
        self.daveProtocolVersion = daveProtocolVersion
        self.privacyCode = privacyCode
        self.microphone = microphone
        self.output = output
    }

    /// Lost packets as a share of all the packets that should have arrived.
    public var lossPercent: Double {
        let expected = packetsReceived + packetsLost
        return expected == 0 ? 0 : Double(packetsLost) * 100 / Double(expected)
    }

    public var averagePing: Double? {
        pings.isEmpty ? nil : pings.map(\.milliseconds).reduce(0, +) / Double(pings.count)
    }
}

/// DAVE's displayable privacy code (protocol whitepaper, "Displayable codes"): six groups of five digits, each
/// group read from five bytes of the epoch authenticator as a big-endian number, reduced modulo 100000.
public enum PrivacyCode {
    public static func format(_ authenticator: [UInt8]) -> String? {
        let groupSize = 5, groups = 6
        guard authenticator.count >= groupSize * groups else { return nil }
        return (0..<groups).map { group -> String in
            let value = authenticator[(group * groupSize)..<((group + 1) * groupSize)].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            let digits = String(value % 100_000)
            return String(repeating: "0", count: groupSize - digits.count) + digits
        }.joined(separator: " ")
    }
}

/// The helper's side of the connection. Requests and events cross as JSON-encoded `Data`.
@objc public protocol DuhcordVoiceProtocol {
    func join(_ request: Data)
    func setMuted(_ muted: Bool, deafened: Bool)
    func leave()
    /// Whether to send `VoiceEvent.stats`: only while the details panel is open.
    func setStatsWanted(_ wanted: Bool)
}

/// The app's side, for events from the helper.
@objc public protocol DuhcordVoiceClientProtocol {
    func voiceEvent(_ event: Data)
}

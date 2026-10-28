import DuhcordUpdateKit
import Foundation

/// What the app and the voice helper agree on. The helper is an XPC service inside Duhcord.app that runs voice
/// calls in its own sandbox: it gets a call's voice token, never the account token.
public enum VoiceKit {
    public static let serviceName = UpdateKit.voiceServiceName
}

/// Asks the helper to join a call. Built from the main gateway's VOICE_STATE_UPDATE and VOICE_SERVER_UPDATE.
public struct VoiceJoinRequest: Codable, Equatable {
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
public enum VoiceEvent: Codable, Equatable {
    case connecting
    /// Audio is flowing. `endToEndEncrypted` is true once the call's DAVE group is set up.
    case connected(endToEndEncrypted: Bool)
    /// Who is talking right now (user IDs), including us.
    case speaking([String])
    /// macOS didn't allow the microphone; the call continues without it.
    case microphoneDenied
    /// The call is over. `reason` is nil when we left on purpose.
    case ended(reason: String?)
}

/// The helper's side of the connection. Requests and events cross as JSON-encoded `Data`.
@objc public protocol DuhcordVoiceProtocol {
    func join(_ request: Data)
    func setMuted(_ muted: Bool, deafened: Bool)
    func leave()
}

/// The app's side, for events from the helper.
@objc public protocol DuhcordVoiceClientProtocol {
    func voiceEvent(_ event: Data)
}

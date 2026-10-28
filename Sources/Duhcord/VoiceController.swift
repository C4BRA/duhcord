import AppKit
import DuhcordCore
import DuhcordVoiceKit

/// Joins and leaves voice channels.
///
/// The main gateway arranges the call (our voice state and the voice server to use). The call itself runs in the
/// voice helper, a separate sandboxed process that gets only that call's voice token, never the account token.
/// The helper is started on join and let go on leave, so nothing voice-related runs between calls.
final class VoiceController: NSObject, DuhcordVoiceClientProtocol {
    enum Status: Equatable {
        case idle
        case connecting
        case connected(endToEndEncrypted: Bool)
    }

    private(set) var status: Status = .idle
    private(set) var guildID: Snowflake?
    private(set) var channelID: Snowflake?
    private(set) var muted = false
    private(set) var deafened = false
    /// Who is talking right now, including us.
    private(set) var speaking: Set<Snowflake> = []

    /// Status, mute or speaking changed.
    var onChange: (() -> Void)?
    /// Something the user should know about, such as a call that ended on its own.
    var onProblem: ((String) -> Void)?

    private let session: DiscordSession
    private var connection: NSXPCConnection?
    private var voiceSessionID: String?
    private var server: VoiceServerUpdate?

    init(session: DiscordSession) {
        self.session = session
        super.init()
        session.onOwnVoiceState = { [weak self] state in self?.ownVoiceStateChanged(state) }
        session.onVoiceServer = { [weak self] update in self?.voiceServerChanged(update) }
    }

    var isInCall: Bool { status != .idle }

    // MARK: - Actions

    func join(_ channel: Channel) {
        guard let guildID = channel.guildId, channel.id != channelID else { return }
        // One call at a time: a fresh helper session for the new channel.
        if isInCall { endHelperCall() }
        self.guildID = guildID
        channelID = channel.id
        voiceSessionID = nil
        server = nil
        status = .connecting
        speaking = []
        session.updateVoiceState(guildID: guildID, channelID: channel.id, muted: muted || deafened, deafened: deafened)
        onChange?()
    }

    func leave() {
        guard isInCall, let guildID else { return }
        session.updateVoiceState(guildID: guildID, channelID: nil, muted: false, deafened: false)
        endHelperCall()
        reset()
    }

    func toggleMute() {
        if deafened {
            // Unmuting while deafened undeafens too, like Discord.
            deafened = false
            muted = false
        } else {
            muted.toggle()
        }
        applyMuteState()
    }

    func toggleDeafen() {
        deafened.toggle()
        applyMuteState()
    }

    private func applyMuteState() {
        if isInCall, let guildID, let channelID {
            session.updateVoiceState(guildID: guildID, channelID: channelID, muted: muted || deafened, deafened: deafened)
            helper?.setMuted(muted || deafened, deafened: deafened)
        }
        onChange?()
    }

    // MARK: - Main gateway

    private func ownVoiceStateChanged(_ state: VoiceState) {
        guard isInCall, state.guildId == guildID else { return }
        guard let newChannel = state.channelId else {
            // Discord took us out of the channel (a moderator, or another device joined voice).
            endHelperCall()
            reset()
            onProblem?("You were disconnected from the voice channel.")
            return
        }
        // Moved by a moderator: Discord also sends a new voice server, which restarts the call there.
        channelID = newChannel
        voiceSessionID = state.sessionId
        startHelperCallIfReady()
    }

    private func voiceServerChanged(_ update: VoiceServerUpdate) {
        guard isInCall, update.guildId == guildID else { return }
        server = update
        startHelperCallIfReady()
    }

    /// Both halves are needed: our voice session ID and the voice server. They can arrive in either order.
    private func startHelperCallIfReady() {
        guard let guildID, let channelID, let voiceSessionID, let server, let endpoint = server.endpoint,
              let me = session.store.me else { return }
        self.server = nil
        let request = VoiceJoinRequest(guildID: guildID, channelID: channelID, userID: me.id, sessionID: voiceSessionID,
                                       token: server.token, endpoint: endpoint, muted: muted || deafened, deafened: deafened)
        guard let data = try? JSONEncoder().encode(request) else { return }
        status = .connecting
        onChange?()
        helper?.join(data)
    }

    private func reset() {
        status = .idle
        guildID = nil
        channelID = nil
        voiceSessionID = nil
        server = nil
        speaking = []
        onChange?()
    }

    // MARK: - Voice helper

    private var helper: DuhcordVoiceProtocol? {
        if connection == nil {
            let connection = NSXPCConnection(serviceName: VoiceKit.serviceName)
            connection.remoteObjectInterface = NSXPCInterface(with: DuhcordVoiceProtocol.self)
            connection.exportedInterface = NSXPCInterface(with: DuhcordVoiceClientProtocol.self)
            connection.exportedObject = self
            let lost: () -> Void = { [weak self, weak connection] in
                DispatchQueue.main.async { self?.helperLost(connection) }
            }
            connection.invalidationHandler = lost
            connection.interruptionHandler = lost
            connection.resume()
            self.connection = connection
        }
        let current = connection
        return connection?.remoteObjectProxyWithErrorHandler { [weak self] _ in
            DispatchQueue.main.async { self?.helperLost(current) }
        } as? DuhcordVoiceProtocol
    }

    private func endHelperCall() {
        guard let connection else { return }
        self.connection = nil
        (connection.remoteObjectProxy as? DuhcordVoiceProtocol)?.leave()
        // Letting go of the connection lets macOS stop the helper.
        connection.invalidate()
    }

    private func helperLost(_ lostConnection: NSXPCConnection?) {
        // Only the current helper matters; one we let go of on purpose is expected to disappear.
        guard let lostConnection, lostConnection === connection else { return }
        connection = nil
        guard isInCall else { return }
        leave()
        onProblem?("Voice stopped unexpectedly. Join the channel again to reconnect.")
    }

    /// From the helper, on an XPC thread.
    func voiceEvent(_ data: Data) {
        guard let event = try? JSONDecoder().decode(VoiceEvent.self, from: data) else { return }
        DispatchQueue.main.async { [weak self] in self?.handle(event) }
    }

    private func handle(_ event: VoiceEvent) {
        guard isInCall else { return }
        switch event {
        case .connecting:
            status = .connecting
        case .connected(let encrypted):
            status = .connected(endToEndEncrypted: encrypted)
        case .speaking(let userIDs):
            speaking = Set(userIDs)
        case .microphoneDenied:
            onProblem?("Duhcord can't use the microphone, so others can't hear you. "
                       + "Allow it in System Settings → Privacy & Security → Microphone, then rejoin the channel.")
        case .ended(let reason):
            connection?.invalidate()
            connection = nil
            leave()
            if let reason { onProblem?(reason) }
            return
        }
        onChange?()
    }
}

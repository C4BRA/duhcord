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
    /// Muted or deafened by a moderator. Our microphone or speakers stay off while it lasts.
    private(set) var serverMuted = false
    private(set) var serverDeafened = false
    /// Who is talking right now, including us.
    private(set) var speaking: Set<Snowflake> = []

    /// Status, mute or speaking changed.
    var onChange: (() -> Void)?
    /// Something the user should know about, such as a call that ended on its own.
    var onProblem: ((_ title: String, _ detail: String) -> Void)?
    /// New connection details, about once a second while `statsWanted` is on.
    var onStats: ((VoiceStats) -> Void)?
    private(set) var latestStats: VoiceStats?

    /// Whether the helper should measure and send connection details: only while the details panel is open.
    var statsWanted = false {
        didSet {
            guard statsWanted != oldValue, connection != nil else { return }
            helper?.setStatsWanted(statsWanted)
        }
    }

    private let session: DiscordSession
    private var connection: NSXPCConnection?
    private var voiceSessionID: String?
    private var server: VoiceServerUpdate?
    private var joinTimer: Timer?
    /// Discord doesn't answer a join it won't allow (no permission, channel full), so give up after this.
    private static let joinTimeout: TimeInterval = 15

    init(session: DiscordSession) {
        self.session = session
        super.init()
        session.onOwnVoiceState = { [weak self] state in self?.ownVoiceStateChanged(state) }
        session.onVoiceServer = { [weak self] update in self?.voiceServerChanged(update) }
    }

    var isInCall: Bool { status != .idle }

    /// What the helper should do: our own choices plus a moderator's.
    private var effectiveDeafened: Bool { deafened || serverDeafened }
    private var effectiveMuted: Bool { muted || serverMuted || effectiveDeafened }

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
        serverMuted = false
        serverDeafened = false
        session.updateVoiceState(guildID: guildID, channelID: channel.id, muted: muted || deafened, deafened: deafened)
        startJoinTimer()
        onChange?()
    }

    func leave() {
        guard isInCall, let guildID else { return }
        // Only take ourselves out if Discord still has the call on this device; if voice moved to another
        // device, a leave from here would disconnect that one.
        if voiceIsOnThisDevice {
            session.updateVoiceState(guildID: guildID, channelID: nil, muted: false, deafened: false)
        }
        endHelperCall()
        reset()
    }

    private var voiceIsOnThisDevice: Bool {
        guard let guildID, let mine = session.store.myVoiceState(in: guildID) else { return true }
        return mine.sessionId == nil || mine.sessionId == session.sessionID
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
            updateHelperMuteState()
        }
        onChange?()
    }

    /// Only a running helper needs telling; a call that hasn't started yet picks the state up when it does.
    private func updateHelperMuteState() {
        guard connection != nil else { return }
        helper?.setMuted(effectiveMuted, deafened: effectiveDeafened)
    }

    // MARK: - Main gateway

    private func ownVoiceStateChanged(_ state: VoiceState) {
        guard isInCall, state.guildId == guildID else { return }
        if let sessionID = state.sessionId, let ours = session.sessionID, sessionID != ours {
            // We joined voice on another device; Discord moved the call there. Don't send a leave from here.
            endHelperCall()
            reset()
            onProblem?("Voice moved to another device", "You joined a voice channel on another device, so the call continues there.")
            return
        }
        guard let newChannel = state.channelId else {
            // A moderator took us out of the channel.
            endHelperCall()
            reset()
            onProblem?("You were disconnected from voice", "A moderator removed you from the voice channel.")
            return
        }
        // Moved by a moderator: Discord also sends a new voice server, which restarts the call there.
        channelID = newChannel
        voiceSessionID = state.sessionId
        if serverMuted != state.mute || serverDeafened != state.deaf {
            serverMuted = state.mute
            serverDeafened = state.deaf
            updateHelperMuteState()
            onChange?()
        }
        startHelperCallIfReady()
    }

    private func voiceServerChanged(_ update: VoiceServerUpdate) {
        guard isInCall, update.guildId == guildID else { return }
        server = update
        if update.endpoint == nil, status != .connecting {
            // Discord is moving the call to another voice server; a new update follows.
            status = .connecting
            onChange?()
        }
        startHelperCallIfReady()
    }

    /// Both halves are needed: our voice session ID and the voice server. They can arrive in either order.
    private func startHelperCallIfReady() {
        guard let guildID, let channelID, let voiceSessionID, let server, let endpoint = server.endpoint,
              let me = session.store.me else { return }
        self.server = nil
        joinTimer?.invalidate()
        joinTimer = nil
        let request = VoiceJoinRequest(guildID: guildID, channelID: channelID, userID: me.id, sessionID: voiceSessionID,
                                       token: server.token, endpoint: endpoint, muted: effectiveMuted, deafened: effectiveDeafened)
        guard let data = try? JSONEncoder().encode(request) else { return }
        status = .connecting
        onChange?()
        helper?.join(data)
        if statsWanted { helper?.setStatsWanted(true) }
    }

    private func startJoinTimer() {
        joinTimer?.invalidate()
        joinTimer = Timer.scheduledTimer(withTimeInterval: Self.joinTimeout, repeats: false) { [weak self] _ in
            guard let self, self.isInCall, self.connection == nil else { return }
            self.leave()
            self.onProblem?("Couldn't join the voice channel", "You may not have permission to join it, or it may be full.")
        }
    }

    private func reset() {
        joinTimer?.invalidate()
        joinTimer = nil
        serverMuted = false
        serverDeafened = false
        status = .idle
        guildID = nil
        channelID = nil
        voiceSessionID = nil
        server = nil
        speaking = []
        latestStats = nil
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
        // An interrupted connection is still alive; let go of it so it (and us, its exported object) can go.
        lostConnection.invalidate()
        guard isInCall else { return }
        leave()
        onProblem?("Voice stopped unexpectedly", "Join the channel again to reconnect.")
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
        case .stats(let stats):
            latestStats = stats
            onStats?(stats)
            return
        case .microphoneDenied:
            onProblem?("Duhcord can't use the microphone", "Others in the call can't hear you. "
                       + "Allow it in System Settings → Privacy & Security → Microphone, then rejoin the channel.")
        case .ended(let reason):
            connection?.invalidate()
            connection = nil
            leave()
            if let reason { onProblem?("The call ended", reason) }
            return
        }
        onChange?()
    }
}

import AVFoundation
import DuhcordCore
import DuhcordVoiceKit
import Foundation
import Network

/// One voice call: the voice gateway WebSocket, the UDP audio socket, end-to-end encryption and the audio engine.
/// Everything runs on `queue`.
final class VoiceCall {
    /// Louder than this (RMS, after voice processing) counts as talking; 300 ms of quiet ends it.
    private static let talkThreshold: Float = 0.01
    private static let hangoverFrames = 15
    /// Someone shows as speaking for this long after their last non-silent frame.
    private static let speakingHold: UInt64 = 400_000_000

    var onEvent: ((VoiceEvent) -> Void)?

    private let request: VoiceJoinRequest
    private let queue: DispatchQueue
    private var muted: Bool
    private var deafened: Bool
    private var stopped = false

    // Voice gateway
    private var socket: URLSessionWebSocketTask?
    private var heartbeat: DispatchSourceTimer?
    private var awaitingAck = false
    private var lastSequence = -1
    private var resuming = false
    private var resumeAttempted = false

    // UDP
    private var udp: NWConnection?
    private var timers: [DispatchSourceTimer] = []
    private var protocolSelected = false
    private var keepAliveCounter: UInt32 = 0
    private var ssrc: UInt32 = 0
    private var mode: TransportCipher.Mode?
    private var cipher: TransportCipher?

    // Media
    private var dave: Dave?
    private let audio = AudioIO()
    private let encoder = OpusEncoder()
    private var decoders: [UInt32: OpusDecoder] = [:]
    private var users: [UInt32: String] = [:]
    private var lastPacketSequence: [UInt32: UInt16] = [:]
    private var sendSequence = UInt16.random(in: 0 ... .max)
    private var sendTimestamp = UInt32.random(in: 0 ... .max)
    private var sendNonce: UInt32 = 0
    private var talking = false
    private var quietFrames = 0
    private var microphoneAllowed = false
    private var audioConfiguration: (capture: Bool, playback: Bool)?

    // Reporting
    private var connected = false
    private var encrypted = false
    private var reportedEncryption: Bool?
    private var heard: [String: UInt64] = [:]
    private var reportedSpeakers: [String] = []

    init(request: VoiceJoinRequest, queue: DispatchQueue) {
        self.request = request
        self.queue = queue
        muted = request.muted
        deafened = request.deafened
        audio.onFrame = { [weak self] frame in
            guard let self else { return }
            self.queue.async { self.captured(frame) }
        }
    }

    func start() {
        onEvent?(.connecting)
        guard let dave = Dave(selfUserID: request.userID, groupID: UInt64(request.channelID) ?? 0) else {
            stop(reason: "Couldn't set up end-to-end encryption.")
            return
        }
        dave.sendJSON = { [weak self] op, data in self?.sendJSON(op: op, data) }
        dave.sendBinary = { [weak self] op, payload in self?.sendBinary(op, payload) }
        dave.onEncryptionChange = { [weak self] on in
            self?.encrypted = on
            self?.reportConnected()
        }
        self.dave = dave
        checkMicrophone()
        openSocket()
    }

    func setMuted(_ muted: Bool, deafened: Bool) {
        self.muted = muted
        self.deafened = deafened
        if talking, muted || deafened { stopTalking() }
        runAudio()
    }

    func stop(reason: String?, report: Bool = true) {
        guard !stopped else { return }
        stopped = true
        heartbeat?.cancel()
        timers.forEach { $0.cancel() }
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        udp?.cancel()
        udp = nil
        audio.stop()
        dave = nil
        if report { onEvent?(.ended(reason: reason)) }
    }

    // MARK: - Voice gateway

    private func openSocket() {
        // The voice server address comes from Discord's main gateway; only Discord's voice hosts are accepted,
        // and SecureSession.voice enforces the same again for the connection itself.
        guard let url = URL(string: "wss://\(request.endpoint)/?v=8"), SecureSession.isVoiceHost(url.host) else {
            stop(reason: "Discord sent an unexpected voice server.")
            return
        }
        var urlRequest = URLRequest(url: url)
        urlRequest.setValue(ClientIdentity.userAgent, forHTTPHeaderField: "User-Agent")
        let task = SecureSession.voice.session.webSocketTask(with: urlRequest)
        task.maximumMessageSize = 1 << 20
        socket = task
        task.resume()
        receive(on: task)
    }

    private func receive(on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self else { return }
            self.queue.async {
                guard task === self.socket, !self.stopped else { return }
                switch result {
                case .success(.string(let text)):
                    self.handleJSON(Data(text.utf8))
                case .success(.data(let data)):
                    self.handleBinary([UInt8](data))
                case .success:
                    break
                case .failure:
                    self.socketClosed(code: task.closeCode == .invalid ? nil : task.closeCode.rawValue)
                    return
                }
                self.receive(on: task)
            }
        }
    }

    private func socketClosed(code: Int?) {
        heartbeat?.cancel()
        heartbeat = nil
        socket = nil
        switch code {
        case 4014?: stop(reason: "Disconnected from the voice channel.")
        case 4006?, 4009?: stop(reason: "The voice session expired.")
        case 4021?: stop(reason: "Discord is rate limiting voice connections. Try again in a moment.")
        case 4022?: stop(reason: "The call ended.")
        case let code? where (4000..<5000).contains(code) && code != 4015:
            stop(reason: "The voice server closed the connection (code \(code)).")
        default:
            // A network blip or a voice server restart: resume once, keeping audio and UDP running.
            guard connected, !resumeAttempted else {
                stop(reason: "Lost the connection to the voice server.")
                return
            }
            resumeAttempted = true
            resuming = true
            queue.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self, !self.stopped else { return }
                self.openSocket()
            }
        }
    }

    private func handleJSON(_ data: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let op = Self.int(json["op"]) else { return }
        if let sequence = Self.int(json["seq"]) { lastSequence = sequence }
        let d = json["d"] as? [String: Any] ?? [:]

        switch op {
        case 8: // Hello
            startHeartbeat(milliseconds: Double(Self.int(d["heartbeat_interval"]) ?? 41_250))
            if resuming {
                sendJSON(op: 7, ["server_id": request.guildID, "session_id": request.sessionID, "token": request.token,
                                 "seq_ack": lastSequence])
            } else {
                sendJSON(op: 0, ["server_id": request.guildID, "user_id": request.userID, "session_id": request.sessionID,
                                 "token": request.token, "max_dave_protocol_version": Int(Dave.maxProtocolVersion)])
            }
        case 2: // Ready
            ready(d)
        case 4: // Session description
            sessionDescription(d)
        case 6: // Heartbeat ACK
            awaitingAck = false
        case 9: // Resumed
            resuming = false
            resumeAttempted = false
        case 5: // Speaking: tells us whose audio an SSRC carries
            if let userID = d["user_id"] as? String, let ssrc = Self.int(d["ssrc"]) {
                users[UInt32(truncatingIfNeeded: ssrc)] = userID
            }
        case 11: // Clients connect
            dave?.clientsConnected(d["user_ids"] as? [String] ?? [])
        case 13: // Client disconnect
            if let userID = d["user_id"] as? String { clientLeft(userID) }
        case 21:
            if let id = Self.uint16(d["transition_id"]), let version = Self.uint16(d["protocol_version"]) {
                dave?.prepareTransition(id: id, version: version)
            }
        case 22:
            if let id = Self.uint16(d["transition_id"]) { dave?.executeTransition(id: id) }
        case 24:
            if let epoch = Self.int(d["epoch"]), let version = Self.uint16(d["protocol_version"]) {
                dave?.prepareEpoch(epoch, version: version)
            }
        default:
            break
        }
    }

    private func handleBinary(_ bytes: [UInt8]) {
        guard let message = VoiceBinaryMessage(bytes) else { return }
        lastSequence = Int(message.sequence)
        switch message.opcode {
        case 25: dave?.externalSender(message.payload)
        case 27: dave?.proposals(message.payload)
        case 29: if let t = message.transition { dave?.announceCommit(transitionID: t.id, commit: t.body) }
        case 30: if let t = message.transition { dave?.welcome(transitionID: t.id, welcome: t.body) }
        default: break
        }
    }

    private func ready(_ d: [String: Any]) {
        guard let ssrc = Self.int(d["ssrc"]), let ip = d["ip"] as? String, let port = Self.uint16(d["port"]),
              let modes = d["modes"] as? [String] else {
            stop(reason: "The voice server sent an unexpected reply.")
            return
        }
        guard let mode = TransportCipher.Mode.preferred(from: modes) else {
            stop(reason: "The voice server offered no encryption Duhcord supports.")
            return
        }
        // Discord gives an IP address here; nothing to resolve, so nothing to redirect.
        guard IPv4Address(ip) != nil || IPv6Address(ip) != nil, let endpointPort = NWEndpoint.Port(rawValue: port) else {
            stop(reason: "The voice server sent an invalid address.")
            return
        }
        self.ssrc = UInt32(truncatingIfNeeded: ssrc)
        self.mode = mode
        dave?.assignSSRC(self.ssrc)
        openUDP(host: NWEndpoint.Host(ip), port: endpointPort)
    }

    private func sessionDescription(_ d: [String: Any]) {
        let keyBytes = (d["secret_key"] as? [Any] ?? []).compactMap { value -> UInt8? in
            Self.int(value).map { UInt8(truncatingIfNeeded: $0) }
        }
        guard let name = d["mode"] as? String, let mode = TransportCipher.Mode(rawValue: name),
              let cipher = TransportCipher(mode: mode, secretKey: keyBytes) else {
            stop(reason: "The voice server sent an unexpected session.")
            return
        }
        self.cipher = cipher
        dave?.protocolSelected(version: Self.uint16(d["dave_protocol_version"]) ?? 0)
        connected = true
        runAudio()
        startSpeakingReports()
        reportConnected()
    }

    private func clientLeft(_ userID: String) {
        dave?.clientDisconnected(userID)
        for (ssrc, user) in users where user == userID {
            users[ssrc] = nil
            decoders[ssrc] = nil
            lastPacketSequence[ssrc] = nil
            audio.mixer.remove(ssrc)
        }
        heard[userID] = nil
    }

    private func startHeartbeat(milliseconds: Double) {
        heartbeat?.cancel()
        awaitingAck = false
        let interval = min(max(milliseconds / 1000, 1), 60)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            if self.awaitingAck {
                // No answer to the last heartbeat: the connection is dead. Closing it leads to a resume.
                self.socket?.cancel(with: .goingAway, reason: nil)
                return
            }
            self.awaitingAck = true
            self.sendJSON(op: 3, ["t": Int(Date().timeIntervalSince1970 * 1000), "seq_ack": self.lastSequence])
        }
        heartbeat = timer
        timer.resume()
    }

    private func sendJSON(op: Int, _ d: [String: Any]) {
        guard let socket, let data = try? JSONSerialization.data(withJSONObject: ["op": op, "d": d]),
              let text = String(data: data, encoding: .utf8) else { return }
        socket.send(.string(text)) { _ in }
    }

    private func sendBinary(_ op: UInt8, _ payload: [UInt8]) {
        socket?.send(.data(VoiceBinaryMessage.outgoing(opcode: op, payload: payload))) { _ in }
    }

    // MARK: - UDP

    private func openUDP(host: NWEndpoint.Host, port: NWEndpoint.Port) {
        let connection = NWConnection(host: host, port: port, using: .udp)
        udp = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection, connection === self.udp else { return }
            switch state {
            case .ready: self.discoverAddress()
            case .failed: self.stop(reason: "Couldn't reach the voice server.")
            default: break
            }
        }
        connection.start(queue: queue)
        receiveUDP(on: connection)
    }

    /// Asks the voice server which address and port it sees us on, then tells the voice gateway.
    private func discoverAddress() {
        let request = IPDiscovery.request(ssrc: ssrc)
        // UDP can drop packets: ask up to three times, and give up after five seconds.
        for attempt in 0..<3 {
            schedule(after: Double(attempt), repeating: nil) { [weak self] in
                guard let self, !self.protocolSelected else { return }
                self.udp?.send(content: Data(request), completion: .idempotent)
            }
        }
        schedule(after: 5, repeating: nil) { [weak self] in
            guard let self, !self.protocolSelected else { return }
            self.stop(reason: "The voice server didn't answer.")
        }
    }

    private func receiveUDP(on connection: NWConnection) {
        connection.receiveMessage { [weak self, weak connection] data, _, _, error in
            guard let self, let connection, connection === self.udp, !self.stopped else { return }
            if let data { self.udpPacket([UInt8](data)) }
            if error == nil { self.receiveUDP(on: connection) }
        }
    }

    private func udpPacket(_ bytes: [UInt8]) {
        guard let cipher else {
            guard !protocolSelected, let mode, let discovered = IPDiscovery.parse(bytes) else { return }
            protocolSelected = true
            sendJSON(op: 1, ["protocol": "udp",
                             "data": ["address": discovered.address, "port": Int(discovered.port), "mode": mode.rawValue] as [String: Any]])
            startKeepAlive()
            return
        }
        guard !deafened, let packet = RTP.open(bytes, cipher: cipher), let userID = users[packet.ssrc] else { return }
        // Drop duplicates and stragglers that arrive after newer packets.
        if let last = lastPacketSequence[packet.ssrc], Int16(bitPattern: packet.sequence &- last) <= 0 { return }
        lastPacketSequence[packet.ssrc] = packet.sequence

        guard let frame = dave?.decrypt(packet.payload, from: userID) else { return }
        if frame != Opus.silence { heard[userID] = DispatchTime.now().uptimeNanoseconds }
        let decoder: OpusDecoder
        if let existing = decoders[packet.ssrc] {
            decoder = existing
        } else {
            guard let created = OpusDecoder() else { return }
            decoders[packet.ssrc] = created
            decoder = created
        }
        if let pcm = decoder.decode(frame) { audio.mixer.push(pcm, for: packet.ssrc) }
    }

    /// Keeps the NAT mapping open while we're quiet, so other people's audio keeps reaching us.
    private func startKeepAlive() {
        schedule(after: 5, repeating: 5) { [weak self] in
            guard let self, let udp = self.udp else { return }
            self.keepAliveCounter &+= 1
            var packet = [UInt8](repeating: 0, count: 8)
            withUnsafeBytes(of: self.keepAliveCounter.littleEndian) { packet.replaceSubrange(0..<4, with: $0) }
            udp.send(content: Data(packet), completion: .idempotent)
        }
    }

    private func schedule(after delay: Double, repeating interval: Double?, _ action: @escaping () -> Void) {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        if let interval {
            timer.schedule(deadline: .now() + delay, repeating: interval)
        } else {
            timer.schedule(deadline: .now() + delay)
        }
        timer.setEventHandler(handler: action)
        timers.append(timer)
        timer.resume()
    }

    // MARK: - Microphone and sending

    private func checkMicrophone() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            microphoneAllowed = true
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                guard let self else { return }
                self.queue.async {
                    self.microphoneAllowed = granted
                    if !granted { self.onEvent?(.microphoneDenied) }
                    self.runAudio()
                }
            }
        default:
            onEvent?(.microphoneDenied)
        }
    }

    /// Starts, rebuilds or stops the audio engine to match mute, deafen and the microphone permission.
    private func runAudio() {
        guard connected, !stopped else { return }
        let capture = microphoneAllowed && !muted && !deafened
        let playback = !deafened
        if let current = audioConfiguration, current.capture == capture, current.playback == playback { return }
        audioConfiguration = (capture, playback)
        do {
            try audio.run(capture: capture, playback: playback)
        } catch {
            voiceLog.error("audio engine failed: \(error.localizedDescription, privacy: .public)")
            // Keep hearing others even if the microphone side won't start.
            if capture { try? audio.run(capture: false, playback: playback) }
        }
    }

    private func captured(_ frame: [Float]) {
        guard connected, !stopped else { return }
        // RTP timestamps follow real time, including the gaps while we're quiet.
        defer { sendTimestamp &+= UInt32(Opus.frameSize) }
        guard !muted, !deafened, cipher != nil else { return }

        let level = (frame.reduce(0) { $0 + $1 * $1 } / Float(frame.count)).squareRoot()
        if level > Self.talkThreshold {
            quietFrames = 0
            if !talking {
                talking = true
                sendJSON(op: 5, ["speaking": 1, "delay": 0, "ssrc": Int(ssrc)])
            }
        } else if talking {
            quietFrames += 1
            if quietFrames > Self.hangoverFrames {
                stopTalking()
                return
            }
        }
        guard talking, let opus = encoder?.encode(frame) else { return }
        sendAudio(opus)
    }

    private func stopTalking() {
        talking = false
        // Five silence frames stop other clients from smoothing over the gap with made-up audio.
        for _ in 0..<5 { sendAudio(Opus.silence) }
        sendJSON(op: 5, ["speaking": 0, "delay": 0, "ssrc": Int(ssrc)])
    }

    private func sendAudio(_ opus: [UInt8]) {
        // No end-to-end key yet means nothing is sent, rather than sending without it.
        guard let cipher, let udp, let sealed = dave?.encrypt(opus, ssrc: ssrc),
              let packet = try? RTP.seal(sealed, sequence: sendSequence, timestamp: sendTimestamp, ssrc: ssrc,
                                         nonce: sendNonce, cipher: cipher) else { return }
        sendSequence &+= 1
        sendNonce &+= 1
        udp.send(content: Data(packet), completion: .idempotent)
    }

    // MARK: - Reporting

    private func reportConnected() {
        guard connected, !stopped, reportedEncryption != encrypted else { return }
        reportedEncryption = encrypted
        onEvent?(.connected(endToEndEncrypted: encrypted))
    }

    private func startSpeakingReports() {
        schedule(after: 0.2, repeating: 0.2) { [weak self] in
            guard let self else { return }
            let now = DispatchTime.now().uptimeNanoseconds
            self.heard = self.heard.filter { now - $0.value < Self.speakingHold }
            var speakers = Array(self.heard.keys)
            if self.talking { speakers.append(self.request.userID) }
            speakers.sort()
            guard speakers != self.reportedSpeakers else { return }
            self.reportedSpeakers = speakers
            self.onEvent?(.speaking(speakers))
        }
    }

    // MARK: - JSON helpers

    private static func int(_ value: Any?) -> Int? { (value as? NSNumber)?.intValue }

    private static func uint16(_ value: Any?) -> UInt16? { int(value).flatMap { UInt16(exactly: $0) } }
}

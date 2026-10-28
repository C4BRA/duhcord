import DuhcordVoiceKit
import Foundation

/// The object the app talks to over XPC. Holds at most one call; everything about it runs on one serial queue.
final class VoiceService: NSObject, DuhcordVoiceProtocol {
    private weak var connection: NSXPCConnection?
    private let queue = DispatchQueue(label: "duhcord.voice", qos: .userInteractive)
    private var call: VoiceCall?
    private var statsWanted = false

    init(connection: NSXPCConnection) {
        self.connection = connection
    }

    func join(_ requestData: Data) {
        guard let request = try? JSONDecoder().decode(VoiceJoinRequest.self, from: requestData) else { return }
        queue.async { [self] in
            call?.stop(reason: nil, report: false)
            let call = VoiceCall(request: request, queue: queue)
            call.onEvent = { [weak self, weak call] event in
                guard let self else { return }
                if case .ended = event, let call, self.call === call { self.call = nil }
                self.send(event)
            }
            self.call = call
            call.start()
            call.setStatsWanted(statsWanted)
        }
    }

    func setMuted(_ muted: Bool, deafened: Bool) {
        queue.async { [self] in call?.setMuted(muted, deafened: deafened) }
    }

    func leave() {
        queue.async { [self] in
            call?.stop(reason: nil)
            call = nil
        }
    }

    func setStatsWanted(_ wanted: Bool) {
        queue.async { [self] in
            statsWanted = wanted
            call?.setStatsWanted(wanted)
        }
    }

    private func send(_ event: VoiceEvent) {
        guard let data = try? JSONEncoder().encode(event),
              let client = connection?.remoteObjectProxy as? DuhcordVoiceClientProtocol else { return }
        client.voiceEvent(data)
    }
}

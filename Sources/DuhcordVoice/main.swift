import DuhcordUpdateKit
import DuhcordVoiceKit
import Foundation
import OSLog

/// Visible with: log show --last 1h --predicate 'subsystem == "com.duhcord.app.Voice"'
let voiceLog = Logger(subsystem: "com.duhcord.app.Voice", category: "voice")

// The voice helper: an XPC service inside Duhcord.app that runs voice calls. macOS starts it when Duhcord joins a
// call and it exits when the call ends.
//
// It's sandboxed separately from the app, with only outgoing network and the microphone. It never sees the
// account token, only each call's voice token, so a bug in the voice code (including the C++ libdave it links)
// can't expose the login.

final class ServiceDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard Self.callerIsDuhcord(connection) else {
            voiceLog.error("rejected connection from pid \(connection.processIdentifier, privacy: .public): not Duhcord")
            return false
        }
        let service = VoiceService(connection: connection)
        connection.exportedInterface = NSXPCInterface(with: DuhcordVoiceProtocol.self)
        connection.exportedObject = service
        connection.remoteObjectInterface = NSXPCInterface(with: DuhcordVoiceClientProtocol.self)
        // If Duhcord quits or crashes, the call ends with it.
        connection.invalidationHandler = { [weak service] in service?.leave() }
        connection.interruptionHandler = { [weak service] in service?.leave() }
        connection.resume()
        return true
    }

    /// Release builds: the caller must be signed with the same certificate as this helper. Ad-hoc builds (local
    /// and branch builds) have no certificate, so the caller must be the very app this helper is inside.
    static func callerIsDuhcord(_ connection: NSXPCConnection) -> Bool {
        if let requirement = CodeSignature.ownCertificateRequirement {
            return CodeSignature.caller(connection, satisfies: requirement)
        }
        return CodeSignature.callerPath(connection) == CodeSignature.containingAppPath
    }
}

let delegate = ServiceDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()

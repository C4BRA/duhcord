import DuhcordMediaKit
import DuhcordUpdateKit
import Foundation
import OSLog

private let mediaDecoderLog = Logger(subsystem: MediaKit.serviceName, category: "decode")

final class ServiceDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard Self.callerIsDuhcord(connection) else {
            mediaDecoderLog.error("rejected connection from pid \(connection.processIdentifier, privacy: .public): not Duhcord")
            return false
        }
        connection.exportedInterface = NSXPCInterface(with: DuhcordMediaDecoderProtocol.self)
        connection.exportedObject = MediaDecoderService()
        connection.resume()
        return true
    }

    private static func callerIsDuhcord(_ connection: NSXPCConnection) -> Bool {
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

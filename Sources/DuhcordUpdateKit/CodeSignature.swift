import CryptoKit
import Foundation
import Security

/// Code-signature checks for Duhcord's XPC helpers, so they only serve Duhcord itself.
public enum CodeSignature {
    /// Duhcord's bundle ID plus the leaf certificate this process was signed with. Callers and new versions must
    /// match it. Nil for ad-hoc builds, which have no certificate.
    public static let ownCertificateRequirement: String? = {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: UInt32(kSecCSSigningInformation)), &info) == errSecSuccess,
              let certificates = (info as? [String: Any])?[kSecCodeInfoCertificates as String] as? [SecCertificate],
              let leaf = certificates.first else { return nil }
        let sha1 = Insecure.SHA1.hash(data: SecCertificateCopyData(leaf) as Data).map { String(format: "%02x", $0) }.joined()
        return "identifier \"\(UpdateKit.appBundleIdentifier)\" and certificate leaf = H\"\(sha1)\""
    }()

    /// Checks the caller's running code against `requirement`. Done by hand because
    /// NSXPCListener.setConnectionCodeSigningRequirement isn't supported on an app's own XPC service listener:
    /// calling it there aborts the helper at launch.
    public static func caller(_ connection: NSXPCConnection, satisfies requirement: String) -> Bool {
        var compiled: SecRequirement?
        guard SecRequirementCreateWithString(requirement as CFString, [], &compiled) == errSecSuccess, let compiled,
              let code = callerCode(connection) else { return false }
        return SecCodeCheckValidity(code, [], compiled) == errSecSuccess
    }

    /// Where the caller's code lives on disk.
    public static func callerPath(_ connection: NSXPCConnection) -> String? {
        var staticCode: SecStaticCode?
        var path: CFURL?
        guard let code = callerCode(connection),
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopyPath(staticCode, [], &path) == errSecSuccess, let path else { return nil }
        return (path as URL).resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// The app bundle an XPC service is embedded in (Duhcord.app/Contents/XPCServices/<name>.xpc).
    public static var containingAppPath: String {
        Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .resolvingSymlinksInPath().standardizedFileURL.path
    }

    private static func callerCode(_ connection: NSXPCConnection) -> SecCode? {
        var code: SecCode?
        let attributes = [kSecGuestAttributePid: connection.processIdentifier] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess else { return nil }
        return code
    }
}

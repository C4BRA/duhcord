import CryptoKit
import DuhcordUpdateKit
import Foundation
import OSLog
import Security

/// Visible with: log show --last 1h --predicate 'subsystem == "com.duhcord.app.Updater"'
private let log = Logger(subsystem: "com.duhcord.app.Updater", category: "install")

// The installer helper: an XPC service inside Duhcord.app. It's the one part of Duhcord outside the sandbox,
// because a sandboxed app can't replace itself. macOS starts it only when Duhcord asks and it exits afterwards.
//
// It has no network access and trusts nothing the app says: it re-verifies the manifest signature, the
// version, the archive checksum and the new app's code signature itself, picks the install location itself,
// and refuses builds that drop the sandbox or the hardened runtime.

/// The leaf certificate this helper was signed with. Callers and new versions must carry the same one.
/// nil for ad-hoc builds, which therefore can't update.
private let signingRequirement: String? = {
    var code: SecCode?
    var staticCode: SecStaticCode?
    var info: CFDictionary?
    guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
          SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
          SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: UInt32(kSecCSSigningInformation)), &info) == errSecSuccess,
          let certificates = (info as? [String: Any])?[kSecCodeInfoCertificates as String] as? [SecCertificate],
          let leaf = certificates.first else {
        log.error("helper has no signing certificate (ad-hoc build?); refusing all requests")
        return nil
    }
    let sha1 = Insecure.SHA1.hash(data: SecCertificateCopyData(leaf) as Data).map { String(format: "%02x", $0) }.joined()
    return "identifier \"\(UpdateKit.appBundleIdentifier)\" and certificate leaf = H\"\(sha1)\""
}()

final class Installer: NSObject, DuhcordUpdaterProtocol {
    private let fileManager = FileManager.default

    func install(archive: FileHandle, manifest: Data, signature: Data, reply: @escaping (String?) -> Void) {
        log.info("install requested")
        do {
            try perform(archive: archive, manifestData: manifest, signature: signature)
            log.info("install finished")
            reply(nil)
        } catch let error as UpdateError {
            log.error("install failed: \(error.localizedDescription, privacy: .public)")
            reply(error.localizedDescription)
        } catch {
            log.error("install failed: \(String(describing: error), privacy: .public)")
            reply(UpdateError.installFailed(error.localizedDescription).localizedDescription)
        }
    }

    private func perform(archive: FileHandle, manifestData: Data, signature: Data) throws {
        guard let requirementText = signingRequirement else { throw UpdateError.invalidApp("this build isn't release-signed") }

        // The helper lives at Duhcord.app/Contents/XPCServices/<name>.xpc, so this is the installed app.
        let installURL = Bundle.main.bundleURL
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .resolvingSymlinksInPath()
        guard installURL.pathExtension == "app", Self.isApplicationsFolder(installURL.deletingLastPathComponent()) else {
            throw UpdateError.wrongLocation
        }

        let manifest = try UpdateVerifier.verify(manifest: manifestData, signature: signature)
        // The installed version is read from disk, never taken from the app.
        guard let installed = Self.version(of: installURL) else { throw UpdateError.installFailed("can't read the installed version") }
        try UpdateVerifier.checkApplicable(manifest, installedVersion: installed)

        // Work in a private folder on the same volume, so the final swap is a single atomic rename.
        let work = try fileManager.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: installURL, create: true)
        defer { try? fileManager.removeItem(at: work) }

        let zipURL = work.appendingPathComponent("update.zip")
        guard fileManager.createFile(atPath: zipURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw UpdateError.installFailed("can't create a temporary file")
        }
        let output = try FileHandle(forWritingTo: zipURL)
        let (sha256, size) = try UpdateVerifier.hash(archive, limit: manifest.size, copyingTo: output)
        try output.close()
        guard size == manifest.size, sha256 == manifest.sha256.lowercased() else { throw UpdateError.hashMismatch }

        // Only now, with a checksum that only the update key could have vouched for, is the archive unpacked.
        let extractURL = work.appendingPathComponent("extract", isDirectory: true)
        try run("/usr/bin/ditto", ["-x", "-k", zipURL.path, extractURL.path])
        let contents = try fileManager.contentsOfDirectory(atPath: extractURL.path)
        guard contents == [installURL.lastPathComponent] || contents == ["Duhcord.app"] else {
            throw UpdateError.invalidApp("unexpected archive contents")
        }
        let newApp = extractURL.appendingPathComponent(contents[0])
        removeQuarantine(newApp)

        let requirement = try makeRequirement(requirementText)
        try validate(newApp, requirement: requirement, expectedVersion: manifest.version)

        // Atomic swap: the new app takes the installed path, the old one moves into the work folder.
        guard renamex_np(newApp.path, installURL.path, UInt32(RENAME_SWAP)) == 0 else {
            throw UpdateError.installFailed(String(cString: strerror(errno)))
        }
        do {
            try validate(installURL, requirement: requirement, expectedVersion: manifest.version)
        } catch {
            // Put the old version back.
            _ = renamex_np(newApp.path, installURL.path, UInt32(RENAME_SWAP))
            throw error
        }
    }

    /// Code signature, certificate, entitlements, hardened runtime and version of a downloaded or installed app.
    private func validate(_ url: URL, requirement: SecRequirement, expectedVersion: String) throws {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess, let staticCode else {
            throw UpdateError.invalidApp("not a signed app")
        }
        let checks = SecCSFlags(rawValue: UInt32(kSecCSCheckAllArchitectures) | UInt32(kSecCSStrictValidate) | UInt32(kSecCSCheckNestedCode))
        var error: Unmanaged<CFError>?
        guard SecStaticCodeCheckValidityWithErrors(staticCode, checks, requirement, &error) == errSecSuccess else {
            let reason = error.map { ($0.takeRetainedValue() as Error).localizedDescription } ?? "signature check failed"
            throw UpdateError.invalidApp(reason)
        }

        var info: CFDictionary?
        let infoFlags = SecCSFlags(rawValue: UInt32(kSecCSSigningInformation) | UInt32(kSecCSRequirementInformation))
        guard SecCodeCopySigningInformation(staticCode, infoFlags, &info) == errSecSuccess,
              let details = info as? [String: Any] else { throw UpdateError.invalidApp("unreadable signature") }

        // 0x10000 is kSecCodeSignatureRuntime: the hardened runtime.
        guard let flags = details[kSecCodeInfoFlags as String] as? UInt32, flags & 0x10000 != 0 else {
            throw UpdateError.invalidApp("hardened runtime is off")
        }
        let entitlements = details[kSecCodeInfoEntitlementsDict as String] as? [String: Any] ?? [:]
        let expected: Set<String> = ["com.apple.security.app-sandbox", "com.apple.security.network.client"]
        guard Set(entitlements.keys) == expected, entitlements.values.allSatisfy({ ($0 as? Bool) == true }) else {
            throw UpdateError.invalidApp("its permissions differ from Duhcord's (sandbox, outgoing network only)")
        }
        guard Self.version(of: url) == expectedVersion else { throw UpdateError.invalidApp("version doesn't match the manifest") }
    }

    private func makeRequirement(_ text: String) throws -> SecRequirement {
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess, let requirement else {
            throw UpdateError.installFailed("can't build the signature requirement")
        }
        return requirement
    }

    private func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw UpdateError.installFailed("couldn't unpack the update") }
    }

    /// Our own verification replaces Gatekeeper's for this copy, so the next launch isn't blocked again.
    private func removeQuarantine(_ url: URL) {
        removexattr(url.path, "com.apple.quarantine", XATTR_NOFOLLOW)
        let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: nil)
        while let item = enumerator?.nextObject() as? URL {
            removexattr(item.path, "com.apple.quarantine", XATTR_NOFOLLOW)
        }
    }

    static func version(of app: URL) -> String? {
        let plist = app.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        return dict["CFBundleShortVersionString"] as? String
    }

    static func isApplicationsFolder(_ folder: URL) -> Bool {
        let path = folder.standardizedFileURL.path
        guard let home = getpwuid(getuid()).map({ String(cString: $0.pointee.pw_dir) }) else { return path == "/Applications" }
        return path == "/Applications" || path == home + "/Applications"
    }
}

final class ServiceDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // Ad-hoc builds have no certificate to check callers against, so they accept nobody.
        guard signingRequirement != nil else {
            log.error("rejected connection: helper isn't release-signed")
            return false
        }
        log.info("accepted connection from pid \(connection.processIdentifier, privacy: .public)")
        connection.exportedInterface = NSXPCInterface(with: DuhcordUpdaterProtocol.self)
        connection.exportedObject = Installer()
        connection.resume()
        return true
    }
}

log.info("helper started; caller requirement: \(signingRequirement ?? "none", privacy: .public)")
let delegate = ServiceDelegate()
let listener = NSXPCListener.service()
// Only Duhcord itself, signed with the same certificate as this helper, may connect. macOS enforces this.
if let signingRequirement { listener.setConnectionCodeSigningRequirement(signingRequirement) }
listener.delegate = delegate
listener.resume()

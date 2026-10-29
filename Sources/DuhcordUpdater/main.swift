import DuhcordUpdateKit
import Foundation
import OSLog
import Security

/// Visible with: log show --last 1h --predicate 'subsystem == "com.duhcord.app.Updater"'
private let updaterLog = Logger(subsystem: "com.duhcord.app.Updater", category: "install")

// The installer helper: an XPC service inside Duhcord.app. It's the one part of Duhcord outside the sandbox,
// because a sandboxed app can't replace itself. macOS starts it only when Duhcord asks and it exits afterwards.
//
// It has no network access and trusts nothing the app says: it re-verifies the manifest signature, the
// version, the archive checksum and the new app's code signature itself, picks the install location itself,
// and refuses builds that drop the sandbox or the hardened runtime.

/// Callers and new versions must carry this helper's own certificate. Nil for ad-hoc builds, which therefore can't update.
private let signingRequirement: String? = {
    let requirement = CodeSignature.ownCertificateRequirement
    if requirement == nil { updaterLog.error("helper has no signing certificate (ad-hoc build?); refusing all requests") }
    return requirement
}()

final class Installer: NSObject, DuhcordUpdaterProtocol {
    private let fileManager = FileManager.default

    func install(archive: FileHandle, manifest: Data, signature: Data, reply: @escaping (String?) -> Void) {
        updaterLog.info("install requested")
        do {
            try perform(archive: archive, manifestData: manifest, signature: signature)
            updaterLog.info("install finished")
            reply(nil)
        } catch let error as UpdateError {
            updaterLog.error("install failed: \(error.localizedDescription, privacy: .public)")
            reply(error.localizedDescription)
        } catch {
            updaterLog.error("install failed: \(String(describing: error), privacy: .public)")
            reply(UpdateError.installFailed(error.localizedDescription).localizedDescription)
        }
    }

    private func perform(archive: FileHandle, manifestData: Data, signature: Data) throws {
        guard let requirementText = signingRequirement else { throw UpdateError.invalidApp("this build isn't release-signed") }

        // The helper lives at Duhcord.app/Contents/XPCServices/<name>.xpc, so this is the installed app.
        let installURL = Bundle.main.bundleURL
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .resolvingSymlinksInPath()
        guard installURL.pathExtension == "app", UpdateKit.isApplicationsFolder(installURL.deletingLastPathComponent()) else {
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

        let sandbox = "com.apple.security.app-sandbox", network = "com.apple.security.network.client"
        try checkLimits(staticCode, oneOfEntitlements: [
            [sandbox, network],
            [sandbox, network, "com.apple.security.files.user-selected.read-write"],
        ], name: "the app")
        // The helpers inside keep their own limits: this one with none at all, the voice helper with network and
        // microphone access, and the optional media decoder with only the app sandbox.
        let services = url.appendingPathComponent("Contents/XPCServices")
        try checkLimits(at: services.appendingPathComponent(UpdateKit.serviceName + ".xpc"), entitlements: [], name: "the installer")
        let voice = services.appendingPathComponent(UpdateKit.voiceServiceName + ".xpc")
        if fileManager.fileExists(atPath: voice.path) {
            try checkLimits(at: voice, entitlements: [sandbox, network, "com.apple.security.device.audio-input"], name: "the voice helper")
        }
        let mediaDecoder = services.appendingPathComponent("com.duhcord.app.MediaDecoder.xpc")
        if fileManager.fileExists(atPath: mediaDecoder.path) {
            try checkLimits(at: mediaDecoder, entitlements: [sandbox], name: "the media decoder")
        }
        guard Self.version(of: url) == expectedVersion else { throw UpdateError.invalidApp("version doesn't match the manifest") }
    }

    private func checkLimits(at url: URL, entitlements expected: Set<String>, name: String) throws {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess, let staticCode else {
            throw UpdateError.invalidApp("\(name) is missing or unsigned")
        }
        try checkLimits(staticCode, entitlements: expected, name: name)
    }

    /// The hardened runtime is on and the entitlements are exactly one allowed set, all switched on.
    private func checkLimits(_ code: SecStaticCode, entitlements expected: Set<String>, name: String) throws {
        try checkLimits(code, oneOfEntitlements: [expected], name: name)
    }

    private func checkLimits(_ code: SecStaticCode, oneOfEntitlements allowed: [Set<String>], name: String) throws {
        var info: CFDictionary?
        let infoFlags = SecCSFlags(rawValue: UInt32(kSecCSSigningInformation) | UInt32(kSecCSRequirementInformation))
        guard SecCodeCopySigningInformation(code, infoFlags, &info) == errSecSuccess,
              let details = info as? [String: Any] else { throw UpdateError.invalidApp("unreadable signature for \(name)") }

        // 0x10000 is kSecCodeSignatureRuntime: the hardened runtime.
        guard let flags = details[kSecCodeInfoFlags as String] as? UInt32, flags & 0x10000 != 0 else {
            throw UpdateError.invalidApp("hardened runtime is off for \(name)")
        }
        let entitlements = details[kSecCodeInfoEntitlementsDict as String] as? [String: Any] ?? [:]
        guard allowed.contains(Set(entitlements.keys)), entitlements.values.allSatisfy({ ($0 as? Bool) == true }) else {
            throw UpdateError.invalidApp("the permissions of \(name) differ from Duhcord's")
        }
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
}

final class ServiceDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // Ad-hoc builds have no certificate to check callers against, so they accept nobody.
        guard let signingRequirement else {
            updaterLog.error("rejected connection: helper isn't release-signed")
            return false
        }
        // Only Duhcord itself, signed with the same certificate as this helper, may talk to it.
        guard CodeSignature.caller(connection, satisfies: signingRequirement) else {
            updaterLog.error("rejected connection from pid \(connection.processIdentifier, privacy: .public): not signed as Duhcord")
            return false
        }
        updaterLog.info("accepted connection from pid \(connection.processIdentifier, privacy: .public)")
        connection.exportedInterface = NSXPCInterface(with: DuhcordUpdaterProtocol.self)
        connection.exportedObject = Installer()
        connection.resume()
        return true
    }
}

updaterLog.info("helper started; caller requirement: \(signingRequirement ?? "none", privacy: .public)")
let delegate = ServiceDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()

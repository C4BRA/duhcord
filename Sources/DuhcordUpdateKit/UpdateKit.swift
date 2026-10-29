import CryptoKit
import Foundation

/// Everything the app and the installer helper agree on about updates.
public enum UpdateKit {
    /// Public halves of the update approval keys (base64 of the raw 32-byte Ed25519 key).
    /// An update is only accepted if its manifest is signed by one of these. Empty means updates are off.
    public static let trustedPublicKeys: [String] = [
        "tdEajMGfkvyhp88QqFWZ2BWyZSWTgMa8fBCbV+EonWY=",
    ]

    /// The installer helper's XPC service name; must match its bundle identifier.
    public static let serviceName = "com.duhcord.app.Updater"
    /// The voice helper, whose limits the installer also checks.
    public static let voiceServiceName = "com.duhcord.app.Voice"
    public static let appBundleIdentifier = "com.duhcord.app"

    /// Updates can only replace Duhcord in /Applications or ~/Applications. Shared by the app (to warn) and the
    /// installer helper (to refuse).
    public static func isApplicationsFolder(_ folder: URL) -> Bool {
        let path = folder.standardizedFileURL.path
        // The sandbox redirects the home folder APIs into the container, so ask the user database instead.
        guard let home = getpwuid(getuid()).map({ String(cString: $0.pointee.pw_dir) }) else { return path == "/Applications" }
        return path == "/Applications" || path == home + "/Applications"
    }

    public static let manifestURL = URL(string: "https://github.com/C4BRA/duhcord/releases/latest/download/update.json")!
    public static let signatureURL = URL(string: "https://github.com/C4BRA/duhcord/releases/latest/download/update.json.sig")!
    /// Release archives must live under this prefix.
    public static let downloadPrefix = "https://github.com/C4BRA/duhcord/releases/download/"

    public static let maxManifestSize = 64 * 1024
    public static let maxSignatureSize = 1024
    public static let maxArchiveSize = 64 * 1024 * 1024
}

/// Describes one release. Signed as a whole: the signature covers the exact bytes of update.json.
public struct UpdateManifest: Codable, Equatable, Sendable {
    public let version: String
    public let url: String
    public let sha256: String
    public let size: Int
    public let expires: Int?
    public let minimumSystemVersion: String?
    public let notes: String?

    public init(version: String, url: String, sha256: String, size: Int, minimumSystemVersion: String? = nil,
                notes: String? = nil, expires: Int? = nil) {
        self.version = version
        self.url = url
        self.sha256 = sha256
        self.size = size
        self.expires = expires
        self.minimumSystemVersion = minimumSystemVersion
        self.notes = notes
    }
}

public enum UpdateError: Error, Equatable, LocalizedError {
    case notConfigured
    case badSignature
    case malformed
    case wrongSource
    case tooLarge
    case notNewer
    case systemTooOld(String)
    case hashMismatch
    case invalidApp(String)
    case wrongLocation
    case installFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured: return "Updates aren't set up in this build."
        case .badSignature: return "The update isn't signed by Duhcord's update key."
        case .malformed: return "The update information is malformed."
        case .wrongSource: return "The update points somewhere other than Duhcord's GitHub releases."
        case .tooLarge: return "The update is larger than allowed."
        case .notNewer: return "The update isn't newer than the installed version."
        case .systemTooOld(let version): return "This update needs macOS \(version) or later."
        case .hashMismatch: return "The downloaded update doesn't match its signed checksum."
        case .invalidApp(let reason): return "The downloaded app failed verification: \(reason)"
        case .wrongLocation: return "Move Duhcord to your Applications folder to install updates."
        case .installFailed(let reason): return "Installing the update failed: \(reason)"
        }
    }
}

public enum UpdateVerifier {
    /// Verifies the signature over the exact manifest bytes, and only then parses them, so nothing unsigned
    /// is ever interpreted.
    public static func verify(manifest: Data, signature: Data, keys: [String] = UpdateKit.trustedPublicKeys) throws -> UpdateManifest {
        guard !keys.isEmpty else { throw UpdateError.notConfigured }
        guard manifest.count <= UpdateKit.maxManifestSize, signature.count <= UpdateKit.maxSignatureSize else {
            throw UpdateError.tooLarge
        }
        let encoded = String(decoding: signature, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let signatureBytes = Data(base64Encoded: encoded) else { throw UpdateError.badSignature }

        let trusted = keys.contains { key in
            guard let raw = Data(base64Encoded: key),
                  let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: raw) else { return false }
            return publicKey.isValidSignature(signatureBytes, for: manifest)
        }
        guard trusted else { throw UpdateError.badSignature }

        guard let parsed = try? JSONDecoder().decode(UpdateManifest.self, from: manifest) else { throw UpdateError.malformed }
        guard parsed.url.hasPrefix(UpdateKit.downloadPrefix), URL(string: parsed.url)?.host == "github.com" else {
            throw UpdateError.wrongSource
        }
        guard parsed.size > 0, parsed.size <= UpdateKit.maxArchiveSize else { throw UpdateError.tooLarge }
        guard parsed.sha256.count == 64, parsed.sha256.allSatisfy(\.isHexDigit) else { throw UpdateError.malformed }
        guard Version(parsed.version) != nil else { throw UpdateError.malformed }
        return parsed
    }

    /// Throws unless `manifest` is newer than `installedVersion` and runs on this macOS.
    public static func checkApplicable(_ manifest: UpdateManifest, installedVersion: String,
                                       systemVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion) throws {
        guard let candidate = Version(manifest.version) else { throw UpdateError.malformed }
        guard let installed = Version(installedVersion), candidate > installed else { throw UpdateError.notNewer }
        if let minimum = manifest.minimumSystemVersion, let required = Version(minimum) {
            let system = Version(parts: [systemVersion.majorVersion, systemVersion.minorVersion, systemVersion.patchVersion])
            guard system >= required else { throw UpdateError.systemTooOld(minimum) }
        }
    }

    /// An absent expiry is stale so older manifests cannot indefinitely claim that no update exists.
    public static func isStale(_ manifest: UpdateManifest, now: Date) -> Bool {
        guard let expires = manifest.expires else { return true }
        return Date(timeIntervalSince1970: TimeInterval(expires)) < now
    }

    /// Copies up to `limit` bytes from `source` to `destination` (if given) and returns the SHA-256 and byte count.
    /// Stops early instead of reading an oversized file to the end.
    public static func hash(_ source: FileHandle, limit: Int, copyingTo destination: FileHandle? = nil) throws -> (sha256: String, size: Int) {
        var hasher = SHA256()
        var total = 0
        while let chunk = try source.read(upToCount: 1 << 20), !chunk.isEmpty {
            total += chunk.count
            guard total <= limit else { throw UpdateError.tooLarge }
            hasher.update(data: chunk)
            try destination?.write(contentsOf: chunk)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return (digest, total)
    }
}

/// A dotted numeric version such as 1.2.0. Missing parts count as zero, so 1.2 == 1.2.0.
public struct Version: Comparable {
    public let parts: [Int]

    public init(parts: [Int]) { self.parts = parts }

    public init?(_ string: String) {
        let trimmed = string.hasPrefix("v") ? String(string.dropFirst()) : string
        let pieces = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        guard !pieces.isEmpty, pieces.count <= 4 else { return nil }
        var parsed: [Int] = []
        for piece in pieces {
            guard let n = Int(piece), n >= 0, piece.allSatisfy(\.isNumber) else { return nil }
            parsed.append(n)
        }
        parts = parsed
    }

    public static func < (a: Version, b: Version) -> Bool {
        let count = max(a.parts.count, b.parts.count)
        for i in 0..<count {
            let x = i < a.parts.count ? a.parts[i] : 0
            let y = i < b.parts.count ? b.parts[i] : 0
            if x != y { return x < y }
        }
        return false
    }

    public static func == (a: Version, b: Version) -> Bool { !(a < b) && !(b < a) }
}

/// What the app asks of the installer helper. The helper re-verifies everything itself and trusts nothing
/// the app tells it beyond the bytes it's handed.
@objc public protocol DuhcordUpdaterProtocol {
    /// `archive` is an open handle to the downloaded zip. The reply is nil on success, else an error message.
    func install(archive: FileHandle, manifest: Data, signature: Data, reply: @escaping (String?) -> Void)
}

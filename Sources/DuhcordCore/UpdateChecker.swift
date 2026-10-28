import DuhcordUpdateKit
import Foundation

/// Looks for new releases and downloads them. Installing is done by the installer helper, which re-checks
/// everything this class checks. Main-thread only.
public final class UpdateChecker {
    public enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(UpdateManifest)
        case downloading(UpdateManifest)
        /// Downloaded and verified, ready to hand to the installer.
        case ready(UpdateManifest, archive: URL)
        case failed(String)
    }

    public var onChange: ((State) -> Void)?
    public private(set) var state: State = .idle {
        didSet { if state != oldValue { onChange?(state) } }
    }

    public let currentVersion: String
    private let keys: [String]
    private let session = SecureSession.updates.session
    /// The exact bytes that were verified, passed on unchanged to the installer.
    public private(set) var manifestData = Data()
    public private(set) var signatureData = Data()

    public init(currentVersion: String, keys: [String] = UpdateKit.trustedPublicKeys) {
        self.currentVersion = currentVersion
        self.keys = keys
    }

    /// False when this build has no trusted update key, in which case nothing is ever fetched.
    public var isEnabled: Bool { !keys.isEmpty }

    /// One small request for the manifest and one for its signature.
    public func check() {
        guard isEnabled, !isBusy else { return }
        state = .checking
        Task { @MainActor in
            do {
                let manifest = try await fetch(UpdateKit.manifestURL, limit: UpdateKit.maxManifestSize)
                let signature = try await fetch(UpdateKit.signatureURL, limit: UpdateKit.maxSignatureSize)
                let parsed = try UpdateVerifier.verify(manifest: manifest, signature: signature, keys: keys)
                do {
                    try UpdateVerifier.checkApplicable(parsed, installedVersion: currentVersion)
                } catch UpdateError.notNewer {
                    state = .upToDate
                    return
                }
                manifestData = manifest
                signatureData = signature
                state = .available(parsed)
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    /// Downloads the archive into the app's temporary folder, checking size and checksum as it goes.
    public func download() {
        guard case .available(let manifest) = state else { return }
        state = .downloading(manifest)
        Task { @MainActor in
            do {
                let url = try await downloadArchive(manifest)
                state = .ready(manifest, archive: url)
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    public func reset() { state = .idle }

    private var isBusy: Bool {
        switch state {
        case .checking, .downloading, .ready: return true
        default: return false
        }
    }

    // MARK: - Networking

    /// Reads at most `limit` bytes, so a misbehaving server can't make us buffer a huge response.
    private func fetch(_ url: URL, limit: Int) async throws -> Data {
        let (bytes, response) = try await session.bytes(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError.installFailed("no release found") }
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count > limit { throw UpdateError.tooLarge }
        }
        return data
    }

    private func downloadArchive(_ manifest: UpdateManifest) async throws -> URL {
        guard let url = URL(string: manifest.url) else { throw UpdateError.malformed }
        // URLSession writes straight to disk; the size cap stops a response that runs past the signed size.
        let (downloaded, response) = try await session.download(from: url, delegate: SizeCap(limit: Int64(manifest.size)))
        defer { try? FileManager.default.removeItem(at: downloaded) }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError.installFailed("download failed") }

        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("Duhcord-\(manifest.version).zip")
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: downloaded, to: destination)

        let input = try FileHandle(forReadingFrom: destination)
        defer { try? input.close() }
        let (sha256, size) = try UpdateVerifier.hash(input, limit: manifest.size)
        guard size == manifest.size, sha256 == manifest.sha256.lowercased() else {
            try? FileManager.default.removeItem(at: destination)
            throw UpdateError.hashMismatch
        }
        return destination
    }
}

/// Cancels a download once it writes more than the signed size.
private final class SizeCap: NSObject, URLSessionDownloadDelegate {
    private let limit: Int64

    init(limit: Int64) { self.limit = limit }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > limit || totalBytesExpectedToWrite > limit { downloadTask.cancel() }
    }

    // Required by the protocol; the async download call delivers the file itself.
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}

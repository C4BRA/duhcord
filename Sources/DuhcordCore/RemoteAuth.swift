import CryptoKit
import Foundation
import Security

/// QR code login, the same flow the official desktop app uses.
///
/// 1. We make a fresh RSA key pair that exists only in memory and send Discord the public half.
/// 2. Discord gives us a fingerprint, which we show as a QR code.
/// 3. The user scans it with the Discord app on their phone and approves.
/// 4. Discord gives us a ticket; we swap it for the token, encrypted to our public key.
///
/// The token is never typed, pasted or shown, and only our in-memory private key can decrypt it.
/// The key is thrown away when the login attempt ends.
///
/// All state lives on the private serial `queue`, which is what makes sharing it across threads safe.
public final class RemoteAuth: @unchecked Sendable {
    public enum Event: Equatable, Sendable {
        /// Show this as a QR code.
        case showCode(URL)
        /// The phone scanned the code and is waiting for the user to approve.
        case scanned(username: String)
        case loggedIn(token: String)
        /// The code timed out or the connection dropped. Start a new attempt to get a fresh code.
        case expired
        /// The user tapped "cancel" on their phone.
        case cancelled
        /// Discord couldn't be reached.
        case unreachable
        case failed(String)
    }

    /// Called on the main queue.
    public var onEvent: ((Event) -> Void)?

    private static let url = URL(string: "wss://remote-auth-gateway.discord.gg/?v=2")!

    private let queue = DispatchQueue(label: "duhcord.remote-auth")
    private var task: URLSessionWebSocketTask?
    private var heartbeat: DispatchSourceTimer?
    private var privateKey: SecKey?
    private var finished = false
    /// Whether Discord answered at all on this attempt, to tell "offline" apart from "code expired".
    private var gotHello = false

    public init() {}

    deinit {
        heartbeat?.cancel()
        task?.cancel(with: .normalClosure, reason: nil)
    }

    public func start() {
        queue.async { [self] in
            stopLocked()
            finished = false
            gotHello = false
            do {
                privateKey = try Self.makeKey()
            } catch {
                finish(.failed("Couldn't create a login key: \(error.localizedDescription)"))
                return
            }
            var request = URLRequest(url: Self.url)
            // The remote-auth gateway rejects connections without Discord's origin.
            request.setValue("https://discord.com", forHTTPHeaderField: "Origin")
            request.setValue(ClientIdentity.userAgent, forHTTPHeaderField: "User-Agent")
            let task = SecureSession.shared.session.webSocketTask(with: request)
            self.task = task
            task.resume()
            receive(on: task)
        }
    }

    public func stop() {
        queue.async { [self] in
            finished = true
            stopLocked()
        }
    }

    // MARK: - Protocol

    private func receive(on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self else { return }
            self.queue.async {
                guard task === self.task, !self.finished else { return }
                switch result {
                case .success(.string(let text)):
                    self.handle(Data(text.utf8))
                    self.receive(on: task)
                case .success(.data(let data)):
                    self.handle(data)
                    self.receive(on: task)
                case .success:
                    self.receive(on: task)
                case .failure:
                    self.finish(self.gotHello ? .expired : .unreachable)
                }
            }
        }
    }

    private func handle(_ data: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let op = json["op"] as? String else { return }

        switch op {
        case "hello":
            gotHello = true
            let interval = min(max((json["heartbeat_interval"] as? Double ?? 41_250) / 1000, 1), 300)
            startHeartbeat(every: interval)
            guard let publicKey = privateKey.flatMap(SecKeyCopyPublicKey),
                  let spki = Self.subjectPublicKeyInfo(for: publicKey) else {
                finish(.failed("Couldn't export the login key."))
                return
            }
            send(["op": "init", "encoded_public_key": spki.base64EncodedString()])

        case "nonce_proof":
            // Proves we hold the private key: decrypt the nonce and send back its SHA-256.
            guard let nonce = decrypt(json["encrypted_nonce"]) else {
                finish(.failed("Discord sent a login challenge we couldn't decrypt."))
                return
            }
            send(["op": "nonce_proof", "proof": Self.base64URL(Data(SHA256.hash(data: nonce)))])

        case "pending_remote_init":
            guard let fingerprint = json["fingerprint"] as? String,
                  let url = URL(string: "https://discord.com/ra/\(fingerprint)") else { return }
            emit(.showCode(url))

        case "pending_ticket":
            // "id:discriminator:avatar:username" — only the name is shown.
            let payload = decrypt(json["encrypted_user_payload"]).flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let username = payload.split(separator: ":", omittingEmptySubsequences: false).dropFirst(3).joined(separator: ":")
            emit(.scanned(username: username.isEmpty ? "your account" : username))

        case "pending_login":
            guard let ticket = json["ticket"] as? String else { return }
            redeem(ticket)

        case "pending_finish":
            // Older protocol versions send the encrypted token directly.
            if let token = decrypt(json["encrypted_token"]).flatMap({ String(data: $0, encoding: .utf8) }) {
                finish(.loggedIn(token: token))
            }

        case "cancel":
            finish(.cancelled)

        default:
            break
        }
    }

    private func redeem(_ ticket: String) {
        stopHeartbeatAndSocket()
        Task {
            do {
                let encrypted = try await RESTClient(token: nil).exchangeRemoteAuthTicket(ticket)
                queue.async { [self] in
                    guard let token = decrypt(encrypted).flatMap({ String(data: $0, encoding: .utf8) }), !token.isEmpty else {
                        finish(.failed("Discord sent a token we couldn't decrypt."))
                        return
                    }
                    finish(.loggedIn(token: token))
                }
            } catch {
                queue.async { [self] in
                    finish(DiscordSession.isConnectivityError(error) ? .unreachable : .failed(error.localizedDescription))
                }
            }
        }
    }

    // MARK: - Plumbing

    private func send(_ payload: [String: Any]) {
        guard let task, let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8) else { return }
        task.send(.string(text)) { _ in }
    }

    private func startHeartbeat(every interval: Double) {
        heartbeat?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in self?.send(["op": "heartbeat"]) }
        heartbeat = timer
        timer.resume()
    }

    private func decrypt(_ value: Any?) -> Data? {
        guard let base64 = value as? String, let data = Data(base64Encoded: base64), let privateKey else { return nil }
        return SecKeyCreateDecryptedData(privateKey, .rsaEncryptionOAEPSHA256, data as CFData, nil) as Data?
    }

    private func emit(_ event: Event) {
        DispatchQueue.main.async { [weak self] in self?.onEvent?(event) }
    }

    /// Ends the attempt, discards the key, and reports the outcome once.
    private func finish(_ event: Event) {
        guard !finished else { return }
        finished = true
        stopLocked()
        emit(event)
    }

    private func stopHeartbeatAndSocket() {
        heartbeat?.cancel()
        heartbeat = nil
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
    }

    private func stopLocked() {
        stopHeartbeatAndSocket()
        privateKey = nil
    }

    // MARK: - Crypto helpers

    private static func makeKey() throws -> SecKey {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048,
            // Never stored in the keychain: the key lives in memory for this one attempt.
            kSecPrivateKeyAttrs as String: [kSecAttrIsPermanent as String: false],
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            throw error!.takeRetainedValue() as Error
        }
        return key
    }

    /// Security.framework exports RSA public keys as bare PKCS#1; Discord wants them wrapped in SubjectPublicKeyInfo.
    static func subjectPublicKeyInfo(for publicKey: SecKey) -> Data? {
        guard let pkcs1 = SecKeyCopyExternalRepresentation(publicKey, nil) as Data? else { return nil }
        return wrapPKCS1(pkcs1)
    }

    static func wrapPKCS1(_ pkcs1: Data) -> Data {
        // AlgorithmIdentifier: rsaEncryption OID with NULL parameters.
        let algorithm = Data([0x30, 0x0D, 0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01, 0x05, 0x00])
        let bitString = der(tag: 0x03, Data([0x00]) + pkcs1)
        return der(tag: 0x30, algorithm + bitString)
    }

    static func der(tag: UInt8, _ content: Data) -> Data {
        var out = Data([tag])
        let n = content.count
        if n < 0x80 {
            out.append(UInt8(n))
        } else {
            var bytes: [UInt8] = []
            var v = n
            while v > 0 {
                bytes.insert(UInt8(v & 0xFF), at: 0)
                v >>= 8
            }
            out.append(0x80 | UInt8(bytes.count))
            out.append(contentsOf: bytes)
        }
        return out + content
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum RESTError: Error, LocalizedError {
    case unauthorized
    case forbidden
    case http(status: Int, message: String?)
    case invalidResponse
    case captchaRequired

    public var errorDescription: String? {
        switch self {
        case .unauthorized: return "Your token was rejected. Please log in again."
        case .forbidden: return "You don't have access to that."
        case .http(let status, let message): return message ?? "Discord returned an error (HTTP \(status))."
        case .invalidResponse: return "Discord sent an unexpected response."
        case .captchaRequired: return "Discord asked for a captcha, which Duhcord can't show. Wait a while and try again."
        }
    }
}

/// The handful of REST endpoints we call. Everything else comes over the gateway.
public final class RESTClient {
    /// nil only for the logged-out client used to finish QR login.
    private let token: String?
    private let session: URLSession
    private let decoder = makeDiscordDecoder()

    public init(token: String?, session: URLSession = SecureSession.shared.session) {
        self.token = token
        self.session = session
    }

    /// Up to `limit` messages, newest first, optionally older than `before`.
    public func messages(in channelID: Snowflake, before: Snowflake? = nil, limit: Int = 50) async throws -> [Message] {
        var query = [URLQueryItem(name: "limit", value: String(limit))]
        if let before { query.append(URLQueryItem(name: "before", value: before)) }
        let data = try await request("GET", "/channels/\(channelID)/messages", query: query)
        return try decoder.decode(LossyArray<Message>.self, from: data).elements
    }

    @discardableResult
    public func sendMessage(_ content: String, to channelID: Snowflake, nonce: String) async throws -> Message {
        let body: [String: Any] = ["content": content, "nonce": nonce, "tts": false, "flags": 0]
        let data = try await request("POST", "/channels/\(channelID)/messages", body: body)
        return try decoder.decode(Message.self, from: data)
    }

    /// Marks a channel as read up to `messageID`.
    public func ack(channelID: Snowflake, messageID: Snowflake) async throws {
        _ = try await request("POST", "/channels/\(channelID)/messages/\(messageID)/ack", body: ["token": NSNull()])
    }

    /// Invalidates the token on Discord's side, so a copy of it is useless afterwards.
    public func logout() async throws {
        _ = try await request("POST", "/auth/logout", body: ["provider": NSNull(), "voip_provider": NSNull()])
    }

    /// Final step of QR login: swaps the ticket from the remote-auth gateway for the encrypted token.
    public func exchangeRemoteAuthTicket(_ ticket: String) async throws -> String {
        struct Response: Decodable { let encryptedToken: String }
        let data = try await request("POST", "/users/@me/remote-auth/login", body: ["ticket": ticket])
        return try decoder.decode(Response.self, from: data).encryptedToken
    }

    // MARK: - Plumbing

    private struct RateLimited: Decodable { let retryAfter: Double }
    private struct ErrorBody: Decodable {
        let message: String?
        let captchaKey: [String]?
    }

    private func request(_ method: String, _ path: String, query: [URLQueryItem] = [], body: [String: Any]? = nil,
                         attempt: Int = 0) async throws -> Data {
        var components = URLComponents(url: ClientIdentity.apiBase.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }

        var req = URLRequest(url: components.url!)
        req.httpMethod = method
        if let token { req.setValue(token, forHTTPHeaderField: "Authorization") }
        req.setValue(ClientIdentity.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue(ClientIdentity.superPropertiesHeader, forHTTPHeaderField: "X-Super-Properties")
        req.setValue(ClientIdentity.locale, forHTTPHeaderField: "X-Discord-Locale")
        if let body {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw RESTError.invalidResponse }

        switch http.statusCode {
        case 200..<300:
            return data
        case 401:
            throw RESTError.unauthorized
        case 403:
            throw RESTError.forbidden
        case 429 where attempt < 3:
            // Wait exactly as long as Discord asks, then try again.
            let wait = (try? decoder.decode(RateLimited.self, from: data).retryAfter) ?? 1
            try await Task.sleep(nanoseconds: UInt64(max(wait, 0.1) * 1_000_000_000))
            return try await request(method, path, query: query, body: body, attempt: attempt + 1)
        default:
            let body = try? decoder.decode(ErrorBody.self, from: data)
            if body?.captchaKey != nil { throw RESTError.captchaRequired }
            throw RESTError.http(status: http.statusCode, message: body?.message)
        }
    }
}

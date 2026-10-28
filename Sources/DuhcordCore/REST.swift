import Foundation

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

    /// The sent message comes back over the gateway, so the response isn't decoded.
    public func sendMessage(_ content: String, to channelID: Snowflake, nonce: String) async throws {
        let body: [String: Any] = ["content": content, "nonce": nonce, "tts": false, "flags": 0]
        _ = try await request("POST", "/channels/\(channelID)/messages", body: body)
    }

    /// Marks a channel as read up to `messageID`.
    public func ack(channelID: Snowflake, messageID: Snowflake) async throws {
        _ = try await request("POST", "/channels/\(channelID)/messages/\(messageID)/ack", body: ["token": NSNull()])
    }

    /// Marks several channels read in one request, as the official client's "Mark as Read" on a server does.
    public func ackBulk(_ acks: [(channelID: Snowflake, messageID: Snowflake)]) async throws {
        guard !acks.isEmpty else { return }
        let states = acks.map { ["channel_id": $0.channelID, "message_id": $0.messageID, "read_state_type": 0] as [String: Any] }
        _ = try await request("POST", "/read-states/ack-bulk", body: ["read_states": states])
    }

    /// Shows "… is typing" to others in the channel for about 10 seconds.
    public func sendTyping(channelID: Snowflake) async throws {
        _ = try await request("POST", "/channels/\(channelID)/typing")
    }

    /// Someone's profile, as the official client loads it for its profile popout: with mutual servers and
    /// friends, and their server profile when `guildID` is given.
    public func profile(of userID: Snowflake, guildID: Snowflake?) async throws -> UserProfile {
        var query = [
            URLQueryItem(name: "type", value: "popout"),
            URLQueryItem(name: "with_mutual_guilds", value: "true"),
            URLQueryItem(name: "with_mutual_friends", value: "true"),
            URLQueryItem(name: "with_mutual_friends_count", value: "true"),
        ]
        if let guildID { query.append(URLQueryItem(name: "guild_id", value: guildID)) }
        let data = try await request("GET", "/users/\(userID)/profile", query: query)
        return try decoder.decode(UserProfile.self, from: data)
    }

    /// Names and icons for games and apps; unknown IDs are left out.
    public func applications(_ ids: [Snowflake]) async throws -> [PartialApplication] {
        guard !ids.isEmpty else { return [] }
        let query = ids.map { URLQueryItem(name: "application_ids", value: $0) }
        let data = try await request("GET", "/applications/public", query: query)
        return try decoder.decode(LossyArray<PartialApplication>.self, from: data).elements
    }

    /// The DM channel with someone, created if there isn't one yet.
    public func openDM(with userID: Snowflake) async throws -> Channel {
        let data = try await request("POST", "/users/@me/channels", body: ["recipients": [userID]])
        return try decoder.decode(Channel.self, from: data)
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
            // Clamped so a bogus value can't overflow the sleep or stall a request for hours.
            try await Task.sleep(nanoseconds: UInt64(min(max(wait, 0.1), 60) * 1_000_000_000))
            return try await request(method, path, query: query, body: body, attempt: attempt + 1)
        default:
            let body = try? decoder.decode(ErrorBody.self, from: data)
            if body?.captchaKey != nil { throw RESTError.captchaRequired }
            throw RESTError.http(status: http.statusCode, message: body?.message)
        }
    }
}

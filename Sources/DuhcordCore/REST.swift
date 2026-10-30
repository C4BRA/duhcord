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
public actor RESTClient {
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

    /// The sent message comes back over the gateway, so the response isn't decoded. `files` are uploaded with it
    /// as attachments, in order.
    public func sendMessage(_ content: String, to channelID: Snowflake, nonce: String, files: [UploadFile] = []) async throws {
        var body: [String: Any] = ["content": content, "nonce": nonce, "tts": false, "flags": 0]
        guard !files.isEmpty else {
            _ = try await request("POST", "/channels/\(channelID)/messages", body: body)
            return
        }
        body["attachments"] = files.enumerated().map { ["id": $0.offset, "filename": $0.element.name] as [String: Any] }
        let multipart = Multipart(json: try JSONSerialization.data(withJSONObject: body), files: files)
        _ = try await request("POST", "/channels/\(channelID)/messages", raw: (data: multipart.body, contentType: multipart.contentType))
    }

    /// Edits one of our messages: new text (nil leaves it), keeping only the attachments listed (the rest are
    /// deleted from Discord).
    public func editMessage(_ messageID: Snowflake, in channelID: Snowflake, content: String?,
                            keepingAttachments attachmentIDs: [Snowflake]) async throws {
        var body: [String: Any] = ["attachments": attachmentIDs.map { ["id": $0] }]
        if let content { body["content"] = content }
        _ = try await request("PATCH", "/channels/\(channelID)/messages/\(messageID)", body: body)
    }

    public func deleteMessage(_ messageID: Snowflake, in channelID: Snowflake) async throws {
        _ = try await request("DELETE", "/channels/\(channelID)/messages/\(messageID)")
    }

    /// Fresh links for attachments whose signed links have expired (Discord's links last about a day).
    public func refreshAttachmentURLs(_ urls: [String]) async throws -> [String: String] {
        struct Response: Decodable {
            struct Pair: Decodable { let original: String; let refreshed: String }
            let refreshedUrls: [Pair]
        }
        let data = try await request("POST", "/attachments/refresh-urls", body: ["attachment_urls": urls])
        let pairs = try decoder.decode(Response.self, from: data).refreshedUrls
        return Dictionary(pairs.map { ($0.original, $0.refreshed) }, uniquingKeysWith: { first, _ in first })
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

    // MARK: - Data Discord collects

    /// Turns off every data-collection and marketing setting Discord offers on the account: the same switches as
    /// the official app's Settings → Data & Privacy, Privacy & Safety and Notifications → Emails.
    /// - Consents: "use data to improve Discord" (usage statistics) and "use data to personalise my experience".
    /// - Account settings: screen-reader tracking, detecting accounts on other platforms (Steam and the like),
    ///   showing the current game, contact sync, phone-number friend finding, and being found by phone or email.
    /// - Emails: recommendations and events, tips, and product announcements.
    public func limitDataCollection() async throws {
        _ = try await request("POST", "/users/@me/consent", body: ["grant": [String](), "revoke": ["usage_statistics", "personalization"]])
        _ = try await request("PATCH", "/users/@me/settings", body: [
            "allow_accessibility_detection": false,
            "detect_platform_accounts": false,
            "show_current_game": false,
            "contact_sync_enabled": false,
            "native_phone_integration_enabled": false,
            "friend_discovery_flags": 0,
        ])
        _ = try await request("PATCH", "/users/@me/email-settings", body: ["settings": ["categories": [
            "recommendations_and_events": false,
            "tips": false,
            "updates_and_announcements": false,
        ]]])
    }

    /// The account's status as Discord stores it: online, idle, dnd or invisible. Anything else counts as online.
    public func accountStatus() async throws -> String {
        struct Body: Decodable { let status: String? }
        let data = try await request("GET", "/users/@me/settings")
        let status = (try? decoder.decode(Body.self, from: data))?.status
        return Self.knownAccountStatus(status) ?? "online"
    }

    /// Sets only the status. The body is that one field, so the rest of the account's settings stay as they are.
    public func setAccountStatus(_ status: String) async throws {
        guard let status = Self.knownAccountStatus(status) else { return }
        _ = try await request("PATCH", "/users/@me/settings", body: ["status": status])
    }

    private static func knownAccountStatus(_ status: String?) -> String? {
        switch status {
        case "online", "idle", "dnd", "invisible": return status
        default: return nil
        }
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

    private struct RateLimited: Decodable {
        let retryAfter: Double
        let global: Bool?
    }
    /// How many message sends this channel may still make, and when that count resets.
    private struct MessageSlot {
        var remaining: Int
        var resetAt: Date
    }
    private var messageSlots: [Snowflake: MessageSlot] = [:]
    private var globalResetAt: Date?
    private struct ErrorBody: Decodable {
        let message: String?
        let captchaKey: [String]?
    }

    private func request(_ method: String, _ path: String, query: [URLQueryItem] = [], body: [String: Any]? = nil,
                         raw: (data: Data, contentType: String)? = nil, attempt: Int = 0) async throws -> Data {
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
        } else if let raw {
            req.httpBody = raw.data
            req.setValue(raw.contentType, forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw RESTError.invalidResponse }
        if method == "POST" { rememberMessageSlot(http, path: path, body: data) }

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
            return try await request(method, path, query: query, body: body, raw: raw, attempt: attempt + 1)
        default:
            let body = try? decoder.decode(ErrorBody.self, from: data)
            if body?.captchaKey != nil { throw RESTError.captchaRequired }
            throw RESTError.http(status: http.statusCode, message: body?.message)
        }
    }

    /// Waits out a message bucket that is already empty, and a global limit, before another send.
    public func waitForMessageSlot(in channelID: Snowflake) async throws {
        let channelWait = messageSlots[channelID].map { slot -> TimeInterval in
            guard slot.remaining <= 0 else { return 0 }
            return slot.resetAt.timeIntervalSinceNow
        } ?? 0
        let globalWait = globalResetAt?.timeIntervalSinceNow ?? 0
        let wait = min(max(channelWait, globalWait, 0), 60)
        guard wait > 0 else { return }
        try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
    }

    /// Discord's remaining-budget headers for POST /channels/{id}/messages. Other routes are left alone.
    private func rememberMessageSlot(_ http: HTTPURLResponse, path: String, body: Data) {
        let parts = path.split(separator: "/").map(String.init)
        let now = Date()
        if parts.count == 3, parts[0] == "channels", parts[2] == "messages",
           let remaining = http.value(forHTTPHeaderField: "X-RateLimit-Remaining").flatMap(Int.init),
           let resetAfter = http.value(forHTTPHeaderField: "X-RateLimit-Reset-After").flatMap(Double.init) {
            messageSlots[parts[1]] = MessageSlot(remaining: remaining, resetAt: now.addingTimeInterval(resetAfter))
        }
        let limited = try? decoder.decode(RateLimited.self, from: body)
        if limited?.global == true, let retry = limited?.retryAfter {
            globalResetAt = now.addingTimeInterval(retry)
        }
    }
}

/// A file uploaded with a message.
public struct UploadFile: Sendable {
    public let name: String
    public let data: Data
    public let contentType: String

    public init(name: String, data: Data, contentType: String) {
        self.name = name
        self.data = data
        self.contentType = contentType
    }
}

/// A multipart/form-data body: the message as `payload_json`, then the files as `files[0]`, `files[1]`…
struct Multipart {
    let body: Data
    let contentType: String

    init(json: Data, files: [UploadFile], boundary: String = "duhcord-" + UUID().uuidString) {
        var body = Data()
        func line(_ text: String) { body.append(Data((text + "\r\n").utf8)) }
        line("--" + boundary)
        line("Content-Disposition: form-data; name=\"payload_json\"")
        line("Content-Type: application/json")
        line("")
        body.append(json)
        line("")
        for (index, file) in files.enumerated() {
            line("--" + boundary)
            line("Content-Disposition: form-data; name=\"files[\(index)]\"; filename=\"\(file.name)\"")
            line("Content-Type: " + file.contentType)
            line("")
            body.append(file.data)
            line("")
        }
        line("--" + boundary + "--")
        self.body = body
        contentType = "multipart/form-data; boundary=" + boundary
    }
}

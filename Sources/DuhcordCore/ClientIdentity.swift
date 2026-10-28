import Foundation

/// How the client describes itself to Discord, kept in one place so the gateway and REST calls agree.
///
/// These values mirror the official macOS desktop app. They may need bumping when Discord ships
/// new desktop builds.
public enum ClientIdentity {
    public static let apiBase = URL(string: "https://discord.com/api/v9")!
    /// Query for every gateway connection. zlib-stream compresses everything Discord sends us (see ZlibStream).
    static let gatewayQuery = "/?v=9&encoding=json&compress=zlib-stream"
    public static let gatewayURL = URL(string: "wss://gateway.discord.gg" + gatewayQuery)!

    static let clientVersion = "0.0.330"
    static let electronVersion = "32.2.7"
    static let chromeVersion = "128.0.6613.186"

    static let osVersion: String = {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }()

    /// Duhcord ships for Apple silicon only.
    static let arch = "arm64"

    static let locale = Locale.preferredLanguages.first ?? "en-US"

    // Built once: these go out with every request.
    public static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) "
            + "discord/\(clientVersion) Chrome/\(chromeVersion) Electron/\(electronVersion) Safari/537.36"

    /// The "properties" object sent in the gateway identify payload.
    static let properties: [String: Any] = [
        "os": "Mac OS X",
        "browser": "Discord Client",
        "release_channel": "stable",
        "client_version": clientVersion,
        "os_version": osVersion,
        "os_arch": arch,
        "system_locale": locale,
        "browser_user_agent": userAgent,
        "browser_version": electronVersion,
        "client_build_number": 0,
        "client_event_source": NSNull(),
    ]

    /// The same properties, base64-encoded for the X-Super-Properties REST header.
    static let superPropertiesHeader = ((try? JSONSerialization.data(withJSONObject: properties)) ?? Data()).base64EncodedString()
}

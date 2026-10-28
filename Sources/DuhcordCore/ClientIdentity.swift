import Foundation

/// How the client describes itself to Discord, kept in one place so the gateway and REST calls agree.
///
/// These mirror what the official macOS desktop app sends (field for field, as documented by the Discord
/// userdoccers' client properties reference), so Duhcord doesn't stand out as a third-party client.
///
/// Discord's build number and desktop version change constantly. Release builds read them from Info.plist,
/// where `scripts/discord-build-info.sh` puts the current values at build time; the constants below are only
/// a fallback for local builds and for a build where Discord couldn't be reached.
public enum ClientIdentity {
    public static let apiBase = URL(string: "https://discord.com/api/v9")!
    /// Query for every gateway connection. zlib-stream compresses everything Discord sends us (see ZlibStream).
    static let gatewayQuery = "/?v=9&encoding=json&compress=zlib-stream"
    public static let gatewayURL = URL(string: "wss://gateway.discord.gg" + gatewayQuery)!

    /// A value bundle.sh wrote into Info.plist; empty when Discord couldn't be reached at build time.
    private static func bundled(_ key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String, !value.isEmpty else { return nil }
        return value
    }

    /// The Discord desktop app version (e.g. "0.0.420").
    static let clientVersion = bundled("DuhcordDiscordClientVersion") ?? "0.0.420"
    /// Discord's web build number, which gates features and experiments on Discord's side.
    static let buildNumber = bundled("DuhcordDiscordBuildNumber").flatMap(Int.init) ?? 653_945
    static let electronVersion = "35.1.5"
    static let chromeVersion = "134.0.6998.179"

    /// The Darwin kernel version ("24.2.0"), which is what the desktop app reports as the OS version.
    static let osVersion: String = {
        var name = utsname()
        guard uname(&name) == 0 else { return "24.0.0" }
        return withUnsafeBytes(of: &name.release) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }()

    /// Duhcord ships for Apple silicon only.
    static let arch = "arm64"

    static let locale = Locale.preferredLanguages.first ?? "en-US"

    /// New for every launch, as in the desktop app.
    static let launchID = UUID().uuidString.lowercased()

    /// A random UUID with the bits that would report detected client mods cleared: none are present.
    static let launchSignature: String = {
        var uuid = UUID().uuid
        let mask: (UInt64, UInt64) = (0x0080_1010_0810_0800, 0x2081_0040_0100_0800)
        withUnsafeMutableBytes(of: &uuid) { bytes in
            for i in 0..<16 {
                let half = i < 8 ? mask.0 : mask.1
                let shift = UInt64(8 * (7 - i % 8))
                bytes[i] &= ~UInt8(truncatingIfNeeded: half >> shift)
            }
        }
        return UUID(uuid: uuid).uuidString.lowercased()
    }()

    // Built once: these go out with every request.
    public static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) "
            + "discord/\(clientVersion) Chrome/\(chromeVersion) Electron/\(electronVersion) Safari/537.36"

    /// The "properties" object sent in the gateway identify payload and, base64-encoded, with every request.
    static let properties: [String: Any] = [
        "os": "Mac OS X",
        "browser": "Discord Client",
        "release_channel": "stable",
        "client_version": clientVersion,
        "os_version": osVersion,
        "os_arch": arch,
        "app_arch": arch,
        "system_locale": locale,
        "has_client_mods": false,
        "client_launch_id": launchID,
        "launch_signature": launchSignature,
        "browser_user_agent": userAgent,
        "browser_version": electronVersion,
        "os_sdk_version": String(osVersion.prefix { $0 != "." }),
        "client_build_number": buildNumber,
        "native_build_number": NSNull(),
        "client_event_source": NSNull(),
        "client_heartbeat_session_id": UUID().uuidString.lowercased(),
    ]

    /// The same properties, base64-encoded for the X-Super-Properties REST header.
    static let superPropertiesHeader = ((try? JSONSerialization.data(withJSONObject: properties)) ?? Data()).base64EncodedString()
}

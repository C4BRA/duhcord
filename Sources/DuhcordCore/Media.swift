import Foundation

/// Where and how big to fetch an image. Pure logic, so it's unit tested.
public enum MediaRequest {
    /// Discord's re-encoding image proxies. Images are only ever fetched from these, so Duhcord decodes
    /// Discord's re-encoded copies, never an untouched upload, and third-party sites never see your IP.
    public static func isAllowedHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        if host == "media.discordapp.net" { return true }
        // images-ext-1.discordapp.net, images-ext-2…: Discord's proxy for images from other sites.
        return host.hasPrefix("images-ext-") && host.hasSuffix(".discordapp.net")
            && host.dropFirst("images-ext-".count).dropLast(".discordapp.net".count).allSatisfy(\.isNumber)
    }

    /// Hosts still images may come from: the proxies, plus Discord's CDN for avatars and server icons.
    /// The CDN is limited to those paths by `isAllowedImageURL`.
    public static func isAllowedImageHost(_ host: String?) -> Bool {
        isAllowedHost(host) || host?.lowercased() == "cdn.discordapp.com"
    }

    /// Profile pictures, banners, server icons, badges and game icons on Discord's CDN are Discord's own
    /// resized, re-encoded copies. Nothing else from the CDN is fetched as a still image.
    public static func isAllowedImageURL(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host?.lowercased() else { return false }
        if isAllowedHost(host) { return true }
        guard host == "cdn.discordapp.com" else { return false }
        let path = url.path
        if ["/avatars/", "/icons/", "/embed/avatars/", "/banners/", "/app-icons/", "/app-assets/", "/badge-icons/"]
            .contains(where: { path.hasPrefix($0) }) { return true }
        // Server profile pictures and banners: /guilds/{guild}/users/{user}/avatars|banners/{hash}
        let parts = path.split(separator: "/")
        return parts.count == 6 && parts[0] == "guilds" && parts[2] == "users" && ["avatars", "banners"].contains(parts[4])
    }

    /// Discord's CDN only serves power-of-two sizes from 16 to 4096.
    public static func cdnSize(forPixels pixels: Int) -> Int {
        var size = 16
        while size < pixels, size < 4096 { size *= 2 }
        return size
    }

    /// A user's profile picture at roughly `pixels` across, or Discord's default avatar if they have none.
    /// Animated avatars come back as a still WebP.
    public static func avatarURL(for user: User, pixels: Int) -> URL? {
        if let hash = user.avatar, !hash.isEmpty {
            return URL(string: "https://cdn.discordapp.com/avatars/\(user.id)/\(hash).webp?size=\(cdnSize(forPixels: pixels))")
        }
        let index: UInt64
        if let tag = user.discriminator, tag != "0", let number = UInt64(tag) {
            index = number % 5
        } else {
            index = (user.id.snowflakeValue >> 22) % 6
        }
        return URL(string: "https://cdn.discordapp.com/embed/avatars/\(index).png")
    }

    /// A server's icon at roughly `pixels` across, or nil if it has none.
    public static func iconURL(for guild: Guild, pixels: Int) -> URL? {
        guard let hash = guild.icon, !hash.isEmpty else { return nil }
        return URL(string: "https://cdn.discordapp.com/icons/\(guild.id)/\(hash).webp?size=\(cdnSize(forPixels: pixels))")
    }

    /// Video streams: the image proxies plus Discord's file CDN (some uploads are only served from there),
    /// over https only. Never a third-party host, and never with the token.
    public static func isAllowedVideoURL(_ url: URL) -> Bool {
        url.scheme == "https" && isAllowedImageHost(url.host)
    }

    /// The largest size that fits in the box without enlarging, keeping the aspect ratio.
    public static func fit(width: Int, height: Int, maxWidth: Double, maxHeight: Double) -> (width: Double, height: Double) {
        guard width > 0, height > 0 else { return (maxWidth, maxHeight) }
        let scale = min(1, maxWidth / Double(width), maxHeight / Double(height))
        return ((Double(width) * scale).rounded(), (Double(height) * scale).rounded())
    }

    /// The proxy URL asking for exactly the pixels we'll draw, as WebP (or, with `format: nil`, in the
    /// original format, which keeps GIFs animated). Existing query items (such as the signed expiry on
    /// attachment links) are kept. Returns nil for anything that isn't a Discord proxy URL.
    public static func url(proxy: String, pixelWidth: Int, pixelHeight: Int, format: String? = "webp") -> URL? {
        guard var components = URLComponents(string: proxy), components.scheme == "https",
              isAllowedHost(components.host), pixelWidth > 0, pixelHeight > 0 else { return nil }
        let ours: Set<String> = ["width", "height", "format", "quality"]
        var items = (components.queryItems ?? []).filter { !ours.contains($0.name) }
        if let format { items.append(URLQueryItem(name: "format", value: format)) }
        items.append(URLQueryItem(name: "width", value: String(pixelWidth)))
        items.append(URLQueryItem(name: "height", value: String(pixelHeight)))
        components.queryItems = items
        return components.url
    }
}

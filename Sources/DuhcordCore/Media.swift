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

    /// The largest size that fits in the box without enlarging, keeping the aspect ratio.
    public static func fit(width: Int, height: Int, maxWidth: Double, maxHeight: Double) -> (width: Double, height: Double) {
        guard width > 0, height > 0 else { return (maxWidth, maxHeight) }
        let scale = min(1, maxWidth / Double(width), maxHeight / Double(height))
        return ((Double(width) * scale).rounded(), (Double(height) * scale).rounded())
    }

    /// The proxy URL asking for exactly the pixels we'll draw, as WebP. Existing query items (such as the
    /// signed expiry on attachment links) are kept. Returns nil for anything that isn't a Discord proxy URL.
    public static func url(proxy: String, pixelWidth: Int, pixelHeight: Int) -> URL? {
        guard var components = URLComponents(string: proxy), components.scheme == "https",
              isAllowedHost(components.host), pixelWidth > 0, pixelHeight > 0 else { return nil }
        let ours: Set<String> = ["width", "height", "format", "quality"]
        var items = (components.queryItems ?? []).filter { !ours.contains($0.name) }
        items.append(URLQueryItem(name: "format", value: "webp"))
        items.append(URLQueryItem(name: "width", value: String(pixelWidth)))
        items.append(URLQueryItem(name: "height", value: String(pixelHeight)))
        components.queryItems = items
        return components.url
    }
}

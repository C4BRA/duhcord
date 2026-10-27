import Foundation

/// Checks a link before it's opened, so Discord's common account-theft tricks get a warning or are refused.
public enum LinkGuard {
    public enum Verdict: Equatable {
        /// Nothing suspicious: open it.
        case open
        /// Ask first, showing these reasons.
        case warn([String])
        /// Never open, with the reason.
        case block(String)
    }

    /// Domains Discord itself uses. Subdomains count too.
    static let officialDomains: Set<String> = [
        "discord.com", "discord.gg", "discordapp.com", "discordapp.net", "discord.gift", "discord.new",
        "discord.media", "discord.co", "discord.dev", "discordstatus.com", "dis.gd",
    ]

    /// `shownText` is the text the link was displayed as, for masked links.
    public static func check(_ url: URL, shownText: String? = nil) -> Verdict {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host?.lowercased(), !host.isEmpty else {
            return .block("Duhcord only opens web links.")
        }

        var reasons: [String] = []

        if isOfficial(host) {
            let path = url.path.lowercased()
            // discord.com/ra/… is someone's QR login code as a link. Approving it logs *them* in as you.
            if path.hasPrefix("/ra/") {
                return .block("This is a Discord login link. Opening it and approving would log someone else into your account. It's a common scam, so Duhcord never opens these.")
            }
            if isOAuthAuthorize(path) {
                reasons.append(contentsOf: oauthReasons(url))
            }
        } else {
            if host.contains("xn--") {
                reasons.append("The address \(host) uses look-alike characters, a common way to fake real sites.")
            } else if looksLikeDiscord(host) {
                reasons.append("\(host) is not a Discord website, but its name imitates one. Fake Discord sites steal accounts.")
            }
            if url.user != nil || url.password != nil {
                reasons.append("The link hides its real destination (\(host)).")
            }
        }

        if let shownText, let shownHost = hostMentioned(in: shownText), !sameSite(shownHost, host) {
            reasons.append("The link says \(shownHost) but actually goes to \(host).")
        }

        return reasons.isEmpty ? .open : .warn(reasons)
    }

    // MARK: - OAuth

    static func isOAuthAuthorize(_ path: String) -> Bool {
        let parts = path.split(separator: "/")
        return Array(parts.suffix(2)) == ["oauth2", "authorize"]
    }

    /// Explains what an "Authorize" link would let the app do, in plain words.
    static func oauthReasons(_ url: URL) -> [String] {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }

        let scopes = Set((value("scope") ?? "").split(whereSeparator: { $0 == " " || $0 == "+" }).map { String($0).lowercased() })
        var reasons = ["This link asks you to authorize an app on your Discord account. Approving gives the app lasting access until you remove it under Settings → Authorized Apps."]

        let permissions = UInt64(value("permissions") ?? "") ?? 0
        if scopes.contains("bot") {
            if permissions & Permissions.administrator != 0 {
                reasons.append("It adds a bot with ADMINISTRATOR permission to a server you choose: full control of that server, including banning everyone and deleting every channel.")
            } else {
                reasons.append("It adds a bot to a server you choose, with the permissions listed on the page.")
            }
        }
        let explanations: [(String, String)] = [
            ("guilds.join", "join servers on your behalf"),
            ("gdm.join", "add you to group DMs"),
            ("messages.read", "read your messages"),
            ("dm_channels.read", "see your DMs"),
            ("dm_channels.messages.read", "read your DMs"),
            ("dm_channels.messages.write", "send DMs as you"),
            ("relationships.read", "see your friends list"),
            ("relationships.write", "change your friends list"),
            ("email", "see your email address"),
            ("connections", "see your linked accounts"),
            ("webhook.incoming", "post messages into a channel you pick"),
            ("activities.write", "change your status"),
            ("role_connections.write", "change your linked roles"),
        ]
        let granted = explanations.filter { scopes.contains($0.0) }.map(\.1)
            + (scopes.contains { $0.hasPrefix("rpc") } ? ["control your Discord app"] : [])
        if !granted.isEmpty {
            reasons.append("It would be able to: " + granted.joined(separator: ", ") + ".")
        }
        return reasons
    }

    // MARK: - Hosts

    static func isOfficial(_ host: String) -> Bool {
        officialDomains.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// Catches names like dlscord.com, discrod-nitro.gift or discord-app.ru.
    static func looksLikeDiscord(_ host: String) -> Bool {
        let labels = host.split(separator: ".").map { normalize(String($0)) }
        func close(_ word: String) -> Bool {
            // One typo for short names, two for longer ones, so "disco" isn't flagged but "discrod" is.
            let limit = word.count >= 7 ? 2 : 1
            return editDistance(word, "discord") <= limit || editDistance(word, "discordapp") <= limit
        }
        return labels.contains { label in
            label.contains("discord") || close(label) || label.split(separator: "-").contains { close(String($0)) }
        }
    }

    /// Folds common look-alike substitutions: 0→o, 1/l/!→i, 3→e, 5→s, rn→m.
    static func normalize(_ s: String) -> String {
        var out = ""
        for c in s.lowercased() {
            switch c {
            case "0": out.append("o")
            case "1", "l", "!", "|": out.append("i")
            case "3": out.append("e")
            case "5": out.append("s")
            default: out.append(c)
            }
        }
        return out.replacingOccurrences(of: "rn", with: "m")
    }

    static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        // Ignore wildly different lengths early.
        if abs(a.count - b.count) > 3 { return 99 }
        var prev = Array(0...b.count)
        var cur = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            cur[0] = i
            for j in 1...b.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            swap(&prev, &cur)
        }
        return prev[b.count]
    }

    /// If the shown text of a masked link looks like an address, the host it names.
    static func hostMentioned(in text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
        let candidate = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard !trimmed.contains(" "), trimmed.contains("."),
              let host = URL(string: candidate)?.host, host.contains("."),
              let tld = host.split(separator: ".").last, tld.count >= 2, tld.allSatisfy(\.isLetter) else { return nil }
        return host
    }

    static func sameSite(_ a: String, _ b: String) -> Bool {
        func strip(_ h: String) -> String { h.hasPrefix("www.") ? String(h.dropFirst(4)) : h }
        let a = strip(a), b = strip(b)
        return a == b || a.hasSuffix("." + b) || b.hasSuffix("." + a)
    }
}

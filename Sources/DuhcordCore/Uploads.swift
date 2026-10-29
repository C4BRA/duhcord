import Foundation

/// How much one message's files may add up to: Discord's limit for the account's Nitro tier, but never more than
/// Duhcord's own cap, since it holds a message's files in memory while sending them.
public enum UploadLimit {
    /// Duhcord's cap per message, whatever the account allows.
    public static let duhcordCap = 100 * 1024 * 1024
    /// What a multipart request adds around the files.
    static let overhead = 64 * 1024

    /// Discord's per-message limit for `premiumType` (0 or nil: no Nitro, 1: Nitro Classic, 2: Nitro, 3: Nitro Basic).
    public static func discordLimit(premiumType: Int?) -> Int {
        switch premiumType ?? 0 {
        case 2: return 500 * 1024 * 1024
        case 1, 3: return 50 * 1024 * 1024
        default: return 10 * 1024 * 1024
        }
    }

    /// What a message's files may add up to, leaving room for the rest of the request.
    public static func bytes(premiumType: Int?) -> Int {
        min(discordLimit(premiumType: premiumType), duhcordCap) - overhead
    }
}

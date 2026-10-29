import Foundation
import DuhcordCore

/// The accounts saved on this Mac, for switching between them (up to five, as in Discord's own app).
///
/// Tokens and the account list (ID, name, picture, which one was last used) live in the one login-keychain
/// item Keychain keeps, so nothing about the accounts is written anywhere else. Only one account is
/// connected at a time.
@MainActor
enum AccountStore {
    static let maxAccounts = 5

    struct Account: Codable, Equatable {
        let id: Snowflake
        var username: String
        var displayName: String
        var avatar: String?
        var discriminator: String?
        /// Discord's data collection settings were turned off for this account (see RESTClient.limitDataCollection).
        var dataLimited: Bool?

        var user: User {
            User(id: id, username: username, globalName: displayName, avatar: avatar, discriminator: discriminator)
        }
    }

    private struct Saved: Codable {
        var accounts: [Account] = []
        var current: Snowflake?
    }

    private static let tokenService = Keychain.tokenService
    private static let listService = Keychain.accountListService
    private static let listAccount = Keychain.accountListAccount
    /// Where builds before account switching kept their one token.
    private static let legacyAccount = Keychain.legacyTokenAccount

    /// Read from the keychain once, then kept in memory; menus ask for it every time they're checked.
    private static var cached: Saved?
    /// The password dialog was cancelled. Stay empty for this launch rather than writing that over the vault.
    private static var unavailable = false

    private static var saved: Saved {
        get {
            if unavailable { return Saved() }
            if let cached { return cached }
            switch Keychain.read(service: listService, account: listAccount) {
            case .value(let data):
                let loaded = (try? JSONDecoder().decode(Saved.self, from: data)) ?? Saved()
                cached = loaded
                // The account on screen first, so cancelling a later prompt still leaves this launch a token.
                var ids = loaded.accounts.map(\.id)
                if let current = loaded.current, let index = ids.firstIndex(of: current) {
                    ids.remove(at: index)
                    ids.insert(current, at: 0)
                }
                Keychain.foldLegacyAccounts(ids)
                return loaded
            case .missing:
                let loaded = Saved()
                cached = loaded
                Keychain.foldLegacyAccounts([])
                return loaded
            case .denied:
                unavailable = true
                return Saved()
            }
        }
        set {
            if unavailable { return }
            cached = newValue
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            Keychain.setData(data, service: listService, account: listAccount)
        }
    }

    static var accounts: [Account] { saved.accounts }
    static var currentID: Snowflake? { saved.current }

    static func token(for id: Snowflake) -> String? {
        Keychain.data(service: tokenService, account: id).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// The token to start with: the last account used, or a token saved by an older build.
    static func launchToken() -> String? {
        if let id = saved.current, let token = token(for: id) { return token }
        if let first = saved.accounts.first(where: { token(for: $0.id) != nil }) { return token(for: first.id) }
        return Keychain.data(service: tokenService, account: legacyAccount).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// Records the account a token belongs to once Discord has said who it is, and makes it current.
    /// Returns the token it replaced for that account, if it was a different one (to be revoked).
    @discardableResult
    static func remember(_ user: User, token newToken: String) -> String? {
        let previous = token(for: user.id)
        Keychain.setData(Data(newToken.utf8), service: tokenService, account: user.id)
        // The old single-token item is now saved under its account.
        Keychain.delete(service: tokenService, account: legacyAccount)
        var list = saved
        var account = Account(id: user.id, username: user.username, displayName: user.displayName,
                              avatar: user.avatar, discriminator: user.discriminator)
        if let index = list.accounts.firstIndex(where: { $0.id == user.id }) {
            account.dataLimited = list.accounts[index].dataLimited
            list.accounts[index] = account
        } else {
            list.accounts.append(account)
        }
        list.current = user.id
        saved = list
        return previous == newToken ? nil : previous
    }

    /// Forgets an account: its token and its place in the list.
    static func remove(_ id: Snowflake) {
        Keychain.delete(service: tokenService, account: id)
        var list = saved
        list.accounts.removeAll { $0.id == id }
        if list.current == id { list.current = list.accounts.first?.id }
        saved = list
    }

    static var isFull: Bool { saved.accounts.count >= maxAccounts }

    static func setDataLimited(_ id: Snowflake, _ limited: Bool) {
        var list = saved
        guard let index = list.accounts.firstIndex(where: { $0.id == id }) else { return }
        list.accounts[index].dataLimited = limited
        saved = list
    }
}

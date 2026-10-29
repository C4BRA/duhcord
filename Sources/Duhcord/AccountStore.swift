import Foundation
import DuhcordCore

/// The accounts saved on this Mac, for switching between them (up to five, as in Discord's own app).
///
/// Each account's token is its own login-keychain item, named by the account's ID. The list itself (ID, name,
/// picture, which one was last used) is one more keychain item, so nothing about the accounts is written
/// anywhere else. Only one account is connected at a time.
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

    private static let tokenService = "com.duhcord.token"
    private static let listService = "com.duhcord.accounts"
    private static let listAccount = "list"
    /// Where builds before account switching kept their one token.
    private static let legacyAccount = "default"

    /// Read from the keychain once, then kept in memory; menus ask for it every time they're checked.
    private static var cached: Saved?

    private static var saved: Saved {
        get {
            if let cached { return cached }
            let loaded = Keychain.data(service: listService, account: listAccount)
                .flatMap { try? JSONDecoder().decode(Saved.self, from: $0) } ?? Saved()
            cached = loaded
            return loaded
        }
        set {
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

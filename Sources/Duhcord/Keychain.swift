import Foundation
import LocalAuthentication
import Security

/// Login-keychain storage for Discord tokens, the account list, and private-messaging keys.
///
/// macOS binds each login-keychain item to the code hash of the build allowed to read it. Duhcord's
/// signing certificate has no Apple Team ID, so that hash changes on every update and macOS asks for
/// the login password again. The password dialog is per item, which is why an update used to ask once
/// for the account list, once for each token, and once for each private-messaging key.
///
/// Everything now lives in one item (`com.duhcord.secrets`). An update asks once. The first launch
/// after a build that stored the secrets separately still has to approve each of those old items;
/// they are copied into the single item and then deleted. Duhcord then re-saves that item so this
/// build owns it, and later launches of the same build stay quiet until the next update.
///
/// Touch ID cannot take the place of this dialog. Biometry is enforced by the data-protection
/// keychain, which macOS only opens for a signature that carries a keychain access group. That
/// entitlement requires an Apple Team ID: without one, creating the item fails, and signing the
/// entitlement in makes macOS kill the process at launch. The dialog that remains is the login
/// keychain's own password dialog.
@MainActor
enum Keychain {
    static let tokenService = "com.duhcord.token"
    static let accountListService = "com.duhcord.accounts"
    static let accountListAccount = "list"
    /// Where builds before account switching kept their one token.
    static let legacyTokenAccount = "default"
    static let privateKeyService = "com.duhcord.private-key"
    static let privateDirectoryService = "com.duhcord.private-directory"

    enum Read {
        case value(Data)
        case missing
        case denied
    }

    /// Copies still-separate login tokens for these accounts into the one item. Private-messaging
    /// keys are copied when that account is next used, so this launch doesn't ask for keys that
    /// wouldn't have been read. Stops if a prompt is cancelled, so the same launch doesn't ask again.
    static func foldLegacyAccounts(_ ids: [String]) {
        for account in ids + [legacyTokenAccount] {
            if case .denied = read(service: tokenService, account: account) { break }
        }
    }

    static func read(service: String, account: String) -> Read {
        guard prepare() else { return .denied }
        let key = entryKey(service: service, account: account)
        if deniedKeys.contains(key) { return .denied }
        if let hit = cache?.entries[key] {
            // A previous launch copied this into the vault and couldn't delete the old item.
            _ = deleteItem(service: service, account: account, allowPrompt: false)
            return .value(hit)
        }
        switch readItem(service: service, account: account, allowPrompt: true) {
        case .value(let data):
            guard var vault = cache else { return .denied }
            vault.entries[key] = data
            cache = vault
            if persist() {
                _ = deleteItem(service: service, account: account, allowPrompt: true)
            }
            return .value(data)
        case .missing:
            return .missing
        case .locked, .denied:
            deniedKeys.insert(key)
            return .denied
        }
    }

    static func data(service: String, account: String) -> Data? {
        if case .value(let data) = read(service: service, account: account) { return data }
        return nil
    }

    @discardableResult
    static func setData(_ data: Data, service: String, account: String) -> Bool {
        guard prepare() else { return false }
        guard var vault = cache else { return false }
        let key = entryKey(service: service, account: account)
        vault.entries[key] = data
        cache = vault
        deniedKeys.remove(key)
        guard persist() else { return false }
        _ = deleteItem(service: service, account: account, allowPrompt: false)
        return true
    }

    static func delete(service: String, account: String) {
        if prepare(), var vault = cache {
            vault.entries.removeValue(forKey: entryKey(service: service, account: account))
            cache = vault
            _ = persist()
        }
        _ = deleteItem(service: service, account: account, allowPrompt: true)
    }

    // MARK: - One item

    private struct Vault: Codable {
        var generation: UInt64 = 0
        var entries: [String: Data] = [:]
    }

    /// Shown in the password dialog. The pending service is only the crash-safe copy made while
    /// replacing the item; it is deleted once the new build owns the main one.
    private static let vaultService = "com.duhcord.secrets"
    private static let pendingService = "com.duhcord.secrets.pending"
    private static let vaultAccount = "Duhcord"

    private static var cache: Vault?
    private static var slot = vaultService
    private static var failed = false
    private static var deniedKeys: Set<String> = []

    private enum Item {
        case value(Data)
        case missing
        /// The item is there, and this build hasn't been approved to read it.
        case locked
        case denied
    }

    private static func entryKey(service: String, account: String) -> String {
        service + "\u{1e}" + account
    }

    /// Loads the vault into `cache`. False when the user cancelled the password dialog or the item
    /// is unreadable: callers must not write an empty vault over it.
    private static func prepare() -> Bool {
        if failed { return false }
        if cache != nil { return true }
        switch unlockStore() {
        case .ready:
            return cache != nil
        case .denied:
            failed = true
            cache = nil
            return false
        }
    }

    private enum Unlock {
        case ready
        case denied
    }

    /// Silent reads first, so a build that already owns the item never shows a dialog. When both
    /// copies exist, the newer generation wins; the pending copy is the newer one whenever a
    /// takeover couldn't delete the previous item.
    private static func unlockStore() -> Unlock {
        let main = readItem(service: vaultService, account: vaultAccount, allowPrompt: false)
        let pending = readItem(service: pendingService, account: vaultAccount, allowPrompt: false)
        switch (main, pending) {
        case (.value(let mainData), .value(let pendingData)):
            let pendingWins = generation(of: pendingData) > generation(of: mainData)
            let data = pendingWins ? pendingData : mainData
            slot = pendingWins ? pendingService : vaultService
            _ = deleteItem(service: pendingWins ? vaultService : pendingService, account: vaultAccount, allowPrompt: false)
            if pendingWins { movePendingToMain(data) }
            return adopt(data)
        case (.value(let data), _):
            slot = vaultService
            _ = deleteItem(service: pendingService, account: vaultAccount, allowPrompt: false)
            return adopt(data)
        case (_, .value(let data)):
            slot = pendingService
            movePendingToMain(data)
            return adopt(data)
        case (.locked, _), (_, .locked):
            // The pending copy is the one written last when both survived. Approve that one only,
            // so a stale main item doesn't add a second password dialog.
            if case .locked = pending {
                return prompt(service: pendingService)
            }
            return prompt(service: vaultService)
        case (.missing, .missing):
            cache = Vault()
            slot = vaultService
            return .ready
        default:
            failed = true
            return .denied
        }
    }

    private static func prompt(service: String) -> Unlock {
        switch readItem(service: service, account: vaultAccount, allowPrompt: true) {
        case .value(let data):
            claim(data, readFrom: service)
            return adopt(data)
        case .missing:
            cache = Vault()
            slot = vaultService
            return .ready
        case .locked, .denied:
            return .denied
        }
    }

    /// Re-saves the vault so this build is the item's owner. A new copy is written before the old
    /// one is removed, so a crash can't drop the secrets. Deletes are silent, so approving the read
    /// doesn't turn into a second password dialog.
    private static func claim(_ data: Data, readFrom service: String) {
        let other = service == vaultService ? pendingService : vaultService
        // A stale item under the other name is left alone: deleting the copy just read, before a
        // new one exists, could drop the secrets. This process was approved to update `service`.
        guard writeOwnedCopy(to: other, data: data) else {
            slot = service
            return
        }
        slot = other
        if deleteItem(service: service, account: vaultAccount, allowPrompt: false),
           writeItem(service: service, account: vaultAccount, data: data) {
            _ = deleteItem(service: other, account: vaultAccount, allowPrompt: false)
            slot = service
        }
    }

    /// Creates `service` as an item this build owns. Fails when a previous item is still there and
    /// can't be removed without a password dialog.
    private static func writeOwnedCopy(to service: String, data: Data) -> Bool {
        if case .missing = readItem(service: service, account: vaultAccount, allowPrompt: false) {
            return writeItem(service: service, account: vaultAccount, data: data)
        }
        guard deleteItem(service: service, account: vaultAccount, allowPrompt: false) else { return false }
        return writeItem(service: service, account: vaultAccount, data: data)
    }

    /// The pending item is this build's copy. Put it back under the main service when the old item
    /// can be removed without another password dialog.
    private static func movePendingToMain(_ data: Data) {
        guard deleteItem(service: vaultService, account: vaultAccount, allowPrompt: false),
              writeItem(service: vaultService, account: vaultAccount, data: data) else { return }
        _ = deleteItem(service: pendingService, account: vaultAccount, allowPrompt: false)
        slot = vaultService
    }

    private static func adopt(_ data: Data) -> Unlock {
        guard let vault = try? JSONDecoder().decode(Vault.self, from: data) else { return .denied }
        cache = vault
        return .ready
    }

    private static func generation(of data: Data) -> UInt64 {
        (try? JSONDecoder().decode(Vault.self, from: data))?.generation ?? 0
    }

    @discardableResult
    private static func persist() -> Bool {
        guard var vault = cache, let slotData = encoded(&vault) else { return false }
        guard writeItem(service: slot, account: vaultAccount, data: slotData) else { return false }
        cache = vault
        return true
    }

    private static func encoded(_ vault: inout Vault) -> Data? {
        vault.generation += 1
        return try? JSONEncoder().encode(vault)
    }

    private static func query(service: String, account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    private static func readItem(service: String, account: String, allowPrompt: Bool) -> Item {
        var query = query(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        if !allowPrompt {
            let context = LAContext()
            context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext as String] = context
        }
        var result: AnyObject?
        switch SecItemCopyMatching(query as CFDictionary, &result) {
        case errSecSuccess:
            return .value((result as? Data) ?? Data())
        case errSecItemNotFound:
            return .missing
        case errSecUserCanceled:
            return .denied
        case errSecInteractionNotAllowed, errSecAuthFailed:
            return allowPrompt ? .denied : .locked
        default:
            return allowPrompt ? .denied : .locked
        }
    }

    @discardableResult
    private static func writeItem(service: String, account: String, data: Data) -> Bool {
        var add = query(service: service, account: account)
        add[kSecValueData as String] = data
        add[kSecAttrLabel as String] = "Duhcord"
        add[kSecAttrDescription as String] = "Saved accounts and private messages"
        let status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let update = [kSecValueData as String: data] as CFDictionary
            return SecItemUpdate(query(service: service, account: account) as CFDictionary, update) == errSecSuccess
        }
        return status == errSecSuccess
    }

    @discardableResult
    private static func deleteItem(service: String, account: String, allowPrompt: Bool) -> Bool {
        var query = query(service: service, account: account)
        if !allowPrompt {
            let context = LAContext()
            context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext as String] = context
        }
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}

import Foundation
import Security

/// Login-keychain items: the Discord tokens and account list (AccountStore) and the private messaging keys.
/// They never touch disk anywhere else. (Accessibility classes only apply to the data-protection keychain, which
/// needs a Team ID; login keychain items are instead limited to apps signed like Duhcord.)
enum Keychain {
    private static func query(service: String, account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    static func data(service: String, account: String) -> Data? {
        var q = query(service: service, account: account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    static func delete(service: String, account: String) {
        SecItemDelete(query(service: service, account: account) as CFDictionary)
    }

    @discardableResult
    static func setData(_ data: Data, service: String, account: String) -> Bool {
        var q = query(service: service, account: account)
        q[kSecValueData as String] = data
        let status = SecItemAdd(q as CFDictionary, nil)
        if status == errSecDuplicateItem {
            return SecItemUpdate(query(service: service, account: account) as CFDictionary,
                                 [kSecValueData as String: data] as CFDictionary) == errSecSuccess
        }
        return status == errSecSuccess
    }
}

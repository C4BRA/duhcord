import Foundation
import Security

/// Stores the Discord token, and the private messaging keys, in the login keychain. They never touch disk
/// anywhere else.
enum Keychain {
    private static let service = "com.duhcord.token"
    private static let account = "default"

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    static func loadToken() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func saveToken(_ token: String) -> Bool {
        // Add, or update in place if one exists, so a failed save never leaves the user with no token.
        // (Accessibility classes only apply to the data-protection keychain, which needs a Team ID; the login
        // keychain item is instead limited to apps signed like Duhcord.)
        var query = baseQuery
        query[kSecValueData as String] = Data(token.utf8)
        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem {
            return SecItemUpdate(baseQuery as CFDictionary, [kSecValueData as String: Data(token.utf8)] as CFDictionary) == errSecSuccess
        }
        return status == errSecSuccess
    }

    static func deleteToken() {
        SecItemDelete(baseQuery as CFDictionary)
    }

    // MARK: - Other items (private messaging keys)

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

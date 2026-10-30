import Foundation
import Security

/// API keys, stored in the login keychain (never in UserDefaults or files).
enum Keychain {
    private static let service = "app.easyimg.viewer.api-key"
    /// Avoids asking the keychain (and possibly the user) on every request.
    private static var cache: [String: String] = [:]

    static func apiKey(for account: String) -> String? {
        if let cached = cache[account] { return cached.isEmpty ? nil : cached }
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let key = SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess
            ? (result as? Data).flatMap { String(data: $0, encoding: .utf8) }
            : nil
        cache[account] = key ?? ""
        return key
    }

    /// Saves `key`, or deletes it when empty.
    static func setAPIKey(_ key: String, for account: String) {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        SecItemDelete(query as CFDictionary)
        cache[account] = key
        guard !key.isEmpty else { return }
        var item = query
        item[kSecValueData] = Data(key.utf8)
        item[kSecAttrLabel] = "Easy Img API key (\(account))"
        SecItemAdd(item as CFDictionary, nil)
    }
}

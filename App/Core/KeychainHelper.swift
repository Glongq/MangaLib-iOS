import Foundation
import Security

/// Тонкая обёртка над Keychain для хранения строковых секретов (токен сессии).
/// UserDefaults для этого не годится — Keychain это стандартное защищённое
/// хранилище на iOS, переживает удаление/переустановку в рамках того же
/// Apple ID (в отличие от UserDefaults, который просто plist-файл приложения).
struct KeychainHelper {
    let service: String

    private func baseQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    /// Сохраняет значение, перезаписывая предыдущее (если было).
    func save(_ value: String, for account: String) {
        let data = Data(value.utf8)
        var query = baseQuery(account)
        SecItemDelete(query as CFDictionary)
        query[kSecValueData as String] = data
        SecItemAdd(query as CFDictionary, nil)
    }

    func readString(_ account: String) -> String? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func delete(_ account: String) {
        SecItemDelete(baseQuery(account) as CFDictionary)
    }
}

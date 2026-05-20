import Foundation
import Security

/// 负责安全存储敏感数据（如 API Key）的工具类
final class KeychainHelper {
    static let shared = KeychainHelper()
    private init() {}

    func save(_ value: String, service: String, account: String) {
        guard let data = value.data(using: .utf8) else { return }

        // Deletion query should only match service and account attributes, not the data itself
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let deleteStatus = SecItemDelete(deleteQuery as CFDictionary)
        print("[KeychainHelper] SecItemDelete status for \(account): \(deleteStatus)")

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data
        ]

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        print("[KeychainHelper] SecItemAdd status for \(account): \(addStatus)")
    }

    func read(service: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: kCFBooleanTrue!,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var dataTypeRef: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &dataTypeRef)

        if status == errSecSuccess, let data = dataTypeRef as? Data {
            return String(data: data, encoding: .utf8)
        }
        return nil
    }

    func delete(service: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}

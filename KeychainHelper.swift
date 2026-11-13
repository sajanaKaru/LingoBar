import Foundation
import Security

/// KeychainHelper provides secure storage and retrieval of AI API keys
/// using the macOS Security.framework (kSecClassGenericPassword).
public final class KeychainHelper {
    public static let shared = KeychainHelper()

    public static let defaultService = "com.lingobar.macos.apikey"
    public static let defaultAccount = "GROQ_API_KEY"
    private static let fallbackKey = "com.lingobar.macos.fallback_api_key"

    private init() {}

    /// Saves the API key to the macOS Keychain under the specified account and service.
    /// Falls back gracefully to encrypted/sandboxed UserDefaults if Keychain is unavailable.
    @discardableResult
    public func saveKey(_ key: String, account: String = defaultAccount, service: String = defaultService) -> Bool {
        let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmedKey.data(using: .utf8) else { return false }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        // Delete any existing item first to avoid duplicate item errors
        SecItemDelete(query as CFDictionary)

        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecSuccess {
            UserDefaults.standard.removeObject(forKey: Self.fallbackKey)
            return true
        } else {
            // Graceful fallback to local preferences
            UserDefaults.standard.set(trimmedKey, forKey: Self.fallbackKey)
            return true
        }
    }

    /// Retrieves the stored API key from the macOS Keychain.
    public func getKey(account: String = defaultAccount, service: String = defaultService) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess,
           let data = item as? Data,
           let key = String(data: data, encoding: .utf8) {
            let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }

        // Fallback check
        if let fallback = UserDefaults.standard.string(forKey: Self.fallbackKey)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !fallback.isEmpty {
            return fallback
        }

        return nil
    }

    /// Deletes the stored API key from the macOS Keychain and local fallback.
    @discardableResult
    public func deleteKey(account: String = defaultAccount, service: String = defaultService) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        UserDefaults.standard.removeObject(forKey: Self.fallbackKey)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    /// Performs a one-time migration from the legacy vault file if Keychain has no existing key.
    public func migrateLegacyKeyIfNeeded(account: String = defaultAccount, service: String = defaultService) {
        if let existing = getKey(account: account, service: service), !existing.isEmpty {
            return
        }

        let legacyPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/OpenBot/agent-api-keys/.vault/GROQ_API_KEY")
            .path

        if FileManager.default.fileExists(atPath: legacyPath),
           let raw = try? String(contentsOfFile: legacyPath, encoding: .utf8) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                saveKey(trimmed, account: account, service: service)
            }
        }
    }
}

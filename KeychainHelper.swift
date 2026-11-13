import Foundation
import Security

public enum KeychainError: LocalizedError, Equatable {
    case invalidData
    case statusError(OSStatus)
    case itemNotFound
    case duplicateItem

    public var errorDescription: String? {
        switch self {
        case .invalidData:
            return "Failed to encode key data."
        case .statusError(let status):
            if let msg = SecCopyErrorMessageString(status, nil) as String? {
                return "Keychain error (\(status)): \(msg)"
            }
            return "Keychain error code: \(status)"
        case .itemNotFound:
            return "Item not found in Keychain."
        case .duplicateItem:
            return "Item already exists in Keychain."
        }
    }
}

/// KeychainHelper provides secure storage and retrieval of AI API keys
/// using the macOS Security.framework (kSecClassGenericPassword).
public final class KeychainHelper {
    public static let shared = KeychainHelper()

    public static let defaultService = "com.lingobar.macos.apikey"
    public static let defaultAccount = "GROQ_API_KEY"
    private static let migrationFlagKey = "com.lingobar.macos.hasMigratedLegacyKey"

    private init() {}

    /// Saves or updates the API key in the macOS Keychain under the specified account and service.
    /// Throws KeychainError on failure. Never stores keys in unencrypted plaintext.
    public func saveKey(_ key: String, account: String = defaultAccount, service: String = defaultService) throws {
        let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmedKey.data(using: .utf8) else {
            throw KeychainError.invalidData
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        // Check if item already exists
        let checkStatus = SecItemCopyMatching(query as CFDictionary, nil)
        if checkStatus == errSecSuccess {
            // Item exists: update with SecItemUpdate
            let updateAttributes: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
            ]
            let updateStatus = SecItemUpdate(query as CFDictionary, updateAttributes as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw KeychainError.statusError(updateStatus)
            }
        } else if checkStatus == errSecItemNotFound {
            // Item does not exist: add new item
            var attributes = query
            attributes[kSecValueData as String] = data
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

            let addStatus = SecItemAdd(attributes as CFDictionary, nil)
            if addStatus == errSecDuplicateItem {
                // In case of concurrent write, fallback to SecItemUpdate
                let updateAttributes: [String: Any] = [
                    kSecValueData as String: data,
                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
                ]
                let updateStatus = SecItemUpdate(query as CFDictionary, updateAttributes as CFDictionary)
                guard updateStatus == errSecSuccess else {
                    throw KeychainError.statusError(updateStatus)
                }
            } else if addStatus != errSecSuccess {
                throw KeychainError.statusError(addStatus)
            }
        } else {
            throw KeychainError.statusError(checkStatus)
        }
    }

    /// Retrieves the stored API key from the macOS Keychain.
    /// Returns nil if item does not exist, or throws KeychainError on system failure.
    public func getKey(account: String = defaultAccount, service: String = defaultService) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw KeychainError.statusError(status)
        }
        guard let data = item as? Data, let key = String(data: data, encoding: .utf8) else {
            throw KeychainError.invalidData
        }

        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Deletes the stored API key from the macOS Keychain.
    /// Throws KeychainError on system failure (absent item is treated as success).
    public func deleteKey(account: String = defaultAccount, service: String = defaultService) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            throw KeychainError.statusError(status)
        }
    }

    /// Performs a one-time migration from the legacy vault file if Keychain has no existing key.
    /// A persistent boolean flag in UserDefaults ensures the legacy key is not re-imported if deleted.
    public func migrateLegacyKeyIfNeeded(account: String = defaultAccount, service: String = defaultService) {
        // If already migrated in a prior run, never re-import
        if UserDefaults.standard.bool(forKey: Self.migrationFlagKey) {
            return
        }

        // Mark flag so future runs skip re-importing
        UserDefaults.standard.set(true, forKey: Self.migrationFlagKey)

        // If Keychain already contains a key, do not overwrite
        if let existing = try? getKey(account: account, service: service), !existing.isEmpty {
            return
        }

        let legacyPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/OpenBot/agent-api-keys/.vault/GROQ_API_KEY")
            .path

        if FileManager.default.fileExists(atPath: legacyPath),
           let raw = try? String(contentsOfFile: legacyPath, encoding: .utf8) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                try? saveKey(trimmed, account: account, service: service)
            }
        }
    }
}

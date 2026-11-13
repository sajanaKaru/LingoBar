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

    // Versioned migration flag (V2 heals premature migration flag from prior build)
    private static let migrationFlagKey = "com.lingobar.macos.hasMigratedVaultV2"
    // Separate explicit deletion flag to respect intentional user key removal
    private static let explicitDeletionFlagKey = "com.lingobar.macos.hasExplicitlyDeletedKey"

    private init() {
        recoverFallbackKeysAndCleanup()
    }

    /// Safely recovers residual unencrypted UserDefaults keys into Keychain before purging them.
    /// If save to Keychain fails (e.g. locked Keychain), keys are retained for future recovery.
    private func recoverFallbackKeysAndCleanup() {
        let fallbackKeys = ["com.lingobar.macos.fallback_api_key", "GROQ_API_KEY"]
        var candidateSecret: String?

        for key in fallbackKeys {
            if let val = UserDefaults.standard.string(forKey: key)?.trimmingCharacters(in: .whitespacesAndNewlines), !val.isEmpty {
                candidateSecret = val
                break
            }
        }

        if let secret = candidateSecret {
            if let existing = try? getKey(), !existing.isEmpty {
                // Keychain already has a valid key; safely purge unencrypted storage
                for key in fallbackKeys {
                    UserDefaults.standard.removeObject(forKey: key)
                }
            } else {
                // Recover into Keychain first
                do {
                    try saveKey(secret)
                    // Successfully recovered; now purge unencrypted storage
                    for key in fallbackKeys {
                        UserDefaults.standard.removeObject(forKey: key)
                    }
                } catch {
                    // Retain fallback keys in UserDefaults if Keychain save failed, enabling future retry
                }
            }
        } else {
            for key in fallbackKeys {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
    }

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

        // Saving a valid key clears any prior explicit deletion flag
        UserDefaults.standard.removeObject(forKey: Self.explicitDeletionFlagKey)
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
    /// Sets explicit deletion flag to ensure intentional removal is preserved across launches.
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
        // Explicit deletion flag preserves intentional deletion so legacy key is not re-imported
        UserDefaults.standard.set(true, forKey: Self.explicitDeletionFlagKey)
    }

    /// Performs a one-time migration from the legacy vault file if Keychain has no existing key.
    /// Uses versioned V2 flag to heal prematurely flagged migrations, while respecting explicit user deletions.
    public func migrateLegacyKeyIfNeeded(account: String = defaultAccount, service: String = defaultService) throws {
        // 1. If user explicitly deleted their key, do not re-import
        if UserDefaults.standard.bool(forKey: Self.explicitDeletionFlagKey) {
            return
        }

        // 2. If already migrated with V2 flag, do not re-run
        if UserDefaults.standard.bool(forKey: Self.migrationFlagKey) {
            return
        }

        // 3. If Keychain already contains a valid key, mark flag and return
        if let existing = try getKey(account: account, service: service), !existing.isEmpty {
            UserDefaults.standard.set(true, forKey: Self.migrationFlagKey)
            return
        }

        let legacyPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/OpenBot/agent-api-keys/.vault/GROQ_API_KEY")
            .path

        if FileManager.default.fileExists(atPath: legacyPath) {
            let raw = try String(contentsOfFile: legacyPath, encoding: .utf8)
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                // Save key to Keychain. Flag is ONLY set after saveKey succeeds!
                try saveKey(trimmed, account: account, service: service)
                UserDefaults.standard.set(true, forKey: Self.migrationFlagKey)
            } else {
                UserDefaults.standard.set(true, forKey: Self.migrationFlagKey)
            }
        } else {
            // No legacy file exists
            UserDefaults.standard.set(true, forKey: Self.migrationFlagKey)
        }
    }
}

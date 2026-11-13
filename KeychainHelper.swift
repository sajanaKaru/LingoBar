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
    public static let fallbackAccount = "GROQ_API_KEY_FALLBACK"

    public static var legacyVaultPath: String {
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/OpenBot/agent-api-keys/.vault/GROQ_API_KEY")
            .path
    }

    // Migration flags
    private static let legacyMigrationFlagKey = "com.lingobar.macos.hasMigratedLegacyKey"
    private static let migrationV2FlagKey = "com.lingobar.macos.hasMigratedVaultV2"
    // Explicit deletion flag to respect intentional user key removal
    private static let explicitDeletionFlagKey = "com.lingobar.macos.hasExplicitlyDeletedKey"

    private init() {
        recoverFallbackKeysAndCleanup()
    }

    /// Safely recovers residual unencrypted UserDefaults keys into Keychain when absence is confirmed.
    /// If a conflict is detected, retains the fallback key so it can be surfaced in UI via pendingFallbackConflictKey.
    /// Propagates Keychain errors explicitly rather than misinterpreting errors as key absence.
    public func recoverFallbackKeys() throws {
        let fallbackKeys = ["com.lingobar.macos.fallback_api_key", "GROQ_API_KEY"]

        // 1. If user explicitly deleted their key, purge residual fallback keys immediately without recovery
        if UserDefaults.standard.bool(forKey: Self.explicitDeletionFlagKey) {
            for key in fallbackKeys {
                UserDefaults.standard.removeObject(forKey: key)
            }
            return
        }

        var candidateSecret: String?
        for key in fallbackKeys {
            if let val = UserDefaults.standard.string(forKey: key)?.trimmingCharacters(in: .whitespacesAndNewlines), !val.isEmpty {
                candidateSecret = val
                break
            }
        }

        guard let secret = candidateSecret else {
            // No candidate values present; clean up empty string keys
            for key in fallbackKeys {
                UserDefaults.standard.removeObject(forKey: key)
            }
            return
        }

        // Explicit Keychain read: do not mistake transient/locked Keychain errors for absence!
        let existingKey = try getKey(account: Self.defaultAccount)

        if let existing = existingKey, !existing.isEmpty {
            if existing == secret {
                // Key matches Keychain; safely purge redundant unencrypted fallback copy
                for key in fallbackKeys {
                    UserDefaults.standard.removeObject(forKey: key)
                }
            } else {
                // Conflict detected: primary key differs from candidate key.
                // Do not silently tuck it away or delete it. Retain it so pendingFallbackConflictKey surfaces it in UI.
            }
        } else {
            // Keychain absence is confirmed: recover into default account
            try saveKey(secret, account: Self.defaultAccount)
            for key in fallbackKeys {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
    }

    private func recoverFallbackKeysAndCleanup() {
        do {
            try recoverFallbackKeys()
        } catch {
            NSLog("KeychainHelper fallback recovery failed with error: %@", error.localizedDescription)
        }
    }

    /// Returns the conflicting fallback key if one exists in UserDefaults or fallbackAccount that differs from the primary key.
    public func getPendingFallbackConflictKey(account: String = defaultAccount, service: String = defaultService) throws -> String? {
        if UserDefaults.standard.bool(forKey: Self.explicitDeletionFlagKey) {
            return nil
        }
        let primaryKey = try getKey(account: account, service: service)
        guard let primary = primaryKey, !primary.isEmpty else {
            return nil // No conflict if primary key does not exist
        }

        let fallbackKeys = ["com.lingobar.macos.fallback_api_key", "GROQ_API_KEY"]
        for key in fallbackKeys {
            if let val = UserDefaults.standard.string(forKey: key)?.trimmingCharacters(in: .whitespacesAndNewlines), !val.isEmpty {
                if val != primary {
                    return val
                }
            }
        }

        // Also check if fallbackAccount has a stored key differing from primary
        if let fallbackInKeychain = try getKey(account: Self.fallbackAccount, service: service), !fallbackInKeychain.isEmpty {
            if fallbackInKeychain != primary {
                return fallbackInKeychain
            }
        }

        return nil
    }

    public var pendingFallbackConflictKey: String? {
        do {
            return try getPendingFallbackConflictKey()
        } catch {
            return nil
        }
    }

    /// Resolves the pending fallback conflict by either adopting it as the primary key or discarding it.
    public func resolveFallbackConflict(useFallbackKey: Bool, account: String = defaultAccount, service: String = defaultService) throws {
        if useFallbackKey {
            if let conflictKey = try getPendingFallbackConflictKey(account: account, service: service) {
                try saveKey(conflictKey, account: account, service: service)
            }
        }
        discardFallbackConflict(service: service)
    }

    /// Purges all residual fallback storage from UserDefaults and fallback Keychain account.
    public func discardFallbackConflict(service: String = defaultService) {
        let fallbackKeys = ["com.lingobar.macos.fallback_api_key", "GROQ_API_KEY"]
        for key in fallbackKeys {
            UserDefaults.standard.removeObject(forKey: key)
        }
        let fallbackQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: Self.fallbackAccount
        ]
        _ = SecItemDelete(fallbackQuery as CFDictionary)
    }

    /// Indicates whether a valid non-empty key exists in the legacy vault file.
    public var isLegacyVaultKeyAvailable: Bool {
        guard FileManager.default.fileExists(atPath: Self.legacyVaultPath) else {
            return false
        }
        guard let raw = try? String(contentsOfFile: Self.legacyVaultPath, encoding: .utf8) else {
            return false
        }
        return !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Explicitly imports the key from the legacy vault file into Keychain.
    @discardableResult
    public func importLegacyVaultKey(account: String = defaultAccount, service: String = defaultService) throws -> String {
        guard FileManager.default.fileExists(atPath: Self.legacyVaultPath) else {
            throw KeychainError.itemNotFound
        }
        let raw = try String(contentsOfFile: Self.legacyVaultPath, encoding: .utf8)
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw KeychainError.invalidData
        }
        try saveKey(trimmed, account: account, service: service)
        UserDefaults.standard.set(true, forKey: Self.migrationV2FlagKey)
        return trimmed
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
    /// Sets explicit deletion flag and purges any fallback keys from UserDefaults and Keychain.
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

        // Also clean up any fallback account if defaultAccount is being deleted
        if account == Self.defaultAccount {
            let fallbackQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: Self.fallbackAccount
            ]
            let fallbackStatus = SecItemDelete(fallbackQuery as CFDictionary)
            if fallbackStatus != errSecSuccess && fallbackStatus != errSecItemNotFound {
                throw KeychainError.statusError(fallbackStatus)
            }
        }

        // Explicit deletion marks intentional removal and purges unencrypted fallbacks
        UserDefaults.standard.set(true, forKey: Self.explicitDeletionFlagKey)
        UserDefaults.standard.removeObject(forKey: "com.lingobar.macos.fallback_api_key")
        UserDefaults.standard.removeObject(forKey: "GROQ_API_KEY")
    }

    /// Performs a one-time migration from the legacy vault file if Keychain has no existing key.
    /// If hasMigratedLegacyKey, hasExplicitlyDeletedKey, or migrationV2FlagKey is true,
    /// it does NOT automatically re-import (avoids guessing).
    /// Ambiguous states are resolved in SettingsView via explicit user action using importLegacyVaultKey().
    public func migrateLegacyKeyIfNeeded(account: String = defaultAccount, service: String = defaultService) throws {
        // 1. If user explicitly deleted their key, legacy migration was marked, or V2 migration was marked, do not auto re-import
        if UserDefaults.standard.bool(forKey: Self.explicitDeletionFlagKey) ||
           UserDefaults.standard.bool(forKey: Self.legacyMigrationFlagKey) ||
           UserDefaults.standard.bool(forKey: Self.migrationV2FlagKey) {
            return
        }

        // 2. Read Keychain explicitly: throws KeychainError on failure
        let existingKey = try getKey(account: account, service: service)

        // 3. If Keychain already contains a valid key, mark flag and return
        if let existing = existingKey, !existing.isEmpty {
            UserDefaults.standard.set(true, forKey: Self.migrationV2FlagKey)
            return
        }

        // 4. Initial clean migration from legacy vault file
        if FileManager.default.fileExists(atPath: Self.legacyVaultPath) {
            let raw = try String(contentsOfFile: Self.legacyVaultPath, encoding: .utf8)
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                try saveKey(trimmed, account: account, service: service)
            }
        }
        UserDefaults.standard.set(true, forKey: Self.migrationV2FlagKey)
    }
}

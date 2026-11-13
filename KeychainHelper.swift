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

public struct ConflictCandidate: Identifiable, Equatable {
    public let id: String
    public let key: String

    public init(id: String, key: String) {
        self.id = id
        self.key = key
    }

    public var maskedKey: String {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 8 else {
            return "••••••••"
        }
        return "\(trimmed.prefix(4))...\(trimmed.suffix(4))"
    }
}

/// KeychainHelper provides secure storage and retrieval of AI API keys
/// using the macOS Security.framework (kSecClassGenericPassword).
public final class KeychainHelper {
    public static let shared = KeychainHelper()

    public static let defaultService = "com.lingobar.macos.apikey"
    public static let defaultAccount = "GROQ_API_KEY"
    public static let fallbackAccount = "GROQ_API_KEY_FALLBACK"
    public static let fallbackAccountPrefix = "com.lingobar.macos.fallback."
    public static let maxFallbackSlots = 10
    public static let pendingRedundantCleanupKey = "com.lingobar.macos.hasPendingRedundantCleanup"

    public static func fallbackAccountName(index: Int) -> String {
        if index == 0 {
            return fallbackAccount
        }
        return "\(fallbackAccountPrefix)\(index)"
    }

    public static func getAllFallbackAccounts() -> [String] {
        var accounts = [fallbackAccount]
        for i in 1..<maxFallbackSlots {
            accounts.append(fallbackAccountName(index: i))
        }
        return accounts
    }

    public static var legacyVaultPath: String {
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/OpenBot/agent-api-keys/.vault/GROQ_API_KEY")
            .path
    }

    // Migration flags
    private static let legacyMigrationFlagKey = "com.lingobar.macos.hasMigratedLegacyKey"
    private static let migrationV2FlagKey = "com.lingobar.macos.hasMigratedVaultV2"
    // Explicit deletion flag to respect intentional user key removal
    static let explicitDeletionFlagKey = "com.lingobar.macos.hasExplicitlyDeletedKey"

    public private(set) var fallbackRecoveryWarning: String? = nil

    public init(service: String = defaultService) {
        recoverFallbackKeysAndCleanup(service: service)
    }

    /// Safely recovers residual unencrypted UserDefaults keys into Keychain when absence is confirmed.
    /// If conflicts are detected, stores them in indexed Keychain fallback accounts and purges UserDefaults.
    /// No secrets remain in plaintext UserDefaults.
    public func recoverFallbackKeys(service: String = defaultService) throws {
        let fallbackKeys = ["com.lingobar.macos.fallback_api_key", "GROQ_API_KEY"]

        // 1. If user explicitly deleted their key, purge residual fallback keys immediately without recovery
        if UserDefaults.standard.bool(forKey: Self.explicitDeletionFlagKey) {
            for key in fallbackKeys {
                UserDefaults.standard.removeObject(forKey: key)
            }
            var deletionFailedStatus: OSStatus? = nil
            for acc in Self.getAllFallbackAccounts() {
                let query: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: service,
                    kSecAttrAccount as String: acc
                ]
                let status = SecItemDelete(query as CFDictionary)
                if status != errSecSuccess && status != errSecItemNotFound {
                    deletionFailedStatus = status
                }
            }
            if let status = deletionFailedStatus {
                fallbackRecoveryWarning = "Keychain deletion error (\(status)). Cleanup will retry."
                return
            }
            fallbackRecoveryWarning = nil
            return
        }

        // Explicit Keychain read: do not mistake transient/locked Keychain errors for absence!
        var existingPrimary = try getKey(account: Self.defaultAccount, service: service)
        if existingPrimary?.isEmpty == true {
            existingPrimary = nil
        }

        var securedFallbacks: [(account: String, key: String)] = []
        for acc in Self.getAllFallbackAccounts() {
            if let val = try getKey(account: acc, service: service), !val.isEmpty {
                securedFallbacks.append((account: acc, key: val))
            }
        }

        for key in fallbackKeys {
            guard let raw = UserDefaults.standard.string(forKey: key),
                  let candidate = raw.trimmingCharacters(in: .whitespacesAndNewlines) as String?,
                  !candidate.isEmpty else {
                // Absent or empty value; cleanly purge key
                UserDefaults.standard.removeObject(forKey: key)
                continue
            }

            // If no primary key exists in Keychain, recover candidate into defaultAccount
            if existingPrimary == nil {
                do {
                    try saveKey(candidate, account: Self.defaultAccount, service: service)
                    UserDefaults.standard.removeObject(forKey: key)
                    existingPrimary = candidate
                    continue
                } catch {
                    fallbackRecoveryWarning = "Failed to store recovered key in Keychain: \(error.localizedDescription)"
                    throw error
                }
            }

            // Primary key exists. Check candidate against primary and already-secured fallback accounts:
            if candidate == existingPrimary || securedFallbacks.contains(where: { $0.key == candidate }) {
                UserDefaults.standard.removeObject(forKey: key)
                continue
            }

            // New distinct key: save into next available Keychain fallback account
            guard let nextAccount = Self.getAllFallbackAccounts().first(where: { acc in
                !securedFallbacks.contains(where: { $0.account == acc })
            }) else {
                // All fallback slots full, leave candidate in UserDefaults and surface warning
                fallbackRecoveryWarning = "Multiple conflicting keys found in local storage. Review in Settings."
                continue
            }

            do {
                try saveKey(candidate, account: nextAccount, service: service)
                UserDefaults.standard.removeObject(forKey: key)
                securedFallbacks.append((account: nextAccount, key: candidate))
            } catch {
                fallbackRecoveryWarning = "Failed to secure conflicting key in Keychain: \(error.localizedDescription)"
                throw error
            }
        }

        // Update warning based on secured fallbacks that differ from primary key
        let distinctConflicts = securedFallbacks.filter { $0.key != existingPrimary }
        if distinctConflicts.count > 1 {
            fallbackRecoveryWarning = "Multiple conflicting keys found in local storage. Review in Settings."
        } else if distinctConflicts.count == 1 {
            fallbackRecoveryWarning = "A conflicting key was found in local storage. Review in Settings."
        } else {
            fallbackRecoveryWarning = nil
        }
    }

    func recoverFallbackKeysAndCleanup(service: String = defaultService) {
        cleanupRedundantFallbacksIfNeeded(service: service)
        do {
            try recoverFallbackKeys(service: service)
        } catch {
            fallbackRecoveryWarning = "Storage recovery error: \(error.localizedDescription)"
            NSLog("KeychainHelper fallback recovery failed with error: %@", error.localizedDescription)
        }
    }

    /// Cleans up any redundant fallback Keychain items whose keys match the primary key.
    /// Retries if hasPendingRedundantCleanup was previously recorded.
    public func cleanupRedundantFallbacksIfNeeded(service: String = defaultService) {
        guard UserDefaults.standard.bool(forKey: Self.pendingRedundantCleanupKey) else {
            return
        }
        guard let primary = try? getKey(account: Self.defaultAccount, service: service), !primary.isEmpty else {
            return
        }

        var allCleaned = true
        for acc in Self.getAllFallbackAccounts() {
            if let val = try? getKey(account: acc, service: service), val == primary {
                let query: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: service,
                    kSecAttrAccount as String: acc
                ]
                let status = SecItemDelete(query as CFDictionary)
                if status != errSecSuccess && status != errSecItemNotFound {
                    allCleaned = false
                }
            }
        }
        if allCleaned {
            UserDefaults.standard.removeObject(forKey: Self.pendingRedundantCleanupKey)
        }
    }

    /// Returns all distinct pending conflict candidates stored in Keychain or UserDefaults.
    public func getPendingConflictCandidates(account: String = defaultAccount, service: String = defaultService) throws -> [ConflictCandidate] {
        cleanupRedundantFallbacksIfNeeded(service: service)
        if UserDefaults.standard.bool(forKey: Self.explicitDeletionFlagKey) {
            return []
        }
        let primaryKey = try getKey(account: account, service: service)
        guard let primary = primaryKey, !primary.isEmpty else {
            return []
        }

        var candidates: [ConflictCandidate] = []
        var seenKeys = Set<String>()
        seenKeys.insert(primary)

        // 1. Check all Keychain fallback accounts
        for acc in Self.getAllFallbackAccounts() {
            if let val = try getKey(account: acc, service: service), !val.isEmpty {
                if !seenKeys.contains(val) {
                    seenKeys.insert(val)
                    candidates.append(ConflictCandidate(id: acc, key: val))
                }
            }
        }

        // 2. Also check UserDefaults if any residual unmigrated keys exist
        let fallbackKeys = ["com.lingobar.macos.fallback_api_key", "GROQ_API_KEY"]
        for key in fallbackKeys {
            if let val = UserDefaults.standard.string(forKey: key)?.trimmingCharacters(in: .whitespacesAndNewlines), !val.isEmpty {
                if !seenKeys.contains(val) {
                    seenKeys.insert(val)
                    candidates.append(ConflictCandidate(id: key, key: val))
                }
            }
        }

        return candidates
    }

    public var pendingConflictCandidates: [ConflictCandidate] {
        do {
            return try getPendingConflictCandidates()
        } catch {
            return []
        }
    }

    /// Returns the first conflicting fallback key if one exists, for backward compatibility.
    public func getPendingFallbackConflictKey(account: String = defaultAccount, service: String = defaultService) throws -> String? {
        let candidates = try getPendingConflictCandidates(account: account, service: service)
        return candidates.first?.key
    }

    public var pendingFallbackConflictKey: String? {
        return pendingConflictCandidates.first?.key
    }

    /// Resolves the pending fallback conflict by either adopting it as the primary key or discarding it.
    public func resolveFallbackConflict(useFallbackKey: Bool, account: String = defaultAccount, service: String = defaultService) throws {
        if useFallbackKey {
            if let candidates = try? getPendingConflictCandidates(account: account, service: service), let first = candidates.first {
                try saveKey(first.key, account: account, service: service)
                do {
                    try discardConflictCandidate(id: first.id, service: service)
                    UserDefaults.standard.removeObject(forKey: Self.pendingRedundantCleanupKey)
                } catch {
                    UserDefaults.standard.set(true, forKey: Self.pendingRedundantCleanupKey)
                    throw error
                }
                return
            }
        }
        try discardFallbackConflict(service: service)
    }

    /// Discards a single conflict candidate by ID (Keychain account name or UserDefaults key).
    public func discardConflictCandidate(id: String, service: String = defaultService) throws {
        let fallbackKeys = ["com.lingobar.macos.fallback_api_key", "GROQ_API_KEY"]
        if fallbackKeys.contains(id) {
            UserDefaults.standard.removeObject(forKey: id)
        } else {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: id
            ]
            let status = SecItemDelete(query as CFDictionary)
            if status != errSecSuccess && status != errSecItemNotFound {
                throw KeychainError.statusError(status)
            }
        }

        // Immediate in-session migration retry: freeing a slot allows pending UserDefaults candidates to be secured
        try? recoverFallbackKeys(service: service)

        // Recompute warning based on remaining candidates
        if let remaining = try? getPendingConflictCandidates(service: service) {
            if remaining.count > 1 {
                fallbackRecoveryWarning = "Multiple conflicting keys found in local storage. Review in Settings."
            } else if remaining.count == 1 {
                fallbackRecoveryWarning = "A conflicting key was found in local storage. Review in Settings."
            } else {
                fallbackRecoveryWarning = nil
            }
        } else {
            fallbackRecoveryWarning = nil
        }
    }

    /// Purges all residual fallback storage from UserDefaults and all fallback Keychain accounts.
    public func discardFallbackConflict(service: String = defaultService) throws {
        let fallbackKeys = ["com.lingobar.macos.fallback_api_key", "GROQ_API_KEY"]
        for key in fallbackKeys {
            UserDefaults.standard.removeObject(forKey: key)
        }
        for acc in Self.getAllFallbackAccounts() {
            let fallbackQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: acc
            ]
            let status = SecItemDelete(fallbackQuery as CFDictionary)
            if status != errSecSuccess && status != errSecItemNotFound {
                throw KeychainError.statusError(status)
            }
        }
        fallbackRecoveryWarning = nil
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

    /// Reads the raw key string from the legacy vault file without saving it directly to Keychain.
    public func readLegacyVaultKey() throws -> String {
        guard FileManager.default.fileExists(atPath: Self.legacyVaultPath) else {
            throw KeychainError.itemNotFound
        }
        let raw = try String(contentsOfFile: Self.legacyVaultPath, encoding: .utf8)
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw KeychainError.invalidData
        }
        return trimmed
    }

    /// Explicitly imports the key from the legacy vault file into Keychain.
    @discardableResult
    public func importLegacyVaultKey(account: String = defaultAccount, service: String = defaultService) throws -> String {
        let trimmed = try readLegacyVaultKey()
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

        // When saving a primary key:
        // Only purge secondary/fallback account if explicitDeletionFlagKey is true (i.e. cleanup was pending from a prior user deletion).
        // If explicitDeletionFlagKey is false, leave fallbackAccount intact so an unresolved conflict is not destroyed.
        if account == Self.defaultAccount && UserDefaults.standard.bool(forKey: Self.explicitDeletionFlagKey) {
            for acc in Self.getAllFallbackAccounts() {
                let fallbackQuery: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: service,
                    kSecAttrAccount as String: acc
                ]
                let fallbackStatus = SecItemDelete(fallbackQuery as CFDictionary)
                if fallbackStatus != errSecSuccess && fallbackStatus != errSecItemNotFound {
                    throw KeychainError.statusError(fallbackStatus)
                }
            }
            UserDefaults.standard.removeObject(forKey: Self.explicitDeletionFlagKey)
        } else if account == Self.defaultAccount {
            UserDefaults.standard.removeObject(forKey: Self.explicitDeletionFlagKey)
        }
    }

    /// Retrieves the stored API key from the macOS Keychain.
    /// Returns nil if item does not exist or was explicitly deleted, or throws KeychainError on system failure.
    public func getKey(account: String = defaultAccount, service: String = defaultService) throws -> String? {
        if UserDefaults.standard.bool(forKey: Self.explicitDeletionFlagKey) {
            return nil
        }

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
    /// Persists deletion intent and purges plaintext fallbacks first to ensure safety against partial Keychain deletion failure.
    public func deleteKey(account: String = defaultAccount, service: String = defaultService) throws {
        // 1. Immediately record deletion intent and purge plaintext fallback keys
        // Persisted first so partial failure of Keychain calls can never resurrect an old key on restart.
        UserDefaults.standard.set(true, forKey: Self.explicitDeletionFlagKey)
        UserDefaults.standard.removeObject(forKey: "com.lingobar.macos.fallback_api_key")
        UserDefaults.standard.removeObject(forKey: "GROQ_API_KEY")

        // 2. Delete primary account from Keychain
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            throw KeychainError.statusError(status)
        }

        // 3. Delete secondary fallback accounts from Keychain
        if account == Self.defaultAccount {
            for acc in Self.getAllFallbackAccounts() {
                let fallbackQuery: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: service,
                    kSecAttrAccount as String: acc
                ]
                let fallbackStatus = SecItemDelete(fallbackQuery as CFDictionary)
                if fallbackStatus != errSecSuccess && fallbackStatus != errSecItemNotFound {
                    throw KeychainError.statusError(fallbackStatus)
                }
            }
        }
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

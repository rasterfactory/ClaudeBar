import Domain
import Foundation

/// The vault definition-driven providers read their keys from — ClaudeBar's credential
/// store, under `provider.<id>.<name>`. A definition names the key; the value
/// lives only here.
public struct ProviderVault: SecretVault, @unchecked Sendable {
    private let credentials: any CredentialRepository
    /// UserDefaults is thread-safe. Only the default login can read a legacy key.
    private let legacyStore: UserDefaults

    public init(credentials: any CredentialRepository = KeychainCredentialRepository.shared, legacyStore: UserDefaults = .standard) {
        self.credentials = credentials
        self.legacyStore = legacyStore
    }

    public func secret(_ name: String, provider: String) -> String? {
        if let migration = migration(name, provider: provider) { return migration.get() }
        return credentials.get(forKey: Self.key(name, provider: provider))
    }

    public func save(_ value: String, _ name: String, provider: String) {
        if let migration = migration(name, provider: provider) { migration.save(value) }
        else { credentials.save(value, forKey: Self.key(name, provider: provider)) }
    }

    @discardableResult
    public func delete(_ name: String, provider: String) -> Bool {
        if let migration = migration(name, provider: provider) { return migration.delete() }
        return credentials.delete(forKey: Self.key(name, provider: provider))
    }

    static func key(_ name: String, provider: String) -> String {
        "provider.\(provider).\(name)"
    }

    private func migration(_ name: String, provider: String) -> SecureCredentialMigration? {
        // Compatibility lives at storage's boundary, never in the provider runtime.
        // Exact default-login keys only: an added login never inherits this entry.
        let legacyKeys = ["provider.deepseek.apiKey": "com.claudebar.credentials.deepseek-api-key"]
        let key = Self.key(name, provider: provider)
        guard let legacyKey = legacyKeys[key] else { return nil }
        return SecureCredentialMigration(secureStore: credentials, legacyStore: legacyStore, secureKey: key, legacyKey: legacyKey)
    }
}

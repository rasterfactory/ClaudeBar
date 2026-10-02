import Domain
import Foundation

/// The vault custom providers read their keys from — ClaudeBar's credential
/// store, under `provider.<id>.<name>`. A definition names the key; the value
/// lives only here.
public struct ProviderVault: SecretVault, @unchecked Sendable {
    private let legacyStore: UserDefaults
    private let credentials: any CredentialRepository

    public init(credentials: any CredentialRepository = KeychainCredentialRepository.shared, legacyStore: UserDefaults = .standard) {
        self.legacyStore = legacyStore
        self.credentials = credentials
    }

    public func secret(_ name: String, provider: String) -> String? {
        if let migration = migration(name, provider: provider) { return migration.get() }
        return credentials.get(forKey: Self.key(name, provider: provider))
    }

    public func save(_ value: String, _ name: String, provider: String) {
        if let migration = migration(name, provider: provider) { migration.save(value); return }
        credentials.save(value, forKey: Self.key(name, provider: provider))
    }

    @discardableResult
    public func delete(_ name: String, provider: String) -> Bool {
        if let migration = migration(name, provider: provider) { return migration.delete() }
        return credentials.delete(forKey: Self.key(name, provider: provider))
    }

    private func migration(_ name: String, provider: String) -> SecureCredentialMigration? {
        guard provider == "minimax", name == "apiKey" else { return nil }
        return SecureCredentialMigration(secureStore: credentials, legacyStore: legacyStore,
            secureKey: Self.key(name, provider: provider), legacyKey: "com.claudebar.credentials.minimax-api-key")
    }

    static func key(_ name: String, provider: String) -> String {
        "provider.\(provider).\(name)"
    }
}

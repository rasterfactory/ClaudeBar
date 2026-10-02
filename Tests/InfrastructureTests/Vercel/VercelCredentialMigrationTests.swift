import Foundation
import Testing
@testable import Domain
@testable import Infrastructure

@Suite struct VercelCredentialMigrationTests {
    @Test func `old secure key migrates to the default scope and added accounts never inherit it`() {
        let name = "VercelMigration.\(UUID())"
        let defaults = UserDefaults(suiteName:name)!
        let secure = UserDefaults(suiteName:name+".secure")!
        defer { defaults.removePersistentDomain(forName:name); secure.removePersistentDomain(forName:name+".secure") }
        let credentials = UserDefaultsCredentialRepository(defaults:secure)
        credentials.save("old-secure",forKey:CredentialKey.vercelApiKey)
        let vault = ProviderVault(credentials:credentials,legacyStore:defaults)
        #expect(vault.secret("apiKey",provider:"vercel-gateway.work") == nil)
        #expect(vault.secret("apiKey",provider:"vercel-gateway") == "old-secure")
        #expect(credentials.get(forKey:"provider.vercel-gateway.apiKey") == "old-secure")
        #expect(credentials.get(forKey:CredentialKey.vercelApiKey) == nil)
        #expect(vault.delete("apiKey",provider:"vercel-gateway"))
        #expect(vault.secret("apiKey",provider:"vercel-gateway") == nil)
    }
}

import Foundation
import Testing
@testable import Domain
@testable import Infrastructure

@Suite struct MiniMaxCredentialMigrationTests {
    @Test func `legacy key migrates securely only for the default account`() {
        let name = "MiniMaxMigration.\(UUID())"
        let defaults = UserDefaults(suiteName:name)!
        let secure = UserDefaults(suiteName:name+".secure")!
        defer { defaults.removePersistentDomain(forName:name); secure.removePersistentDomain(forName:name+".secure") }
        let credentials = UserDefaultsCredentialRepository(defaults:secure)
        defaults.set("old",forKey:"com.claudebar.credentials.minimax-api-key")
        let vault = ProviderVault(credentials:credentials,legacyStore:defaults)
        #expect(vault.secret("apiKey",provider:"minimax.work") == nil)
        #expect(vault.secret("apiKey",provider:"minimax") == "old")
        #expect(credentials.get(forKey:"provider.minimax.apiKey") == "old")
        #expect(defaults.object(forKey:"com.claudebar.credentials.minimax-api-key") == nil)
        #expect(vault.delete("apiKey",provider:"minimax"))
        #expect(vault.secret("apiKey",provider:"minimax") == nil)
    }
}

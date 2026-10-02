import Foundation
import Testing
@testable import Domain
@testable import Infrastructure

@Suite
struct CopilotCredentialMigrationTests {
    private struct RefusingStore: CredentialRepository {
        func save(_ value: String, forKey key: String) {}
        func get(forKey key: String) -> String? { nil }
        func delete(forKey key: String) -> Bool { false }
        func exists(forKey key: String) -> Bool { false }
    }

    @Test
    func `a legacy key migrates once and is shared by settings and the default vault scope`() {
        let suite = "CopilotMigration.\(UUID())"
        let legacy = UserDefaults(suiteName: suite)!
        let secure = UserDefaults(suiteName: suite + ".secure")!
        defer {
            legacy.removePersistentDomain(forName: suite)
            secure.removePersistentDomain(forName: suite + ".secure")
        }
        legacy.set("old-key", forKey: "com.claudebar.credentials.github-copilot-token")
        let credentials = UserDefaultsCredentialRepository(defaults: secure)
        let vault = ProviderVault(credentials: credentials, legacyStore: legacy)
        #expect(vault.secret("apiKey", provider: "copilot") == "old-key")
        #expect(credentials.get(forKey: "provider.copilot.apiKey") == "old-key")
        #expect(legacy.object(forKey: "com.claudebar.credentials.github-copilot-token") == nil)
        #expect(vault.secret("apiKey", provider: "copilot.work") == nil)
        vault.save("work-key", "apiKey", provider: "copilot.work")
        #expect(vault.secret("apiKey", provider: "copilot.work") == "work-key")
        #expect(vault.secret("apiKey", provider: "copilot") == "old-key")
        #expect(vault.delete("apiKey", provider: "copilot.work"))
        #expect(vault.secret("apiKey", provider: "copilot") == "old-key")
    }

    @Test
    func `a refused migration keeps the existing login and refuses destructive deletion`() {
        let suite = "CopilotFailedMigration.\(UUID())"
        let legacy = UserDefaults(suiteName: suite)!
        defer { legacy.removePersistentDomain(forName: suite) }
        legacy.set("old-key", forKey: "com.claudebar.credentials.github-copilot-token")
        let vault = ProviderVault(credentials: RefusingStore(), legacyStore: legacy)
        #expect(vault.secret("apiKey", provider: "copilot") == "old-key")
        #expect(vault.secret("apiKey", provider: "copilot.work") == nil)
        #expect(vault.delete("apiKey", provider: "copilot") == false)
        #expect(legacy.string(forKey: "com.claudebar.credentials.github-copilot-token") == "old-key")
    }

    @Test func `username and token migration share the config card and default runtime store`() {
        let suite = "CopilotMigration.Shared.\(UUID())"
        let legacy = UserDefaults(suiteName: suite)!
        let secure = UserDefaults(suiteName: suite + ".secure")!
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer {
            legacy.removePersistentDomain(forName: suite)
            secure.removePersistentDomain(forName: suite + ".secure")
            try? FileManager.default.removeItem(at: file)
        }
        legacy.set("old-token", forKey: "com.claudebar.credentials.github-copilot-token")
        legacy.set("old-user", forKey: "com.claudebar.credentials.github-username")
        let credentials = UserDefaultsCredentialRepository(defaults: secure)
        let vault = ProviderVault(credentials: credentials, legacyStore: legacy)
        let settings = JSONSettingsRepository(store: JSONSettingsStore(fileURL: file), credentials: legacy, secureCredentials: credentials)
        #expect(settings.getGithubToken() == "old-token")
        #expect(vault.secret("username", provider: "copilot") == "old-user")
        #expect(settings.getGithubUsername() == "old-user")
        #expect(vault.secret("username", provider: "copilot.work") == nil)
        #expect(legacy.string(forKey: "com.claudebar.credentials.github-username") == nil)
        settings.saveGithubToken("new-token")
        settings.saveGithubUsername("new-user")
        #expect(vault.secret("apiKey", provider: "copilot") == "new-token")
        #expect(vault.secret("username", provider: "copilot") == "new-user")
        settings.deleteGithubToken()
        settings.deleteGithubUsername()
        #expect(vault.secret("apiKey", provider: "copilot") == nil)
        #expect(vault.secret("username", provider: "copilot") == nil)
    }
}

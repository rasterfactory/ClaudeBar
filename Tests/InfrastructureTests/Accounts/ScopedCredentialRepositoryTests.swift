import Foundation
import Testing
import Domain
import Mockable
@testable import Infrastructure

@Suite("Account credential isolation")
struct ScopedCredentialRepositoryTests {
    @Test
    func missingAccountKeyCannotReadDefaultOrSiblingKey() {
        let vault = MemoryAccountCredentials()
        vault.save("default-secret", forKey: CredentialKey.zaiApiKey)
        let personal = ScopedCredentialRepository(providerId: "zai", accountId: "personal", repository: vault)
        let work = ScopedCredentialRepository(providerId: "zai", accountId: "work", repository: vault)
        personal.save("personal-secret", forKey: CredentialKey.zaiApiKey)
        #expect(work.get(forKey: CredentialKey.zaiApiKey) == nil)
        work.save("work-secret", forKey: CredentialKey.zaiApiKey)
        #expect(personal.get(forKey: CredentialKey.zaiApiKey) == "personal-secret")
        #expect(work.delete(forKey: CredentialKey.zaiApiKey))
        #expect(personal.exists(forKey: CredentialKey.zaiApiKey))
        #expect(vault.get(forKey: CredentialKey.zaiApiKey) == "default-secret")
    }

    @Test
    func isolatedSettingsNeverReadOrMigrateSharedLegacyCredentials() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "account-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("default-secret", forKey: "com.claudebar.credentials.zai-api-key")
        defaults.set("default-github", forKey: "com.claudebar.credentials.github-copilot-token")
        let vault = MemoryAccountCredentials()
        let scoped = ScopedCredentialRepository(providerId: "product", accountId: "work", repository: vault)
        let repo = JSONSettingsRepository(store: JSONSettingsStore(fileURL: root.appendingPathComponent("settings.json")),
            credentials: defaults, secureCredentials: scoped, isolatedAccountCredentials: true)
        #expect(repo.getZaiApiKey() == nil)
        #expect(repo.getGithubToken() == nil)
        repo.saveZaiApiKey("work-secret")
        repo.saveGithubToken("work-github")
        repo.saveMinimaxApiKey("work-minimax")
        repo.saveDeepSeekApiKey("work-deepseek")
        repo.saveAlibabaManualCookie("work-cookie")
        #expect(repo.getZaiApiKey() == "work-secret")
        #expect(repo.getGithubToken() == "work-github")
        #expect(repo.getMinimaxApiKey() == "work-minimax")
        #expect(repo.getDeepSeekApiKey() == "work-deepseek")
        #expect(repo.getAlibabaManualCookie() == "work-cookie")
        #expect(defaults.string(forKey: "com.claudebar.credentials.zai-api-key") == "default-secret")
        #expect(defaults.string(forKey: "com.claudebar.credentials.github-copilot-token") == "default-github")
        #expect(defaults.string(forKey: "com.claudebar.credentials.minimax-api-key") == nil)
        repo.deleteZaiApiKey()
        #expect(repo.getZaiApiKey() == nil)
        #expect(defaults.string(forKey: "com.claudebar.credentials.zai-api-key") == "default-secret")
    }
}

private final class MemoryAccountCredentials: CredentialRepository, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    func save(_ value: String, forKey key: String) { lock.lock(); defer { lock.unlock() }; values[key] = value }
    func get(forKey key: String) -> String? { lock.lock(); defer { lock.unlock() }; return values[key] }
    func delete(forKey key: String) -> Bool { lock.lock(); defer { lock.unlock() }; values[key] = nil; return true }
    func exists(forKey key: String) -> Bool { get(forKey: key) != nil }
}

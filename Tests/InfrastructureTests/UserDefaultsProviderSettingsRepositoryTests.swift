import Testing
import Foundation
@testable import Infrastructure
@testable import Domain

@Suite("UserDefaultsProviderSettingsRepository Tests")
struct UserDefaultsProviderSettingsRepositoryTests {

    // Use a unique suite name to avoid conflicts with other tests
    private let testSuiteName = "com.claudebar.test.settings.\(UUID().uuidString)"

    private func makeRepository() -> UserDefaultsProviderSettingsRepository {
        let defaults = UserDefaults(suiteName: testSuiteName)!
        return UserDefaultsProviderSettingsRepository(userDefaults: defaults)
    }

    private func cleanupDefaults() {
        UserDefaults().removePersistentDomain(forName: testSuiteName)
    }

    // MARK: - isEnabled Tests

    @Test
    func `should show or hide a provider by its default when the person never chose`() {
        // Given
        let repository = makeRepository()
        defer { cleanupDefaults() }

        // When
        let enabledWithTrueDefault = repository.isEnabled(forProvider: "claude", defaultValue: true)
        let enabledWithFalseDefault = repository.isEnabled(forProvider: "codex", defaultValue: false)

        // Then
        #expect(enabledWithTrueDefault == true)
        #expect(enabledWithFalseDefault == false)
    }

    @Test
    func `should show a provider the person turned on, whatever its default`() {
        // Given
        let repository = makeRepository()
        defer { cleanupDefaults() }
        repository.setEnabled(true, forProvider: "claude")

        // When
        let enabled = repository.isEnabled(forProvider: "claude", defaultValue: false)

        // Then
        #expect(enabled == true)
    }

    @Test
    func `should hide a provider the person turned off, whatever its default`() {
        // Given
        let repository = makeRepository()
        defer { cleanupDefaults() }
        repository.setEnabled(false, forProvider: "claude")

        // When
        let enabled = repository.isEnabled(forProvider: "claude", defaultValue: true)

        // Then
        #expect(enabled == false)
    }

    // MARK: - setEnabled Tests

    @Test
    func `should remember a provider turned on`() {
        // Given
        let repository = makeRepository()
        defer { cleanupDefaults() }

        // When
        repository.setEnabled(true, forProvider: "gemini")

        // Then
        let enabled = repository.isEnabled(forProvider: "gemini", defaultValue: false)
        #expect(enabled == true)
    }

    @Test
    func `should follow a provider turned on and then off again`() {
        // Given
        let repository = makeRepository()
        defer { cleanupDefaults() }

        // When
        repository.setEnabled(true, forProvider: "copilot")
        let enabledFirst = repository.isEnabled(forProvider: "copilot", defaultValue: false)

        repository.setEnabled(false, forProvider: "copilot")
        let enabledSecond = repository.isEnabled(forProvider: "copilot", defaultValue: true)

        // Then
        #expect(enabledFirst == true)
        #expect(enabledSecond == false)
    }

    // MARK: - Provider Isolation Tests

    @Test
    func `should keep each provider on or off independently`() {
        // Given
        let repository = makeRepository()
        defer { cleanupDefaults() }

        // When
        repository.setEnabled(true, forProvider: "claude")
        repository.setEnabled(false, forProvider: "codex")

        // Then
        #expect(repository.isEnabled(forProvider: "claude", defaultValue: false) == true)
        #expect(repository.isEnabled(forProvider: "codex", defaultValue: true) == false)
        #expect(repository.isEnabled(forProvider: "gemini", defaultValue: true) == true) // Uses default
    }

    // MARK: - Persistence Tests

    @Test
    func `should remember a provider turned on across restarts`() {
        // Given
        let defaults = UserDefaults(suiteName: testSuiteName)!
        defer { cleanupDefaults() }

        let repository1 = UserDefaultsProviderSettingsRepository(userDefaults: defaults)
        repository1.setEnabled(true, forProvider: "antigravity")

        // When
        let repository2 = UserDefaultsProviderSettingsRepository(userDefaults: defaults)
        let enabled = repository2.isEnabled(forProvider: "antigravity", defaultValue: false)

        // Then
        #expect(enabled == true)
    }

    // MARK: - Hidden Quota Keys (issue #140)

    @Test
    func `should hide no quotas until the person hides some (#140)`() {
        let repository = makeRepository()
        defer { cleanupDefaults() }

        #expect(repository.hiddenQuotaKeys(forProvider: "gemini") == [])
    }

    @Test
    func `should remember hidden quotas across restarts (#140)`() {
        let defaults = UserDefaults(suiteName: testSuiteName)!
        defer { cleanupDefaults() }

        let repository1 = UserDefaultsProviderSettingsRepository(userDefaults: defaults)
        repository1.setHiddenQuotaKeys(["model:gemini-2.0-flash"], forProvider: "gemini")

        let repository2 = UserDefaultsProviderSettingsRepository(userDefaults: defaults)

        #expect(repository2.hiddenQuotaKeys(forProvider: "gemini") == ["model:gemini-2.0-flash"])
    }

    @Test
    func `should keep each provider's hidden quotas apart (#140)`() {
        let repository = makeRepository()
        defer { cleanupDefaults() }

        repository.setHiddenQuotaKeys(["model:gemini-2.0-flash"], forProvider: "gemini")
        repository.setHiddenQuotaKeys(["weekly"], forProvider: "codex")

        #expect(repository.hiddenQuotaKeys(forProvider: "gemini") == ["model:gemini-2.0-flash"])
        #expect(repository.hiddenQuotaKeys(forProvider: "codex") == ["weekly"])
        #expect(repository.hiddenQuotaKeys(forProvider: "claude") == [])
    }

    @Test
    func `should show every quota again once nothing is hidden (#140)`() {
        let repository = makeRepository()
        defer { cleanupDefaults() }

        repository.setHiddenQuotaKeys(["model:gemini-2.0-flash"], forProvider: "gemini")
        repository.setHiddenQuotaKeys([], forProvider: "gemini")

        #expect(repository.hiddenQuotaKeys(forProvider: "gemini") == [])
    }

    // MARK: - Claude CLI Fallback

    @Test
    func `should fall back to Claude's CLI when the person never chose`() {
        let repository = makeRepository()
        defer { cleanupDefaults() }

        #expect(repository.claudeCliFallbackEnabled() == true)
    }

    @Test
    func `should remember turning Claude's CLI fallback off`() {
        let repository = makeRepository()
        defer { cleanupDefaults() }

        repository.setClaudeCliFallbackEnabled(false)
        #expect(repository.claudeCliFallbackEnabled() == false)
    }

    // MARK: - Codex Verified Flag

    @Test
    func `should not count Codex as verified before it ever answered`() {
        let repository = makeRepository()
        defer { cleanupDefaults() }

        #expect(repository.codexVerifiedAtLeastOnce() == false)
    }

    @Test
    func `should remember whether Codex has been verified`() {
        let repository = makeRepository()
        defer { cleanupDefaults() }

        repository.setCodexVerifiedAtLeastOnce(true)
        #expect(repository.codexVerifiedAtLeastOnce() == true)

        repository.setCodexVerifiedAtLeastOnce(false)
        #expect(repository.codexVerifiedAtLeastOnce() == false)
    }

    // MARK: - Provider Order

    @Test
    func `should keep no provider order until the person arranges them`() {
        let repository = makeRepository()
        defer { cleanupDefaults() }

        #expect(repository.providerOrder() == [])
    }

    @Test
    func `should remember the provider order across restarts`() {
        let repository = makeRepository()
        defer { cleanupDefaults() }

        repository.setProviderOrder(["gemini", "claude", "codex"])

        // Read back through a fresh repository over the same suite, so the
        // value really landed in the persistent store.
        let reloaded = makeRepository()
        #expect(reloaded.providerOrder() == ["gemini", "claude", "codex"])
    }

    @Test
    func `should forget the provider order when it is cleared`() {
        let repository = makeRepository()
        defer { cleanupDefaults() }

        repository.setProviderOrder(["gemini", "claude", "codex"])
        repository.setProviderOrder([])
        #expect(repository.providerOrder() == [])
    }
}

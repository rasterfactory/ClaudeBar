import Foundation
import Providers
import Testing

/// *The product's switch* (TARGET §12, slice 1): Claude on or off hides every
/// login of it, and keeps each login's own *Pause*. On upgrade, the old
/// switch — which was the plain login's — keeps meaning what it did.
@MainActor
@Suite
struct ProductSwitchTests {
    private func work() -> ProviderAccountConfig {
        ProviderAccountConfig(accountId: "work", label: "work", probeConfig: ["codexHome": "/tmp/work", "chatgptAccountId": "work"])
    }

    private func codex(_ settings: InMemoryProviderSettings) throws -> Provider {
        try ProviderFactory.make("codex", settings: settings, accounts: settings.accounts(forProvider: "codex"))
    }

    private func twoLogins() -> InMemoryProviderSettings {
        let settings = InMemoryProviderSettings()
        settings.addAccount(work(), forProvider: "codex")
        return settings
    }

    @Test
    func `a product is on, and every login of it is in the lineup`() throws {
        let codex = try codex(twoLogins())

        let shown = codex.accounts.filter(codex.isInLineup).count
        #expect(codex.isEnabled)
        #expect(shown == 2)
    }

    @Test
    func `turning the product off hides every login and keeps each login's own switch`() throws {
        let codex = try codex(twoLogins())

        codex.isEnabled = false

        let shown = codex.accounts.filter(codex.isInLineup).count
        let on = codex.accounts.filter(\.isEnabled).count
        #expect(shown == 0)
        #expect(on == 2)
    }

    @Test
    func `pausing a login leaves the product on`() throws {
        let codex = try codex(twoLogins())

        codex.defaultAccount.isEnabled = false

        #expect(codex.isEnabled)
        #expect(!codex.plainIsInLineup)
        #expect(codex.isInLineup(codex.accounts[1]))
    }

    @Test
    func `the product's switch and a login's pause are kept apart across a relaunch`() throws {
        let settings = twoLogins()
        let first = try codex(settings)
        first.defaultAccount.isEnabled = false
        first.isEnabled = false

        let again = try codex(settings)

        #expect(!again.isEnabled)
        #expect(!again.defaultAccount.isEnabled)
        #expect(again.accounts[1].isEnabled)
    }

    // MARK: - Upgrade: the old switch was the plain login's

    @Test
    func `an old off with another login on meant the plain login was paused`() throws {
        let settings = twoLogins()
        settings.setEnabled(false, forProvider: "codex")

        let codex = try codex(settings)

        #expect(codex.isEnabled)
        #expect(!codex.defaultAccount.isEnabled)
        #expect(codex.isInLineup(codex.accounts[1]))
    }

    @Test
    func `an old off with no other login on meant the product was off`() throws {
        let settings = InMemoryProviderSettings()
        settings.setEnabled(false, forProvider: "codex")

        let codex = try codex(settings)

        #expect(!codex.isEnabled)
        #expect(codex.defaultAccount.isEnabled)
    }

    @Test
    func `the upgrade reads the old switch once`() throws {
        let settings = twoLogins()
        settings.setEnabled(false, forProvider: "codex")
        let first = try codex(settings)
        first.defaultAccount.isEnabled = true

        let again = try codex(settings)

        #expect(again.isEnabled)
        #expect(again.defaultAccount.isEnabled)
    }
}

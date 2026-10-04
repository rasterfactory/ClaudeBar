import Foundation
import Testing
@testable import Domain
@testable import Infrastructure

/// Settings → Providers, by product (TARGET §12, slice 1): one row per
/// product, its switch hiding every login, its logins moving together.
@MainActor
@Suite
struct ProductTabsTests {
    private let temp = FileManager.default.temporaryDirectory.appendingPathComponent("product-tabs-\(UUID().uuidString)")

    /// Codex with two logins (*me* and *work*), then Claude with one.
    private func monitor() throws -> (QuotaMonitor, codex: Provider, claude: Provider) {
        let settings = JSONSettingsRepository(store: JSONSettingsStore(fileURL: temp.appendingPathComponent("settings.json")))
        let work = ProviderAccountConfig(accountId: "work", label: "work", probeConfig: ["codexHome": "/tmp/work", "chatgptAccountId": "work"])
        let codex = try ProviderFactory.make("codex", settings: settings, accounts: [work])
        let claude = try ProviderFactory.make("claude", settings: settings)
        return (QuotaMonitor(providers: kept([codex, claude])), codex, claude)
    }

    @Test
    func `each product is one tab, its logins inside, whether on or off`() throws {
        let (monitor, codex, _) = try monitor()
        codex.accounts[1].isEnabled = false

        let tabs = monitor.productTabs

        #expect(tabs.map(\.id) == ["codex", "claude"])
        #expect(tabs[0].accounts.count == 2)
    }

    @Test
    func `turning a product off hides every login of it and keeps them`() throws {
        let (monitor, codex, _) = try monitor()

        monitor.setProductEnabled(monitor.productTabs[0], enabled: false)

        #expect(!monitor.productTabs[0].isEnabled)
        #expect(!monitor.lineup.contains { $0.id.hasPrefix("codex") })
        #expect(codex.accounts.allSatisfy(\.isEnabled) == true)
    }

    @Test
    func `turning off the selected product selects another`() throws {
        let (monitor, _, _) = try monitor()
        monitor.selectedProviderId = "codex"

        monitor.setProductEnabled(monitor.productTabs[0], enabled: false)

        #expect(monitor.selectedProviderId == "claude")
    }

    @Test
    func `moving a product moves its logins together`() throws {
        let (monitor, _, _) = try monitor()

        monitor.providers.move("claude", by: -1)

        #expect(monitor.productTabs.map(\.id) == ["claude", "codex"])
        #expect(monitor.logins.map(\.id).prefix(1) == ["claude"])
        #expect(monitor.logins.map(\.id).suffix(2) == ["codex", "codex.work"])
    }

    @Test
    func `a row names each login only when the product has several`() throws {
        let (monitor, codex, claude) = try monitor()
        codex.accounts.rename(codex.defaultAccount, to: "personal")

        #expect(monitor.productTabs[0].loginName(codex.defaultAccount) == "personal")
        #expect(monitor.productTabs[0].loginName(codex.accounts[1]) == "work")
        #expect(monitor.productTabs[1].loginName(claude.defaultAccount) == nil)
    }

    @Test
    func `a product's page shows its plain login's settings`() throws {
        let (monitor, codex, _) = try monitor()

        #expect(monitor.productTabs[0].page === codex.defaultAccount)
    }
}

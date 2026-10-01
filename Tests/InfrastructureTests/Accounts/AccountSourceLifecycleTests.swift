import Foundation
import Testing
import Providers
import Quotas
@testable import Infrastructure

@Suite("Shared account source lifecycle")
@MainActor
struct AccountSourceLifecycleTests {
    // These test the shared lifecycle, not the providers' authentication adapters.
    nonisolated static let providerIds = ["claude", "codex", "gemini", "antigravity", "zai", "copilot", "bedrock", "ampcode", "kimi", "kiro", "cursor", "minimax", "deepseek", "vercel-gateway", "alibaba", "mistral", "opencode-go", "omp", "grok", "commandcode", "custom", "extension"]

    @Test(arguments: providerIds)
    func independentUsageNamesAndRestart(_ id: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("settings.json")
        let settings = JSONSettingsRepository(store: JSONSettingsStore(fileURL: file))
        let work = ProviderAccountConfig(accountId: "work", label: "Work", email: "work@example.com", probeConfig: ["source": "/work"])
        settings.addAccount(work, forProvider: id)
        func make(_ settings: JSONSettingsRepository) throws -> Provider {
            try Provider(profile: .init(id: id, name: "Product"), settings: settings,
                accounts: settings.accounts(forProvider: id), makeAccountSource: { config in
                    FixtureAccountSource(id: id, email: config?.email ?? "personal@example.com", remaining: config == nil ? 80 : 30)
                })
        }
        let provider = try make(settings)
        #expect(provider.accounts.count == 2)
        let personal = try await provider.defaultAccount.refresh(.background)
        let added = try #require(provider.accounts.last)
        let usage = try await added.refresh()
        #expect(personal.sessionQuota?.percentRemaining == 80)
        #expect(usage.sessionQuota?.percentRemaining == 30)
        #expect(usage.providerId == "\(id).work")
        #expect(usage.quotas.allSatisfy { $0.providerId == added.id })
        #expect(provider.rename(provider.defaultAccount, to: "Personal"))
        #expect(provider.rename(added, to: "Office"))
        #expect(added.snapshot == usage)
        added.isEnabled = false
        let reopened = try make(JSONSettingsRepository(store: JSONSettingsStore(fileURL: file)))
        _ = try await reopened.defaultAccount.refresh()
        #expect(reopened.defaultAccount.name == "Personal")
        #expect(reopened.accounts.last?.name == "Office")
        #expect(reopened.accounts.last?.isEnabled == false)
        provider.remove(added)
        #expect(provider.defaultAccount.name == "Product")
        #expect(provider.defaultAccount.snapshot == personal)
    }

    @Test
    func changedIdentityCannotReplaceAnotherAccountsUsage() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = JSONSettingsRepository(store: JSONSettingsStore(fileURL: root.appendingPathComponent("settings.json")))
        let work = ProviderAccountConfig(accountId: "work", label: "Work", email: "work@example.com")
        let source = FixtureAccountSource(id: "product", email: "work@example.com", remaining: 20)
        let provider = try Provider(profile: .init(id: "product", name: "Product"), settings: settings, accounts: [work],
            makeAccountSource: { config in config == nil ? FixtureAccountSource(id: "product", email: "personal@example.com", remaining: 90) : source })
        let personal = try await provider.defaultAccount.refresh()
        let added = try #require(provider.accounts.last)
        _ = try await added.refresh()
        source.email = "wrong@example.com"
        await #expect(throws: UsageError.self) { try await added.refresh() }
        #expect(added.snapshot == nil)
        #expect(added.lastError != nil)
        #expect(provider.defaultAccount.snapshot == personal)
        #expect(provider.defaultAccount.lastError == nil)
    }

    @Test
    func invalidSourceIsNeverSubstitutedWithDefault() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = JSONSettingsRepository(store: JSONSettingsStore(fileURL: root.appendingPathComponent("settings.json")))
        let provider = try Provider(profile: .init(id: "product", name: "Product"), settings: settings,
            makeAccountSource: { config in
                if config != nil { throw UsageError.authenticationRequired }
                return FixtureAccountSource(id: "product", email: "personal@example.com", remaining: 90)
            })
        #expect(provider.add(.init(accountId: "work", label: "Work")) == nil)
        #expect(provider.accounts.count == 1)
    }
}

@MainActor
private final class FixtureAccountSource: AccountUsageSource {
    let id: String
    var email: String
    let remaining: Double
    var backgroundRefreshFloor: Duration? { .seconds(60) }
    init(id: String, email: String, remaining: Double) {
        self.id = id; self.email = email; self.remaining = remaining
    }
    func isAvailable() async -> Bool { true }
    func refresh(_ kind: RefreshKind) async throws -> UsageSnapshot {
        UsageSnapshot(providerId: id, quotas: [.init(percentRemaining: remaining, quotaType: .session, providerId: id)],
                      capturedAt: Date(), accountEmail: email)
    }
}

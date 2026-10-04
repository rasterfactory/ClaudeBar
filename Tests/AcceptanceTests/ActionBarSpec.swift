import Testing
import Foundation
import Mockable
import Providers
@testable import Domain
@testable import Infrastructure

/// Feature: Action Bar
///
/// Users interact with action buttons: Dashboard, Refresh, Share, Settings, Quit.
///
/// Behaviors covered:
/// - #24: User clicks Dashboard → opens provider's web dashboard in browser
/// - #25: User clicks Share (Claude only) → shows referral link overlay
@Suite("Feature: Action Bar")
struct ActionBarSpec {

    // MARK: - #24: Dashboard URLs

    @Suite("Scenario: Dashboard opens correct URL per provider")
    @MainActor
    struct DashboardURLs {

        private static func makeSettings() -> MockProviderSettingsRepository {
            let mock = MockProviderSettingsRepository()
            given(mock).isEnabled(forProvider: .any, defaultValue: .any).willReturn(true)
            given(mock).isEnabled(forProvider: .any).willReturn(true)
            given(mock).setEnabled(.any, forProvider: .any).willReturn()
            return mock
        }

        private static func makeUsageProbe(tier: AccountTier?) -> MockUsageProbe {
            let probe = MockUsageProbe()
            given(probe).probe().willReturn(
                UsageSnapshot(providerId: "claude", quotas: [], capturedAt: Date(), accountTier: tier)
            )
            given(probe).isAvailable().willReturn(true)
            return probe
        }

        @Test
        func `should open Claude's usage settings from Dashboard (#24)`() throws {
            let claude = try ProviderFactory.builtIn("claude")
            #expect(claude.profile.links.dashboard?.absoluteString == "https://claude.ai/new#settings/usage")
        }

        @Test
        func `should open OpenAI's usage page from Codex's Dashboard (#24)`() throws {
            let codex = try ProviderFactory.builtIn("codex")
            #expect(codex.profile.links.dashboard?.absoluteString == "https://platform.openai.com/usage")
        }

        @Test
        func `should open GitHub's Copilot features page from Copilot's Dashboard (#24)`() throws {
            let suiteName = "com.claudebar.test.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suiteName)!
            let settings = UserDefaultsProviderSettingsRepository(userDefaults: defaults)
            let copilot = try ProviderFactory.make("copilot", settings: settings)
            #expect(copilot.dashboardURL(of: copilot.defaultAccount)?.absoluteString == "https://github.com/settings/copilot/features")
        }

        @Test
        func `should offer no Dashboard for Antigravity (#24)`() throws {
            let settings = UserDefaultsProviderSettingsRepository(userDefaults: UserDefaults(suiteName: "com.claudebar.test.\(UUID().uuidString)")!)
            let antigravity = try ProviderFactory.make("antigravity", settings: settings)
            #expect(antigravity.dashboardURL(of: antigravity.defaultAccount) == nil)
        }

        @Test
        func `should open the AWS Bedrock console from Bedrock's Dashboard (#24)`() throws {
            let suiteName = "com.claudebar.test.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suiteName)!
            let settings = UserDefaultsProviderSettingsRepository(userDefaults: defaults)
            let bedrock = try ProviderFactory.make("bedrock", settings: settings)
            #expect(bedrock.dashboardURL(of: bedrock.defaultAccount)?.absoluteString == "https://console.aws.amazon.com/bedrock/home")
        }

        @Test
        func `should open Z.ai's subscription page from Z.ai's Dashboard (#24)`() throws {
            let suiteName = "com.claudebar.test.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suiteName)!
            let settings = UserDefaultsProviderSettingsRepository(userDefaults: defaults)
            let zai = try ProviderFactory.make("zai", settings: settings)
            #expect(zai.dashboardURL(of: zai.defaultAccount)?.absoluteString == "https://z.ai/subscribe")
        }
    }

    // MARK: - #25: Claude guest passes

    @Suite("Scenario: Share Claude Code guest passes")
    @MainActor
    struct GuestPassSharing {

        private static func usage(_ tier: AccountTier?) -> UsageSnapshot {
            UsageSnapshot(providerId: "claude", quotas: [], capturedAt: Date(), accountTier: tier)
        }

        @Test
        func `should offer Claude guest passes only when ClaudeBar can read them (#25)`() throws {
            let settings = UserDefaultsProviderSettingsRepository(userDefaults: UserDefaults(suiteName: "com.claudebar.test.\(UUID().uuidString)")!)
            let withoutPasses = try ProviderFactory.make("claude", settings: settings).defaultAccount
            let withPasses = try ProviderFactory.make("claude", settings: settings, guestPasses: GuestPasses(source: MockGuestPassSource())).defaultAccount

            #expect(withoutPasses.guestPasses == nil)
            #expect(withPasses.guestPasses != nil)
        }

        @Test
        func `should show the Share button to a Max account (#25)`() {
            let passes = GuestPasses(source: MockGuestPassSource())

            #expect(passes.isOffered(for: Self.usage(.claudeMax)))
        }

        @Test
        func `should not show the Share button to a Pro account (#243)`() {
            // Issue #243: Anthropic issues invitation links to Max plans only.
            let passes = GuestPasses(source: MockGuestPassSource())

            #expect(passes.isOffered(for: Self.usage(.claudePro)) == false)
        }

        @Test
        func `should report a failure, not stay silent, when guest passes cannot be fetched (#25)`() async {
            let passSource = MockGuestPassSource()
            given(passSource).fetch().willThrow(UsageError.parseFailed("Could not find referral URL"))
            let passes = GuestPasses(source: passSource)

            do {
                _ = try await passes.fetch()
            } catch {
                // Expected to throw
            }

            #expect(passes.error != nil)
            #expect(passes.pass == nil)
        }
    }
}

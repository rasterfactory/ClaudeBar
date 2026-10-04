import DataSources
import Foundation
import Mockable
import Quotas
import Testing
@testable import Providers

/// *NOT SET UP* — a login with no usage whose tool isn't on this Mac, or
/// that has never signed in, is waiting to be set up, not failing (#198). The
/// definition's `setup` says what that takes; a real failure stays one.
@MainActor
@Suite
struct NotSetUpTests {
    private func cliNotFound(_ claude: ClaudeHarness) {
        given(claude.cli).locate(.any).willReturn(nil)
        given(claude.cli).execute(binary: .any, args: .any, input: .any, timeout: .any, workingDirectory: .any, autoResponses: .any)
            .willThrow(UsageError.cliNotFound("claude"))
    }

    @Test
    func `no CLI and no sign-in is not set up`() async throws {
        let claude = try ClaudeHarness()
        defer { claude.cleanUp() }
        cliNotFound(claude)
        let provider = try claude.provider()

        _ = try? await provider.refreshPlain()

        #expect(provider.defaultAccount.needsSetup)
    }

    @Test
    func `in API mode, no sign-in and no CLI is not set up`() async throws {
        let claude = try ClaudeHarness()
        defer { claude.cleanUp() }
        cliNotFound(claude)
        let provider = try claude.provider(settings: InMemoryProviderSettings(dataSourceKinds: ["claude": "api"]))

        _ = try? await provider.refreshPlain()

        #expect(provider.defaultAccount.needsSetup)
    }

    @Test
    func `a CLI that is there but fails is a failure, not setup`() async throws {
        let claude = try ClaudeHarness()
        defer { claude.cleanUp() }
        given(claude.cli).locate(.any).willReturn("/usr/local/bin/claude")
        given(claude.cli).execute(binary: .any, args: .any, input: .any, timeout: .any, workingDirectory: .any, autoResponses: .any)
            .willThrow(UsageError.executionFailed("claude is not running"))
        let provider = try claude.provider()

        _ = try? await provider.refreshPlain()

        #expect(provider.defaultAccount.lastError != nil)
        #expect(!provider.defaultAccount.needsSetup)
    }

    @Test
    func `a login that has never refreshed is not yet waiting for setup`() throws {
        let claude = try ClaudeHarness()
        defer { claude.cleanUp() }
        #expect(try !claude.provider().defaultAccount.needsSetup)
    }

    @Test
    func `claude says what setting it up takes and where`() throws {
        let setup = try #require(try ProviderFactory.builtIn("claude").setup)
        #expect(setup.title == "See your session and weekly limits")
        #expect(setup.text.contains("Claude Code"))
        #expect(setup.url == URL(string: "https://claude.ai/code"))
        #expect(setup.button == "Set up Claude Code")
    }

    @Test
    func `setup decodes, and a provider without one has none`() throws {
        let json = #"{"title":"Install Acme","text":"Acme reads your limits through its CLI.","url":"https://acme.dev/cli"}"#
        let setup = try JSONDecoder().decode(ProviderDefinition.Setup.self, from: Data(json.utf8))
        #expect(setup == ProviderDefinition.Setup(title: "Install Acme", text: "Acme reads your limits through its CLI.",
                                                  url: URL(string: "https://acme.dev/cli")))
        #expect(setup.button == "Set up")
        #expect(try ProviderFactory.builtIn("grok").setup == nil)
    }

    @Test
    func `the notice is the definition's setup`() async throws {
        let claude = try ClaudeHarness()
        defer { claude.cleanUp() }
        cliNotFound(claude)
        let provider = try claude.provider()
        _ = try? await provider.refreshPlain()

        #expect(provider.setupNotice(of: provider.defaultAccount).title == "See your session and weekly limits")
        #expect(provider.setupNotice(of: provider.defaultAccount).button == "Set up Claude Code")
    }

    @Test
    func `without a setup in the definition, the notice names the provider and says what failed`() throws {
        let definition = try ProviderDefinition(
            profile: ProviderFactory.builtIn("claude").profile, dataSources: ProviderFactory.builtIn("claude").dataSources,
            defaultDataSource: "cli")
        let notice = ProviderDefinition.Setup.fallback(for: definition.profile.name, error: UsageError.cliNotFound("acme"))

        #expect(definition.setup == nil)
        #expect(notice.title == "Set up Claude")
        #expect(notice.text == UsageError.cliNotFound("acme").localizedDescription)
        #expect(notice.url == nil)
    }

    @Test
    func `a login with no usage history reads no usage`() async throws {
        let claude = try ClaudeHarness()
        defer { claude.cleanUp() }
        let provider = try claude.provider()
        #expect(!provider.defaultAccount.readsUsage)
    }
}

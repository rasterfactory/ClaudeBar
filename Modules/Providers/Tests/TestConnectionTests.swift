import DataSources
import Foundation
import Providers
import Quotas
import Testing

/// *Test Connection* — the active data source looks up its key and fetches,
/// stopping before mapping, so a person sees what came back or which step failed.
@MainActor
@Suite
struct TestConnectionTests {
    @Test
    func `should show the status the provider answered with when the connection works`() async throws {
        let stub = try StubbedProvider(dataSourceKind: "api", providerId: "codex")
        defer { stub.cleanUp() }
        try stub.writeCodexAuth(accountId: "me")
        stub.answerHTTP(#"{"anything":"unmapped"}"#)
        let codex = try stub.makeProvider("codex")

        let result = await codex.testConnection()

        #expect(try result.get().status == 200)
    }

    @Test
    func `should say the key lookup failed when there is no key`() async throws {
        let stub = try StubbedProvider(dataSourceKind: "api", providerId: "codex")
        defer { stub.cleanUp() }
        let codex = try stub.makeProvider("codex")

        let result = await codex.testConnection()

        guard case .failure(let error) = result else {
            Issue.record("Expected a failure")
            return
        }
        #expect(error.step == .lookup)
    }

    @Test
    func `should allow background refreshes once the person has tested the connection`() async throws {
        let stub = try StubbedProvider(providerId: "codex")
        defer { stub.cleanUp() }
        stub.answerRPC(#"{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":20}}}}"#)
        let codex = try stub.makeProvider("codex")

        _ = await codex.testConnection()

        #expect(stub.settings.isOn("verifiedAtLeastOnce", forProvider: "codex") == true)
    }
}

/// The fallback a definition lets the person switch off — Claude's API → CLI.
@MainActor
@Suite
struct FallbackSettingTests {
    @Test
    func `should use the fallback until the person switches it off, and remember the choice`() throws {
        let claude = try ClaudeHarness()
        defer { claude.cleanUp() }
        let settings = InMemoryProviderSettings()
        let provider = try claude.provider(settings: settings)

        #expect(provider.configuration.isFallbackEnabled(from: "api"))

        provider.configuration.setFallbackEnabled(false, from: "api")

        #expect(provider.configuration.isFallbackEnabled(from: "api") == false)
        #expect(settings.isOn("cliFallbackEnabled", forProvider: "claude") == false)
    }

    @Test
    func `should always use a fallback the person cannot switch off`() throws {
        let claude = try ClaudeHarness()
        defer { claude.cleanUp() }
        let provider = try claude.provider()

        provider.configuration.setFallbackEnabled(false, from: "cli")

        #expect(provider.configuration.isFallbackEnabled(from: "cli"))
    }
}

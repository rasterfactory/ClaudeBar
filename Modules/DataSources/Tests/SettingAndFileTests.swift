import DataSources
import Foundation
import Mockable
import Quotas
import Testing

/// Two cases *Add Provider* needs: a key the person pasted into ClaudeBar
/// (`setting`, kept in its vault, never in a file), and a usage file on disk
/// (`file`) — *Start from: API · File*.
@Suite
struct SettingAndFileTests {
    /// A vault in memory, keyed by provider and setting name.
    final class Vault: SecretStore, @unchecked Sendable {
        var secrets: [String: String]
        init(_ secrets: [String: String] = [:]) { self.secrets = secrets }
        func secret(_ name: String, provider: String) -> String? { secrets["\(provider).\(name)"] }
    }

    private func source(_ json: String) throws -> DataSourceDefinition {
        try JSONDecoder().decode(DataSourceDefinition.self, from: Data(json.utf8))
    }

    private func make(_ definition: DataSourceDefinition, network: MockNetworkClient = MockNetworkClient(),
                      vault: Vault = Vault(), home: URL = FileManager.default.temporaryDirectory) -> DataSource {
        DataSources.make(
            definition, providerId: "openrouter",
            cliExecutor: MockCLIExecutor(), network: network,
            makeTransport: { _, _, _, _ in MockRPCTransport() },
            secrets: vault,
            environment: { _ in nil }, homeDirectory: home, now: { Date() }
        )
    }

    private static let api = """
    { "kind": "api", "credential": { "setting": "apiKey" },
      "fetch": { "http": { "url": "https://openrouter.ai/api/v1/auth/key", "headers": { "Authorization": "Bearer {{token}}" } } },
      "mapping": { "json": { "quotas": [] } } }
    """

    @Test
    func `should send the key the person saved in ClaudeBar as the definition says`() async throws {
        let network = MockNetworkClient()
        given(network).request(.matching { @Sendable in $0.value(forHTTPHeaderField: "Authorization") == "Bearer sk-or-1" })
            .willReturn((Data("{}".utf8), HTTPURLResponse(url: URL(string: "https://openrouter.ai")!, statusCode: 200, httpVersion: nil, headerFields: nil)!))

        let response = try await make(try source(Self.api), network: network, vault: Vault(["openrouter.apiKey": "sk-or-1"])).fetchResponse()

        #expect(response.status == 200)
    }

    @Test
    func `should ask for a key at the lookup step when none is saved`() async throws {
        let source = make(try source(Self.api))

        await #expect(throws: DataSourceError(.lookup, .authenticationRequired)) { try await source.fetchResponse() }
        #expect(source.hasKey == false)
    }

    @Test
    func `should name where the key is kept, never its value, when it is saved in ClaudeBar`() throws {
        #expect(try source(Self.api).credential?.lookupOrder == ["API key saved in ClaudeBar"])
    }

    @Test
    func `should show what a usage file holds`() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("file-fetch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try Data(#"{"left":42}"#.utf8).write(to: home.appendingPathComponent("usage.json"))
        let source = make(try source("""
        { "kind": "file", "fetch": { "file": { "path": "~/usage.json" } },
          "mapping": { "json": { "quotas": [{ "kind": "session", "leftPercent": "$.left" }] } } }
        """), home: home)

        #expect(await source.isReady())
        #expect(try await source.fetchUsage().quota(for: .session)?.percentRemaining == 42)
    }

    @Test
    func `should not be ready and fail at the fetch step when the usage file is missing`() async throws {
        let source = make(try source("""
        { "kind": "file", "fetch": { "file": { "path": "/nonexistent/usage.json" } }, "mapping": { "json": { "quotas": [] } } }
        """))

        #expect(await source.isReady() == false)
        await #expect(throws: DataSourceError.self) { try await source.fetchResponse() }
    }
}

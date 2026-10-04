import Foundation
import Quotas
import Testing
@testable import DataSources

/// `script` — a script run with `/bin/sh` from its own folder, every setting
/// in its environment and secrets read from the vault: what an extension's
/// section runs (TARGET §12). Run for real, in a temporary folder.
@Suite
struct ScriptFetchTests {
    private let folder = FileManager.default.temporaryDirectory.appendingPathComponent("script-fetch-\(UUID().uuidString)", isDirectory: true)

    private final class Vault: SecretStore, @unchecked Sendable {
        let values: [String: String]
        init(_ values: [String: String]) { self.values = values }
        func secret(_ name: String, provider: String) -> String? { values["\(provider).\(name)"] }
    }

    private func script(_ name: String, _ body: String) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func source(_ fetch: String, secrets: [String: String] = [:]) throws -> DataSource {
        let json = """
        {"kind":"quotas","fetch":{"script":\(fetch)},
         "mapping":{"json":{"quotas":[{"kind":"weekly","at":"$.weekly","leftPercent":"left"}]}}}
        """
        let definition = try JSONDecoder().decode(DataSourceDefinition.self, from: Data(json.utf8))
        return DataSources.make(definition, providerId: "ext-acme", secrets: Vault(secrets))
    }

    @Test
    func `a script runs from its own folder and its output is the response`() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try script("probe.sh", #"cat left.json"#)
        try Data(#"{"weekly":{"left":62}}"#.utf8).write(to: folder.appendingPathComponent("left.json"))

        let usage = try await source(#"{"run":"./probe.sh","folder":"\#(folder.path)"}"#).fetchUsage()

        #expect(usage.quota(for: .weekly)?.percentRemaining == 62)
    }

    @Test
    func `settings reach the script as environment variables, secrets from the vault`() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try script("probe.sh", #"echo "{\"weekly\":{\"left\":${#CLAUDEBAR_API_KEY}$CLAUDEBAR_REGION}}""#)

        let fetch = #"{"run":"./probe.sh","folder":"\#(folder.path)","environment":{"CLAUDEBAR_REGION":"0"},"secrets":{"CLAUDEBAR_API_KEY":"apiKey"}}"#
        let usage = try await source(fetch, secrets: ["ext-acme.apiKey": "sk-123"]).fetchUsage()

        // ${#KEY} is the key's length (6), then the region "0": 60% left.
        #expect(usage.quota(for: .weekly)?.percentRemaining == 60)
    }

    @Test
    func `a script that fails is a failure at the fetch step`() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try script("probe.sh", "exit 3")

        await #expect { try await source(#"{"run":"./probe.sh","folder":"\#(folder.path)"}"#).fetchUsage() } throws: { error in
            (error as? DataSourceError)?.step == .fetch
        }
    }

    @Test
    func `a script that isn't there is not ready`() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let missing = try source(#"{"run":"./missing.sh","folder":"\#(folder.path)"}"#)

        #expect(await missing.isReady() == false)
    }

    @Test
    func `a script runs nothing it isn't given, and says what it runs`() throws {
        let fetch = try JSONDecoder().decode(Fetch.self, from: Data(#"{"script":{"run":"./probe.sh","folder":"/tmp/x"}}"#.utf8))

        #expect(fetch.connection.commands == [["/bin/sh", "-c", "./probe.sh"]])
        #expect(fetch.connection.urls.isEmpty)
    }
}

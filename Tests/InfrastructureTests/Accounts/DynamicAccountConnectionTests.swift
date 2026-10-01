import DataSources
import Domain
import Foundation
import Providers
import Testing
@testable import Infrastructure

@Suite("Custom and extension account connections")
@MainActor
struct DynamicAccountConnectionTests {
    @Test
    func customFileAndVaultAreScopedAcrossRestart() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "dynamic-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let credentials = UserDefaultsCredentialRepository(defaults: defaults, keyPrefix: "fixture.")
        let settings = JSONSettingsRepository(store: .init(fileURL: root.appendingPathComponent("settings.json")))
        let connections = LegacyAccountConnections(credentials: credentials, settingsRoot: root)
        let definition = try ProviderDefinition.parse(Data(#"{"profile":{"id":"custom-fixture","name":"Fixture"},"dataSources":[{"kind":"file","credential":{"firstOf":[{"environment":"FIXTURE_KEY"},{"setting":"apiKey"}]},"fetch":{"file":{"path":"~/usage.json"}},"mapping":{"json":{"quotas":[{"kind":"session","leftPercent":"$.left"}]}}}],"defaultDataSource":"file"}"#.utf8), origin: .custom)
        ProviderVault(credentials: credentials).save("default-key", "apiKey", provider: definition.id)
        let group = try CustomAccountConnections.make(definition, settings: settings, secrets: ProviderVault(credentials: credentials), connections: connections)
        #expect(group.hasKey(for: "file"))
        let personal = try config(root, id: "personal", left: 80)
        let work = try config(root, id: "work", left: 30)
        try connections.saveField("personal-key", field: "FIXTURE_KEY", providerId: definition.id, config: personal)
        try connections.saveField("work-key", field: "FIXTURE_KEY", providerId: definition.id, config: work)
        settings.addAccount(personal, forProvider: definition.id); settings.addAccount(work, forProvider: definition.id)
        let a = try #require(group.add(personal)); let b = try #require(group.add(work))
        #expect(try await a.refresh().lowestQuota?.percentRemaining == 80)
        #expect(try await b.refresh().lowestQuota?.percentRemaining == 30)
        #expect(group.rename(b, to: "Office"))
        let restarted = try CustomAccountConnections.make(definition, settings: settings, secrets: ProviderVault(credentials: credentials), connections: connections)
        #expect(restarted.accounts.last?.label == "Office")
        #expect(try await restarted.accounts.last?.refresh().lowestQuota?.percentRemaining == 30)
        connections.deleteField("FIXTURE_KEY", providerId: definition.id, config: work)
        await #expect(throws: (any Error).self) { try await b.refresh() }
        #expect(try await a.refresh().lowestQuota?.percentRemaining == 80)
    }

    @Test
    func realExtensionSubprocessReceivesOwnHomeAndKeysAndChecksIdentity() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let personal = try config(root, id: "personal", left: 80)
        let work = try config(root, id: "work", left: 30)
        let script = root.appendingPathComponent("probe.sh")
        try Data(#"""
#!/bin/sh
[ "$HOME" = "$CLAUDEBAR_ACCOUNT_HOME" ] || exit 1
[ "$CLAUDEBAR_API_KEY" = "$CLAUDEBAR_ACCOUNT_ID-key" ] || exit 2
left=$(cat "$HOME/left.txt")
printf '{"accountId":"%s","quotas":[{"type":"session","percentRemaining":%s}]}' "$CLAUDEBAR_ACCOUNT_ID" "$left"
"""#.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let suite = "extension-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let credentials = UserDefaultsCredentialRepository(defaults: defaults, keyPrefix: "fixture.")
        let connections = LegacyAccountConnections(credentials: credentials, settingsRoot: root)
        let settings = JSONSettingsRepository(store: .init(fileURL: root.appendingPathComponent("settings.json")))
        let manifest = ExtensionManifest(id: "fixture", name: "Fixture", version: "1", configFields: [.init(id: "apiKey", label: "API key", type: .secret, required: true)], sections: [.init(id: "usage", type: .quotaGrid, probeCommand: script.path)])
        let original = ExtensionProvider(manifest: manifest, probes: [:], settingsRepository: settings)
        let group = try ExtensionAccountConnections.make(original: original, result: .init(manifest: manifest, directory: root), settings: settings, connections: connections)
        try connections.saveField("personal-key", field: "apiKey", providerId: original.id, config: personal)
        try connections.saveField("work-key", field: "apiKey", providerId: original.id, config: work)
        let a = try #require(group.add(personal)); let b = try #require(group.add(work))
        #expect(try await a.refresh().lowestQuota?.percentRemaining == 80)
        #expect(try await b.refresh().lowestQuota?.percentRemaining == 30)
        settings.addAccount(personal, forProvider: original.id)
        settings.addAccount(work, forProvider: original.id)
        connections.deleteField("apiKey", providerId: original.id, config: work)
        let restored = try ExtensionAccountConnections.make(original: original, result: .init(manifest: manifest, directory: root), settings: settings, connections: connections)
        #expect(restored.accounts.count == 3)
        let restoredWork = try #require(restored.accounts.last)
        await #expect(throws: UsageError.authenticationRequired) { try await restoredWork.refresh() }
        #expect(try await a.refresh().lowestQuota?.percentRemaining == 80)
        try connections.saveField("work-key", field: "apiKey", providerId: original.id, config: work)
        try Data("#!/bin/sh\necho '{\"accountId\":\"wrong\",\"quotas\":[]}'\n".utf8).write(to: script)
        await #expect(throws: (any Error).self) { try await b.refresh() }
        #expect(b.snapshot == nil)
    }

    private func config(_ root: URL, id: String, left: Int) throws -> ProviderAccountConfig {
        let home = root.appendingPathComponent(id)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try Data("{\"left\":\(left)}".utf8).write(to: home.appendingPathComponent("usage.json"))
        try Data("\(left)".utf8).write(to: home.appendingPathComponent("left.txt"))
        return .init(accountId: id, label: id.capitalized, probeConfig: ["source": home.path])
    }
}

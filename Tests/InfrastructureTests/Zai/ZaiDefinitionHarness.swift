import DataSources
import Providers
import Foundation
import Domain
import Infrastructure
import Mockable

/// Turns the original fake cat response into a temporary native file. The
/// provider uses its real definition and filesystem reader, never a real login.
struct ZaiDefinitionHarness: Sendable {
    let executor: any CLIExecutor
    let network: any NetworkClient
    let settings: any ZaiSettingsRepository
    init(cliExecutor: any CLIExecutor = MockCLIExecutor(), networkClient: any NetworkClient = MockNetworkClient(), settingsRepository: any ZaiSettingsRepository, timeout: TimeInterval = 10) {
        executor = cliExecutor; network = networkClient; settings = settingsRepository
    }
    private struct Secrets: SecretStore {
        let settings: any ZaiSettingsRepository
        func secret(_ name: String, provider: String) -> String? { name == "apiKey" ? settings.getZaiApiKey() : nil }
    }
    private func source(configPath: String) throws -> DataSource {
        DataSources.make(try Providers.builtIn("zai").dataSources[0], providerId: "zai", cliExecutor: executor, network: network,
            makeTransport: { _,_,_,_ in MockRPCTransport() }, scripts: Providers.builtInScripts, secrets: Secrets(settings: settings),
            environment: { name in
                if name == "ZAI_CONFIG_PATH" { return configPath }
                if name == "GLM_AUTH_NAME" { return settings.glmAuthEnvVar() }
                return ProcessInfo.processInfo.environment[name]
            }, homeDirectory: FileManager.default.temporaryDirectory, now: { Date() })
    }
    private func materializeConfig(at url: URL) async {
        let path = settings.zaiConfigPath().isEmpty ? NSHomeDirectory()+"/.claude/settings.json" : settings.zaiConfigPath()
        if let result = try? await executor.execute(binary: "cat", args: [path], input: nil, timeout: 10, workingDirectory: nil, autoResponses: [:]) {
            try? Data(result.output.utf8).write(to: url)
        }
    }
    func isAvailable() async -> Bool {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".json")
        defer { try? FileManager.default.removeItem(at: url) }
        if (settings.getZaiApiKey() ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, executor.locate("claude") != nil {
            await materializeConfig(at: url)
        }
        return (try? await source(configPath: url.path).isReady()) ?? false
    }
    func probe() async throws -> UsageSnapshot {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".json")
        defer { try? FileManager.default.removeItem(at: url) }
        if executor.locate("claude") != nil || !(settings.getZaiApiKey() ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            await materializeConfig(at: url)
        }
        do { return try await source(configPath: url.path).fetchUsage() }
        catch let error as DataSourceError { throw error.reason }
    }
}

enum FixtureResetValue {
    case timestamp(Int64), string(String)
    var json: Any {
        switch self { case .timestamp(let value): value; case .string(let value): value }
    }
}

extension ZaiDefinitionHarness {
    private final class Header: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: String?
        func set(_ value: String?) { lock.withLock { stored = value } }
        var value: String? { lock.withLock { stored } }
    }
    private struct SavedKey: SecretStore {
        let key: String?
        func secret(_ name: String, provider: String) -> String? { key }
    }
    private static func fixtureSource(config: String, savedKey: String? = nil, network: any NetworkClient = MockNetworkClient()) throws -> (DataSource, URL) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".json")
        try Data(config.utf8).write(to: url)
        let executor = MockCLIExecutor()
        given(executor).locate(.any).willReturn("/usr/local/bin/claude")
        let source = DataSources.make(try Providers.builtIn("zai").dataSources[0], providerId: "zai", cliExecutor: executor, network: network,
            makeTransport: { _,_,_,_ in MockRPCTransport() }, scripts: Providers.builtInScripts, secrets: SavedKey(key: savedKey),
            environment: { $0 == "ZAI_CONFIG_PATH" ? url.path : nil }, homeDirectory: FileManager.default.temporaryDirectory, now: { Date() })
        return (source,url)
    }
    static func extractedKey(from config: String) async -> String? {
        let header = Header(), network = MockNetworkClient()
        given(network).request(.any).willProduce { @Sendable request in
            header.set(request.value(forHTTPHeaderField: "Authorization"))
            return (Data("{}".utf8),HTTPURLResponse(url: request.url!,statusCode:200,httpVersion:nil,headerFields:nil)!)
        }
        guard let (source,url) = try? fixtureSource(config: config,network: network) else { return nil }
        defer { try? FileManager.default.removeItem(at: url) }
        _ = try? await source.fetchResponse()
        return header.value?.replacingOccurrences(of: "Bearer ", with: "")
    }
    static func platformWithSavedKey(from config: String) -> String? {
        guard let (source,url) = try? fixtureSource(config: config,savedKey:"fixture-key") else { return nil }
        defer { try? FileManager.default.removeItem(at: url) }
        return source.value(of: .credential("baseURL"))
    }
    static func resetDate(_ value: FixtureResetValue) -> Date? {
        guard let definition = try? Providers.builtIn("zai"),
              let data = try? JSONSerialization.data(withJSONObject:["data":["limits":[["type":"TOKENS_LIMIT","percentage":0,"nextResetTime":value.json]]]]) else { return nil }
        let source = DataSources.make(definition.dataSources[0],providerId:"zai",scripts:Providers.builtInScripts)
        return (try? source.read(Response(body:data)))?.quotas.first?.resetsAt
    }
}

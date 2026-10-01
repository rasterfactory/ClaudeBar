import Domain
import Foundation
import Providers

@MainActor
public enum ExtensionAccountConnections {
    public static func make(original: ExtensionProvider, result: ExtensionScanResult,
                            settings: any MultiAccountSettingsRepository,
                            connections: LegacyAccountConnections = .shared,
                            makeCLI: @escaping @Sendable (AccountCommandContext) -> any CLIExecutor = { $0.executor() }) throws -> Provider {
        let endpoints = result.manifest.sections.compactMap { section -> ConfigField? in
            guard case .healthCheck = section.probeConfig else { return nil }
            return .init(id: "endpoint." + section.id, label: "\(section.id) account URL", type: .string, required: true)
        }
        connections.register(original.id, recipe: .init(source: .home, title: "Separate account home",
            help: "Scripts receive separate settings and CLAUDEBAR_ACCOUNT_ID. They must return that accountId in their JSON. Health checks need an account-specific URL.", options: [], fields: result.manifest.configFields + endpoints)) { config in
            let home = URL(fileURLWithPath: config.probeConfig["source"] ?? "").standardizedFileURL.resolvingSymlinksInPath()
            guard config.probeConfig["source"]?.hasPrefix("/") == true,
                  home != FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath() else { throw UsageError.authenticationRequired }
            let repository = ScopedExtensionConfig(values: config.probeConfig, credentials: connections.accountCredentials(original.id, config: config))
            let fields = result.manifest.configFields
            var environment = LegacyAccountConnections.environment(home: home)
            environment["CLAUDEBAR_ACCOUNT_ID"] = config.accountId
            environment["CLAUDEBAR_ACCOUNT_HOME"] = home.path
            let exclusions = LegacyAccountConnections.excludedEnvironment + ProcessInfo.processInfo.environment.keys.filter { $0.hasPrefix("CLAUDEBAR_") }
            let executor = makeCLI(.init(environment: environment, exclusions: exclusions, directory: home, interactive: false))
            var probes: [String: any UsageProbe] = [:]
            for section in result.manifest.sections {
                switch section.probeConfig {
                case .script(let command):
                    probes[section.id] = ScriptProbe(scriptPath: command, extensionDir: result.directory,
                        providerId: original.id, sectionType: section.type, timeout: section.timeout,
                        cliExecutor: executor, configRepository: repository, manifest: result.manifest, expectedAccountId: config.accountId)
                case .healthCheck(let defaultURL):
                    guard let raw = config.probeConfig["endpoint." + section.id], let url = URL(string: raw),
                          ["https", "http"].contains(url.scheme), url.host != nil, url != defaultURL else { throw UsageError.authenticationRequired }
                    probes[section.id] = HealthCheckProbe(url: url, providerId: original.id, timeout: section.timeout)
                }
            }
            return RequiredExtensionAccountSource(source: LegacyAccountUsageSource(ExtensionProvider(manifest: result.manifest, probes: probes,
                settingsRepository: settings, requireAllSections: true)), fields: fields, repository: repository)
        }
        return try connections.make(original, settings: settings)
    }
}

private struct ScopedExtensionConfig: ExtensionConfigRepository {
    let values: [String: String]
    let credentials: ScopedCredentialRepository
    func value(forFieldId id: String, extensionId: String) -> String? { values[id] }
    func secretValue(forFieldId id: String, extensionId: String) -> String? { credentials.get(forKey: "field." + id) }
    func setValue(_ value: String?, forFieldId: String, extensionId: String) {}
    func setSecretValue(_ value: String?, forFieldId: String, extensionId: String) {}
    func allValues(forExtensionId: String, fields: [ConfigField]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: fields.compactMap { field in
            let value = field.isSecret ? secretValue(forFieldId: field.id, extensionId: "") : values[field.id] ?? field.defaultValue
            return value.map { (field.id, $0) }
        })
    }
}

@MainActor
private final class RequiredExtensionAccountSource: AccountUsageSource {
    let source: LegacyAccountUsageSource
    let fields: [ConfigField]
    let repository: ScopedExtensionConfig
    var backgroundRefreshFloor: Duration? { source.backgroundRefreshFloor }
    init(source: LegacyAccountUsageSource, fields: [ConfigField], repository: ScopedExtensionConfig) {
        self.source = source; self.fields = fields; self.repository = repository
    }
    private var hasConfiguration: Bool {
        let values = repository.allValues(forExtensionId: "", fields: fields)
        return fields.filter(\.required).allSatisfy { values[$0.id]?.isEmpty == false }
    }
    func isAvailable() async -> Bool { guard hasConfiguration else { return false }; return await source.isAvailable() }
    func refresh(_ kind: RefreshKind) async throws -> UsageSnapshot {
        guard hasConfiguration else { throw UsageError.authenticationRequired }
        return try await source.refresh(kind)
    }
}

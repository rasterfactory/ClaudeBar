import DataSources
import Domain
import Foundation
import Providers

/// Custom definitions retain their original default connection. Added connections
/// resolve files under their chosen home and keys from a separate vault namespace.
@MainActor
public enum CustomAccountConnections {
    public static func make(_ definition: ProviderDefinition, settings: any MultiAccountSettingsRepository,
                            secrets: any SecretStore, connections: LegacyAccountConnections = .shared) throws -> Provider {
        let original = Providers.make(definition, settings: settings, secrets: secrets)
        let fields = fields(in: definition)
        connections.register(definition.id, recipe: .init(source: .home, title: "Separate account home",
            help: "Choose a separate home for this connection. Files stay within it; enter this account’s keys below. Shared environment credentials are never used.", options: [], fields: fields)) { config in
            let home = URL(fileURLWithPath: config.probeConfig["source"] ?? "").standardizedFileURL.resolvingSymlinksInPath()
            guard config.probeConfig["source"]?.hasPrefix("/") == true,
                  home != FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath() else { throw UsageError.authenticationRequired }
            let vault = FieldSecretStore(repository: connections.accountCredentials(definition.id, config: config))
            let environment = LegacyAccountConnections.environment(home: home)
            let sources = try definition.dataSources.map { try scoped($0, home: home, values: config.probeConfig) }
            let scopedDefinition = ProviderDefinition(profile: definition.profile, cli: definition.cli,
                enabledByDefault: definition.enabledByDefault, dataSources: sources, defaultDataSource: definition.defaultDataSource)
            let account = Provider(definition: scopedDefinition, settings: settings, makeDataSource: { source in
                DataSources.make(source, providerId: definition.id, scripts: Providers.builtInScripts, secrets: vault,
                    environment: { environment[$0] }, homeDirectory: home,
                    makeCLIExecutor: { call in
                        var env = call.environment.set
                        env.merge(environment) { _, scoped in scoped }
                        return DefaultCLIExecutor(environmentExclusions: LegacyAccountConnections.excludedEnvironment + call.environment.unset, environmentAdditions: env, isolatedDirectory: home)
                    },
                    makeTransport: { executable, arguments, supplied, _ in
                        var env = supplied ?? [:]
                        env.merge(environment) { _, scoped in scoped }
                        return try ProcessRPCTransport(executable: executable, arguments: arguments, environment: env, workingDirectory: home)
                    })
            })
            return LegacyAccountUsageSource(account.defaultAccount)
        }
        return try Provider(profile: definition.profile, sourceDefinition: definition, makeDefaultDataSource: { DataSources.make($0, providerId: definition.id, scripts: Providers.builtInScripts, secrets: secrets) }, cli: definition.cli,
            enabledByDefault: definition.enabledByDefault, settings: settings, accounts: settings.accounts(forProvider: definition.id),
            makeAccountSource: { config in
                guard let config else { return LegacyAccountUsageSource(original.defaultAccount) }
                return try connections.source(providerId: definition.id, config: config)
            })
    }

    private static func fields(in definition: ProviderDefinition) -> [ConfigField] {
        var found: [String: ConfigField] = [:]
        func visit(_ lookup: CredentialLookup) {
            switch lookup {
            case .setting(let key), .environment(let key): found[key] = .init(id: key, label: key, type: .secret)
            case .keychain(let item):
                let key = "keychain." + item.service
                found[key] = .init(id: key, label: "Separate Keychain service for \(item.service)", type: .string)
            case .firstOf(let lookups): lookups.forEach(visit)
            case .refreshing(let base, _): visit(base)
            case .jsonFile: break
            }
        }
        definition.dataSources.compactMap(\.credential).forEach(visit)
        return found.values.sorted { $0.id < $1.id }
    }

    private static func scoped(_ source: DataSourceDefinition, home: URL, values: [String: String]) throws -> DataSourceDefinition {
        func lookup(_ value: CredentialLookup) throws -> CredentialLookup {
            switch value {
            case .environment(let key): return .setting(key)
            case .setting: return value
            case .jsonFile: return value
            case .keychain(let item):
                guard let service = values["keychain." + item.service], !service.isEmpty, service != item.service else {
                    // An unavailable alternative must not fall back to the ordinary Keychain item.
                    return .setting("unconfigured-keychain." + item.service)
                }
                return .keychain(.init(service: service, fields: item.fields))
            case .firstOf(let lookups): return .firstOf(try lookups.map(lookup))
            case .refreshing(let base, let refresh): return .refreshing(try lookup(base), refresh)
            }
        }
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(source)) as! [String: Any]
        if let credential = source.credential { json["credential"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(lookup(credential))) }
        // Absolute local paths cannot silently escape the chosen account scope.
        func check(_ value: Any, key: String = "") throws {
            if let map = value as? [String: Any] { for (key, child) in map { try check(child, key: key) } }
            else if let array = value as? [Any] { for child in array { try check(child, key: key) } }
            else if let path = value as? String, (key == "path" || key == "requiresFiles") {
                let environment = LegacyAccountConnections.environment(home: home)
                let expanded = DataSources.expandPath(path, homeDirectory: home, environment: { environment[$0] })
                let canonical = URL(fileURLWithPath: expanded).standardizedFileURL.resolvingSymlinksInPath().path
                guard canonical.hasPrefix(home.path + "/") else { throw UsageError.executionFailed("This definition uses a shared absolute file path. Copy the definition and use a path under the separate account home.") }
            }
        }
        try check(json)
        return try JSONDecoder().decode(DataSourceDefinition.self, from: JSONSerialization.data(withJSONObject: json))
    }
}

private struct FieldSecretStore: SecretStore {
    let repository: ScopedCredentialRepository
    func secret(_ name: String, provider: String) -> String? { repository.get(forKey: "field." + name) }
}

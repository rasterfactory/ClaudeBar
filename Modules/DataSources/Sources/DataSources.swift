import Diagnostics
import Foundation

/// The module's factory: the only place a case of `Fetch`, `Mapping` or
/// `CredentialLookup` meets the one connection it needs. Callers get a
/// `DataSource` and never name a worker.
public enum DataSources {
    /// Starts a CLI for a JSON-RPC conversation.
    public typealias TransportFactory = @Sendable (_ executable: String, _ arguments: [String], _ environment: [String: String]?, _ workingDirectory: URL?) throws -> any RPCTransport

    /// The text of a mapping script, by the file name a definition gives.
    public typealias ScriptSource = @Sendable (_ file: String) -> String?

    /// A definition's path as the app sees it: `~` and `${VARIABLE:-default}` filled in.
    public static func expandPath(
        _ path: String,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: @escaping @Sendable (String) -> String? = { ProcessInfo.processInfo.environment[$0] }
    ) -> String {
        Paths.expand(path, homeDirectory: homeDirectory, environment: environment)
    }

    /// A data source on the real network, CLI, Keychain and file system.
    public static func make(
        _ definition: DataSourceDefinition,
        providerId: String,
        scripts: @escaping ScriptSource = { _ in nil },
        settingValue: @escaping @Sendable (String) -> String? = { _ in nil },
        browserCookies: any BrowserCookieReading = SystemBrowserCookies(),
        cloudWatch: (any CloudWatchClient)? = nil,
        secrets: (any SecretStore)? = nil,
        settings: (any SettingStore)? = nil,
        environment: @escaping @Sendable (String) -> String? = { ProcessInfo.processInfo.environment[$0] }
    ) -> DataSource {
        make(
            definition,
            providerId: providerId,
            makeCLIExecutor: CLIFetcher.system,
            network: URLSession.shared,
            makeTransport: { executable, arguments, environment, directory in
                try ProcessRPCTransport(executable: executable, arguments: arguments, environment: environment, workingDirectory: directory)
            },
            security: KeychainReader.system,
            scripts: scripts,
            settingValue: settingValue,
            browserCookies: browserCookies,
            cloudWatch: cloudWatch,
            secrets: secrets,
            settings: settings,
            environment: environment,
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
            now: { Date() }
        )
    }

    /// The same, with each connection handed in — how tests, here and in the
    /// modules above, run real definitions over stubbed connections. Every
    /// CLI call runs on `cliExecutor`, whatever environment it asks for.
    public static func make(
        _ definition: DataSourceDefinition,
        providerId: String,
        cliExecutor: any CLIExecutor,
        network: any NetworkClient,
        loopbackNetwork: any NetworkClient = InsecureLocalhostNetworkClient(),
        makeTransport: @escaping TransportFactory,
        security: @escaping @Sendable ([String]) -> (status: Int32, output: String) = { _ in (1, "") },
        scripts: @escaping ScriptSource = { _ in nil },
        settingValue: @escaping @Sendable (String) -> String? = { _ in nil },
        browserCookies: any BrowserCookieReading = SystemBrowserCookies(),
        cloudWatch: (any CloudWatchClient)? = nil,
        secrets: (any SecretStore)? = nil,
        settings: (any SettingStore)? = nil,
        environment: @escaping @Sendable (String) -> String?,
        homeDirectory: URL,
        now: @escaping @Sendable () -> Date,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) },
        calendar: Calendar = .current,
        directoryReader: any DirectoryReading = SystemDirectoryReader()
    ) -> DataSource {
        make(
            definition,
            providerId: providerId,
            makeCLIExecutor: { _ in cliExecutor },
            network: network,
            loopbackNetwork: loopbackNetwork,
            makeTransport: makeTransport,
            security: security,
            scripts: scripts,
            settingValue: settingValue,
            browserCookies: browserCookies,
            cloudWatch: cloudWatch,
            secrets: secrets,
            settings: settings,
            environment: environment,
            homeDirectory: homeDirectory,
            now: now, sleep: sleep, calendar: calendar, directoryReader: directoryReader
        )
    }

    static func make(
        _ definition: DataSourceDefinition,
        providerId: String,
        makeCLIExecutor: @escaping CLIFetcher.MakeExecutor,
        network: any NetworkClient,
        loopbackNetwork: any NetworkClient = InsecureLocalhostNetworkClient(),
        makeTransport: @escaping TransportFactory,
        security: @escaping KeychainReader.Security,
        scripts: @escaping ScriptSource,
        settingValue: @escaping @Sendable (String) -> String? = { _ in nil },
        browserCookies: any BrowserCookieReading = SystemBrowserCookies(),
        cloudWatch: (any CloudWatchClient)? = nil,
        secrets: (any SecretStore)?,
        settings: (any SettingStore)? = nil,
        environment: @escaping @Sendable (String) -> String?,
        homeDirectory: URL,
        now: @escaping @Sendable () -> Date,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) },
        calendar: Calendar = .current,
        directoryReader: any DirectoryReading = SystemDirectoryReader()
    ) -> DataSource {
        let fetcher: any Fetching = switch definition.fetch {
        case .commandPlan(let plan):
            CommandPlanFetcher(plan: plan, executor: makeCLIExecutor(CLICall(cli: plan.cli)), script: scripts(plan.script), now: now)
        case .httpSequence(let sequence):
            HTTPSequenceFetcher(sequence: sequence, network: network, now: now)
        case .httpFlow(let flow):
            HTTPFlowFetcher(flow: flow, network: network, script: scripts(flow.script), settingValue: settingValue, now: now, sleep: sleep)
        case .workflow(let flow):
            WorkflowFetcher(flow: flow, network: network, loopbackNetwork: loopbackNetwork, makeExecutor: makeCLIExecutor, script: scripts(flow.script), now: now, settingValue: settingValue)
        case .directory(let call):
            DirectoryFetcher(call: call, reader: directoryReader, homeDirectory: homeDirectory, environment: environment, calendar: calendar, now: now)
        case .cloudWatch(let query):
            CloudWatchFetcher(query:query,client:cloudWatch,settingValue:settingValue,calendar:calendar,now:now)
        case .http(let request):
            HTTPFetcher(request: request, network: network, now: now, settingValue: settingValue)
        case .jsonRpc(let call):
            JSONRPCFetcher(call: call, cliExecutor: makeCLIExecutor(CLICall(cli: call.cli)), makeTransport: makeTransport)
        case .cli(let call):
            CLIFetcher(call: call, makeExecutor: makeCLIExecutor)
        case .file(let call):
            FileFetcher(call: call, homeDirectory: homeDirectory, environment: environment)
        }

        let mapper: any Reading = switch definition.mapping {
        case .json(let mapping): JSONMapper(mapping: mapping, now: now)
        case .text(let mapping): TextMapper(mapping: mapping, now: now)
        case .script(let mapping): ScriptMapper(file: mapping.file, source: scripts(mapping.file), now: now)
        }

        var refresher: (any CredentialRefreshing)?
        var lookup = definition.credential
        if case .refreshing(let base, let oauth)? = lookup {
            refresher = OAuth2Refresher(refresh: oauth, network: network, now: now)
            lookup = base
        }

        if case .refreshingWithCLI(let base, _)? = lookup { lookup = base }
        let readers = Readers(environment: environment, homeDirectory: homeDirectory, security: security,
                              secrets: secrets, providerId: providerId, scripts: scripts, makeExecutor: makeCLIExecutor, browserCookies: browserCookies, settingValue: settingValue)
        if case .refreshingWithCLI(let base, let refresh)? = definition.credential {
            refresher = CLIRefresher(refresh: refresh, reader: readers.reader(for: base), makeExecutor: makeCLIExecutor, sleep: sleep)
        }
        return DataSource(
            definition: definition,
            providerId: providerId,
            credentials: lookup.map { readers.reader(for: $0) },
            refresher: refresher,
            fetcher: fetcher,
            mapper: mapper,
            contextFiles: definition.context.mapValues {
                JSONFileReader(file: $0, homeDirectory: homeDirectory, environment: environment)
            },
            recoveries: definition.recover.mapValues { recovery -> any Recovering in
                switch recovery {
                case .patchJSONFile(let path, let keys, let value):
                    JSONFilePatch(path: path, keys: keys, value: value, homeDirectory: homeDirectory, environment: environment)
                }
            },
            requiredFiles: definition.requiresFiles.map {
                Paths.expand($0, homeDirectory: homeDirectory, environment: environment)
            },
            settings: settings,
            now: now
        )
    }

    private struct Readers: Sendable {
        let environment: @Sendable (String) -> String?
        let homeDirectory: URL
        let security: KeychainReader.Security
        let secrets: (any SecretStore)?
        let providerId: String
        let scripts: ScriptSource
        let makeExecutor: CLIFetcher.MakeExecutor
        let browserCookies: any BrowserCookieReading
        let settingValue: @Sendable (String) -> String?

        func reader(for lookup: CredentialLookup) -> any CredentialFinding {
            switch lookup {
            case .script(let script):
                ScriptCredentialReader(definition: script, source: scripts(script.file), inputs: script.inputs.mapValues { reader(for: $0) }, environment: environment, homeDirectory: homeDirectory, executor: makeExecutor(CLICall(cli: "/bin/zsh")))
            case .environment(let name):
                EnvironmentReader(name: name, environment: environment)
            case .jsonFile(let file):
                JSONFileReader(file: file, homeDirectory: homeDirectory, environment: environment)
            case .keychain(let item):
                KeychainReader(item: item, security: security)
            case .sqlite(let file):
                SQLiteReader(file: file, homeDirectory: homeDirectory, environment: environment)
            case .claiming(let base, let claims):
                ClaimsReader(base: reader(for: base), claims: claims)
            case .bySetting(let choice):
                ChoiceReader(choice: choice, settingValue: settingValue, makeReader: reader(for:))
            case .tagged(let lookup, let facts):
                TaggedReader(base: reader(for: lookup), facts: facts)
            case .browserCookies(let query):
                BrowserCookieReader(query: query, cookies: browserCookies, settingValue: settingValue)
            case .setting(let name):
                SettingReader(name: name, providerId: providerId, secrets: secrets)
            case .firstOf(let lookups):
                FirstOfReader(readers: lookups.map { reader(for: $0) })
            case .accompanying(let base, let rule):
                CompanionsReader(base: reader(for: base), fields: rule.fields.mapValues { reader(for: $0) }, rule: rule)
            case .refreshing(let base, _), .refreshingWithCLI(let base, _):
                // A refresh nested inside `firstOf` is refreshed by the outer
                // data source only; reading still works.
                reader(for: base)
            }
        }
    }
}

/// `recover.patchJSONFile` — sets one value deep in a JSON file that already
/// exists, e.g. a CLI's "I trust this folder" flag. `true` only when it changed
/// the file, so a second failure is not retried forever.
struct JSONFilePatch: Recovering {
    let path: String
    let keys: [String]
    let value: JSONValue
    let homeDirectory: URL
    let environment: @Sendable (String) -> String?

    func recover() -> Bool {
        let url = URL(fileURLWithPath: Paths.expand(path, homeDirectory: homeDirectory, environment: environment))
        guard let data = try? Data(contentsOf: url),
              let document = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return false }
        let cliDirectory = CLIWorkingDirectory.resolve().path
        let keys = keys.map { $0.replacingOccurrences(of: "{{cliDirectory}}", with: cliDirectory) }
        guard let patched = Self.set(value.foundationObject, at: keys[...], in: document) else { return false }
        do {
            let output = try JSONSerialization.data(withJSONObject: patched, options: [.prettyPrinted, .sortedKeys])
            try output.write(to: url, options: .atomic)
            AppLog.probes.info("Patched \(path) so the CLI can run in the probe directory")
            return true
        } catch {
            AppLog.probes.error("Could not patch \(path): \(error.localizedDescription)")
            return false
        }
    }

    /// The document with the value set, or `nil` when it already had it or a
    /// key on the way is not an object.
    private static func set(_ value: Any, at keys: ArraySlice<String>, in object: [String: Any]) -> [String: Any]? {
        guard let key = keys.first else { return nil }
        var copy = object
        if keys.count == 1 {
            if let existing = object[key] as? NSObject, let new = value as? NSObject, existing.isEqual(new) { return nil }
            copy[key] = value
            return copy
        }
        let child: [String: Any]
        switch object[key] {
        case nil: child = [:]
        case let existing as [String: Any]: child = existing
        default: return nil
        }
        guard let updated = set(value, at: keys.dropFirst(), in: child) else { return nil }
        copy[key] = updated
        return copy
    }
}

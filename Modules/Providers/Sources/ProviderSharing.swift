import DataSources
import Foundation

extension ProviderDefinition {
    /// *Export…* — the definition as a file to share. A key is only ever a
    /// NAME in a definition (`"setting": "apiKey"`); its value lives in the
    /// vault, so no exported file holds one (USER_JOURNEYS F9). The origin is
    /// left out: whoever imports it decides.
    public func exported() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    /// *Key needed* — the settings this definition asks whoever adds it for.
    public var neededSettings: [String] {
        Array(Set(dataSources.flatMap { $0.credential.map(Self.settings(in:)) ?? [] })).sorted()
    }

    /// Fixed destinations declared by each authenticated connection.
    public var keyDestinations: [String] {
        Array(Set(dataSources.flatMap { source -> [String] in
            let requests: [HTTPRequest]
            switch source.fetch {
            case .workflow(let flow): requests = Array(flow.requests.values)
            case .http(let request): requests = source.credential == nil ? [] : [request]
            case .httpSequence(let sequence): requests = source.credential == nil ? [] : sequence.steps.map(\.request)
            case .httpFlow(let flow): requests = source.credential == nil ? [] : Array(flow.requests.values)
            default: requests = []
            }
            return requests.flatMap { request in
                ([request.url] + Array(request.urlBySetting?.values.values ?? Dictionary<String,String>().values)).map {URL(string:$0)?.host ?? $0}
            }
        })).sorted()
    }

    public var commands: [String] {
        var commands = dataSources.flatMap { source -> [String] in
            switch source.fetch {
            case .commandPlan(let plan): return ["\(plan.cli) (arguments from \(plan.script), up to 8 commands)"]
            case .cli(let call): return [([call.cli] + call.args).joined(separator:" ")]
            case .jsonRpc(let call): return [([call.cli] + call.args).joined(separator:" ")]
            case .workflow(let flow):
                return flow.commands.values.map { ([$0.cli] + $0.args).joined(separator:" ") } + (flow.alternateExecutables?.values.flatMap{$0} ?? [])
            case .http, .httpSequence, .file, .httpFlow, .directory, .cloudWatch: return []
            }
        }
        for source in dataSources {
            if case .refreshingWithCLI(_,let refresh)? = source.credential {
                commands.append(([refresh.call.cli] + refresh.call.args).joined(separator:" "))
            }
        }
        return Array(Set(commands)).sorted()
    }

    private static func settings(in lookup:CredentialLookup) -> [String] {
        switch lookup {
        case .script(let script):script.inputs.values.flatMap(settings(in:))
        case .setting(let name):[name]
        case .firstOf(let lookups):lookups.flatMap(settings(in:))
        case .refreshing(let base,_),.refreshingWithCLI(let base,_),.claiming(let base,_),.tagged(let base,_):settings(in:base)
        case .accompanying(let base,let rule):settings(in:base)+rule.fields.values.flatMap(settings(in:))
        case .bySetting(let choice):choice.values.values.flatMap(settings(in:))
        case .environment,.jsonFile,.keychain,.sqlite,.browserCookies:[]
        }
    }

}

/// *Import provider* — what a shared file would do, shown BEFORE anything is
/// saved or run (USER_JOURNEYS F10).
public struct ImportReview: Sendable, Equatable {
    /// As it will be saved: origin custom, its id kept unless taken.
    public let definition: ProviderDefinition
    /// "It will send your key to that address."
    public let sendsKeyTo: [String]
    /// The commands it runs — a person agrees to them first.
    public let runs: [String]
    /// "Key needed".
    public let needs: [String]
}

extension ProviderCatalog {
    /// Reads a shared file and says what it would do. Its id is kept unless a
    /// built-in or a saved provider already has it; then it gets a new one.
    public func review(_ file: Data) throws -> ImportReview {
        var definition = try ProviderDefinition.parse(file, origin: .custom)
        if Providers.builtInDefinitions[definition.id] != nil || custom().contains(where: { $0.id == definition.id }) {
            definition = definition.renamed(id: mintId(for: definition.profile.name))
        }
        return ImportReview(
            definition: definition,
            sendsKeyTo: definition.keyDestinations,
            runs: definition.commands,
            needs: definition.neededSettings
        )
    }

    /// *Add*: saves what the review showed.
    @discardableResult
    public func `import`(_ review: ImportReview) throws -> ProviderDefinition {
        try add(review.definition)
        return review.definition
    }
}

extension ProviderDefinition {
    /// The same definition under another id, as custom.
    func renamed(id: String) -> ProviderDefinition {
        ProviderDefinition(
            profile: ProviderProfile(id: id, name: profile.name, notificationName: profile.notificationName, links: profile.links, look: profile.look, origin: .custom),
            cli: cli,
            enabledByDefault: enabledByDefault,
            dataSources: dataSources,
            defaultDataSource: defaultDataSource,
            accounts: accounts
        )
    }
}

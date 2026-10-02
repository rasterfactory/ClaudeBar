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

    /// Where it sends a key — the host of every API that sends a credential.
    public var keyDestinations: [String] {
        Array(Set(dataSources.compactMap { source -> String? in
            guard source.credential != nil, case .http(let request) = source.fetch else { return nil }
            return URL(string: request.url)?.host ?? request.url
        })).sorted()
    }

    /// Every command it runs, as typed.
    public var commands: [String] {
        dataSources.compactMap { source in
            switch source.fetch {
            case .cli(let call): ([call.cli] + call.args).joined(separator: " ")
            case .jsonRpc(let call): ([call.cli] + call.args).joined(separator: " ")
            case .http, .file: nil
            }
        }
    }

    private static func settings(in lookup: CredentialLookup) -> [String] {
        switch lookup {
        case .setting(let name): [name]
        case .firstOf(let lookups): lookups.flatMap(settings(in:))
        case .refreshing(let base, _): settings(in: base)
        case .environment, .jsonFile, .keychain, .browserCookies: []
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
            profile: ProviderProfile(id: id, name: profile.name, links: profile.links, look: profile.look, origin: .custom),
            cli: cli,
            enabledByDefault: enabledByDefault,
            dataSources: dataSources,
            defaultDataSource: defaultDataSource,
            accounts: accounts
        )
    }
}

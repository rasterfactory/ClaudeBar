import DataSources
import Quotas
import Foundation

/// A provider as data — what ships in `Resources/Providers/<id>.json` for a
/// built-in, and what *Add Provider* will write for a custom one. Validated
/// when parsed, so a `Provider` is only ever made from a definition that
/// keeps the laws below.
public struct ProviderDefinition: Sendable, Equatable, Codable {
    public struct Links: Sendable, Equatable, Codable {
        public let dashboard: URL?
        public let status: URL?
        /// A different dashboard for some plans — `{ "claudeApi": "…" }`. Keyed
        /// by the plan names mapping scripts use (`claudeMax`, `claudePro`,
        /// `claudeApi`) or a badge as written.
        public let dashboardByPlan: [String: URL]

        public init(dashboard: URL? = nil, status: URL? = nil, dashboardByPlan: [String: URL] = [:]) {
            self.dashboard = dashboard
            self.status = status
            self.dashboardByPlan = dashboardByPlan
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.init(
                dashboard: try container.decodeIfPresent(URL.self, forKey: .dashboard),
                status: try container.decodeIfPresent(URL.self, forKey: .status),
                dashboardByPlan: try container.decodeIfPresent([String: URL].self, forKey: .dashboardByPlan) ?? [:]
            )
        }

        /// The dashboard for the plan the last usage reported, else the default.
        public func dashboard(for plan: AccountTier?) -> URL? {
            guard let plan, let url = dashboardByPlan[Self.key(for: plan)] else { return dashboard }
            return url
        }

        static func key(for plan: AccountTier) -> String {
            switch plan {
            case .claudeMax: "claudeMax"
            case .claudePro: "claudePro"
            case .claudeApi: "claudeApi"
            case .custom(let badge): badge
            }
        }
    }

    /// Stable forever: settings, the menu-bar choice and the lineup are keyed by it.
    /// WHO IT IS — the only place an id becomes a face.
    public var profile: ProviderProfile
    /// Stable forever: settings, the menu-bar choice and the lineup are keyed by it.
    public var id: String { profile.id }
    /// The CLI a person would run (`codex`), when there is one.
    public let cli: String?
    public let enabledByDefault: Bool
    public let dataSources: [DataSourceDefinition]
    public let defaultDataSource: String
    /// Logins added beside the default one, and how they differ.
    public let accounts: Accounts?

    /// Logins a person adds beside the default one (Codex, #326). An added
    /// login runs the SAME data sources with `patch` merged in (RFC 7396) and
    /// its saved values filling `{{account.<name>}}` — one definition, never
    /// a copy per login.
    public struct Accounts: Sendable, Equatable, Codable {
        /// The login's email names it — two logins of one product are told
        /// apart by who they are.
        public let nameFromEmail: Bool
        /// How a person adds one: by choosing the folder its login lives in.
        public let folder: Folder?
        /// By data source kind, what an added login changes — its own folder,
        /// its identity check, no fallback to the shared terminal. `null`
        /// leaves that data source out for added logins.
        public let patch: [String: JSONValue]

        /// `{ "savedAs": "codexHome", "default": "${CODEX_HOME:-~/.codex}",
        /// "accountId": { "fact": "account", "savedAs": "chatgptAccountId" } }`
        /// — the folder and the login's account id are saved as the account's
        /// values; `notSignedIn` is what a folder without a login says.
        public struct Folder: Sendable, Equatable, Codable {
            public struct AccountId: Sendable, Equatable, Codable {
                /// The credential value that names the login.
                public let fact: String
                public let savedAs: String

                public init(fact: String, savedAs: String) {
                    self.fact = fact
                    self.savedAs = savedAs
                }
            }

            public struct DerivedValue: Sendable, Equatable, Codable {
                public let prefix: String
                public let hashLength: Int
            }
            /// Values derived from the canonical selected folder, e.g. a scoped vault service.
            public let derivedValues: [String: DerivedValue]?
            public let savedAs: String
            /// The default login's folder — never added a second time.
            public let `default`: String?
            public let accountId: AccountId
            public let notSignedIn: String?

            public init(savedAs: String, default folder: String? = nil, accountId: AccountId, notSignedIn: String? = nil) {
                self.derivedValues = nil
                self.savedAs = savedAs
                self.default = folder
                self.accountId = accountId
                self.notSignedIn = notSignedIn
            }
        }

        public init(nameFromEmail: Bool = false, folder: Folder? = nil, patch: [String: JSONValue] = [:]) {
            self.nameFromEmail = nameFromEmail
            self.folder = folder
            self.patch = patch
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            nameFromEmail = try container.decodeIfPresent(Bool.self, forKey: .nameFromEmail) ?? false
            folder = try container.decodeIfPresent(Folder.self, forKey: .folder)
            patch = try container.decodeIfPresent([String: JSONValue].self, forKey: .patch) ?? [:]
        }
    }

    public init(
        profile: ProviderProfile,
        cli: String? = nil,
        enabledByDefault: Bool = true,
        dataSources: [DataSourceDefinition],
        defaultDataSource: String,
        accounts: Accounts? = nil
    ) {
        self.profile = profile
        self.cli = cli
        self.enabledByDefault = enabledByDefault
        self.dataSources = dataSources
        self.defaultDataSource = defaultDataSource
        self.accounts = accounts
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        profile = try container.decode(ProviderProfile.self, forKey: .profile)
        cli = try container.decodeIfPresent(String.self, forKey: .cli)
        enabledByDefault = try container.decodeIfPresent(Bool.self, forKey: .enabledByDefault) ?? true
        dataSources = try container.decode([DataSourceDefinition].self, forKey: .dataSources)
        defaultDataSource = try container.decode(String.self, forKey: .defaultDataSource)
        accounts = try container.decodeIfPresent(Accounts.self, forKey: .accounts)
    }

    enum CodingKeys: String, CodingKey {
        case profile, cli, enabledByDefault, dataSources, defaultDataSource, accounts
    }

    /// Decodes and checks the laws: at least one data source, kinds unique,
    /// the default and every fallback naming one of them.
    public static func parse(_ data: Data, origin: ProviderProfile.Origin = .builtIn) throws -> ProviderDefinition {
        var definition = try JSONDecoder().decode(ProviderDefinition.self, from: data)
        definition.profile.origin = origin
        try definition.validate()
        return definition
    }

    /// The data sources an added login runs: each one with `accounts.patch`
    /// merged in and `{{account.<name>}}` filled from the login's `values`.
    /// Throws when a value the definition needs is missing.
    public func dataSources(forAccount values: [String: String]) throws -> [DataSourceDefinition] {
        let patch = accounts?.patch ?? [:]
        return try dataSources.compactMap { source -> DataSourceDefinition? in
            var adapted = source
            if let change = patch[source.kind] {
                if case .null = change { return nil }
                adapted = try source.patched(with: change)
            }
            adapted = try adapted.filled(values, scope: "account")
            if let missing = adapted.unfilled(scope: "account").first {
                throw DefinitionError.missingAccountValue(id, missing)
            }
            return adapted
        }
    }

    public func validate() throws {
        guard !dataSources.isEmpty else { throw DefinitionError.noDataSources(id) }
        var kinds = Set<String>()
        for source in dataSources {
            guard kinds.insert(source.kind).inserted else {
                throw DefinitionError.duplicateKind(id, source.kind)
            }
        }
        guard kinds.contains(defaultDataSource) else {
            throw DefinitionError.unknownDataSource(id, defaultDataSource)
        }
        let handOffs = dataSources.flatMap { [$0.fallback?.to].compactMap { $0 } + Array($0.fallbackOn.values) }
        for kind in handOffs where !kinds.contains(kind) {
            throw DefinitionError.unknownDataSource(id, kind)
        }
    }

    public func dataSource(_ kind: String) -> DataSourceDefinition? {
        dataSources.first { $0.kind == kind }
    }
}

public enum DefinitionError: Error, Sendable, Equatable, LocalizedError {
    case noDataSources(String)
    case duplicateKind(String, String)
    case unknownDataSource(String, String)
    case missingFile(String)
    case missingAccountValue(String, String)
    case duplicateProvider(String)

    public var errorDescription: String? {
        switch self {
        case .noDataSources(let id): "Provider '\(id)' has no data sources"
        case .duplicateKind(let id, let kind): "Provider '\(id)' lists data source '\(kind)' twice"
        case .unknownDataSource(let id, let kind): "Provider '\(id)' names data source '\(kind)', which it doesn't have"
        case .missingFile(let name): "No provider definition named '\(name)'"
        case .missingAccountValue(let id, let name): "A '\(id)' account has no saved '\(name)'"
        case .duplicateProvider(let id): "A provider named '\(id)' already exists"
        }
    }
}

/// WHO IT IS — name, face and links; data, never a `switch` on id.
public struct ProviderProfile: Sendable, Equatable, Codable {
    /// Where the definition came from — the badge Settings prints.
    public enum Origin: String, Sendable, Equatable, Codable {
        /// "Built in" — shipped in the app.
        case builtIn
        /// "Custom" — made in *Add Provider*, copied or imported.
        case custom
        /// "Extension" — a manifest in `~/.claudebar/extensions/`.
        case `extension`
    }

    /// Stable forever: settings, the menu-bar choice and the lineup are keyed by it.
    public let id: String
    public let name: String
    public let links: ProviderDefinition.Links
    public let look: ProviderLook
    /// Not written in the file: whoever loads it knows where it came from.
    public var origin: Origin

    public init(id: String, name: String, links: ProviderDefinition.Links = .init(), look: ProviderLook = .init(), origin: Origin = .builtIn) {
        self.id = id
        self.name = name
        self.links = links
        self.look = look
        self.origin = origin
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(String.self, forKey: .id),
            name: try container.decode(String.self, forKey: .name),
            links: try container.decodeIfPresent(ProviderDefinition.Links.self, forKey: .links) ?? .init(),
            look: try container.decodeIfPresent(ProviderLook.self, forKey: .look) ?? .init()
        )
    }

    enum CodingKeys: String, CodingKey {
        case id, name, links, look
    }
}

/// The face — an SF Symbol, an icon in the asset catalog, and a colour with
/// the gradient it runs into, for light and dark. Plain data: the app turns it
/// into colours.
public struct ProviderLook: Sendable, Equatable, Codable {
    /// `[red, green, blue]`, each 0…1, as written in the definition.
    public struct RGB: Sendable, Equatable, Codable {
        public let red: Double
        public let green: Double
        public let blue: Double

        public init(_ red: Double, _ green: Double, _ blue: Double) {
            self.red = red
            self.green = green
            self.blue = blue
        }

        public init(from decoder: Decoder) throws {
            var container = try decoder.unkeyedContainer()
            self.init(try container.decode(Double.self), try container.decode(Double.self), try container.decode(Double.self))
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.unkeyedContainer()
            try container.encode(red)
            try container.encode(green)
            try container.encode(blue)
        }
    }

    /// One colour per appearance.
    public struct Shades: Sendable, Equatable, Codable {
        public let light: RGB
        public let dark: RGB

        public init(light: RGB, dark: RGB) {
            self.light = light
            self.dark = dark
        }
    }

    public let symbol: String?
    public let icon: String?
    public let color: Shades?
    /// Where the provider's gradient ends; it starts at `color`.
    public let gradientEnd: Shades?

    public init(symbol: String? = nil, icon: String? = nil, color: Shades? = nil, gradientEnd: Shades? = nil) {
        self.symbol = symbol
        self.icon = icon
        self.color = color
        self.gradientEnd = gradientEnd
    }
}

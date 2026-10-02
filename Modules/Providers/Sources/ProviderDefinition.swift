import DataSources
import Quotas
import CryptoKit
import Foundation

/// A provider as data — what ships in `Resources/Providers/<id>.json` for a
/// built-in, and what *Add Provider* will write for a custom one. Validated
/// when parsed, so a `Provider` is only ever made from a definition that
/// keeps the laws below.
public struct ProviderDefinition: Sendable, Equatable, Codable {
    public struct Links: Sendable, Equatable, Codable {
        public let dashboardBySetting: SettingURL?
        public let dashboard: URL?
        public let status: URL?
        /// A different dashboard for some plans — `{ "claudeApi": "…" }`. Keyed
        /// by the plan names mapping scripts use (`claudeMax`, `claudePro`,
        /// `claudeApi`) or a badge as written.
        public let dashboardByPlan: [String: URL]

        public init(dashboard: URL? = nil, status: URL? = nil, dashboardByPlan: [String: URL] = [:], dashboardBySetting: SettingURL? = nil) {
            self.dashboardBySetting = dashboardBySetting
            self.dashboard = dashboard
            self.status = status
            self.dashboardByPlan = dashboardByPlan
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.init(
                dashboard: try container.decodeIfPresent(URL.self, forKey: .dashboard),
                status: try container.decodeIfPresent(URL.self, forKey: .status),
                dashboardByPlan: try container.decodeIfPresent([String: URL].self, forKey: .dashboardByPlan) ?? [:],
                dashboardBySetting: try container.decodeIfPresent(SettingURL.self, forKey: .dashboardBySetting)
            )
        }

        /// The dashboard for the plan the last usage reported, else the default.
        public func dashboard(for plan: AccountTier?, value: String? = nil) -> URL? {
            if let text = dashboardBySetting?.resolve(value: value), let url = URL(string: text) { return url }
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
    /// Minimum spacing between background refreshes; manual refresh is unaffected.
    public let backgroundRefreshSeconds: TimeInterval?
    public let dataSources: [DataSourceDefinition]
    public let defaultDataSource: String
    /// Logins added beside the default one, and how they differ.
    public let accounts: Accounts?

    /// Logins a person adds beside the default one (Codex, #326). An added
    /// login runs the SAME data sources with `patch` merged in (RFC 7396) and
    /// its saved values filling `{{account.<name>}}` — one definition, never
    /// a copy per login.
    public struct Accounts: Sendable, Equatable, Codable {
        /// How a person adds one: by choosing the folder its login lives in.
        public let folder: Folder?
        /// …or by running the vendor's login into a new folder, which
        /// `folder` then checks — so a sign-in needs a folder rule.
        public let signIn: SignInCall?
        /// …or by filling in the account's own settings — an API key, a
        /// region. A secret field is kept in the vault, under the account.
        public let form: [Field]
        public let defaultLoginDescription: String?
        public let defaultReauthHelp: String?
        public let dataSourceField: String?

        /// One setting *Add Account*'s form asks for.
        public struct Field: Sendable, Equatable, Codable {
            public let id: String
            public let label: String
            public let secret: Bool
            public let vault: Bool
            public let defaultValue: String?
            public let pattern: String?
            /// Only ask for this field when these form choices match.
            public let when: [String: String]?
            public let absolutePath: Bool
            public let existingDirectory: Bool
            public let excludedPaths: [String]
            /// The only values it takes, when it is a choice.
            public let choices: [String]?

            public init(id: String, label: String, secret: Bool = false, vault: Bool = false, defaultValue: String? = nil, pattern: String? = nil, when: [String: String]? = nil, absolutePath: Bool = false, existingDirectory: Bool = false, excludedPaths: [String] = [], choices: [String]? = nil) {
                self.id = id
                self.label = label
                self.secret = secret
                self.vault = vault
                self.defaultValue = defaultValue
                self.pattern = pattern
                self.when = when
                self.absolutePath = absolutePath
                self.existingDirectory = existingDirectory
                self.excludedPaths = excludedPaths
                self.choices = choices
                self.absolutePath = absolutePath
            }

            public func isShown(values: [String: String]) -> Bool {
                when?.allSatisfy { values[$0.key] == $0.value } ?? true
            }

            public func isShown(values: [String: String]) -> Bool {
                when?.allSatisfy { values[$0.key] == $0.value } ?? true
            }

            public func isShown(values: [String: String]) -> Bool {
                when?.allSatisfy { values[$0.key] == $0.value } ?? true
            }

            public func isShown(values: [String: String]) -> Bool {
                when?.allSatisfy { values[$0.key] == $0.value } ?? true
            }

            public init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                id = try container.decode(String.self, forKey: .id)
                label = try container.decode(String.self, forKey: .label)
                secret = try container.decodeIfPresent(Bool.self, forKey: .secret) ?? false
                vault = try container.decodeIfPresent(Bool.self, forKey: .vault) ?? false
                defaultValue = try container.decodeIfPresent(String.self, forKey: .defaultValue)
                pattern = try container.decodeIfPresent(String.self, forKey: .pattern)
                when = try container.decodeIfPresent([String: String].self, forKey: .when)
                absolutePath = try container.decodeIfPresent(Bool.self, forKey: .absolutePath) ?? false
                existingDirectory = try container.decodeIfPresent(Bool.self, forKey: .existingDirectory) ?? false
                excludedPaths = try container.decodeIfPresent([String].self, forKey: .excludedPaths) ?? []
                if secret, defaultValue != nil {
                    throw DecodingError.dataCorruptedError(forKey: .defaultValue, in: container, debugDescription: "Secret account fields cannot embed a default value")
                }
                choices = try container.decodeIfPresent([String].self, forKey: .choices)
                absolutePath = try container.decodeIfPresent(Bool.self, forKey: .absolutePath) ?? false
            }
        }
        /// By data source kind, what an added login changes — its own folder,
        /// its identity check, no fallback to the shared terminal. `null`
        /// leaves that data source out for added logins.
        public let patch: [String: JSONValue]

        /// `{ "savedAs": "codexHome", "default": "${CODEX_HOME:-~/.codex}",
        /// "accountId": { "field": "account", "savedAs": "chatgptAccountId" } }`
        /// — the folder and the login's account id are saved as the account's
        /// values; `notSignedIn` is what a folder without a login says.
        public struct Folder: Sendable, Equatable, Codable {
            public struct AccountId: Sendable, Equatable, Codable {
                /// The field that identifies the login — a credential value,
                /// or a field of a context file (`$context.account.email`).
                public let field: IdentityField
                public let savedAs: String

                public init(field: IdentityField, savedAs: String) {
                    self.field = field
                    self.savedAs = savedAs
                }
            }

            /// A value worked out from the chosen folder rather than read from
            /// it: `prefix` + the first `sha256` hex digits of the folder's
            /// path — how Claude Code names a config folder's Keychain item.
            public struct Derived: Sendable, Equatable, Codable {
                public let prefix: String
                public let sha256: Int

                public init(prefix: String, sha256: Int) {
                    self.prefix = prefix
                    self.sha256 = sha256
                }
            }

            public let savedAs: String
            /// The default login's folder — never added a second time.
            public let `default`: String?
            public let accountId: AccountId
            /// Where the login's email is read. A credential's `email` unless
            /// the definition says otherwise.
            public let email: IdentityField
            /// Values saved beside the folder, by name, for `{{account.<name>}}`.
            public let derived: [String: Derived]
            public let notSignedIn: String?

            public init(
                savedAs: String,
                default folder: String? = nil,
                accountId: AccountId,
                email: IdentityField = .credential("email"),
                derived: [String: Derived] = [:],
                notSignedIn: String? = nil
            ) {
                self.savedAs = savedAs
                self.default = folder
                self.accountId = accountId
                self.email = email
                self.derived = derived
                self.notSignedIn = notSignedIn
            }

            public init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                savedAs = try container.decode(String.self, forKey: .savedAs)
                self.default = try container.decodeIfPresent(String.self, forKey: .default)
                accountId = try container.decode(AccountId.self, forKey: .accountId)
                email = try container.decodeIfPresent(IdentityField.self, forKey: .email) ?? .credential("email")
                derived = try container.decodeIfPresent([String: Derived].self, forKey: .derived) ?? [:]
                notSignedIn = try container.decodeIfPresent(String.self, forKey: .notSignedIn)
            }

            /// The account's values for a chosen folder: the folder, and what
            /// is derived from it.
            public func values(for folder: String) -> [String: String] {
                var values = [savedAs: folder]
                guard !derived.isEmpty else { return values }
                let hash = SHA256.hash(data: Data(folder.utf8)).map { String(format: "%02x", $0) }.joined()
                for (name, rule) in derived {
                    values[name] = rule.prefix + hash.prefix(max(0, rule.sha256))
                }
                return values
            }
        }

        /// The ways *Add Account* offers, easiest first.
        public var ways: [AddAccountWay] {
            [signIn.map { _ in .signIn }, folder.map { _ in .folder }, form.isEmpty ? nil : .form].compactMap { $0 }
        }

        public init(folder: Folder? = nil, signIn: SignInCall? = nil, form: [Field] = [], defaultLoginDescription: String? = nil, defaultReauthHelp: String? = nil, dataSourceField: String? = nil, patch: [String: JSONValue] = [:]) {
            self.defaultLoginDescription = defaultLoginDescription
            self.defaultReauthHelp = defaultReauthHelp
            self.signIn = signIn
            self.form = form
            self.dataSourceField = dataSourceField
            self.folder = folder
            self.patch = patch
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            defaultLoginDescription = try container.decodeIfPresent(String.self, forKey: .defaultLoginDescription)
            defaultReauthHelp = try container.decodeIfPresent(String.self, forKey: .defaultReauthHelp)
            folder = try container.decodeIfPresent(Folder.self, forKey: .folder)
            signIn = try container.decodeIfPresent(SignInCall.self, forKey: .signIn)
            form = try container.decodeIfPresent([Field].self, forKey: .form) ?? []
            dataSourceField = try container.decodeIfPresent(String.self, forKey: .dataSourceField)
            if signIn != nil, folder == nil {
                throw DecodingError.dataCorruptedError(forKey: .signIn, in: container,
                    debugDescription: "accounts.signIn needs accounts.folder to check the folder it signs into")
            }
            patch = try container.decodeIfPresent([String: JSONValue].self, forKey: .patch) ?? [:]
        }
    }

    public init(
        profile: ProviderProfile,
        cli: String? = nil,
        enabledByDefault: Bool = true,
        backgroundRefreshSeconds: TimeInterval? = nil,
        dataSources: [DataSourceDefinition],
        defaultDataSource: String,
        accounts: Accounts? = nil
    ) {
        self.profile = profile
        self.cli = cli
        self.enabledByDefault = enabledByDefault
        self.backgroundRefreshSeconds = backgroundRefreshSeconds
        self.dataSources = dataSources
        self.defaultDataSource = defaultDataSource
        self.accounts = accounts
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        profile = try container.decode(ProviderProfile.self, forKey: .profile)
        cli = try container.decodeIfPresent(String.self, forKey: .cli)
        enabledByDefault = try container.decodeIfPresent(Bool.self, forKey: .enabledByDefault) ?? true
        backgroundRefreshSeconds = try container.decodeIfPresent(TimeInterval.self, forKey: .backgroundRefreshSeconds)
        dataSources = try container.decode([DataSourceDefinition].self, forKey: .dataSources)
        defaultDataSource = try container.decode(String.self, forKey: .defaultDataSource)
        accounts = try container.decodeIfPresent(Accounts.self, forKey: .accounts)
    }

    enum CodingKeys: String, CodingKey {
        case profile, cli, enabledByDefault, backgroundRefreshSeconds, dataSources, defaultDataSource, accounts
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
        var selected: Set<String>?
        if let field = accounts?.dataSourceField, let kind = values[field] {
            guard dataSource(kind) != nil else { throw DefinitionError.unknownDataSource(id, kind) }
            var included = Set<String>(), pending = [kind]
            while let current = pending.popLast() {
                guard included.insert(current).inserted else { continue }
                if let source = dataSource(current) {
                    pending += [source.fallback?.to].compactMap { $0 } + Array(source.fallbackOn.values)
                }
            }
            selected = included
        }
        return try dataSources.compactMap { source -> DataSourceDefinition? in
            guard selected?.contains(source.kind) ?? true else { return nil }
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

    /// The same definition running `binary` instead of its CLI's name — the
    /// person's *CLI location* (#210). Only the executable changes: every
    /// CLI and JSON-RPC data source keeps its arguments, prompts and
    /// timing, and so does Add Account's sign-in. The value reaches a
    /// subprocess as argv[0], never a shell command line. An empty,
    /// whitespace-only or unchanged name is a no-op.
    public func runningCLI(_ binary: String) throws -> ProviderDefinition {
        let binary = binary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let cli, !binary.isEmpty, binary != cli else { return self }
        let sources = try dataSources.map { original -> DataSourceDefinition in
            var source = original
            if case .script(let script)? = source.credential {
                let changed = script.cli.filter { $0.value == cli }.mapValues { _ in JSONValue.string(binary) }
                if !changed.isEmpty {
                    source = try source.patched(with: .object(["credential": .object(["script": .object(["cli": .object(changed)])])]))
                }
            }
            let tag: String
            switch source.fetch {
            case .commandPlan(let plan) where plan.cli == cli: tag = "commandPlan"
            case .cli(let call) where call.cli == cli: tag = "cli"
            case .jsonRpc(let call) where call.cli == cli: tag = "jsonRpc"
            default: return source
            }
            if case .refreshingWithCLI(_, let refresh)? = source.credential, refresh.call.cli == cli {
                patch["credential"] = .object(["refresh": .object(["cli": .object(["call": .object(["cli": .string(binary)])])])])
            }
            return patch.isEmpty ? source : try source.patched(with: .object(patch))
        }
        var accounts = accounts
        if let signIn = accounts?.signIn, signIn.cli == cli {
            accounts = Accounts(
                folder: accounts?.folder,
                signIn: SignInCall(cli: binary, args: signIn.args, homeVariable: signIn.homeVariable,
                                   unset: signIn.unset, timeout: signIn.timeout, alsoAt: signIn.alsoAt),
                form: accounts?.form ?? [],
                defaultLoginDescription: accounts?.defaultLoginDescription,
                defaultReauthHelp: accounts?.defaultReauthHelp,
                dataSourceField: accounts?.dataSourceField,
                patch: accounts?.patch ?? [:]
            )
        }
        return ProviderDefinition(
            profile: profile,
            cli: cli,
            enabledByDefault: enabledByDefault,
            backgroundRefreshSeconds: backgroundRefreshSeconds,
            dataSources: sources,
            defaultDataSource: defaultDataSource,
            accounts: accounts
        )
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
    /// The longer product name used in alerts, when different from the menu label.
    public let notificationName: String?
    public let links: ProviderDefinition.Links
    public let look: ProviderLook
    /// Not written in the file: whoever loads it knows where it came from.
    public var origin: Origin

    public init(id: String, name: String, notificationName: String? = nil, links: ProviderDefinition.Links = .init(), look: ProviderLook = .init(), origin: Origin = .builtIn) {
        self.id = id
        self.name = name
        self.notificationName = notificationName
        self.links = links
        self.look = look
        self.origin = origin
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(String.self, forKey: .id),
            name: try container.decode(String.self, forKey: .name),
            notificationName: try container.decodeIfPresent(String.self, forKey: .notificationName),
            links: try container.decodeIfPresent(ProviderDefinition.Links.self, forKey: .links) ?? .init(),
            look: try container.decodeIfPresent(ProviderLook.self, forKey: .look) ?? .init()
        )
    }

    enum CodingKeys: String, CodingKey {
        case id, name, notificationName, links, look
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

/// A way *Add Account* offers — one per key of a definition's `accounts`.
public enum AddAccountWay: Sendable, Equatable {
    /// *Sign in with browser*
    case signIn
    /// *Choose Signed-in Folder*
    case folder
    /// The account's own settings — *Enter API key*
    case form
}

import Foundation

/// WHOSE KEY — the screen's *Key lookup order*. A closed sum, one case per JSON
/// tag; `firstOf` is the order itself, and `refresh` keeps an OAuth token fresh
/// and writes it back where it came from.
///
/// ```json
/// "credential": {
///   "jsonFile": { "path": "~/.codex/auth.json", "token": "$.tokens.access_token" },
///   "refresh":  { "oauth2": { "tokenURL": "…", "clientId": "…", "every": 691200 } }
/// }
/// ```
public indirect enum CredentialLookup: Sendable, Equatable {
    /// An environment variable holds the token.
    case environment(String)
    /// Pure selection over declared credential, file, CLI and environment inputs.
    case script(ScriptCredentialLookup)
    /// A JSON file on this Mac holds the token and its companions.
    case jsonFile(JSONFileCredential)
    /// A generic-password Keychain item whose password is JSON (or the token
    /// itself, with `"token": "$"`).
    case keychain(KeychainCredential)
    /// A key the person gave ClaudeBar (*API KEY*), kept in its vault.
    case setting(String)
    case sqlite(SQLiteCredential)
    case claiming(CredentialLookup, CredentialClaims)
    case browserCookies(BrowserCookieCredential)
    case browserCookies(BrowserCookieCredential)
    case bySetting(CredentialChoice)
    case tagged(CredentialLookup, [String: String])
    /// The first lookup that answers wins.
    case firstOf([CredentialLookup])
    /// A lookup whose token is kept fresh by an OAuth 2 refresh.
    case refreshing(CredentialLookup, OAuth2Refresh)
    case accompanying(CredentialLookup, CompanionLookups)
}

/// What a lookup found: the token and the values that travel with it
/// (`refreshToken`, `account`, `refreshedAt`, …), by name. A fetch substitutes
/// them into `{{name}}` placeholders. Never logged.
public struct Credential: Sendable, Equatable {
    public var values: [String: String]

    public init(_ values: [String: String]) {
        self.values = values
    }

    public var token: String? { values["token"] }

    public subscript(_ name: String) -> String? {
        get { values[name] }
        set { values[name] = newValue }
    }
}

/// A Keychain item and where in its JSON password each credential value lives.
public struct KeychainCredential: Sendable, Equatable, Codable {
    public let service: String
    /// Credential name → JSON path in the password. `token` is required.
    public let fields: [String: String]

    public init(service: String, fields: [String: String]) {
        self.service = service
        self.fields = fields
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: TagKey.self)
        service = try container.decode(String.self, forKey: TagKey("service"))
        var fields: [String: String] = [:]
        for key in container.allKeys where key.stringValue != "service" {
            fields[key.stringValue] = try container.decode(String.self, forKey: key)
        }
        self.fields = fields
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: TagKey.self)
        try container.encode(service, forKey: TagKey("service"))
        for (name, path) in fields {
            try container.encode(path, forKey: TagKey(name))
        }
    }
}

/// A JSON file and where in it each credential value lives. `path` may start
/// with `~/` or `${VARIABLE:-~}/`.
public struct JSONFileCredential: Sendable, Equatable, Codable {
    /// `~` expands to the home directory.
    public let path: String
    /// Credential name → JSON path in the file. `token` is required.
    public let fields: [String: String]
    public let select: RecordSelection?
    public let defaults: [String: String]

    public init(path: String, fields: [String: String], select: RecordSelection? = nil, defaults: [String: String] = [:]) {
        self.path = path
        self.fields = fields
        self.select = select
        self.defaults = defaults
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: TagKey.self)
        path = try container.decode(String.self, forKey: TagKey("path"))
        select = try container.decodeIfPresent(RecordSelection.self, forKey: TagKey("select"))
        defaults = try container.decodeIfPresent([String: String].self, forKey: TagKey("defaults")) ?? [:]
        var fields: [String: String] = [:]
        for key in container.allKeys where !["path", "select", "defaults"].contains(key.stringValue) {
            fields[key.stringValue] = try container.decode(String.self, forKey: key)
        }
        self.fields = fields
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: TagKey.self)
        try container.encode(path, forKey: TagKey("path"))
        try container.encodeIfPresent(select, forKey: TagKey("select"))
        if !defaults.isEmpty { try container.encode(defaults, forKey: TagKey("defaults")) }
        for (name, path) in fields {
            try container.encode(path, forKey: TagKey(name))
        }
    }
}

/// OAuth 2's refresh-token grant (RFC 6749 §6), with the two triggers a
/// provider can ask for: age since the last refresh, and an HTTP status.
public struct OAuth2Refresh: Sendable, Equatable, Codable {
    public let tokenURL: String
    public let clientId: String
    public let tokenPath: String?
    public let missingRefreshError: ErrorRef?
    public let retryFailure: ErrorRef?
    /// Refresh when the credential's `refreshedAt` is older than this many seconds.
    public let every: TimeInterval?
    /// Refresh once, and fetch once more, when the fetch answers one of these.
    public let onStatus: [Int]
    /// Error codes in the token endpoint's answer that mean "log in again".
    public let expiredCodes: [String]
    /// What to tell the person when the session has expired.
    public let hint: String?
    /// `form` (RFC 6749's default) or `json`.
    public let bodyFormat: BodyFormat
    public let scope: String?
    /// Refresh when the credential's `expiresAt` is within `skew` seconds.
    public let dueWhen: Expiry?

    public enum BodyFormat: String, Sendable, Equatable, Codable {
        case form
        case json
    }

    /// When a token expires: the credential value holding the instant, its
    /// unit, and how early to refresh. A missing value means "refresh now".
    public struct Expiry: Sendable, Equatable, Codable {
        public enum Unit: String, Sendable, Equatable, Codable {
            case seconds
            case milliseconds
            case iso8601
        }

        public let expiresAt: String
        public let unit: Unit
        public let skew: TimeInterval
        public let missingIsDue: Bool

        public init(expiresAt: String = "expiresAt", unit: Unit = .seconds, skew: TimeInterval = 0, missingIsDue: Bool = true) {
            self.expiresAt = expiresAt
            self.unit = unit
            self.skew = skew
            self.missingIsDue = missingIsDue
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            expiresAt = try container.decodeIfPresent(String.self, forKey: .expiresAt) ?? "expiresAt"
            unit = try container.decodeIfPresent(Unit.self, forKey: .unit) ?? .seconds
            skew = try container.decodeIfPresent(TimeInterval.self, forKey: .skew) ?? 0
            missingIsDue = try container.decodeIfPresent(Bool.self, forKey: .missingIsDue) ?? true
        }
    }

    public init(
        tokenURL: String,
        clientId: String,
        every: TimeInterval? = nil,
        onStatus: [Int] = [],
        expiredCodes: [String] = [],
        hint: String? = nil,
        bodyFormat: BodyFormat = .form,
        scope: String? = nil,
        dueWhen: Expiry? = nil,
        tokenPath: String? = nil,
        missingRefreshError: ErrorRef? = nil,
        retryFailure: ErrorRef? = nil
    ) {
        self.tokenURL = tokenURL
        self.clientId = clientId
        self.every = every
        self.onStatus = onStatus
        self.expiredCodes = expiredCodes
        self.hint = hint
        self.bodyFormat = bodyFormat
        self.scope = scope
        self.dueWhen = dueWhen
        self.tokenPath = tokenPath
        self.missingRefreshError = missingRefreshError
        self.retryFailure = retryFailure
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tokenURL = try container.decode(String.self, forKey: .tokenURL)
        clientId = try container.decode(String.self, forKey: .clientId)
        every = try container.decodeIfPresent(TimeInterval.self, forKey: .every)
        onStatus = try container.decodeIfPresent([Int].self, forKey: .onStatus) ?? []
        expiredCodes = try container.decodeIfPresent([String].self, forKey: .expiredCodes) ?? []
        hint = try container.decodeIfPresent(String.self, forKey: .hint)
        bodyFormat = try container.decodeIfPresent(BodyFormat.self, forKey: .bodyFormat) ?? .form
        scope = try container.decodeIfPresent(String.self, forKey: .scope)
        dueWhen = try container.decodeIfPresent(Expiry.self, forKey: .dueWhen)
        tokenPath = try container.decodeIfPresent(String.self, forKey: .tokenPath)
        missingRefreshError = try container.decodeIfPresent(ErrorRef.self, forKey: .missingRefreshError)
        retryFailure = try container.decodeIfPresent(ErrorRef.self, forKey: .retryFailure)
    }
}

// MARK: - JSON

extension CredentialLookup: Codable {
    private static let tags = ["environment", "jsonFile", "keychain", "setting", "firstOf", "sqlite", "script", "browserCookies", "bySetting"]

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: TagKey.self)
        var base: CredentialLookup
        switch try container.singleTag(of: Self.tags, in: "credential") {
        case "script":
            base = .script(try container.decode(ScriptCredentialLookup.self, forKey: TagKey("script")))
        case "environment":
            base = .environment(try container.decode(String.self, forKey: TagKey("environment")))
        case "jsonFile":
            base = .jsonFile(try container.decode(JSONFileCredential.self, forKey: TagKey("jsonFile")))
        case "keychain":
            base = .keychain(try container.decode(KeychainCredential.self, forKey: TagKey("keychain")))
        case "sqlite":
            base = .sqlite(try container.decode(SQLiteCredential.self, forKey: TagKey("sqlite")))
        case "bySetting":
            base = .bySetting(try container.decode(CredentialChoice.self, forKey: TagKey("bySetting")))
        case "browserCookies":
            base = .browserCookies(try container.decode(BrowserCookieCredential.self, forKey: TagKey("browserCookies")))
        case "setting":
            base = .setting(try container.decode(String.self, forKey: TagKey("setting")))
        default:
            base = .firstOf(try container.decode([CredentialLookup].self, forKey: TagKey("firstOf")))
        }
        if let claims = try container.decodeIfPresent(CredentialClaims.self, forKey: TagKey("claims")) {
            base = .claiming(base, claims)
        }
        if let companions = try container.decodeIfPresent(CompanionLookups.self, forKey: TagKey("companions")) {
            base = .accompanying(base, companions)
        }
        let facts = try container.decodeIfPresent([String: String].self, forKey: TagKey("as")) ?? [:]
        guard Set(facts.keys).isDisjoint(with: ["token", "refreshToken", "accessToken", "apiKey"]) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Credential tags cannot embed secret values"))
        }
        let tagged = facts.isEmpty ? base : .tagged(base, facts)
        if container.contains(TagKey("refresh")) {
            let refresh = try container.nestedContainer(keyedBy: TagKey.self, forKey: TagKey("refresh"))
            self = .refreshing(tagged, try refresh.decode(OAuth2Refresh.self, forKey: TagKey("oauth2")))
        } else {
            self = tagged
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: TagKey.self)
        try encodeBase(into: &container)
    }

    private func encodeBase(into container: inout KeyedEncodingContainer<TagKey>) throws {
        switch self {
        case .script(let script):
            try container.encode(script, forKey: TagKey("script"))
        case .environment(let name):
            try container.encode(name, forKey: TagKey("environment"))
        case .jsonFile(let file):
            try container.encode(file, forKey: TagKey("jsonFile"))
        case .keychain(let item):
            try container.encode(item, forKey: TagKey("keychain"))
        case .sqlite(let file):
            try container.encode(file, forKey: TagKey("sqlite"))
        case .claiming(let base, let claims):
            try base.encodeBase(into: &container)
            try container.encode(claims, forKey: TagKey("claims"))
        case .bySetting(let choice):
            try container.encode(choice, forKey: TagKey("bySetting"))
        case .tagged(let lookup, let facts):
            try lookup.encodeBase(into: &container)
            try container.encode(facts, forKey: TagKey("as"))
        case .browserCookies(let query):
            try container.encode(query, forKey: TagKey("browserCookies"))
        case .setting(let name):
            try container.encode(name, forKey: TagKey("setting"))
        case .firstOf(let lookups):
            try container.encode(lookups, forKey: TagKey("firstOf"))
        case .accompanying(let base, let companions):
            try base.encodeBase(into: &container)
            try container.encode(companions, forKey: TagKey("companions"))
        case .refreshing(let base, let refresh):
            try base.encodeBase(into: &container)
            var nested = container.nestedContainer(keyedBy: TagKey.self, forKey: TagKey("refresh"))
            try nested.encode(refresh, forKey: TagKey("oauth2"))
        }
    }
}

extension CredentialLookup {
    /// *KEY LOOKUP ORDER* — where the key is looked for, in order, as a person
    /// would find it: a file path, a Keychain item, `$VARIABLE`. Never a value.
    public var lookupOrder: [String] {
        switch self {
        case .script(let script): script.inputs.sorted { $0.key < $1.key }.flatMap { $0.value.lookupOrder } + script.files.values.sorted()
        case .environment(let name): ["$\(name)"]
        case .jsonFile(let file): [file.path]
        case .sqlite(let file): [file.path]
        case .claiming(let base, _): base.lookupOrder
        case .keychain(let item): ["Keychain “\(item.service)”"]
        case .bySetting(let choice): choice.values.keys.sorted().flatMap { choice.values[$0]?.lookupOrder ?? [] }
        case .tagged(let base, _): base.lookupOrder
        case .browserCookies: ["Signed-in browser cookies"]
        case .setting: ["API key saved in ClaudeBar"]
        case .firstOf(let lookups): lookups.flatMap(\.lookupOrder)
        case .refreshing(let base, _), .accompanying(let base, _): base.lookupOrder
        }
    }

    /// What to do when no key answers, or it can no longer be refreshed —
    /// the refresh's hint ("Run `claude` in terminal to log in again.").
    public var hint: String? {
        switch self {
        case .tagged(let base, _): base.hint
        case .bySetting(let choice): choice.values.keys.sorted().lazy.compactMap { choice.values[$0]?.hint }.first
        case .refreshing(let base, let refresh): refresh.hint ?? base.hint
        case .claiming(let base, _): base.hint
        case .accompanying(let base, _): base.hint
        case .firstOf(let lookups): lookups.lazy.compactMap(\.hint).first
        case .browserCookies, .script, .environment, .jsonFile, .keychain, .setting, .sqlite: nil
        case .environment, .jsonFile, .keychain, .setting, .browserCookies: nil
        }
    }
}

public struct SQLiteCredential: Sendable, Equatable, Codable {
    public let path: String
    public let query: String
    public let fields: [String: String]
}

public struct CredentialClaims: Sendable, Equatable, Codable {
    public let fields: [String: String]
    public let required: [String]
}

/// Select one credential record from a dictionary, preserving its exact key
/// for refresh writes. Preference names refer to the mapped credential fields.
public struct RecordSelection: Sendable, Equatable, Codable {
    public let records: String
    public let preferPresent: [String]
    public let newest: String?
    public let missingNewestIsFuture: Bool
    public let keyAs: String?
}

/// Request companions, found after the primary token. The primary token
/// never falls back to a companion, and companions cannot replace secrets.
public struct CompanionLookups: Sendable, Equatable, Codable {
    public let fields: [String: CredentialLookup]
    public let required: [String]
    public let missing: ErrorRef?
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fields = try container.decode([String: CredentialLookup].self, forKey: .fields)
        required = try container.decodeIfPresent([String].self, forKey: .required) ?? []
        missing = try container.decodeIfPresent(ErrorRef.self, forKey: .missing)
        guard Set(fields.keys).isDisjoint(with: ["token", "refreshToken", "idToken"]), Set(required).isSubset(of: Set(fields.keys)) else {
            throw DecodingError.dataCorruptedError(forKey: .fields, in: container, debugDescription: "Companions must name non-secret fields; every required field must be declared")
        }
    }
}

/// Credential scripts have no I/O API: each input is explicitly declared here.
public struct ScriptCredentialLookup: Sendable, Equatable, Codable {
    public let file: String
    public let inputs: [String: CredentialLookup]
    public let files: [String: String]
    public let environment: [String: String]
    public let constants: [String: String]
    public let cli: [String: String]
    public let timeout: TimeInterval
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        file = try c.decode(String.self, forKey: .file)
        inputs = try c.decodeIfPresent([String: CredentialLookup].self, forKey: .inputs) ?? [:]
        files = try c.decodeIfPresent([String: String].self, forKey: .files) ?? [:]
        environment = try c.decodeIfPresent([String: String].self, forKey: .environment) ?? [:]
        constants = try c.decodeIfPresent([String: String].self, forKey: .constants) ?? [:]
        cli = try c.decodeIfPresent([String: String].self, forKey: .cli) ?? [:]
        timeout = try c.decodeIfPresent(TimeInterval.self, forKey: .timeout) ?? 10
    }
}

public struct BrowserCookieCredential: Codable, Sendable, Equatable {
    public let domains: [String]
    public let domainsBySetting: SettingValues<[String]>?
    public let names: [String]
    public let format: Format
    public enum Format: String, Codable, Sendable { case value, header }
}

public struct CredentialChoice: Codable, Sendable, Equatable {
    public let setting: String
    public let `default`: String
    public let values: [String: CredentialLookup]
}

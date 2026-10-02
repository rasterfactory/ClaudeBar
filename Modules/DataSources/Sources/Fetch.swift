import Foundation

/// HOW TO GET THE BYTES — *Data fetching method*. A closed sum, one case per
/// JSON tag, because the decoder must know every tag and the picker is a fixed
/// list. A new protocol is a new case and one new worker.
public enum Fetch: Sendable, Equatable {
    case httpFlow(HTTPFlow)
    case workflow(Workflow)
    /// An HTTP request — the *API* choice.
    case http(HTTPRequest)
    /// A JSON-RPC conversation with a CLI over stdin/stdout.
    case jsonRpc(JSONRPCCall)
    /// A CLI run in a terminal, its screen captured — the *CLI* choice.
    case cli(CLICall)
    /// A file on this Mac that some tool keeps up to date — the *File* choice.
    case file(FileCall)
}

/// `{ "path": "~/.tool/usage.json" }` — `~` and `${VAR:-default}` expand.
public struct FileCall: Sendable, Equatable, Codable {
    public let path: String

    public init(path: String) {
        self.path = path
    }
}

/// `{{name}}` placeholders in `url`, `headers` and `body` are filled from the
/// credential at fetch time.
public struct SettingURL: Sendable, Equatable, Codable {
    public let setting: String?
    public let value: String?
    public let values: [String: String]

    public init(setting: String? = nil, value: String? = nil, values: [String: String]) {
        self.setting = setting
        self.value = value
        self.values = values
    }

    public func resolve(value selected: String? = nil) -> String? {
        guard let key = value ?? selected else { return nil }
        return values[key]
    }
}

public struct HTTPRequest: Sendable, Equatable, Codable {
    public let url: String
    public let urlBySetting: SettingURL?
    public let headersBySetting: SettingValues<[String: String]>?
    public let networkErrorPrefix: String?
    public let invalidResponseError: ErrorRef?
    public let propagateNetworkErrors: Bool
    public let ignoreResponseStatus: Bool
    public let method: String
    public let headers: [String: String]
    public let body: String?
    public let timeout: TimeInterval
    public let acceptedStatuses: [Int]?
    public let errors: [String: ErrorRef]

    public init(url: String, urlBySetting: SettingURL? = nil, headersBySetting: SettingValues<[String: String]>? = nil, networkErrorPrefix: String? = nil, invalidResponseError: ErrorRef? = nil, propagateNetworkErrors: Bool = false, ignoreResponseStatus: Bool = false, method: String = "GET", headers: [String: String] = [:], body: String? = nil, timeout: TimeInterval = 15, acceptedStatuses: [Int]? = nil, errors: [String: ErrorRef] = [:]) {
        self.url = url
        self.urlBySetting = urlBySetting
        self.headersBySetting = headersBySetting
        self.networkErrorPrefix = networkErrorPrefix
        self.invalidResponseError = invalidResponseError
        self.propagateNetworkErrors = propagateNetworkErrors
        self.ignoreResponseStatus = ignoreResponseStatus
        self.method = method
        self.headers = headers
        self.body = body
        self.timeout = timeout
        self.acceptedStatuses = acceptedStatuses
        self.errors = errors
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        url = try container.decode(String.self, forKey: .url)
        urlBySetting = try container.decodeIfPresent(SettingURL.self, forKey: .urlBySetting)
        headersBySetting = try container.decodeIfPresent(SettingValues<[String: String]>.self, forKey: .headersBySetting)
        networkErrorPrefix = try container.decodeIfPresent(String.self, forKey: .networkErrorPrefix)
        invalidResponseError = try container.decodeIfPresent(ErrorRef.self, forKey: .invalidResponseError)
        propagateNetworkErrors = try container.decodeIfPresent(Bool.self, forKey: .propagateNetworkErrors) ?? false
        ignoreResponseStatus = try container.decodeIfPresent(Bool.self, forKey: .ignoreResponseStatus) ?? false
        method = try container.decodeIfPresent(String.self, forKey: .method) ?? "GET"
        headers = try container.decodeIfPresent([String: String].self, forKey: .headers) ?? [:]
        body = try container.decodeIfPresent(String.self, forKey: .body)
        timeout = try container.decodeIfPresent(TimeInterval.self, forKey: .timeout) ?? 15
        acceptedStatuses = try container.decodeIfPresent([Int].self, forKey: .acceptedStatuses)
        errors = try container.decodeIfPresent([String: ErrorRef].self, forKey: .errors) ?? [:]
    }
}

/// Where a CLI runs. `dedicated` is ClaudeBar's own trusted directory, so a
/// CLI's folder-trust prompt never blocks a fetch.
public enum WorkingDirectory: String, Sendable, Equatable, Codable {
    /// ClaudeBar's own folder, so a CLI's folder-trust prompt never blocks it.
    case dedicated
}

/// Starts `cli args…`, sends the `handshake` in order, then `call`, and answers
/// with the call's result.
public struct JSONRPCCall: Sendable, Equatable, Codable {
    public struct Step: Sendable, Equatable, Codable {
        /// A request, answered before the next step.
        public let request: String?
        /// A notification, never answered.
        public let notify: String?
        public let params: JSONValue?

        public init(request: String? = nil, notify: String? = nil, params: JSONValue? = nil) {
            self.request = request
            self.notify = notify
            self.params = params
        }
    }

    /// A request after the call, its whole answer added to the response
    /// under `as` — e.g. the account behind the usage.
    public struct FollowUp: Sendable, Equatable, Codable {
        public let request: String
        public let params: JSONValue?
        public let `as`: String

        public init(request: String, params: JSONValue? = nil, as name: String) {
            self.request = request
            self.params = params
            self.as = name
        }
    }

    public let cli: String
    public let args: [String]
    public let workingDirectory: WorkingDirectory?
    public let handshake: [Step]
    public let call: String
    public let params: JSONValue?
    public let then: [FollowUp]
    /// Variables to remove from, and add to, the CLI's environment.
    public let environment: CLICall.Environment

    public init(
        cli: String,
        args: [String],
        workingDirectory: WorkingDirectory? = nil,
        handshake: [Step] = [],
        call: String,
        params: JSONValue? = nil,
        then: [FollowUp] = [],
        environment: CLICall.Environment = CLICall.Environment()
    ) {
        self.cli = cli
        self.args = args
        self.workingDirectory = workingDirectory
        self.handshake = handshake
        self.call = call
        self.params = params
        self.then = then
        self.environment = environment
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cli = try container.decode(String.self, forKey: .cli)
        args = try container.decodeIfPresent([String].self, forKey: .args) ?? []
        workingDirectory = try container.decodeIfPresent(WorkingDirectory.self, forKey: .workingDirectory)
        handshake = try container.decodeIfPresent([Step].self, forKey: .handshake) ?? []
        call = try container.decode(String.self, forKey: .call)
        params = try container.decodeIfPresent(JSONValue.self, forKey: .params)
        then = try container.decodeIfPresent([FollowUp].self, forKey: .then) ?? []
        environment = try container.decodeIfPresent(CLICall.Environment.self, forKey: .environment) ?? CLICall.Environment()
    }
}

/// Runs `cli args…` in a terminal, types `input`, answers prompts it
/// recognises from `autoResponses`, and returns what the screen showed.
public struct CLICall: Sendable, Equatable, Codable {
    /// Variables to remove from, and add to, the CLI's environment.
    public struct Environment: Sendable, Equatable, Codable {
        public let unset: [String]
        public let set: [String: String]

        public init(unset: [String] = [], set: [String: String] = [:]) {
            self.unset = unset
            self.set = set
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            unset = try container.decodeIfPresent([String].self, forKey: .unset) ?? []
            set = try container.decodeIfPresent([String: String].self, forKey: .set) ?? [:]
        }
    }

    /// Text that means the screen has finished drawing: a phrase, or
    /// `{ "row": "…" }` for a phrase that must end its row.
    public struct ReadyMarker: Sendable, Equatable, Codable {
        public let text: String
        public let endsRow: Bool

        public init(_ text: String, endsRow: Bool = false) {
            self.text = text
            self.endsRow = endsRow
        }

        private enum Keys: String, CodingKey { case row }

        public init(from decoder: Decoder) throws {
            if let text = try? decoder.singleValueContainer().decode(String.self) {
                self.init(text)
                return
            }
            let container = try decoder.container(keyedBy: Keys.self)
            self.init(try container.decode(String.self, forKey: .row), endsRow: true)
        }

        public func encode(to encoder: Encoder) throws {
            if endsRow {
                var container = encoder.container(keyedBy: Keys.self)
                try container.encode(text, forKey: .row)
            } else {
                var container = encoder.singleValueContainer()
                try container.encode(text)
            }
        }
    }

    /// How the captured output reaches the mapping.
    public enum Screen: String, Sendable, Equatable, Codable {
        /// The raw bytes, escape codes and all.
        case raw
        /// Drawn by a terminal emulator first, so a TUI's cursor moves land
        /// where they put the text.
        case rendered
    }

    public let cli: String
    public let args: [String]
    public let input: String?
    public let timeout: TimeInterval
    public let inputDelay: TimeInterval?
    public let checkAvailability: Bool
    public let wrapExecutionErrors: Bool
    public let workingDirectory: WorkingDirectory?
    /// Prompt text → what to type when it appears.
    public let autoResponses: [String: String]
    public let environment: Environment
    public let readyWhen: [ReadyMarker]
    public let screen: Screen
    /// Run in one session instead of a fresh one per run (#132).
    public let session: Session?

    public init(
        cli: String,
        args: [String] = [],
        input: String? = nil,
        timeout: TimeInterval = 20,
        inputDelay: TimeInterval? = nil,
        checkAvailability: Bool = false,
        wrapExecutionErrors: Bool = false,
        workingDirectory: WorkingDirectory? = nil,
        autoResponses: [String: String] = [:],
        environment: Environment = Environment(),
        readyWhen: [ReadyMarker] = [],
        screen: Screen = .raw,
        session: Session? = nil
    ) {
        self.cli = cli
        self.args = args
        self.input = input
        self.timeout = timeout
        self.inputDelay = inputDelay
        self.checkAvailability = checkAvailability
        self.wrapExecutionErrors = wrapExecutionErrors
        self.workingDirectory = workingDirectory
        self.autoResponses = autoResponses
        self.environment = environment
        self.readyWhen = readyWhen
        self.screen = screen
        self.session = session
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cli = try container.decode(String.self, forKey: .cli)
        args = try container.decodeIfPresent([String].self, forKey: .args) ?? []
        input = try container.decodeIfPresent(String.self, forKey: .input)
        timeout = try container.decodeIfPresent(TimeInterval.self, forKey: .timeout) ?? 20
        inputDelay = try container.decodeIfPresent(TimeInterval.self, forKey: .inputDelay)
        checkAvailability = try container.decodeIfPresent(Bool.self, forKey: .checkAvailability) ?? false
        wrapExecutionErrors = try container.decodeIfPresent(Bool.self, forKey: .wrapExecutionErrors) ?? false
        workingDirectory = try container.decodeIfPresent(WorkingDirectory.self, forKey: .workingDirectory)
        autoResponses = try container.decodeIfPresent([String: String].self, forKey: .autoResponses) ?? [:]
        environment = try container.decodeIfPresent(Environment.self, forKey: .environment) ?? Environment()
        readyWhen = try container.decodeIfPresent([ReadyMarker].self, forKey: .readyWhen) ?? []
        screen = try container.decodeIfPresent(Screen.self, forKey: .screen) ?? .raw
        session = try container.decodeIfPresent(Session.self, forKey: .session)
    }

    private enum CodingKeys: String, CodingKey {
        case cli, args, input, timeout, inputDelay, checkAvailability, wrapExecutionErrors, workingDirectory, autoResponses, environment, readyWhen, screen, session
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(cli, forKey: .cli)
        try container.encode(args, forKey: .args)
        try container.encodeIfPresent(input, forKey: .input)
        try container.encode(timeout, forKey: .timeout)
        try container.encodeIfPresent(inputDelay, forKey: .inputDelay)
        try container.encode(checkAvailability, forKey: .checkAvailability)
        try container.encode(wrapExecutionErrors, forKey: .wrapExecutionErrors)
        try container.encodeIfPresent(workingDirectory, forKey: .workingDirectory)
        try container.encode(autoResponses, forKey: .autoResponses)
        try container.encode(environment, forKey: .environment)
        try container.encode(readyWhen, forKey: .readyWhen)
        try container.encode(screen, forKey: .screen)
        try container.encodeIfPresent(session, forKey: .session)
    }
}

extension CLICall {
    /// The one session every run of a call shares (#132) — a poll that starts
    /// the CLI again and again keeps **one** session instead of leaving a
    /// fresh, empty one behind per run.
    ///
    /// Only the vendor's facts are data: the args that create the session and
    /// the args that resume it (`{{id}}` is the id), the output that says the
    /// session is gone, and the output — trusted only on a non-zero exit —
    /// that says this CLI build refuses the flags, so every later run falls
    /// back to the call's plain args. Which session a login is in is the
    /// worker's own memory, never part of a definition.
    public struct Session: Sendable, Equatable, Codable {
        /// Args appended to the call that creates the session.
        public let create: [String]
        /// Args appended to a run that resumes the session.
        public let resume: [String]
        /// Output meaning the session no longer exists — it is created again
        /// under a fresh id.
        public let recreateOn: [String]
        /// Output meaning the CLI rejected the session flags. Only honoured
        /// when the run also exited non-zero: the words alone can come from a
        /// prompt or a hook's transcript.
        public let unsupportedOn: [String]

        public init(create: [String], resume: [String], recreateOn: [String] = [], unsupportedOn: [String] = []) {
            self.create = create
            self.resume = resume
            self.recreateOn = recreateOn
            self.unsupportedOn = unsupportedOn
        }

        private enum CodingKeys: String, CodingKey { case create, resume, recreateOn, unsupportedOn }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            create = try container.decode([String].self, forKey: .create)
            resume = try container.decode([String].self, forKey: .resume)
            recreateOn = try container.decodeIfPresent([String].self, forKey: .recreateOn) ?? []
            unsupportedOn = try container.decodeIfPresent([String].self, forKey: .unsupportedOn) ?? []
        }
    }
}

// MARK: - JSON

extension Fetch: Codable {
    private static let tags = ["http", "jsonRpc", "cli", "file", "httpFlow", "workflow"]

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: TagKey.self)
        switch try container.singleTag(of: Self.tags, in: "fetch") {
        case "workflow": self = .workflow(try container.decode(Workflow.self, forKey: TagKey("workflow")))
        case "httpFlow": self = .httpFlow(try container.decode(HTTPFlow.self, forKey: TagKey("httpFlow")))
        case "http": self = .http(try container.decode(HTTPRequest.self, forKey: TagKey("http")))
        case "jsonRpc": self = .jsonRpc(try container.decode(JSONRPCCall.self, forKey: TagKey("jsonRpc")))
        case "file": self = .file(try container.decode(FileCall.self, forKey: TagKey("file")))
        default: self = .cli(try container.decode(CLICall.self, forKey: TagKey("cli")))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: TagKey.self)
        switch self {
        case .workflow(let flow): try container.encode(flow, forKey: TagKey("workflow"))
        case .httpFlow(let flow): try container.encode(flow, forKey: TagKey("httpFlow"))
        case .http(let request): try container.encode(request, forKey: TagKey("http"))
        case .jsonRpc(let call): try container.encode(call, forKey: TagKey("jsonRpc"))
        case .cli(let call): try container.encode(call, forKey: TagKey("cli"))
        case .file(let call): try container.encode(call, forKey: TagKey("file"))
        }
    }
}

/// A named choice controls a typed request or credential value.
public struct SettingValues<Value: Codable & Sendable & Equatable>: Codable, Sendable, Equatable {
    public let setting: String?
    public let value: String?
    public let values: [String: Value]
    public func resolve(selected: String?) -> Value? { (value ?? selected).flatMap { values[$0] } }
}

/// A bounded HTTP conversation; scripts select only named, fixed request templates.
public struct HTTPFlow: Codable, Sendable, Equatable {
    public let script: String
    public let requests: [String: HTTPRequest]
    public let settings: [String: String]?
    public let constants: [String: JSONValue]?
}

/// A pure planner over fixed commands and HTTP templates. No shell or script I/O.
public struct Workflow: Codable, Sendable, Equatable {
    public let script: String
    public let commands: [String: CLICall]
    public let alternateExecutables: [String: [String]]?
    public let requests: [String: HTTPRequest]
    public let loopbackRequests: [String]?
    public let continueOnError: [String: [String]]?
    public let constants: [String: JSONValue]?
    public let maxSteps: Int?
}

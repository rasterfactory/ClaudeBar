import Diagnostics
import Quotas
import Foundation

/// Fills `{{name}}` from a credential. `nil` when a placeholder has no value,
/// so a header like `ChatGPT-Account-Id: {{account}}` is simply left out.
enum Template {
    static func fill(_ text: String, with credential: Credential?) -> String? {
        var result = ""
        var rest = Substring(text)
        while let open = rest.range(of: "{{") {
            result += rest[..<open.lowerBound]
            guard let close = rest[open.upperBound...].range(of: "}}") else { return nil }
            let name = rest[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespaces)
            guard let value = credential?[name] else { return nil }
            result += value
            rest = rest[close.upperBound...]
        }
        return result + rest
    }
}

/// `http` — one HTTP request. 2xx answers with the response; anything else
/// becomes the `UsageError` a provider reports, keeping its status so a
/// refresh-and-retry can be tried.
struct HTTPFetcher: Fetching {
    let request: HTTPRequest
    let network: any NetworkClient
    let now: @Sendable () -> Date

    var settingValue: @Sendable (String) -> String? = { _ in nil }

    static let defaultRetryAfter: TimeInterval = 5 * 60

    func isReady() -> Bool { true }

    func fetch(with credential: Credential?) async throws -> Response {
        guard let urlText = Template.fill(request.urlBySetting?.resolve(value: request.urlBySetting?.setting.flatMap(settingValue)) ?? request.url, with: credential), let url = URL(string: urlText) else {
            throw UsageError.executionFailed("Invalid URL")
        }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method
        urlRequest.timeoutInterval = request.timeout
        for (name, value) in request.headers {
            if let filled = Template.fill(value, with: credential) {
                urlRequest.setValue(filled, forHTTPHeaderField: name)
            }
        }
        if let body = request.body, let filled = Template.fill(body, with: credential) {
            urlRequest.httpBody = Data(filled.utf8)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await network.request(urlRequest)
        } catch {
            AppLog.probes.error("HTTP fetch failed: \(error.localizedDescription)")
            throw UsageError.executionFailed("Network error: \(error.localizedDescription)")
        }
        guard let http = response as? HTTPURLResponse else {
            throw UsageError.executionFailed("Invalid response")
        }

        var headers: [String: String] = [:]
        for (name, value) in http.allHeaderFields {
            if let name = name as? String, let value = value as? String {
                headers[name] = value
            }
        }

        let accepted = request.acceptedStatuses?.contains(http.statusCode) ?? (200..<300).contains(http.statusCode)
        if accepted { return Response(status: http.statusCode, headers: headers, body: data) }
        if let error = request.errors[String(http.statusCode)] ?? request.errors["default"] {
            var reason = error.usageError
            if case .executionFailed(let message) = reason { reason = .executionFailed(message.replacingOccurrences(of: "{{status}}", with: String(http.statusCode))) }
            throw HTTPStatusError(status: http.statusCode, reason: reason)
        }
        switch http.statusCode {
                case 401, 403:
            throw HTTPStatusError(status: http.statusCode, reason: .authenticationRequired)
        case 429:
            let wait = Self.retryAfter(http.value(forHTTPHeaderField: "Retry-After"), now: now()) ?? Self.defaultRetryAfter
            throw HTTPStatusError(status: 429, reason: .rateLimited(retryAt: now().addingTimeInterval(wait)))
        default:
            AppLog.probes.error("HTTP fetch: status \(http.statusCode)")
            throw HTTPStatusError(status: http.statusCode, reason: .executionFailed("HTTP error: \(http.statusCode)"))
        }
    }

    /// `Retry-After` as seconds, or as an HTTP date.
    static func retryAfter(_ value: String?, now: Date) -> TimeInterval? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        // `0` or a negative wait is no answer: retrying at once would hammer the endpoint.
        if let seconds = TimeInterval(value) { return seconds > 0 ? seconds : nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        formatter.timeZone = TimeZone(identifier: "GMT")
        guard let date = formatter.date(from: value), date > now else { return nil }
        return date.timeIntervalSince(now)
    }
}

/// `jsonRpc` — starts the CLI, sends the handshake, then the call, and
/// answers with the call's whole message as the response body.
struct JSONRPCFetcher: Fetching {
    let call: JSONRPCCall
    let cliExecutor: any CLIExecutor
    let makeTransport: DataSources.TransportFactory

    func isReady() -> Bool {
        if cliExecutor.locate(call.cli) != nil { return true }
        AppLog.probes.error("'\(call.cli)' not found in PATH")
        return false
    }

    func fetch(with credential: Credential?) async throws -> Response {
        let directory = try call.workingDirectory?.resolve()
        let transport = try makeTransport(call.cli, call.args, Self.environment(call.environment), directory)
        defer { transport.close() }

        let session = RPCSession(transport: transport)
        for step in call.handshake {
            if let method = step.request {
                _ = try await session.request(method, params: step.params)
            } else if let method = step.notify {
                try session.notify(method, params: step.params)
            }
        }
        var message = try await session.request(call.call, params: call.params)
        for followUp in call.then {
            message[followUp.as] = try await session.request(followUp.request, params: followUp.params)
        }
        AppLog.probes.debug("\(call.cli) \(call.call) answered")
        return Response(body: try JSONSerialization.data(withJSONObject: message))
    }

    /// The app's environment changed as the call asks, or `nil` to inherit it
    /// untouched. Each process gets its own; the app's is never mutated.
    static func environment(_ change: CLICall.Environment) -> [String: String]? {
        guard !change.unset.isEmpty || !change.set.isEmpty else { return nil }
        var environment = ProcessInfo.processInfo.environment
        for name in change.unset { environment.removeValue(forKey: name) }
        environment.merge(change.set) { _, new in new }
        return environment
    }
}

/// Newline-delimited JSON-RPC over a transport: numbered requests, answers
/// matched by id, notifications skipped.
final class RPCSession: @unchecked Sendable {
    private let transport: any RPCTransport
    private var nextID = 1

    init(transport: any RPCTransport) {
        self.transport = transport
    }

    func request(_ method: String, params: JSONValue?) async throws -> [String: Any] {
        let id = nextID
        nextID += 1
        try send(["id": id, "method": method, "params": params?.foundationObject ?? [String: Any]()])
        while true {
            let data = try await transport.receive()
            guard let message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let messageID = message["id"] as? Int, messageID == id else {
                continue
            }
            if let error = message["error"] as? [String: Any], let text = error["message"] as? String {
                throw UsageError.executionFailed("RPC error: \(text)")
            }
            return message
        }
    }

    func notify(_ method: String, params: JSONValue?) throws {
        try send(["method": method, "params": params?.foundationObject ?? [String: Any]()])
    }

    private func send(_ payload: [String: Any]) throws {
        try transport.send(try JSONSerialization.data(withJSONObject: payload))
    }
}

/// `cli` — runs the CLI in a terminal and answers with what the screen showed,
/// drawn by a terminal emulator first when the call asks for it.
struct CLIFetcher: Fetching {
    /// The executor for one call: its environment changes and ready markers.
    typealias MakeExecutor = @Sendable (CLICall) -> any CLIExecutor

    let call: CLICall
    let makeExecutor: MakeExecutor
    /// The session this worker runs in — one per worker, and the provider
    /// makes a worker per login, so each login keeps its own (#132).
    private let session = SessionMemory()

    func isReady() -> Bool {
        makeExecutor(call).locate(call.cli) != nil
    }

    func fetch(with credential: Credential?) async throws -> Response {
        // Resolve a credential only at execution time. It never enters account
        // metadata, the shared definition, or the app's process environment.
        var additions: [String: String] = [:]
        for (name, template) in call.environment.set {
            guard let value = Template.fill(template, with: credential) else {
                throw UsageError.authenticationRequired
            }
            additions[name] = value
        }
        let call = CLICall(cli: call.cli, args: call.args, input: call.input, timeout: call.timeout,
            workingDirectory: call.workingDirectory, autoResponses: call.autoResponses,
            environment: .init(unset: call.environment.unset, set: additions), readyWhen: call.readyWhen,
            screen: call.screen, session: call.session, errors: call.errors, mode: call.mode)
        if let label = call.errors?.missing, makeExecutor(call).locate(call.cli) == nil {
            throw UsageError.cliNotFound(label)
        }
        let directory = try call.workingDirectory?.resolve()
        let result: CLIResult
        do {
            if let plan = call.session {
                result = try await CLISessionRunner(
                    call: call,
                    session: plan,
                    directory: directory,
                    makeExecutor: makeExecutor,
                    memory: session
                ).run()
            } else {
                result = try await makeExecutor(call).execute(
                    binary: call.cli,
                    args: call.args,
                    input: call.input,
                    timeout: call.timeout,
                    workingDirectory: directory,
                    autoResponses: call.autoResponses
                )
            }
        } catch {
            if let template = call.errors?.failed {
                let message: String
                if case UsageError.executionFailed(let reason) = error { message = reason }
                else { message = error.localizedDescription }
                throw UsageError.executionFailed(template.replacingOccurrences(of: "{{error}}", with: message))
            }
            if let usage = error as? UsageError { throw usage }
            throw UsageError.executionFailed(error.localizedDescription)
        }
        if result.exitCode != 0, let template = call.errors?.nonzero {
            throw UsageError.executionFailed(template.replacingOccurrences(of: "{{exitCode}}", with: String(result.exitCode)))
        }
        AppLog.probes.debug("\(call.cli) screen captured (\(result.output.count) chars)")
        switch call.screen {
        case .raw: return Response(text: result.output)
        case .rendered: return Response(text: TerminalRenderer(cols: 160, rows: 50).render(result.output))
        }
    }

    /// The real terminal: `DefaultCLIExecutor` with the call's environment and ready markers.
    static let system: MakeExecutor = { call in
        if call.mode == .pipes { return PipeCLIExecutor(environment: call.environment) }
        return DefaultCLIExecutor(
            environmentExclusions: call.environment.unset,
            environmentAdditions: call.environment.set,
            completionRule: call.readyWhen.isEmpty
                ? nil
                : CLICompletionRule(readyMarkers: call.readyWhen.map { CLICompletionRule.Marker($0.text, endsRow: $0.endsRow) })
        )
    }
}

/// `file` — reads a file some tool keeps up to date. Ready while it exists.
struct FileFetcher: Fetching {
    let call: FileCall
    let homeDirectory: URL
    let environment: @Sendable (String) -> String?

    private var path: String {
        Paths.expand(call.path, homeDirectory: homeDirectory, environment: environment)
    }

    func isReady() -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    func fetch(with credential: Credential?) async throws -> Response {
        guard let data = FileManager.default.contents(atPath: path) else {
            throw UsageError.executionFailed("No file at \(call.path)")
        }
        return Response(body: data)
    }
}
private extension WorkingDirectory {
    func resolve() throws -> URL {
        switch self {
        case .dedicated: return CLIWorkingDirectory.resolve()
        case .path(let value):
            guard value.hasPrefix("/") else { throw UsageError.executionFailed("CLI working directory must be absolute") }
            return URL(fileURLWithPath: value, isDirectory: true)
        }
    }
}

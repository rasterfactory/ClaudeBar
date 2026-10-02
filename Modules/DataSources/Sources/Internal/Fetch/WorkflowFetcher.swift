import Foundation
import JavaScriptCore
import Quotas

struct WorkflowFetcher: Fetching, ReadinessChecking {
    let flow: Workflow
    let network: any NetworkClient
    let loopbackNetwork: any NetworkClient
    let makeExecutor: CLIFetcher.MakeExecutor
    let script: String?
    let now: @Sendable () -> Date
    let settingValue: @Sendable (String) -> String?
    func isReady() -> Bool { script != nil && !(flow.commands.isEmpty && flow.requests.isEmpty) }
    func checkReadiness(with credential: Credential?) async -> Bool {
        guard let response = try? await run(with: credential, checking: true),
              let object = try? JSONSerialization.jsonObject(with: response.body) as? [String: Bool] else { return false }
        return object["available"] == true
    }
    func fetch(with credential: Credential?) async throws -> Response { try await run(with: credential, checking: false) }
    private func run(with original: Credential?, checking: Bool) async throws -> Response {
        guard isReady(), let script else { throw UsageError.parseFailed("Missing workflow script") }
        let limit = flow.maxSteps ?? 128
        guard (1...128).contains(limit) else { throw UsageError.executionFailed("Invalid workflow step limit") }
        var responses: [String: [String: JSONValue]] = [:]
        var attempts: [String: Int] = [:]
        var protected = Array(original?.values.values ?? Dictionary<String,String>().values)
        for step in 0...limit {
            try Task.checkCancellation()
            let input: [String: JSONValue] = [
                "responses": .object(responses.mapValues { .object($0) }),
                "context": .object([
                    "credential": .object((original?.values ?? [:]).mapValues { .string($0) }),
                    "now": .number(now().timeIntervalSince1970), "availability": .bool(checking),
                    "attempts": .object(attempts.mapValues { .number(Double($0)) }),
                    "constants": .object(flow.constants ?? [:])
                ])
            ]
            guard let context = JSContext() else { throw UsageError.executionFailed("JavaScriptCore is unavailable") }
            var failed = false
            context.exceptionHandler = { _, _ in failed = true }
            let encoded = try JSONEncoder().encode(input)
            context.setObject(String(decoding: encoded, as: UTF8.self), forKeyedSubscript: "__input" as NSString)
            context.evaluateScript(script)
            let output = context.evaluateScript("JSON.stringify(next(JSON.parse(__input).responses, JSON.parse(__input).context))")
            guard !failed else { throw UsageError.parseFailed("Workflow script failed") }
            guard let text = output?.toString(), let data = text.data(using: .utf8),
                  let action = try? JSONDecoder().decode(Action.self, from: data) else { throw UsageError.parseFailed("Invalid workflow output") }
            if let error = action.error { throw Self.redacted(error, values: protected).usageError }
            if let result = action.result, action.command == nil, action.request == nil {
                return Response(body: try JSONEncoder().encode(result))
            }
            guard step < limit, (action.command == nil) != (action.request == nil) else { throw UsageError.executionFailed("Workflow request limit exceeded") }
            let name = action.command ?? action.request!
            var values = original?.values ?? [:]
            for (key,value) in action.values ?? [:] where values[key] == nil { values[key] = value }
            protected.append(contentsOf: (action.values ?? [:]).values.filter { !$0.isEmpty })
            attempts[name, default: 0] += 1
            do {
                if let command = action.command {
                    guard let call = flow.commands[command], !call.cli.contains("{{") else { throw UsageError.executionFailed("Unknown workflow command") }
                    // Only declared argument strings change. The executable stays fixed.
                    let arguments = try call.args.map { text -> String in
                        guard let filled = Template.fill(text, with: Credential(values)) else { throw UsageError.executionFailed("Missing workflow argument") }
                        return filled
                    }
                    let directory = call.workingDirectory == .dedicated ? CLIWorkingDirectory.resolve() : nil
                    let executable = FileManager.default.isExecutableFile(atPath: call.cli) ? call.cli
                        : flow.alternateExecutables?[command]?.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) ?? call.cli
                    let result = try await makeExecutor(call).execute(binary: executable,args: arguments,input: call.input,timeout: call.timeout,workingDirectory: directory,autoResponses: call.autoResponses)
                    responses[name] = ["text": .string(result.output), "exitCode": .number(Double(result.exitCode)), "json": (try? JSONDecoder().decode(JSONValue.self,from:Data(result.output.utf8))) ?? .null]
                } else {
                    guard !checking, let request = flow.requests[name] else { throw UsageError.executionFailed("Unknown workflow request") }
                    let client: any NetworkClient = flow.loopbackRequests?.contains(name) == true ? LoopbackOnlyNetworkClient(base: loopbackNetwork) : network
                    let response = try await HTTPFetcher(request: request,network: client,now: now,settingValue: settingValue).fetch(with: Credential(values))
                    responses[name] = ["text": .string(response.text), "status": response.status.map { .number(Double($0)) } ?? .null,
                        "json": (try? JSONDecoder().decode(JSONValue.self,from:response.body)) ?? .null]
                }
            } catch is CancellationError { throw CancellationError() }
            catch {
                try Task.checkCancellation()
                let tag = Self.tag(error)
                let allowed = flow.continueOnError?[name] ?? []
                guard checking || allowed.contains("*") || allowed.contains(tag) else { throw error }
                // Only a failure category reaches the planner; exceptions may contain credentials.
                responses[name] = ["text": .string(""), "status": .null, "exitCode": .null, "json": .null, "failure": .string(tag)]
            }
        }
        throw UsageError.executionFailed("Workflow request limit exceeded")
    }
    private static func redacted(_ error: ErrorRef, values: [String]) -> ErrorRef {
        func clean(_ text: String) -> String { values.filter { !$0.isEmpty }.reduce(text) { $0.replacingOccurrences(of: $1, with: "[redacted]") } }
        return switch error {
        case .executionFailed(let text): .executionFailed(clean(text))
        case .parseFailed(let text): .parseFailed(clean(text))
        case .sessionExpired(let text): .sessionExpired(text.map(clean))
        case .cliNotFound(let text): .cliNotFound(clean(text))
        default: error
        }
    }
    private static func tag(_ error: Error) -> String {
        if let error = error as? UsageError { return error.tag }
        if let error = error as? InteractiveRunner.RunError, case .timedOut = error { return "timeout" }
        return "executionFailed"
    }
    private struct Action: Decodable {
        let command: String?
        let request: String?
        let values: [String: String]?
        let result: JSONValue?
        let error: ErrorRef?
    }
}

/// An explicitly local template cannot send credentials to a remote host.
struct LoopbackOnlyNetworkClient: NetworkClient {
    let base: any NetworkClient
    func request(_ request: URLRequest) async throws -> (Data, URLResponse) {
        guard let url = request.url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              ["127.0.0.1", "localhost", "::1"].contains(url.host?.lowercased() ?? ""),
              let port = url.port, (1...65535).contains(port) else { throw UsageError.executionFailed("Invalid loopback URL") }
        return try await base.request(request)
    }
}

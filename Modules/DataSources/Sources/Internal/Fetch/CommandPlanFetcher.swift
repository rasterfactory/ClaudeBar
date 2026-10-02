import Foundation
import JavaScriptCore
import Quotas

/// `commandPlan` — each command must exit successfully before its output
/// reaches the next step. The planner has no host I/O and cannot change the
/// executable. Prior responses and a fixed clock are its only inputs.
struct CommandPlanFetcher: Fetching {
    let plan: CommandPlan
    let executor: any CLIExecutor
    let script: String?
    let now: @Sendable () -> Date

    func isReady() -> Bool { executor.locate(plan.cli) != nil }

    func fetch(with credential: Credential?) async throws -> Response {
        guard let executable = executor.locate(plan.cli) else { throw UsageError.cliNotFound(plan.cli) }
        guard let script else { throw UsageError.parseFailed("Command planner '\(plan.script)' is missing") }
        let clock = now().timeIntervalSince1970
        var responses: [String] = []
        // Eight commands plus one final planner invocation. Never a shell.
        for step in 0...8 {
            guard let context = JSContext() else { throw UsageError.executionFailed("JavaScriptCore is unavailable") }
            var exception: String?
            context.exceptionHandler = { _, value in exception = value?.toString() }
            let input = try JSONSerialization.data(withJSONObject: ["responses": responses, "context": ["now": clock]])
            context.setObject(String(decoding: input, as: UTF8.self), forKeyedSubscript: "__input" as NSString)
            context.evaluateScript(script)
            let value = context.evaluateScript("JSON.stringify(next(JSON.parse(__input).responses, JSON.parse(__input).context))")
            if let exception { throw UsageError.parseFailed("Command planner failed: \(exception)") }
            guard let text = value?.toString(), let bytes = text.data(using: .utf8),
                  let result = try? JSONDecoder().decode(Step.self, from: bytes) else {
                throw UsageError.parseFailed("Invalid command planner output")
            }
            if let error = result.error { throw error.usageError }
            if let done = result.done, result.args == nil {
                return Response(body: try JSONEncoder().encode(done))
            }
            guard step < 8, let args = result.args, result.done == nil,
                  !args.isEmpty, args.allSatisfy({ !$0.contains("\0") }) else {
                throw UsageError.executionFailed("Invalid command or command limit exceeded")
            }
            let response = try await executor.execute(binary: executable, args: args, input: nil,
                timeout: plan.timeout, workingDirectory: nil, autoResponses: [:])
            guard response.exitCode == 0 else {
                throw UsageError.executionFailed("\(plan.cli) \(args[0]) exited with code \(response.exitCode)")
            }
            responses.append(response.output)
        }
        throw UsageError.executionFailed("Command limit exceeded")
    }

    private struct Step: Decodable {
        let args: [String]?
        let done: JSONValue?
        let error: ErrorRef?
    }
}

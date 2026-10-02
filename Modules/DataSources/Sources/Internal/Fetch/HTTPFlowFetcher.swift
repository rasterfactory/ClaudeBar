import Foundation
import JavaScriptCore
import Quotas

/// The only I/O boundary for a flow: the script has no I/O and can select
/// only the request templates the definition declared. Eight requests maximum.
struct HTTPFlowFetcher: Fetching {
    let flow: HTTPFlow
    let network: any NetworkClient
    let script: String?
    let settingValue: @Sendable (String) -> String?
    let now: @Sendable () -> Date
    let sleep: @Sendable (TimeInterval) async throws -> Void
    func isReady() -> Bool { !flow.requests.isEmpty && flow.requests.count <= 8 }
    func fetch(with original: Credential?) async throws -> Response {
        guard isReady(), let script else { throw UsageError.parseFailed("Missing or invalid HTTP flow") }
        let settings = (flow.settings ?? [:]).compactMapValues(settingValue)
        var responses: [String: Response] = [:]
        var attempts: [String: Int] = [:]
        for step in 0...8 {
            guard let context = JSContext() else { throw UsageError.executionFailed("JavaScriptCore is unavailable") }
            var failed = false
            context.exceptionHandler = { _, _ in failed = true }
            let responseValues = responses.mapValues { response -> [String: Any] in
                ["status": response.status.map { $0 as Any } ?? NSNull(), "text": response.text,
                 "json": (try? JSONSerialization.jsonObject(with: response.body, options: [.fragmentsAllowed])) ?? NSNull()]
            }
            let input: [String: Any] = ["responses": responseValues, "context": [
                "credential": original?.values ?? [:], "now": now().timeIntervalSince1970,
                "attempts": attempts, "settings": settings, "constants": (flow.constants ?? [:]).mapValues(\.foundationObject)]]
            let data = try JSONSerialization.data(withJSONObject: input)
            context.setObject(String(decoding: data, as: UTF8.self), forKeyedSubscript: "__input" as NSString)
            context.evaluateScript(script)
            let output = context.evaluateScript("JSON.stringify(next(JSON.parse(__input).responses, JSON.parse(__input).context))")
            guard !failed else { throw UsageError.parseFailed("HTTP flow script failed") }
            guard let text = output?.toString(), let bytes = text.data(using: .utf8),
                  let action = try? JSONDecoder().decode(Action.self, from: bytes) else {
                throw UsageError.parseFailed("Invalid HTTP flow output")
            }
            if let error = action.error { throw Self.redacted(error, credential: original).usageError }
            if let done = action.done, action.request == nil, let response = responses[done] { return response }
            guard step < 8, action.done == nil, let name = action.request, let request = flow.requests[name] else {
                throw UsageError.executionFailed("Unknown HTTP flow request or request limit exceeded")
            }
            var credential = original ?? Credential([:])
            // The planner cannot replace credentials found by the lookup.
            for (key, value) in action.values ?? [:] where credential.values[key] == nil { credential[key] = value }
            try Task.checkCancellation()
            if let delay = action.delaySeconds {
                guard delay.isFinite, delay >= 0, delay <= 5 else { throw UsageError.executionFailed("Invalid HTTP flow delay") }
                try await sleep(delay)
            }
            attempts[name, default: 0] += 1
            do {
                responses[name] = try await HTTPFetcher(request: request, network: network, now: now, settingValue: settingValue).fetch(with: credential)
            } catch is CancellationError { throw CancellationError() }
            catch {
                try Task.checkCancellation()
                guard flow.continueOnError?.contains(name) == true else { throw error }
                // No exception text crosses into a planner; it may contain a secret.
                responses[name] = Response(text: "")
            }
        }
        throw UsageError.executionFailed("HTTP request limit exceeded")
    }
    private struct Action: Decodable { let request: String?; let values: [String: String]?; let done: String?; let error: ErrorRef?; let delaySeconds: TimeInterval? }
    private static func redacted(_ error: ErrorRef, credential: Credential?) -> ErrorRef {
        func clean(_ text: String) -> String { (credential?.values.values ?? Dictionary<String,String>().values).filter { !$0.isEmpty }.reduce(text) { $0.replacingOccurrences(of: $1, with: "[redacted]") } }
        switch error {
        case .parseFailed(let text): return .parseFailed(clean(text))
        case .executionFailed(let text): return .executionFailed(clean(text))
        case .sessionExpired(let hint): return .sessionExpired(hint.map(clean))
        default: return error
        }
    }
}

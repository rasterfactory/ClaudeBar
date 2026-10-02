import Foundation
import Quotas

/// Each fixed HTTP request completes before the next one. Queries are
/// encoded as URLQueryItems, never interpolated into a URL or shell command.
/// The named response objects become one mapping response.
struct HTTPSequenceFetcher: Fetching {
    let sequence: HTTPSequence
    let network: any NetworkClient
    let now: @Sendable () -> Date

    func isReady() -> Bool {
        !sequence.steps.isEmpty && sequence.steps.count <= 8 &&
        Set(sequence.steps.map(\.name)).count == sequence.steps.count
    }

    func fetch(with credential: Credential?) async throws -> Response {
        guard isReady() else { throw UsageError.executionFailed("Invalid HTTP sequence") }
        var responses: [String: Any] = [:]
        for step in sequence.steps {
            let scope = JSONScope(root: responses)
            guard let text = Template.fill(step.request.url, with: credential),
                  var url = URLComponents(string: text) else { throw UsageError.executionFailed("Invalid URL") }
            var query = url.queryItems ?? []
            for name in step.queryFrom.keys.sorted() {
                let selected = step.queryFrom[name]?.lazy.compactMap { scope.string($0)?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
                if let selected { query.append(URLQueryItem(name: name, value: selected)) }
            }
            url.queryItems = query.isEmpty ? nil : query
            guard let requestURL = url.url else { throw UsageError.executionFailed("Invalid URL") }
            let request = HTTPRequest(url:requestURL.absoluteString,urlBySetting:step.request.urlBySetting,headersBySetting:step.request.headersBySetting,networkErrorPrefix:step.request.networkErrorPrefix,invalidResponseError:step.request.invalidResponseError,propagateNetworkErrors:step.request.propagateNetworkErrors,ignoreResponseStatus:step.request.ignoreResponseStatus,method:step.request.method,headers:step.request.headers,body:step.request.body,timeout:step.request.timeout,acceptedStatuses:step.request.acceptedStatuses,errors:step.request.errors)
            let response = try await HTTPFetcher(request: request, network: network, now: now).fetch(with: credential)
            guard let object = (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any] else {
                throw step.whenInvalid?.usageError ?? UsageError.parseFailed("HTTP sequence response is not a JSON object")
            }
            responses[step.name] = object
        }
        return Response(body: try JSONSerialization.data(withJSONObject: responses))
    }
}

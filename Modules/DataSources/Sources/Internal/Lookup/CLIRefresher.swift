import Foundation
import Quotas

struct CLIRefresher: CredentialRefreshing {
    let refresh: CLIRefresh
    let reader: any CredentialFinding
    let makeExecutor: CLIFetcher.MakeExecutor
    let sleep: @Sendable (TimeInterval) async throws -> Void
    var retryStatuses: [Int] { refresh.onStatus }
    func isDue(_ credential: Credential) -> Bool { false }
    func refresh(_ credential: Credential) async throws -> Credential {
        let call = refresh.call
        guard makeExecutor(call).locate(call.cli) != nil else {
            throw refresh.missingError?.usageError ?? UsageError.cliNotFound(call.cli)
        }
        _ = try await CLIFetcher(call: call, makeExecutor: makeExecutor).fetch(with: nil)
        if let delay = refresh.delaySeconds {
            guard delay.isFinite, delay >= 0, delay <= 5 else { throw UsageError.executionFailed("Invalid CLI refresh delay") }
            try await sleep(delay)
        }
        guard let renewed = try reader.find() else { throw UsageError.authenticationRequired }
        return renewed.credential
    }
}

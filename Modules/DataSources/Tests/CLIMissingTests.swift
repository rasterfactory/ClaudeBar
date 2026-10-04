import Quotas
import Foundation
import Mockable
import Testing
@testable import DataSources

/// A CLI that isn't on this Mac is `cliNotFound` — the fact that lets a login
/// read as *not set up* rather than failing (#198) — not the terminal
/// runner's own error, which reached the popover as "Couldn't connect".
@Suite
struct CLIMissingTests {
    @Test
    func `should report a CLI that isn't installed as missing, not as a failed connection (#198)`() async throws {
        let executor = MockCLIExecutor()
        given(executor).execute(binary: .any, args: .any, input: .any, timeout: .any, workingDirectory: .any, autoResponses: .any)
            .willThrow(UsageError.cliNotFound("acme"))
        let fetcher = CLIFetcher(call: CLICall(cli: "acme", args: ["/usage"]), makeExecutor: { _ in executor })

        do {
            _ = try await fetcher.fetch(with: nil)
            Issue.record("a missing CLI fetched")
        } catch let failure as ReportedFailure {
            #expect(failure.fact == .cliMissing)
            #expect(failure.reason == .cliNotFound("acme"))
        }
    }

    @Test
    func `should report the CLI as not found when it isn't on this Mac`() async throws {
        let executor = DefaultCLIExecutor()

        await #expect(throws: UsageError.cliNotFound("claudebar-no-such-cli")) {
            _ = try await executor.execute(binary: "claudebar-no-such-cli", args: [], input: nil, timeout: 1,
                                           workingDirectory: nil, autoResponses: [:])
        }
    }
}

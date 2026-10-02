import Testing
import Foundation
import Mockable
import Providers
import DataSources
import Quotas


@MainActor @Suite("OmpUsageProbe Tests")
struct OmpExecutionTests {
    private func make(_ cli: MockCLIExecutor) throws -> Provider {
        let definition = try Providers.builtIn("omp")
        return Provider(definition: definition, settings: InMemoryProviderSettings(), makeDataSource: { source, _ in
            DataSources.make(source, providerId: "omp", cliExecutor: cli, network: MockNetworkClient(),
                makeTransport: { _,_,_,_ in MockRPCTransport() }, scripts: Providers.builtInScripts,
                environment: { _ in nil }, homeDirectory: FileManager.default.temporaryDirectory, now: { Date() })
        })
    }


    private static let validOutput = OmpDefinitionTests.sampleResponse

    // MARK: - isAvailable Tests

    @Test
    func `isAvailable returns true when omp binary is found`() async throws {
        let mockExecutor = MockCLIExecutor()
        given(mockExecutor).locate(.any).willReturn("/Users/dev/.bun/bin/omp")
        let probe = try make(mockExecutor).defaultAccount

        #expect(await probe.isAvailable() == true)
    }

    @Test
    func `isAvailable returns false when omp binary is not found`() async throws {
        let mockExecutor = MockCLIExecutor()
        given(mockExecutor).locate(.any).willReturn(nil)
        let probe = try make(mockExecutor).defaultAccount

        #expect(await probe.isAvailable() == false)
    }

    // MARK: - Probe Success Tests

    @Test
    func `probe runs omp usage --json and returns snapshot`() async throws {
        let mockExecutor = MockCLIExecutor()

        given(mockExecutor).locate(.any).willReturn("/Users/dev/.bun/bin/omp")
        given(mockExecutor).execute(
            binary: .value("omp"),
            args: .value(["usage", "--json"]),
            input: .any,
            timeout: .any,
            workingDirectory: .any,
            autoResponses: .any
        ).willReturn(CLIResult(output: Self.validOutput, exitCode: 0))

        let probe = try make(mockExecutor).defaultAccount
        let snapshot = try await probe.refresh()

        #expect(snapshot.providerId == "omp")
        #expect(snapshot.quotas.count == 7)
        #expect(snapshot.quota(for: .timeLimit("Claude 5h"))?.percentRemaining == 92.0)
    }

    // MARK: - Probe Error Tests

    @Test
    func `probe throws cliNotFound when binary missing`() async throws {
        let mockExecutor = MockCLIExecutor()
        given(mockExecutor).locate(.any).willReturn(nil)

        let probe = try make(mockExecutor).defaultAccount

        await #expect(throws: UsageError.cliNotFound("omp")) {
            try await probe.refresh()
        }
    }

    @Test
    func `probe throws executionFailed on non-zero exit`() async throws {
        let mockExecutor = MockCLIExecutor()

        given(mockExecutor).locate(.any).willReturn("/Users/dev/.bun/bin/omp")
        given(mockExecutor).execute(
            binary: .any,
            args: .any,
            input: .any,
            timeout: .any,
            workingDirectory: .any,
            autoResponses: .any
        ).willReturn(CLIResult(output: "env: bun: No such file or directory", exitCode: 127))

        let probe = try make(mockExecutor).defaultAccount

        await #expect(throws: UsageError.self) {
            try await probe.refresh()
        }
    }

    @Test
    func `execution failure never surfaces raw CLI output`() async throws {
        // Usage output carries account emails/ids; the thrown error reaches
        // the UI via `lastError` and must only name the exit code.
        let mockExecutor = MockCLIExecutor()

        given(mockExecutor).locate(.any).willReturn("/Users/dev/.bun/bin/omp")
        given(mockExecutor).execute(
            binary: .any,
            args: .any,
            input: .any,
            timeout: .any,
            workingDirectory: .any,
            autoResponses: .any
        ).willReturn(CLIResult(
            output: "partial { \"email\": \"leak@example.com\", \"accountId\": \"tok-abc123\" } crash",
            exitCode: 3
        ))

        let probe = try make(mockExecutor).defaultAccount

        // Exact match pins the complete surfaced message (UsageError's
        // Equatable compares payloads) — no fragment of CLI output survives.
        await #expect(throws: UsageError.executionFailed("omp usage exited with code 3")) {
            try await probe.refresh()
        }
    }

    @Test
    func `probe throws on unparseable output`() async throws {
        let mockExecutor = MockCLIExecutor()

        given(mockExecutor).locate(.any).willReturn("/Users/dev/.bun/bin/omp")
        given(mockExecutor).execute(
            binary: .any,
            args: .any,
            input: .any,
            timeout: .any,
            workingDirectory: .any,
            autoResponses: .any
        ).willReturn(CLIResult(output: "Unexpected interactive prompt", exitCode: 0))

        let probe = try make(mockExecutor).defaultAccount

        await #expect(throws: UsageError.self) {
            try await probe.refresh()
        }
    }

    @Test
    func `probe wraps executor failures as executionFailed`() async throws {
        let mockExecutor = MockCLIExecutor()

        given(mockExecutor).locate(.any).willReturn("/Users/dev/.bun/bin/omp")
        given(mockExecutor).execute(
            binary: .any,
            args: .any,
            input: .any,
            timeout: .any,
            workingDirectory: .any,
            autoResponses: .any
        ).willThrow(NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Process timed out"]))

        let probe = try make(mockExecutor).defaultAccount

        await #expect(throws: UsageError.self) {
            try await probe.refresh()
        }
    }
}

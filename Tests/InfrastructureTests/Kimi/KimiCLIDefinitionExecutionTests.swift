import Providers
import DataSources
import Testing
import Foundation
import Mockable
@testable import Infrastructure
@testable import Domain

@Suite("KimiCLIUsageProbe Tests")
struct KimiCLIDefinitionExecutionTests {

    private var completionRule: CLICompletionRule {
        let definition = try! Providers.builtIn("kimi")
        guard case .cli(let call) = definition.dataSource("cli")!.fetch else { fatalError() }
        return CLICompletionRule(readyMarkers: call.readyWhen.map { .init($0.text, endsRow: $0.endsRow) })
    }
    private func cli(cliExecutor: any CLIExecutor) -> Fixture {
        let definition = try! Providers.builtIn("kimi")
        return Fixture(source: DataSources.make(definition.dataSource("cli")!, providerId: "kimi", cliExecutor: cliExecutor, network: MockNetworkClient(), makeTransport: { _, _, _, _ in MockRPCTransport() }, scripts: Providers.builtInScripts, environment: { _ in nil }, homeDirectory: FileManager.default.temporaryDirectory, now: { Date() }))
    }
    private struct Fixture {
        let source: DataSource
        func isAvailable() async -> Bool { await source.isReady() }
        func probe() async throws -> UsageSnapshot {
            do { return try await source.fetchUsage() }
            catch let error as DataSourceError { throw error.reason }
        }
    }

    // MARK: - Sample Output

    private static let validCLIOutput = """
    ╭─────────────────────────────── API Usage ───────────────────────────────╮
    │  Weekly limit  ━━━━━━━━━━━━━━━━━━━━  100% left  (resets in 6d 23h 22m)  │
    │  5h limit      ━━━━━━━━━━━━━━━━━━━━  100% left  (resets in 4h 22m)      │
    ╰─────────────────────────────────────────────────────────────────────────╯
    """

    // MARK: - isAvailable Tests

    @Test
    func `isAvailable returns true when kimi binary is found`() async {
        let mockExecutor = MockCLIExecutor()
        given(mockExecutor).locate(.any).willReturn("/usr/local/bin/kimi")
        let probe = cli(cliExecutor: mockExecutor)

        #expect(await probe.isAvailable() == true)
    }

    @Test
    func `isAvailable returns false when kimi binary is not found`() async {
        let mockExecutor = MockCLIExecutor()
        given(mockExecutor).locate(.any).willReturn(nil)
        let probe = cli(cliExecutor: mockExecutor)

        #expect(await probe.isAvailable() == false)
    }

    // MARK: - Probe Success Tests

    @Test
    func `probe sends usage command and returns snapshot`() async throws {
        let mockExecutor = MockCLIExecutor()

        given(mockExecutor).locate(.any).willReturn("/usr/local/bin/kimi")
        given(mockExecutor).execute(
            binary: .any,
            args: .any,
            input: .any,
            timeout: .any,
            workingDirectory: .any,
            autoResponses: .any
        ).willReturn(CLIResult(output: Self.validCLIOutput, exitCode: 0))

        let probe = cli(cliExecutor: mockExecutor)
        let snapshot = try await probe.probe()

        #expect(snapshot.providerId == "kimi")
        #expect(snapshot.quotas.count == 2)
        #expect(snapshot.quota(for: .weekly)?.percentRemaining == 100.0)
        #expect(snapshot.quota(for: .session)?.percentRemaining == 100.0)
    }

    // MARK: - Probe Error Tests

    @Test
    func `probe throws cliNotFound when binary missing`() async {
        let mockExecutor = MockCLIExecutor()
        given(mockExecutor).locate(.any).willReturn(nil)

        let probe = cli(cliExecutor: mockExecutor)

        await #expect(throws: UsageError.cliNotFound("kimi")) {
            try await probe.probe()
        }
    }

    @Test
    func `probe throws on unexpected output`() async {
        let mockExecutor = MockCLIExecutor()

        given(mockExecutor).locate(.any).willReturn("/usr/local/bin/kimi")
        given(mockExecutor).execute(
            binary: .any,
            args: .any,
            input: .any,
            timeout: .any,
            workingDirectory: .any,
            autoResponses: .any
        ).willReturn(CLIResult(output: "Unexpected output with no usage data", exitCode: 0))

        let probe = cli(cliExecutor: mockExecutor)

        await #expect(throws: UsageError.self) {
            try await probe.probe()
        }
    }

    @Test
    func `probe throws executionFailed when CLI execution fails`() async {
        let mockExecutor = MockCLIExecutor()

        given(mockExecutor).locate(.any).willReturn("/usr/local/bin/kimi")
        given(mockExecutor).execute(
            binary: .any,
            args: .any,
            input: .any,
            timeout: .any,
            workingDirectory: .any,
            autoResponses: .any
        ).willThrow(NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Process timed out"]))

        let probe = cli(cliExecutor: mockExecutor)

        await #expect(throws: UsageError.self) {
            try await probe.probe()
        }
    }

    // MARK: - Input Strategy

    /// Records execute() arguments so tests can assert what the probe sends.
    private final class CapturingCLIExecutor: CLIExecutor, @unchecked Sendable {
        struct Invocation: Sendable {
            let input: String?
            let workingDirectory: URL?
            let autoResponses: [String: String]
        }

        private let lock = NSLock()
        private var storage: [Invocation] = []

        var invocations: [Invocation] {
            withLock { storage }
        }

        private func withLock<T>(_ body: () -> T) -> T {
            lock.lock(); defer { lock.unlock() }
            return body()
        }

        func locate(_ binary: String) -> String? { "/usr/local/bin/kimi" }

        func execute(
            binary: String,
            args: [String],
            input: String?,
            timeout: TimeInterval,
            workingDirectory: URL?,
            autoResponses: [String: String]
        ) async throws -> CLIResult {
            let invocation = Invocation(input: input, workingDirectory: workingDirectory, autoResponses: autoResponses)
            withLock { storage.append(invocation) }
            return CLIResult(output: KimiCLIDefinitionExecutionTests.validCLIOutput, exitCode: 0)
        }
    }

    @Test
    func `probe types /usage as delayed input and keeps prompt markers as backup`() async throws {
        let executor = CapturingCLIExecutor()
        let probe = cli(cliExecutor: executor)

        let snapshot = try await probe.probe()

        let invocation = try #require(executor.invocations.first)
        // Typed input must land after the TUI's startup paint settles; typing it
        // the moment the footer first painted used to lose it to a redraw.
        #expect(invocation.input == "/usage")
        // The ready markers stay as backup for slower CLIs.
        #expect(invocation.autoResponses["💫"] == "/usage\r")
        #expect(invocation.autoResponses["context:"] == "/usage\r")
        #expect(snapshot.quotas.count == 2)
    }

    @Test
    func `probe runs in a dedicated directory so the folder trust prompt never blocks`() async throws {
        let executor = CapturingCLIExecutor()
        let probe = cli(cliExecutor: executor)

        _ = try await probe.probe()

        let invocation = try #require(executor.invocations.first)
        let directory = try #require(invocation.workingDirectory)
        // A nil working directory inherits the app's cwd, where the CLI's
        // one-time "Trust this folder?" prompt swallows the typed /usage and
        // the probe reports "No quota data found".
        #expect(directory.lastPathComponent == "Probe")
        // The one-time trust prompt is accepted with Enter and remembered, so
        // it never appears again.
        #expect(invocation.autoResponses["Trust this folder"] == "\r")
    }

    // MARK: - Completion Rule

    @Test
    func `completion rule stays pending while the usage panel is still fetching`() {
        let startupScreen = "K2.8 Preview\nNo session yet\ncontext: 0% (0/1M)"

        #expect(completionRule.isPending(startupScreen) == true)
    }

    @Test
    func `completion rule settles once a quota line appears`() {
        let withPanel = "context: 0% (0/1M)\n│   5h limit  ░░  0% used  resets in 2h 41m │"

        #expect(completionRule.isPending(withPanel) == false)
    }

    @Test
    func `completion rule also settles on old format and error screens`() {
        #expect(completionRule.isPending("context: 1%\nWeekly limit  100% left") == false)
        #expect(completionRule.isPending("context: 1%\nError: not logged in") == false)
    }

    @Test
    func `completion rule settles on a pre-0.36 screen without the status footer`() {
        // Pre-0.36 CLIs have no "context:" footer; their quota line still ends the wait.
        #expect(completionRule.isPending("💫 > /usage\nWeekly limit  100% left") == false)
    }
}

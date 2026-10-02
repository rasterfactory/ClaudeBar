import Quotas
import Foundation
import Testing
@testable import DataSources

@Suite
struct PipeCLIExecutorTests {

    // MARK: - PATH Augmentation
    //
    // Menu bar apps launched by launchd get a minimal PATH; script CLIs
    // with `/usr/bin/env` shebangs (bun/node) need their runtime findable.

    @Test
    func `augmented PATH contains the binary's own directory`() {
        let env = PipeCLIExecutor.augmentedEnvironment(binaryPath: "/test-omp-home/.bun/bin/omp")
        let entries = (env["PATH"] ?? "").split(separator: ":").map(String.init)

        // The runtime (bun) usually lives next to the tool it runs.
        #expect(entries.filter { $0 == "/test-omp-home/.bun/bin" }.count == 1)
    }

    @Test
    func `augmented PATH keeps existing entries in front and appends common dirs`() {
        let env = PipeCLIExecutor.augmentedEnvironment(binaryPath: "/usr/bin/true")
        let entries = (env["PATH"] ?? "").split(separator: ":").map(String.init)

        if let currentFirst = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").first.map(String.init) {
            #expect(entries.first == currentFirst)
        }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(entries.contains("\(home)/.bun/bin"))
        #expect(entries.contains("\(home)/.local/bin"))
    }

    @Test func `profile environment overrides and clears inherited credentials`() async throws {
        let executor = PipeCLIExecutor(environment: .init(unset:["USER"], set: ["HOME":"/tmp/isolated home", "PROFILE_TEST":"work"]))
        let result = try await executor.execute(binary: "/bin/sh", args:["-c", "printf '%s|%s|%s' \"$HOME\" \"$PROFILE_TEST\" \"${USER-unset}\""], input:nil, timeout:10, workingDirectory:nil, autoResponses:[:])
        #expect(result.output == "/tmp/isolated home|work|unset")
    }

    // MARK: - Execution

    @Test
    func `execute captures output and exit code`() async throws {
        let result = try await PipeCLIExecutor().execute(
            binary: "/bin/echo",
            args: ["example-output"],
            input: nil,
            timeout: 10,
            workingDirectory: nil,
            autoResponses: [:]
        )

        #expect(result.output.contains("example-output"))
        #expect(result.exitCode == 0)
    }

    @Test
    func `execute reports a non-zero exit code without throwing`() async throws {
        let result = try await PipeCLIExecutor().execute(
            binary: "/bin/sh",
            args: ["-c", "exit 7"],
            input: nil,
            timeout: 10,
            workingDirectory: nil,
            autoResponses: [:]
        )

        #expect(result.exitCode == 7)
    }

    @Test
    func `execute merges stderr into the output blob`() async throws {
        let result = try await PipeCLIExecutor().execute(
            binary: "/bin/sh",
            args: ["-c", "echo out; echo err 1>&2"],
            input: nil,
            timeout: 10,
            workingDirectory: nil,
            autoResponses: [:]
        )

        #expect(result.output.contains("out"))
        #expect(result.output.contains("err"))
    }

    @Test
    func `execute throws cliNotFound for a missing binary`() async {
        await #expect(throws: UsageError.self) {
            try await PipeCLIExecutor().execute(
                binary: "claudebar-not-a-real-cli",
                args: [],
                input: nil,
                timeout: 10,
                workingDirectory: nil,
                autoResponses: [:]
            )
        }
    }

    @Test
    func `execute times out rather than hanging on a long-running command`() async {
        let start = CFAbsoluteTimeGetCurrent()

        await #expect(throws: UsageError.self) {
            try await PipeCLIExecutor().execute(
                binary: "/bin/sh",
                args: ["-c", "sleep 30"],
                input: nil,
                timeout: 0.5,
                workingDirectory: nil,
                autoResponses: [:]
            )
        }

        // Must give up near the timeout, not ride out the full sleep.
        #expect(CFAbsoluteTimeGetCurrent() - start < 10)
    }

    @Test
    func `execute survives output larger than the pipe buffer`() async throws {
        // The previous implementation raced two DispatchQueue readers against a
        // usleep poll loop; this is the case that made that fragile.
        let result = try await PipeCLIExecutor().execute(
            binary: "/bin/sh",
            args: ["-c", "seq 1 50000"],
            input: nil,
            timeout: 20,
            workingDirectory: nil,
            autoResponses: [:]
        )

        #expect(result.exitCode == 0)
        #expect(result.output.count > 200_000)
    }

    @Test
    func `augmented PATH does not duplicate directories it appends`() {
        let env = PipeCLIExecutor.augmentedEnvironment(binaryPath: "/opt/homebrew/bin/tool")
        let entries = (env["PATH"] ?? "").split(separator: ":").map(String.init)

        // /opt/homebrew/bin is both the binary dir and a common path —
        // it must be appended at most once beyond any ambient occurrence.
        let ambient = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").map(String.init)
        let ambientCount = ambient.filter { $0 == "/opt/homebrew/bin" }.count
        let augmentedCount = entries.filter { $0 == "/opt/homebrew/bin" }.count
        #expect(augmentedCount == max(ambientCount, 1))
    }
}

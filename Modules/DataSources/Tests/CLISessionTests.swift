import Quotas
import Foundation
import Mockable
import Testing
@testable import DataSources

/// One session shared by every run of a CLI call (#132).
///
/// The definition carries only the vendor's facts — the args that create and
/// resume the session, the output that says it is gone, and the output that
/// says this CLI build rejects the flags. Which session a worker is in is its
/// own memory: create once, resume after, recreate when gone, fall back to the
/// plain invocation when the flags are refused.
@Suite("Session reuse on a CLI call (#132)")
struct CLISessionTests {

    // MARK: - Helpers


    /// Thread-safe recorder of every `execute` run's args, in order.
    private final class Launches: @unchecked Sendable {
        private let lock = NSLock()
        private var all: [[String]] = []
        func record(_ args: [String]) { lock.withLock { all.append(args) } }
        var recorded: [[String]] { lock.withLock { all } }
    }

    private func call(
        args: [String] = ["/usage", "--allowed-tools", ""],
        session: CLICall.Session,
        workingDirectory: WorkingDirectory? = nil
    ) -> CLICall {
        CLICall(cli: "claude", args: args, timeout: 20, workingDirectory: workingDirectory, session: session)
    }

    /// Thread-safe queue of ids the runner hands out, in order.
    private final class IDQueue: @unchecked Sendable {
        private let lock = NSLock()
        private let ids: [String]
        private var index = 0
        init(_ ids: [String]) { self.ids = ids }
        func next() -> String {
            lock.withLock {
                defer { index += 1 }
                guard index < ids.count else { return "unexpected-id-\(index)" }
                return ids[index]
            }
        }
    }

    private func runner(
        _ call: CLICall,
        executor: MockCLIExecutor,
        launches: Launches? = nil,
        ids: [String] = [],
        memory: SessionMemory = SessionMemory()
    ) -> CLISessionRunner {
        let queue = IDQueue(ids)
        return CLISessionRunner(
            call: call,
            session: call.session ?? session(),
            directory: nil,
            makeExecutor: { _ in executor },
            memory: memory,
            nextID: { queue.next() }
        )
    }

    private func screen(_ text: String, exitCode: Int32 = 0, executor: MockCLIExecutor, launches: Launches) {
        given(executor).locate(.any).willReturn("/usr/local/bin/claude")
        given(executor).execute(
            binary: .any, args: .any, input: .any, timeout: .any, workingDirectory: .any, autoResponses: .any
        ).willProduce { @Sendable _, args, _, _, _, _ in
            launches.record(args)
            return CLIResult(output: text, exitCode: exitCode)
        }
    }

    private let usageScreen = """
    Current session
    ████████████████░░░░ 65% left
    Resets in 2h 15m
    """

    private func session() -> CLICall.Session {
        CLICall.Session(
            create: ["--session-id", "{{id}}", "--name", "ClaudeBar Probe"],
            resume: ["--resume", "{{id}}"],
            recreateOn: ["no conversation found", "no session found"],
            unsupportedOn: ["unknown option '--session-id'", "unknown option '--resume'", "unknown option '--name'"]
        )
    }

    // MARK: - The definition side

    @Test
    func `should read a session's create and resume arguments and its gone and refused phrases from the definition`() throws {
        let call = try JSONDecoder().decode(CLICall.self, from: Data("""
        {"cli":"claude","args":["/usage"],
         "session":{"create":["--session-id","{{id}}","--name","ClaudeBar Probe"],
                    "resume":["--resume","{{id}}"],
                    "recreateOn":["no conversation found"],
                    "unsupportedOn":["unknown option '--session-id'"]}}
        """.utf8))

        let session = try #require(call.session)
        #expect(session.create == ["--session-id", "{{id}}", "--name", "ClaudeBar Probe"])
        #expect(session.resume == ["--resume", "{{id}}"])
        #expect(session.recreateOn == ["no conversation found"])
        #expect(session.unsupportedOn == ["unknown option '--session-id'"])
    }

    @Test
    func `should treat no session as gone or refused when the definition names no phrases`() throws {
        let call = try JSONDecoder().decode(CLICall.self, from: Data("""
        {"cli":"claude","session":{"create":["--session-id","{{id}}"],"resume":["--resume","{{id}}"]}}
        """.utf8))
        #expect(call.session?.recreateOn.isEmpty == true)
        #expect(call.session?.unsupportedOn.isEmpty == true)
    }

    @Test
    func `should write no session when the CLI call has none`() throws {
        let call = CLICall(cli: "claude", args: ["/usage"])
        let json = String(data: try JSONEncoder().encode(call), encoding: .utf8)!

        #expect(json.contains("session") == false)
        #expect(try JSONDecoder().decode(CLICall.self, from: Data(json.utf8)) == call)
    }

    @Test
    func `should keep the session when the definition is written out and read back`() throws {
        let call = call(session: session())
        let again = try JSONDecoder().decode(CLICall.self, from: JSONEncoder().encode(call))

        #expect(again == call)
    }

    // MARK: - The plan loop

    @Test
    func `should create and name a session on the first run and remember its id`() async throws {
        let launches = Launches()
        let executor = MockCLIExecutor()
        screen(usageScreen, executor: executor, launches: launches)
        let memory = SessionMemory()
        let runner = self.runner(
            call(session: session()),
            executor: executor,
            ids: ["11111111-2222-3333-4444-555555555555"],
            memory: memory
        )

        let result = try await runner.run()

        #expect(result.output == usageScreen)
        #expect(launches.recorded.count == 1)
        #expect(launches.recorded[0] == ["/usage", "--allowed-tools", "", "--session-id", "11111111-2222-3333-4444-555555555555", "--name", "ClaudeBar Probe"])
        #expect(await memory.id == "11111111-2222-3333-4444-555555555555")
    }

    @Test
    func `should resume the session it created on every later run`() async throws {
        let launches = Launches()
        let executor = MockCLIExecutor()
        screen(usageScreen, executor: executor, launches: launches)
        let memory = SessionMemory()
        let runner = self.runner(call(session: session()), executor: executor,
                                 ids: ["aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"], memory: memory)

        _ = try await runner.run()
        _ = try await runner.run()
        _ = try await runner.run()

        #expect(launches.recorded.count == 3)
        #expect(launches.recorded[0].contains("--session-id"))
        #expect(launches.recorded[1] == ["/usage", "--allowed-tools", "", "--resume", "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"])
        #expect(launches.recorded[2] == ["/usage", "--allowed-tools", "", "--resume", "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"])
        #expect(await memory.id == "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
    }

    @Test
    func `should create a fresh session when the CLI says the remembered one is gone`() async throws {
        let launches = Launches()
        let executor = MockCLIExecutor()
        let gone = "No conversation found with session ID aaaaaaaaaa"
        given(executor).execute(
            binary: .any, args: .any, input: .any, timeout: .any, workingDirectory: .any, autoResponses: .any
        ).willProduce { @Sendable _, args, _, _, _, _ in
            launches.record(args)
            return CLIResult(output: args.contains("--resume") ? gone : usageScreen, exitCode: 0)
        }
        let memory = SessionMemory()
        await memory.remember("aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
        let runner = self.runner(
            call(session: session()),
            executor: executor,
            ids: ["11111111-2222-3333-4444-555555555555"],
            memory: memory
        )

        let result = try await runner.run()

        #expect(result.output == usageScreen)
        #expect(launches.recorded.count == 2)
        #expect(launches.recorded[0].contains("--resume"))
        #expect(launches.recorded[1] == ["/usage", "--allowed-tools", "", "--session-id", "11111111-2222-3333-4444-555555555555", "--name", "ClaudeBar Probe"])
        #expect(await memory.id == "11111111-2222-3333-4444-555555555555")
    }

    @Test
    func `should run the CLI plainly for good when this CLI build rejects the session flags`() async throws {
        let launches = Launches()
        let executor = MockCLIExecutor()
        let refused = "error: unknown option '--session-id'"
        given(executor).execute(
            binary: .any, args: .any, input: .any, timeout: .any, workingDirectory: .any, autoResponses: .any
        ).willProduce { @Sendable _, args, _, _, _, _ in
            launches.record(args)
            return CLIResult(output: args.contains("--session-id") || args.contains("--resume") ? refused : usageScreen, exitCode: 1)
        }
        let memory = SessionMemory()
        let runner = self.runner(call(session: session()), executor: executor, ids: ["11111111-2222-3333-4444-555555555555"], memory: memory)

        let first = try await runner.run()
        let second = try await runner.run()

        #expect(first.output == usageScreen)
        #expect(second.output == usageScreen)
        // Create refused → plain retry; the memory keeps every later run plain.
        #expect(launches.recorded.count == 3)
        #expect(launches.recorded[0].contains("--session-id"))
        #expect(launches.recorded[1] == ["/usage", "--allowed-tools", ""])
        #expect(launches.recorded[2] == ["/usage", "--allowed-tools", ""])
        #expect(await memory.id == nil)
        #expect(await memory.isRefused)
    }

    @Test
    func `should run plainly and forget the session when the CLI rejects resuming it`() async throws {
        let launches = Launches()
        let executor = MockCLIExecutor()
        let refused = "error: unknown option '--resume'"
        given(executor).execute(
            binary: .any, args: .any, input: .any, timeout: .any, workingDirectory: .any, autoResponses: .any
        ).willProduce { @Sendable _, args, _, _, _, _ in
            launches.record(args)
            return CLIResult(output: args.contains("--resume") ? refused : usageScreen, exitCode: 1)
        }
        let memory = SessionMemory()
        await memory.remember("aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
        let runner = self.runner(call(session: session()), executor: executor, memory: memory)

        _ = try await runner.run()

        #expect(launches.recorded.count == 2)
        #expect(launches.recorded[0].contains("--resume"))
        #expect(launches.recorded[1] == ["/usage", "--allowed-tools", ""])
        #expect(await memory.id == nil)
    }

    @Test
    func `should keep the session when a successful screen merely mentions an unknown option`() async throws {
        // A SessionStart hook or transcript can carry the words; only a failed
        // run proves the CLI build rejects the flags.
        let launches = Launches()
        let executor = MockCLIExecutor()
        let chatty = """
        Tip: passing an unknown option '--session-id' used to error out.
        \(usageScreen)
        """
        screen(chatty, executor: executor, launches: launches)
        let memory = SessionMemory()
        let runner = self.runner(
            call(session: session()),
            executor: executor,
            ids: ["11111111-2222-3333-4444-555555555555"],
            memory: memory
        )

        _ = try await runner.run()

        #expect(launches.recorded.count == 1)
        #expect(launches.recorded[0].contains("--session-id"))
        #expect(await memory.id == "11111111-2222-3333-4444-555555555555")
    }

    // MARK: - The detection rules

    @Test
    func `should count the flags as rejected only when the CLI fails and says a refusal phrase`() {
        let refused = CLIResult(output: "error: unknown option '--session-id'", exitCode: 1)

        #expect(CLISessionRunner.isRefused(refused, tokens: session().unsupportedOn))
        #expect(CLISessionRunner.isRefused(CLIResult(output: "error: unknown option '--session-id'", exitCode: 0), tokens: session().unsupportedOn) == false)
        #expect(CLISessionRunner.isRefused(CLIResult(output: "boom", exitCode: 1), tokens: session().unsupportedOn) == false)
        #expect(CLISessionRunner.isRefused(refused, tokens: []) == false)
    }

    @Test
    func `should recognise a refusal phrase in any letter case`() {
        let refused = CLIResult(output: "ERROR: UNKNOWN OPTION '--session-id'", exitCode: 1)

        #expect(CLISessionRunner.isRefused(refused, tokens: ["unknown option '--session-id'"]))
    }

    @Test
    func `should recognise a gone-session phrase in any letter case, and nothing else`() {
        #expect(CLISessionRunner.isGone("No Conversation Found With Session ID x", tokens: ["no conversation found"]))
        #expect(CLISessionRunner.isGone("all good", tokens: ["no conversation found"]) == false)
        #expect(CLISessionRunner.isGone("all good", tokens: []) == false)
    }

    // MARK: - The memory

    @Test
    func `should forget the session for good when many runs see the flags rejected at once`() async {
        let memory = SessionMemory()
        await memory.remember("aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
        #expect(await memory.isRefused == false)

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<50 {
                group.addTask { await memory.refuse() }
            }
        }

        #expect(await memory.isRefused)
        #expect(await memory.id == nil)
    }

    // MARK: - The fetcher wiring

    @Test
    func `should create a session once and then resume it when the definition asks for one`() async throws {
        let launches = Launches()
        let executor = MockCLIExecutor()
        screen(usageScreen, executor: executor, launches: launches)
        let fetcher = CLIFetcher(
            call: call(session: CLICall.Session(
                create: ["--session-id", "{{id}}", "--name", "ClaudeBar Probe"],
                resume: ["--resume", "{{id}}"],
                recreateOn: [],
                unsupportedOn: []
            )),
            makeExecutor: { _ in executor }
        )

        _ = try await fetcher.fetch(with: nil)
        _ = try await fetcher.fetch(with: nil)

        #expect(launches.recorded.count == 2)
        #expect(launches.recorded[0].contains("--session-id"))
        #expect(launches.recorded[1].contains("--resume"))
    }

    @Test
    func `should keep a separate session for each of two logins`() async throws {
        let launches = Launches()
        let executor = MockCLIExecutor()
        screen(usageScreen, executor: executor, launches: launches)
        let plan = CLICall.Session(create: ["--session-id", "{{id}}"], resume: ["--resume", "{{id}}"])
        let mine = CLIFetcher(call: call(session: plan), makeExecutor: { _ in executor })
        let work = CLIFetcher(call: call(session: plan), makeExecutor: { _ in executor })

        _ = try await mine.fetch(with: nil)
        _ = try await work.fetch(with: nil)

        let created = launches.recorded.compactMap { args in args.firstIndex(of: "--session-id").map { args[$0 + 1] } }
        #expect(created.count == 2)
        #expect(Set(created).count == 2)
    }

    @Test
    func `should run the CLI with its plain arguments when the definition asks for no session`() async throws {
        let launches = Launches()
        let executor = MockCLIExecutor()
        screen(usageScreen, executor: executor, launches: launches)
        let fetcher = CLIFetcher(
            call: CLICall(cli: "claude", args: ["/usage", "--allowed-tools", ""], timeout: 20),
            makeExecutor: { _ in executor }
        )

        let response = try await fetcher.fetch(with: nil)

        #expect(launches.recorded.count == 1)
        #expect(launches.recorded[0] == ["/usage", "--allowed-tools", ""])
        #expect(response.text.contains("65% left"))
    }
}

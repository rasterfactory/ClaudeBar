import Foundation
import Mockable
import Quotas
import Testing
@testable import DataSources

@Suite struct CLIAccountExecutionTests {
    private func call(_ json: String) throws -> CLICall { try JSONDecoder().decode(CLICall.self, from: Data(json.utf8)) }
    private func executor(output: String = "usage", exit: Int32 = 0, available: Bool = true) -> MockCLIExecutor {
        let executor = MockCLIExecutor()
        given(executor).locate(.any).willReturn(available ? "/bin/example" : nil)
        given(executor).execute(binary: .any, args: .any, input: .any, timeout: .any, workingDirectory: .any, autoResponses: .any)
            .willReturn(CLIResult(output: output, exitCode: exit))
        return executor
    }
    @Test func `credential environment is resolved separately for each process`() async throws {
        let definition = try call(#"{"cli":"example","environment":{"unset":["EXAMPLE_KEY"],"set":{"EXAMPLE_KEY":"{{token}}"}}}"#)
        let personal = executor(output: "personal usage")
        let work = executor(output: "work usage")
        let fetcher = CLIFetcher(call: definition, makeExecutor: { call in
            switch call.environment.set["EXAMPLE_KEY"] {
            case "personal": return personal
            case "work": return work
            default: return personal
            }
        })
        #expect(try await fetcher.fetch(with: Credential(["token":"personal"])).text == "personal usage")
        #expect(try await fetcher.fetch(with: Credential(["token":"work"])).text == "work usage")
        await #expect(throws: UsageError.authenticationRequired) { try await fetcher.fetch(with: nil) }
        #expect(definition.environment.set["EXAMPLE_KEY"] == "{{token}}")
    }
    @Test func `exit errors cannot be mapped as successful output`() async throws {
        let definition = try call(#"{"cli":"example","errors":{"nonzero":"example exited with code {{exitCode}}"}}"#)
        let executor = executor(exit: 2)
        let fetcher = CLIFetcher(call: definition, makeExecutor: { _ in executor })
        await #expect(throws: UsageError.executionFailed("example exited with code 2")) { try await fetcher.fetch(with: nil) }
    }
    @Test func `missing CLI has a configurable legacy label`() async throws {
        let definition = try call(#"{"cli":"example","errors":{"missing":"Example"}}"#)
        let executor = executor(available: false)
        let fetcher = CLIFetcher(call: definition, makeExecutor: { _ in executor })
        await #expect(throws: UsageError.cliNotFound("Example")) { try await fetcher.fetch(with: nil) }
    }
}

import Foundation
import Mockable
import Quotas
import Testing
@testable import DataSources

@Suite struct CommandPlanTests {
    private func worker(script: String, result: CLIResult = CLIResult(output:"first")) -> CommandPlanFetcher {
        let cli = MockCLIExecutor()
        given(cli).locate(.any).willReturn("/test/tool")
        given(cli).execute(binary:.any,args:.any,input:.any,timeout:.any,workingDirectory:.any,autoResponses:.any).willReturn(result)
        return CommandPlanFetcher(plan:CommandPlan(cli:"tool",script:"planner.js"),executor:cli,script:script,now:{Date(timeIntervalSince1970:1000)})
    }
    @Test func `completed plans preserve output and use a fixed clock`() async throws {
        let w = worker(script:"function next(responses, context) { return responses.length ? {done:{answer:responses[0],time:context.now}} : {args:['query']}; }")
        let response = try await w.fetch(with:nil)
        let json = try #require(try JSONSerialization.jsonObject(with:response.body) as? [String:Any])
        #expect(json["answer"] as? String == "first")
        #expect(json["time"] as? Double == 1000)
    }
    @Test func `failed commands do not reach the planner as successful responses`() async {
        let w = worker(script:"function next(responses) { return responses.length ? {done:{healthy:true}} : {args:['query']}; }", result:CLIResult(output:"{}",exitCode:2))
        await #expect(throws:UsageError.executionFailed("tool query exited with code 2")) { try await w.fetch(with:nil) }
    }
    @Test(arguments:["function next() { return {args:['query']}; }", "function next() { return {args:[]}; }", "function next() { return {args:['query'],done:{}}; }", "function next() { return {args:[3]}; }", "function next() { throw new Error('bad response'); }"])
    func `unbounded malformed or throwing plans fail`(_ script:String) async {
        await #expect(throws:UsageError.self) { try await worker(script:script).fetch(with:nil) }
    }
    @Test func `missing planner fails without executing commands`() async {
        let cli = MockCLIExecutor()
        given(cli).locate(.any).willReturn("/test/tool")
        let w = CommandPlanFetcher(plan:CommandPlan(cli:"tool",script:"absent.js"),executor:cli,script:nil,now:{Date()})
        await #expect(throws:UsageError.self) { try await w.fetch(with:nil) }
    }
}

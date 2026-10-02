import DataSources
import Foundation
import Mockable
import Quotas
import Testing

@Suite struct ScriptCredentialTests {
    private func make(_ script: String, environment: [String: String] = [:], executor: MockCLIExecutor = MockCLIExecutor()) throws -> DataSource {
        let definition = try JSONDecoder().decode(DataSourceDefinition.self, from: Data(#"{"kind":"api","credential":{"script":{"file":"key.js","environment":{"auth":"KEY"}}},"fetch":{"http":{"url":"https://example.com"}},"mapping":{"json":{"quotas":[]}}}"#.utf8))
        let network = MockNetworkClient()
        given(network).request(.any).willReturn((Data("{}".utf8),HTTPURLResponse(url: URL(string:"https://example.com")!,statusCode:200,httpVersion:nil,headerFields:nil)!))
        return DataSources.make(definition,providerId:"example",cliExecutor:executor,network:network,makeTransport:{_,_,_,_ in MockRPCTransport()},scripts:{_ in script},environment:{ environment[$0] },homeDirectory:FileManager.default.temporaryDirectory,now:{Date()})
    }
    @Test func `readiness can describe configuration without starting a shell`() async throws {
        let source = try make("function readCredential() { return {available:true}; }")
        #expect(await source.isReady())
        #expect(source.hasKey == false)
    }
    @Test func `a declared process environment answers without shell fallback`() async throws {
        let source = try make("function readCredential(input) { return {credential:{token:input.environment.auth}}; }",environment:["KEY":"test-token"])
        #expect(try await source.fetchResponse().status == 200)
    }
    @Test func `only a requested declared variable can use login shell fallback`() async throws {
        let executor = MockCLIExecutor()
        given(executor).execute(binary:.any,args:.any,input:.any,timeout:.any,workingDirectory:.any,autoResponses:.any).willReturn(CLIResult(output:"@@CLAUDEBAR_BEGIN@@shell-key@@CLAUDEBAR_END@@",exitCode:0))
        let source = try make("function readCredential(input) { return input.environment.auth ? {credential:{token:input.environment.auth}} : {needEnvironment:'auth'}; }",executor:executor)
        #expect(try await source.fetchResponse().status == 200)
        let undeclared = try make("function readCredential() { return {needEnvironment:'undeclared'}; }")
        await #expect(throws: DataSourceError(.lookup,.authenticationRequired)) { try await undeclared.fetchResponse() }
    }
    @Test func `script exceptions cannot echo credential contents`() async throws {
        let source = try make("function readCredential(input) { throw new Error(input.environment.auth); }",environment:["KEY":"private-test-token"])
        do { _ = try await source.fetchResponse(); Issue.record("Expected script failure") }
        catch { #expect(!error.localizedDescription.contains("private-test-token")) }
    }
}

import Foundation
import Mockable
import Quotas
import Testing
@testable import DataSources

@Suite struct WorkflowTests {
    private func definition(_ options:String = "") throws -> DataSourceDefinition {
        let json="{\"kind\":\"api\",\"fetch\":{\"workflow\":{\"script\":\"flow.js\",\"maxSteps\":2,\"commands\":{\"tool\":{\"cli\":\"/fake/tool\",\"args\":[\"{{argument}}\"]}},\"requests\":{\"local\":{\"url\":\"https://127.0.0.1:{{port}}\",\"propagateNetworkErrors\":true}},\"loopbackRequests\":[\"local\"]\(options)}},\"mapping\":{\"json\":{\"quotas\":[]}}}"
        return try JSONDecoder().decode(DataSourceDefinition.self,from:Data(json.utf8))
    }
    private func source(_ definition:DataSourceDefinition,script:String,cli:MockCLIExecutor=MockCLIExecutor(),local:MockNetworkClient=MockNetworkClient()) -> DataSource {
        DataSources.make(definition,providerId:"test",cliExecutor:cli,network:MockNetworkClient(),loopbackNetwork:local,makeTransport:{_,_,_,_ in MockRPCTransport()},scripts:{_ in script},environment:{_ in nil},homeDirectory:FileManager.default.temporaryDirectory,now:{Date()})
    }
    @Test func `fixed command arguments stay literal and declared loopback calls use the local network`() async throws {
        let cli=MockCLIExecutor(),local=MockNetworkClient()
        given(cli).execute(binary:.value("/fake/tool"),args:.value(["literal; echo nope"]),input:.any,timeout:.any,workingDirectory:.any,autoResponses:.any).willReturn(CLIResult(output:#"{"port":9999}"#))
        given(local).request(.any).willProduce { @Sendable request in
            #expect(request.url!.host == "127.0.0.1")
            #expect(request.url!.port == 9999)
            return (Data(#"{"done":true}"#.utf8),HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:nil)!)
        }
        let script="function next(r){if(r.local)return {result:r.local.json};if(r.tool)return {request:'local',values:{port:String(r.tool.json.port)}};return {command:'tool',values:{argument:'literal; echo nope'}};}"
        #expect(try await source(definition(),script:script,cli:cli,local:local).fetchResponse().text == #"{"done":true}"#)
    }
    @Test func `undeclared commands fail before execution`() async throws {
        let source=source(try definition(),script:"function next(){return {command:'undeclared'};}")
        await #expect(throws:DataSourceError(.fetch,.executionFailed("Unknown workflow command"))) { try await source.fetchResponse() }
    }
    @Test func `step limits bound repeated CLI calls`() async throws {
        let cli=MockCLIExecutor()
        given(cli).execute(binary:.any,args:.any,input:.any,timeout:.any,workingDirectory:.any,autoResponses:.any).willReturn(CLIResult(output:""))
        let source=source(try definition(),script:"function next(){return {command:'tool',values:{argument:'fixed'}};}",cli:cli)
        await #expect(throws:DataSourceError(.fetch,.executionFailed("Workflow request limit exceeded"))) { try await source.fetchResponse() }
        verify(cli).execute(binary:.any,args:.any,input:.any,timeout:.any,workingDirectory:.any,autoResponses:.any).called(2)
    }
    @Test func `script exceptions reveal no payload`() async throws {
        let source=source(try definition(),script:"function next(){throw Error('secret-token');}")
        await #expect(throws:DataSourceError(.fetch,.parseFailed("Workflow script failed"))) { try await source.fetchResponse() }
    }
    @Test func `readiness cannot issue quota HTTP requests`() async throws {
        let source=source(try definition(),script:"function next(){return {request:'local',values:{port:'9999'}};}")
        #expect(await source.isReady() == false)
    }
    @Test func `loopback trust refuses remote destinations before network access`() async throws {
        let json=#"{"kind":"api","fetch":{"workflow":{"script":"flow.js","commands":{},"requests":{"local":{"url":"https://remote.example:443","propagateNetworkErrors":true}},"loopbackRequests":["local"]}},"mapping":{"json":{"quotas":[]}}}"#
        let definition=try JSONDecoder().decode(DataSourceDefinition.self,from:Data(json.utf8))
        let source=source(definition,script:"function next(){return {request:'local'};}")
        await #expect(throws:DataSourceError(.fetch,.executionFailed("Invalid loopback URL"))) { try await source.fetchResponse() }
    }
    @Test func `optional commands cannot swallow cancellation`() async throws {
        let definition=try definition(",\"continueOnError\":{\"tool\":[\"*\"]}")
        guard case .workflow(let flow)=definition.fetch else { Issue.record("Missing workflow");return }
        let cli=MockCLIExecutor()
        given(cli).execute(binary:.any,args:.any,input:.any,timeout:.any,workingDirectory:.any,autoResponses:.any).willThrow(CancellationError())
        let fetcher=WorkflowFetcher(flow:flow,network:MockNetworkClient(),loopbackNetwork:MockNetworkClient(),makeExecutor:{_ in cli},
            script:"function next(){return {command:'tool',values:{argument:'fixed'}};}",now:{Date()},settingValue:{_ in nil})
        await #expect(throws:CancellationError.self) { try await fetcher.fetch(with:nil) }
    }
    @Test func `planner failures redact the original credential`() async throws {
        let definition=try definition().patched(with:.object(["credential":.object(["environment":.string("TEST_TOKEN")])]))
        let script="function next(r,c){return {error:{executionFailed:'Failed with '+c.credential.token}};}"
        let source=DataSources.make(definition,providerId:"test",cliExecutor:MockCLIExecutor(),network:MockNetworkClient(),makeTransport:{_,_,_,_ in MockRPCTransport()},scripts:{_ in script},environment:{_ in "private-value"},homeDirectory:FileManager.default.temporaryDirectory,now:{Date()})
        await #expect(throws:DataSourceError(.fetch,.executionFailed("Failed with [redacted]"))) { try await source.fetchResponse() }
    }

}

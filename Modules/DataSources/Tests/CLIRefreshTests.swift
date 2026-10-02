import Foundation
import Mockable
import Quotas
import Testing
@testable import DataSources

@Suite struct CLIRefreshTests {
    private final class Delays: @unchecked Sendable {
        private let lock=NSLock()
        private var values:[Double]=[]
        func add(_ value:Double) { lock.lock();defer{lock.unlock()};values.append(value) }
        func read() -> [Double] { lock.lock();defer{lock.unlock()};return values }
    }
    @Test func `CLI refresh rereads only its own file and preserves owner writes`() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let file=root.appendingPathComponent("oauth.json"),other=root.appendingPathComponent("other.json")
        try Data(#"{"token":"expired","metadata":"initial"}"#.utf8).write(to:file)
        try Data(#"{"token":"personal"}"#.utf8).write(to:other)
        let json=#"{"kind":"api","credential":{"jsonFile":{"path":"~/oauth.json","token":"$.token","strict":true},"refresh":{"cli":{"call":{"cli":"custom-cli","input":"/quit\n","environment":{"unset":["OTHER_KEY"],"set":{"TOOL_HOME":"isolated"}}},"onStatus":[401],"delaySeconds":1.5}}},"fetch":{"http":{"url":"https://example.com","headers":{"Authorization":"Bearer {{token}}"},"errors":{"401":"authenticationRequired"}}},"mapping":{"json":{"quotas":[]}}}"#
        let definition=try JSONDecoder().decode(DataSourceDefinition.self,from:Data(json.utf8))
        let network=MockNetworkClient(),cli=MockCLIExecutor(),delays=Delays()
        given(network).request(.any).willProduce { @Sendable request in
            let status=request.value(forHTTPHeaderField:"Authorization") == "Bearer expired" ? 401 : 200
            #expect(["Bearer expired","Bearer renewed"].contains(request.value(forHTTPHeaderField:"Authorization")))
            return (Data("{}".utf8),HTTPURLResponse(url:request.url!,statusCode:status,httpVersion:nil,headerFields:nil)!)
        }
        given(cli).locate(.value("custom-cli")).willReturn("/fake/custom-cli")
        given(cli).execute(binary:.value("custom-cli"),args:.any,input:.value("/quit\n"),timeout:.any,workingDirectory:.any,autoResponses:.any).willProduce { @Sendable _,_,_,_,_,_ in
            try Data(#"{"token":"renewed","metadata":"CLI-updated","unknown":42}"#.utf8).write(to:file)
            return CLIResult(output:"")
        }
        let source=DataSources.make(definition,providerId:"work",makeCLIExecutor:{call in
            #expect(call.cli == "custom-cli")
            #expect(call.environment.set["TOOL_HOME"] == "isolated")
            #expect(call.environment.unset == ["OTHER_KEY"])
            return cli
        },network:network,makeTransport:{_,_,_,_ in MockRPCTransport()},security:{_ in(1,"")},scripts:{_ in nil},secrets:nil,environment:{_ in nil},homeDirectory:root,now:{Date()},sleep:{delays.add($0)})
        #expect(try await source.fetchResponse().status == 200)
        #expect(delays.read() == [1.5])
        #expect(String(decoding:try Data(contentsOf:other),as:UTF8.self) == #"{"token":"personal"}"#)
        let document=try JSONSerialization.jsonObject(with:Data(contentsOf:file)) as! [String:Any]
        #expect(document["metadata"] as? String == "CLI-updated")
        #expect(document["unknown"] as? Int == 42)
        verify(cli).execute(binary:.any,args:.any,input:.any,timeout:.any,workingDirectory:.any,autoResponses:.any).called(1)
    }
    @Test func `optional failures expose no error payload and retries use bounded delays`() async throws {
        let json=#"{"kind":"api","fetch":{"httpFlow":{"script":"flow.js","continueOnError":["optional"],"requests":{"optional":{"url":"https://example.com/optional"},"quota":{"url":"https://example.com/quota"}}}},"mapping":{"json":{"quotas":[]}}}"#
        let definition=try JSONDecoder().decode(DataSourceDefinition.self,from:Data(json.utf8)),network=MockNetworkClient(),delays=Delays()
        given(network).request(.any).willProduce { @Sendable request in
            if request.url!.path == "/optional" { throw UsageError.executionFailed("secret-payload") }
            return (Data("{}".utf8),HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:nil)!)
        }
        let script="function next(r,c){if(r.quota)return {done:'quota'};if(r.optional&&r.optional.text!=='')throw Error('payload');var n=c.attempts.optional||0;if(n<3)return {request:'optional',delaySeconds:n?0.2*(n+1):0};return {request:'quota'};}"
        let source=DataSources.make(definition,providerId:"test",cliExecutor:MockCLIExecutor(),network:network,makeTransport:{_,_,_,_ in MockRPCTransport()},scripts:{_ in script},environment:{_ in nil},homeDirectory:FileManager.default.temporaryDirectory,now:{Date()},sleep:{delays.add($0)})
        #expect(try await source.fetchResponse().status == 200)
        #expect(delays.read().count == 3)
        for (actual,expected) in zip(delays.read(),[0,0.4,0.6]) { #expect(abs(actual-expected) < 0.000001) }
        verify(network).request(.matching{$0.url!.path == "/optional"}).called(3)
    }
    @Test func `file existence readiness does not parse credentials but missing files are unavailable`() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer{try? FileManager.default.removeItem(at:root)}
        let json=#"{"kind":"api","availability":"files","requiresFiles":["~/oauth.json"],"credential":{"jsonFile":{"path":"~/oauth.json","token":"$.token","strict":true}},"fetch":{"http":{"url":"https://example.com"}},"mapping":{"json":{"quotas":[]}}}"#
        let definition=try JSONDecoder().decode(DataSourceDefinition.self,from:Data(json.utf8))
        let source=DataSources.make(definition,providerId:"test",cliExecutor:MockCLIExecutor(),network:MockNetworkClient(),makeTransport:{_,_,_,_ in MockRPCTransport()},environment:{_ in nil},homeDirectory:root,now:{Date()})
        #expect(await source.isReady() == false)
        try Data("[]".utf8).write(to:root.appendingPathComponent("oauth.json"))
        #expect(await source.isReady())
        await #expect(throws:DataSourceError(.lookup,.parseFailed("Invalid credentials file"))) { try await source.fetchResponse() }
        try Data(#"{"token":123}"#.utf8).write(to:root.appendingPathComponent("oauth.json"))
        await #expect(throws:DataSourceError(.lookup,.authenticationRequired)) { try await source.fetchResponse() }
    }
}

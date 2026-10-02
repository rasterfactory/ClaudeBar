import Foundation
import Mockable
import Quotas
import Testing
@testable import DataSources

@Suite struct HTTPFlowTests {
    private func source(script: String, network: MockNetworkClient = MockNetworkClient()) throws -> DataSource {
        let json = #"{"kind":"api","fetch":{"httpFlow":{"script":"flow.js","requests":{"first":{"url":"https://example.com/first"},"second":{"url":"https://example.com/second","headers":{"X-Value":"{{selected}}"}}}}},"mapping":{"json":{"quotas":[]}}}"#
        let definition = try JSONDecoder().decode(DataSourceDefinition.self,from:Data(json.utf8))
        return DataSources.make(definition,providerId:"test",cliExecutor:MockCLIExecutor(),network:network,makeTransport:{_,_,_,_ in MockRPCTransport()},scripts:{ _ in script },environment:{_ in nil},homeDirectory:FileManager.default.temporaryDirectory,now:{Date()})
    }
    @Test func `a flow uses a prior response to fill only a declared request`() async throws {
        let network = MockNetworkClient()
        given(network).request(.any).willProduce { @Sendable request in
            let text = request.url?.path == "/first" ? "{\"selected\":\"chosen\"}" : "{\"value\":\"\(request.value(forHTTPHeaderField:"X-Value") ?? "missing")\"}"
            return (Data(text.utf8),HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:nil)!)
        }
        let source = try source(script:"function next(r) { if(r.second) return {done:'second'}; if(r.first) return {request:'second',values:{selected:r.first.json.selected}}; return {request:'first'}; }",network:network)
        #expect(try await source.fetchResponse().text == "{\"value\":\"chosen\"}")
    }
    @Test func `undeclared request targets fail before network access`() async throws {
        let source = try source(script:"function next(){return {request:'undeclared'};}")
        await #expect(throws:DataSourceError(.fetch,.executionFailed("Unknown HTTP flow request or request limit exceeded"))) { try await source.fetchResponse() }
    }
    @Test func `repeated requests stop at the bounded request count`() async throws {
        let network=MockNetworkClient()
        given(network).request(.any).willReturn((Data("{}".utf8),HTTPURLResponse(url:URL(string:"https://example.com")!,statusCode:200,httpVersion:nil,headerFields:nil)!))
        let source = try source(script:"function next(){return {request:'first'};}",network:network)
        await #expect(throws:DataSourceError(.fetch,.executionFailed("Unknown HTTP flow request or request limit exceeded"))) { try await source.fetchResponse() }
    }
    @Test func `flow exceptions expose no script payload`() async throws {
        let source = try source(script:"function next(){throw new Error('private-session');}")
        await #expect(throws:DataSourceError(.fetch,.parseFailed("HTTP flow script failed"))) { try await source.fetchResponse() }
    }
    @Test func `tagged lookup cannot embed a token in exported definition data`() throws {
        let json = #"{"setting":"apiKey","as":{"token":"embedded"}}"#
        #expect(throws:DecodingError.self) { try JSONDecoder().decode(CredentialLookup.self,from:Data(json.utf8)) }
    }
}

@Suite struct CredentialChoiceTests {
    private struct Keys: SecretStore {
        let values:[String:String]
        func secret(_ name:String,provider:String) -> String? { values[name] }
    }
    private struct UnexpectedBrowser: BrowserCookieReading {
        func stores(domains: [String], names: [String]) -> [[BrowserCookie]] { stores(domains: domains, names: names, includeEmpty: false) }
        func stores(domains:[String],names:[String],includeEmpty:Bool) -> [[BrowserCookie]] {
            Issue.record("A higher-priority saved key or manual cookie must avoid browser access")
            return []
        }
    }
    @Test(arguments:[true,false]) func `saved keys and manual cookies avoid unrelated browser credential access`(api:Bool) async throws {
        let json = #"{"kind":"api","credential":{"firstOf":[{"setting":"apiKey","as":{"mode":"api"}},{"bySetting":{"setting":"cookieSource","default":"auto","values":{"manual":{"setting":"cookie"},"auto":{"browserCookies":{"domains":["example.com"],"names":["session"],"format":"header"}}}},"as":{"mode":"cookie"}}]},"fetch":{"http":{"url":"https://example.com","headers":{"Authorization":"{{token}}","X-Mode":"{{mode}}"}}},"mapping":{"json":{"quotas":[]}}}"#
        let definition=try JSONDecoder().decode(DataSourceDefinition.self,from:Data(json.utf8)),network=MockNetworkClient()
        given(network).request(.any).willProduce { @Sendable request in
            let expected=api ? "key" : "manual-session"
            #expect(request.value(forHTTPHeaderField:"Authorization") == expected)
            #expect(request.value(forHTTPHeaderField:"X-Mode") == (api ? "api" : "cookie"))
            return (Data("{}".utf8),HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:nil)!)
        }
        let source=DataSources.make(definition,providerId:"test",cliExecutor:MockCLIExecutor(),network:network,makeTransport:{_,_,_,_ in MockRPCTransport()},settingValue:{_ in api ? "auto" : "manual"},browserCookies:UnexpectedBrowser(),secrets:Keys(values:api ? ["apiKey":"key"] : ["cookie":"manual-session"]),environment:{_ in nil},homeDirectory:FileManager.default.temporaryDirectory,now:{Date()})
        #expect(try await source.fetchResponse().status == 200)
    }
}

import Foundation
import Mockable
import Quotas
import Testing
@testable import DataSources

@Suite struct HTTPRegionalTests {
    @Test func `request errors redact credential values echoed by a server`() async throws {
        let request = try JSONDecoder().decode(HTTPRequest.self, from: Data(#"{"url":"https://example.com","acceptedStatuses":[200],"errors":{"default":{"executionFailed":"HTTP {{status}}: {{body}}"}}}"#.utf8))
        let network = MockNetworkClient()
        given(network).request(.any).willReturn((Data("echo private-token".utf8),HTTPURLResponse(url: URL(string:"https://example.com")!,statusCode:500,httpVersion:nil,headerFields:nil)!))
        let fetcher = HTTPFetcher(request:request,network:network,now:{Date()})
        do { _ = try await fetcher.fetch(with:Credential(["token":"private-token"])); Issue.record("Expected error") }
        catch let error as HTTPStatusError { #expect(error.reason == .executionFailed("HTTP 500: echo [redacted]")) }
    }
    @Test func `a definition can preserve its invalid-response error`() async throws {
        let request = HTTPRequest(url:"https://example.com", invalidResponseError:.executionFailed("Invalid HTTP response"))
        let network = MockNetworkClient()
        given(network).request(.any).willReturn((Data(),URLResponse(url:URL(string:"https://example.com")!,mimeType:nil,expectedContentLength:0,textEncodingName:nil)))
        let fetcher = HTTPFetcher(request:request,network:network,now:{Date()})
        await #expect(throws: UsageError.executionFailed("Invalid HTTP response")) { try await fetcher.fetch(with:nil) }
    }
    @Test func `a CLI definition can wrap execution failures while retaining missing-binary errors`() async throws {
        let executor = MockCLIExecutor()
        given(executor).execute(binary:.any,args:.any,input:.any,timeout:.any,workingDirectory:.any,autoResponses:.any).willThrow(UsageError.authenticationRequired)
        let fetcher = CLIFetcher(call:CLICall(cli:"example", wrapExecutionErrors:true), makeExecutor:{ _ in executor })
        await #expect(throws:UsageError.executionFailed(UsageError.authenticationRequired.localizedDescription)) { try await fetcher.fetch(with:nil) }
    }

}

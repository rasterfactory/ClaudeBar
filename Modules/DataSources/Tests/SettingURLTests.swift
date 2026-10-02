import Foundation
import Mockable
import Quotas
import Testing
@testable import DataSources

@Suite struct SettingURLTests {
    final class Choice: @unchecked Sendable { var value = "a" }
    @Test func `a running source reads changed settings and falls back for unknown selections`() async throws {
        let choice = Choice()
        let network = MockNetworkClient()
        given(network).request(.any).willProduce { request in
            let expected = choice.value == "b" ? "b.example" : "a.example"
            #expect(request.url?.host == expected)
            return (Data("{}".utf8),HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:nil)!)
        }
        let request = HTTPRequest(url:"https://a.example",urlBySetting:SettingURL(setting:"region",values:["a":"https://a.example","b":"https://b.example"]))
        let fetcher = HTTPFetcher(request:request,network:network,now:{Date()},settingValue:{_ in choice.value})
        _ = try await fetcher.fetch(with:nil)
        choice.value = "b"
        _ = try await fetcher.fetch(with:nil)
        choice.value = "unknown"
        _ = try await fetcher.fetch(with:nil)
        #expect(try JSONDecoder().decode(HTTPRequest.self,from:JSONEncoder().encode(request)) == request)
    }
    @Test func `an account selection takes precedence over global settings`() {
        let selector = SettingURL(setting:"region",value:"b",values:["a":"https://a.example","b":"https://b.example"])
        #expect(selector.resolve(value:"a") == "https://b.example")
    }
}

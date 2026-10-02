import Foundation
import Mockable
import Quotas
import Testing
@testable import DataSources

@Suite struct HTTPSequenceTests {
    private func sequence(first: String, status: Int = 200) -> HTTPSequenceFetcher {
        let network = MockNetworkClient()
        given(network).request(.any).willProduce { @Sendable request in
            if request.url?.path == "/second" {
                #expect(URLComponents(url:request.url!,resolvingAgainstBaseURL:false)?.queryItems?.first?.value == "team & org")
            }
            return (Data((request.url?.path == "/first" ? first : #"{"balance":12}"#).utf8),HTTPURLResponse(url:request.url!,statusCode:status,httpVersion:nil,headerFields:nil)!)
        }
        let definition = HTTPSequence(steps:[
            .init(name:"identity",request:HTTPRequest(url:"https://example.test/first")),
            .init(name:"usage",request:HTTPRequest(url:"https://example.test/second"),queryFrom:["org":["$.identity.org"]])])
        return HTTPSequenceFetcher(sequence:definition,network:network,now:{Date()})
    }
    @Test func `named responses retain identity and encode dependent queries`() async throws {
        let response = try await sequence(first:#"{"org":"team & org"}"#).fetch(with:nil)
        let body = try #require(try JSONSerialization.jsonObject(with:response.body) as? [String:Any])
        #expect((body["identity"] as? [String:Any])?["org"] as? String == "team & org")
        #expect((body["usage"] as? [String:Any])?["balance"] as? Int == 12)
    }
    @Test(arguments:["[]","not JSON"]) func `invalid JSON objects cannot become successful usage`(_ first:String) async {
        await #expect(throws:UsageError.self) { try await sequence(first:first).fetch(with:nil) }
    }
    @Test func `HTTP failure stops a sequence`() async {
        await #expect(throws:HTTPStatusError.self) { try await sequence(first:"{}",status:500).fetch(with:nil) }
    }
}

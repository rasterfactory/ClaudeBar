import DataSources
import Domain
import Foundation
import Mockable
import Providers
import Testing
@testable import Infrastructure

@Suite struct GeminiProjectRepositoryTests {
    private func probe(network: MockNetworkClient, root: URL) -> GeminiDefinitionProbe {
        GeminiDefinitionProbe(homeDirectory: root.path, timeout: 1, networkClient: network, cliExecutor: MockCLIExecutor(), clock: NoWait())
    }
    private struct NoWait: Clock {
        func sleep(for duration: Duration) async throws {}
        func sleep(nanoseconds: UInt64) async throws {}
    }
    private func home() throws -> URL {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root.appendingPathComponent(".gemini"),withIntermediateDirectories:true)
        try Data(#"{"access_token":"test-token"}"#.utf8).write(to:root.appendingPathComponent(".gemini/oauth_creds.json"))
        return root
    }
    @Test func `project network failures retry three times then fetch projectless quota`() async throws {
        let root=try home(); defer { try? FileManager.default.removeItem(at:root) }
        let network=MockNetworkClient()
        given(network).request(.any).willProduce { @Sendable request in
            if request.url!.absoluteString.contains("loadCodeAssist") { throw URLError(.notConnectedToInternet) }
            #expect(String(decoding:request.httpBody!,as:UTF8.self) == "{}")
            return (Data(#"{"buckets":[{"modelId":"gemini-pro","remainingFraction":0.4}]}"#.utf8),HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:nil)!)
        }
        #expect(try await probe(network:network,root:root).probe().quotas[0].percentRemaining == 40)
        verify(network).request(.matching { $0.url!.absoluteString.contains("loadCodeAssist") }).called(3)
    }
    @Test func `resolved Code Assist project is sent to quota endpoint`() async throws {
        try await assertDiscovery(project:#"{"currentTier":{"id":"standard-tier"},"cloudaicompanionProject":"alien-superstate-rq4hk"}"#, expected:"alien-superstate-rq4hk")
    }
    @Test func `discovery sends bearer token and GEMINI plugin metadata`() async throws {
        try await assertDiscovery(project:#"{"cloudaicompanionProject":"alien-superstate-rq4hk"}"#,expected:"alien-superstate-rq4hk",checkRequest:true)
    }
    @Test func `missing Code Assist project immediately fetches projectless quota`() async throws {
        try await assertDiscovery(project:#"{"currentTier":{"id":"standard-tier"}}"#,expected:nil)
    }
    @Test func `the resolved personal OAuth project wins without GCP project enumeration`() async throws {
        try await assertDiscovery(project:#"{"cloudaicompanionProject":"alien-superstate-rq4hk"}"#,expected:"alien-superstate-rq4hk")
    }
    private func assertDiscovery(project:String,expected:String?,checkRequest:Bool=false) async throws {
        let root=try home(); defer { try? FileManager.default.removeItem(at:root) }
        let network=MockNetworkClient()
        given(network).request(.any).willProduce { @Sendable request in
            let isProject=request.url!.absoluteString.contains("loadCodeAssist")
            if isProject && checkRequest {
                #expect(request.value(forHTTPHeaderField:"Authorization") == "Bearer test-token")
                #expect(request.httpMethod == "POST")
                #expect(String(decoding:request.httpBody!,as:UTF8.self) == #"{"metadata":{"pluginType":"GEMINI"}}"#)
            }
            if !isProject {
                let body=try JSONSerialization.jsonObject(with:request.httpBody!) as! [String:String]
                #expect(body["project"] == expected)
            }
            let body=isProject ? project : #"{"buckets":[{"modelId":"gemini-pro","remainingFraction":0.8}]}"#
            return (Data(body.utf8),HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:nil)!)
        }
        #expect(try await probe(network:network,root:root).probe().quotas[0].percentRemaining == 80)
        verify(network).request(.matching { $0.url!.absoluteString.contains("loadCodeAssist") }).called(1)
    }
}

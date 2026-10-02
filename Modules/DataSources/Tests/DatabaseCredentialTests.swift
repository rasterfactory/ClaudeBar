import Foundation
import Mockable
import Quotas
import Testing
@testable import DataSources

@Suite struct DatabaseCredentialTests {
    private struct Store: SecretStore {
        let token:String
        func secret(_ name:String,provider:String)->String? {token}
    }
    private func source(_ credential:String, token:String="header.eyJzdWIiOiJ3b3JrLXVzZXIifQ.signature") throws -> DataSource {
        let json="{\"kind\":\"api\",\"credential\":\(credential),\"fetch\":{\"http\":{\"url\":\"https://example.test\",\"headers\":{\"Cookie\":\"{{user}}::{{token}}\"}}},\"mapping\":{\"json\":{\"quotas\":[]}}}"
        let definition=try JSONDecoder().decode(DataSourceDefinition.self,from:Data(json.utf8))
        let network=MockNetworkClient()
        given(network).request(.any).willProduce { @Sendable request in
            #expect(request.value(forHTTPHeaderField:"Cookie") == "work-user::"+token)
            return (Data("{}".utf8),HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:nil)!)
        }
        return DataSources.make(definition,providerId:"example",cliExecutor:MockCLIExecutor(),network:network,makeTransport:{_,_,_,_ in MockRPCTransport()},secrets:Store(token:token),environment:{_ in nil},homeDirectory:FileManager.default.temporaryDirectory,now:{Date()})
    }
    @Test func `SQL credentials read their own database without writing it`() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:root)}
        let db=root.appendingPathComponent("auth.db")
        let token="header.eyJzdWIiOiJ3b3JrLXVzZXIifQ.signature"
        let process=Process();process.executableURL=URL(fileURLWithPath:"/usr/bin/sqlite3");process.arguments=[db.path,"CREATE TABLE tokens(value TEXT); INSERT INTO tokens VALUES ('\(token)');"]
        try process.run();process.waitUntilExit();#expect(process.terminationStatus == 0)
        let before=try Data(contentsOf:db)
        let lookup="{\"sqlite\":{\"path\":\"\(db.path)\",\"query\":\"SELECT value AS token FROM tokens\",\"fields\":{\"token\":\"$.token\"}},\"claims\":{\"fields\":{\"user\":\"sub\"},\"required\":[\"user\"]}}"
        _ = try await source(lookup).fetchResponse()
        #expect(try Data(contentsOf:db) == before)
    }
    @Test func `claims decorate vault credentials and retain the full subject`() async throws {
        _ = try await source(#"{"setting":"token","claims":{"fields":{"user":"sub"},"required":["user"]}}"#).fetchResponse()
    }
    @Test(arguments:[("not-a-jwt","Invalid JWT format"),("header.!invalid!.sig","Failed to decode JWT payload"),("header.eyJpYXQiOjF9.sig","JWT payload missing 'sub' claim")])
    func `bad required claims fail before a request`(_ fixture:(String,String)) async throws {
        let reader=try source(#"{"setting":"token","claims":{"fields":{"user":"sub"},"required":["user"]}}"#,token:fixture.0)
        await #expect(throws:DataSourceError(.lookup,.parseFailed(fixture.1))) {try await reader.fetchResponse()}
    }
}

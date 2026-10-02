import Foundation
import Testing
@testable import DataSources

@Suite struct ProfileDirectoryTests {
    @Test func `explicit profile directories survive definition round trips`() throws {
        let definition = try JSONDecoder().decode(CLICall.self, from:Data(#"{"cli":"example","workingDirectory":{"path":"/tmp/work profile"}}"#.utf8))
        let data = try JSONEncoder().encode(definition)
        let object = try #require(JSONSerialization.jsonObject(with:data) as? [String:Any])
        #expect((object["workingDirectory"] as? [String:String])?["path"] == "/tmp/work profile")
    }
}

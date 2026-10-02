import Foundation
import Testing
@testable import DataSources

@Suite struct PipeCLIDefinitionTests {
    @Test func `a pipe command survives definition round trips`() throws {
        let call = try JSONDecoder().decode(CLICall.self, from: Data(#"{"cli":"example","mode":"pipes","input":"/usage\n/quit\n"}"#.utf8))
        let document = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(call)) as? [String:Any])
        #expect(document["mode"] as? String == "pipes")
        #expect(document["input"] as? String == "/usage\n/quit\n")
        #expect(String(describing: type(of: CLIFetcher.system(call))) == "PipeCLIExecutor")
    }
}

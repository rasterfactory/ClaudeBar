import Foundation
import Quotas
import Testing
@testable import DataSources

@Suite struct CompanionLookupTests {
    private func rule() throws -> CompanionLookups {
        try JSONDecoder().decode(CompanionLookups.self, from: Data(#"{"fields":{"username":{"environment":"USER"}},"required":["username"],"missing":{"executionFailed":"Enter username"}}"#.utf8))
    }
    @Test func `a companion never supplies a missing primary token`() throws {
        let lookup = CompanionsReader(base: EnvironmentReader(name: "KEY", environment: { _ in nil }),
            fields: ["username": EnvironmentReader(name: "USER", environment: { _ in "someone" })],
            rule: try rule())
        #expect(try lookup.find() == nil)
    }
    @Test func `missing required companion returns the declared error`() {
        let lookup = CompanionsReader(base: EnvironmentReader(name: "KEY", environment: { _ in "token" }),
            fields: ["username": EnvironmentReader(name: "USER", environment: { _ in nil })],
            rule: try! rule())
        #expect(throws: UsageError.executionFailed("Enter username")) { try lookup.find() }
    }
    @Test func `a companion cannot overwrite token fields or require undeclared fields`() {
        for json in [#"{"environment":"KEY","companions":{"fields":{"token":{"environment":"USER"}}}}"#,
                     #"{"environment":"KEY","companions":{"fields":{},"required":["username"]}}"#] {
            #expect(throws: DecodingError.self) { try JSONDecoder().decode(CredentialLookup.self, from: Data(json.utf8)) }
        }
    }
}

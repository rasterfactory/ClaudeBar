import Foundation
import Testing
@testable import Domain

@Suite
struct UsernameTests {
    @Test func `should accept every name the shared rule allows`() throws {
        for text in try LeaderboardVectors.load().usernames.valid {
            #expect(Username(text)?.value == text, "\(text)")
        }
    }

    @Test func `should refuse every name the shared rule refuses`() throws {
        for text in try LeaderboardVectors.load().usernames.invalid {
            #expect(Username(text) == nil, "\(text)")
        }
    }

    @Test func `should show a username with its at sign`() {
        #expect(Username("tokenwhale")?.description == "@tokenwhale")
    }
}

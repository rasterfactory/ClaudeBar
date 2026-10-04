import Foundation
import Testing
@testable import Domain

@Suite
struct ProfileLinkTests {
    @Test func `should accept every profile handle the shared rules allow`() throws {
        for pair in try LeaderboardVectors.load().links.valid {
            let platform = try #require(ProfileLink.Platform(rawValue: pair[0]))
            #expect(ProfileLink(platform: platform, handle: pair[1]) != nil, "\(pair)")
        }
    }

    @Test func `should refuse every profile handle the shared rules refuse`() throws {
        for pair in try LeaderboardVectors.load().links.invalid {
            guard let platform = ProfileLink.Platform(rawValue: pair[0]) else { continue }   // an unknown platform can't even be named
            #expect(ProfileLink(platform: platform, handle: pair[1]) == nil, "\(pair)")
        }
    }

    @Test func `should link to the platform's own address and the handle, never anything typed`() throws {
        let link = try #require(ProfileLink(platform: .github, handle: "octocat"))
        #expect(link.url.absoluteString == "https://github.com/octocat")
        #expect(try #require(ProfileLink(platform: .x, handle: "jack")).url.absoluteString == "https://x.com/jack")
        #expect(try #require(ProfileLink(platform: .instagram, handle: "a.b_c")).url.absoluteString == "https://instagram.com/a.b_c")
    }

    @Test func `should accept a handle the person typed with an at sign or spaces around it`() {
        #expect(ProfileLink.typed(" @jack ", on: .x)?.handle == "jack")
        #expect(ProfileLink(platform: .x, handle: "@jack") == nil)
    }

    @Test func `should send a profile link as just a platform and a handle`() throws {
        let link = try #require(ProfileLink(platform: .x, handle: "jack"))
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(link)) as? [String: String]
        #expect(json == ["platform": "x", "handle": "jack"])
    }
}

import Foundation
import Testing
@testable import Domain

@Suite
struct ProfileLinkTests {
    @Test func `every handle the shared rules allow is a link`() throws {
        for pair in try LeaderboardVectors.load().links.valid {
            let platform = try #require(ProfileLink.Platform(rawValue: pair[0]))
            #expect(ProfileLink(platform: platform, handle: pair[1]) != nil, "\(pair)")
        }
    }

    @Test func `every handle the shared rules refuse is not`() throws {
        for pair in try LeaderboardVectors.load().links.invalid {
            guard let platform = ProfileLink.Platform(rawValue: pair[0]) else { continue }   // an unknown platform can't even be named
            #expect(ProfileLink(platform: platform, handle: pair[1]) == nil, "\(pair)")
        }
    }

    @Test func `a link is the platform's own address and the handle, never anything typed`() throws {
        let link = try #require(ProfileLink(platform: .github, handle: "octocat"))
        #expect(link.url.absoluteString == "https://github.com/octocat")
        #expect(try #require(ProfileLink(platform: .x, handle: "jack")).url.absoluteString == "https://x.com/jack")
        #expect(try #require(ProfileLink(platform: .instagram, handle: "a.b_c")).url.absoluteString == "https://instagram.com/a.b_c")
    }

    @Test func `typing an at sign or spaces still makes the handle`() {
        #expect(ProfileLink.typed(" @jack ", on: .x)?.handle == "jack")
        #expect(ProfileLink(platform: .x, handle: "@jack") == nil)
    }

    @Test func `the wire form is a platform and a handle`() throws {
        let link = try #require(ProfileLink(platform: .x, handle: "jack"))
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(link)) as? [String: String]
        #expect(json == ["platform": "x", "handle": "jack"])
    }
}

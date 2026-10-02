import Foundation
import Mockable
import Testing
@testable import DataSources

@Suite struct BrowserCookieTests {
    private struct Cookies: BrowserCookieReading {
        let stores: [[BrowserCookie]]
        func stores(domains: [String], names: [String]) -> [[BrowserCookie]] { domains == ["example.com"] ? stores : [] }
    }
    private func reader(format: String, stores: [[BrowserCookie]], region: String? = nil) throws -> BrowserCookieReader {
        let data = Data("{\"domains\":[\"example.com\"],\"domainsBySetting\":{\"setting\":\"region\",\"values\":{\"other\":[\"other.com\"]}},\"names\":[\"session\",\"identity\"],\"format\":\"\(format)\"}".utf8)
        let query = try JSONDecoder().decode(BrowserCookieCredential.self, from: data)
        return BrowserCookieReader(query: query, cookies: Cookies(stores: stores), settingValue: { _ in region })
    }
    @Test func `value chooses the first nonempty matching cookie across ordered stores`() throws {
        let result = try reader(format: "value", stores: [[.init(name:"session",value:"")],[.init(name:"other",value:"ignored"),.init(name:"session",value:"first"),.init(name:"session",value:"second")]]).find()
        #expect(result?.credential.token == "first")
    }
    @Test func `header includes declared cookies from one store only`() throws {
        let result = try reader(format: "header", stores: [[.init(name:"session",value:"s"),.init(name:"identity",value:"i"),.init(name:"other",value:"ignored")],[.init(name:"session",value:"other-store")]]).find()
        #expect(result?.credential.token == "session=s; identity=i")
    }
    @Test func `region selects its own domains and never uses another region's cookies`() throws {
        #expect(try reader(format: "value", stores: [[.init(name:"session",value:"s")]], region:"other").find() == nil)
    }
}

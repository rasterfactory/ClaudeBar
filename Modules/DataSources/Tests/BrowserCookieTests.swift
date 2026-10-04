import Foundation
import Mockable
import Testing
@testable import DataSources

/// `browserCookies` — *COOKIE SOURCE*: the first store holding a named cookie.
@Suite
struct BrowserCookieTests {
    private func reader(_ format: BrowserCookieCredential.Format, stores: [[BrowserCookie]]) -> BrowserCookieReader {
        let cookies = MockBrowserCookieReading()
        given(cookies).stores(domains: .value(["acme.test"]), names: .value(["session", "csrf"])).willReturn(stores)
        return BrowserCookieReader(query: BrowserCookieCredential(domains: ["acme.test"], names: ["session", "csrf"], format: format),
                                   cookies: cookies)
    }

    @Test
    func `should use the first named cookie's value as the key when the definition asks for a value`() throws {
        let found = try reader(.value, stores: [[BrowserCookie(name: "session", value: "s-1"), BrowserCookie(name: "csrf", value: "c-1")]]).find()
        #expect(found?.credential.token == "s-1")
    }

    @Test
    func `should send every named cookie as one Cookie header when the definition asks for a header`() throws {
        let found = try reader(.header, stores: [[BrowserCookie(name: "session", value: "s-1"), BrowserCookie(name: "csrf", value: "c-1")]]).find()
        #expect(found?.credential.token == "session=s-1; csrf=c-1")
    }

    @Test
    func `should pass over a browser whose cookies are empty for the next one`() throws {
        let found = try reader(.value, stores: [[BrowserCookie(name: "session", value: "")], [BrowserCookie(name: "session", value: "s-2")]]).find()
        #expect(found?.credential.token == "s-2")
    }

    @Test
    func `should find no key when no browser is signed in`() throws {
        #expect(try reader(.value, stores: []).find() == nil)
    }

    @Test
    func `should name the site, never a cookie's value, in the lookup order`() throws {
        let lookup = try JSONDecoder().decode(CredentialLookup.self, from: Data(#"{"browserCookies":{"domains":["acme.test"],"names":["session"]}}"#.utf8))
        #expect(lookup.lookupOrder == ["Browser cookies for acme.test"])
        #expect(lookup == .browserCookies(BrowserCookieCredential(domains: ["acme.test"], names: ["session"])))
    }
}

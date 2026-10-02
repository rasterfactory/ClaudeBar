import Mockable
import Foundation
import SweetCookieKit

/// One browser store's cookies, in its native order. Values never enter logs.
public struct BrowserCookie: Sendable, Equatable {
    public let name: String
    public let value: String
    public init(name: String, value: String) { self.name = name; self.value = value }
}
@Mockable
public protocol BrowserCookieReading: Sendable {
    func stores(domains: [String], names: [String]) -> [[BrowserCookie]]
}
public struct SystemBrowserCookies: BrowserCookieReading {
    public init() {}
    public func stores(domains: [String], names: [String]) -> [[BrowserCookie]] {
        let client = BrowserCookieClient()
        let query = BrowserCookieQuery(domains: domains, domainMatch: .suffix, includeExpired: false)
        
        for browser in Browser.defaultImportOrder {
            guard let stores = try? client.records(matching: query, in: browser) else { continue }
            for store in stores {
                let matches = store.cookies(origin: query.origin).filter { names.contains($0.name) && !$0.value.isEmpty }.map { BrowserCookie(name: $0.name, value: $0.value) }
                if !matches.isEmpty { return [matches] }
            }
        }
        return []
    }
}
struct BrowserCookieReader: CredentialFinding {
    let query: BrowserCookieCredential
    let cookies: any BrowserCookieReading
    let settingValue: @Sendable (String) -> String?
    func find() throws -> FoundCredential? {
        let domains = query.domainsBySetting?.resolve(selected: query.domainsBySetting?.setting.flatMap(settingValue)) ?? query.domains
        for store in cookies.stores(domains: domains, names: query.names) {
            let matches = store.filter { query.names.contains($0.name) && !$0.value.isEmpty }
            guard let first = matches.first else { continue }
            let token = query.format == .value ? first.value : matches.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
            return FoundCredential(credential: Credential(["token": token]), save: nil)
        }
        return nil
    }
}

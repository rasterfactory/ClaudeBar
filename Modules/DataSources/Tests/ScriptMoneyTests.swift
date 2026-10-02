import Foundation
import Quotas
import Testing
@testable import DataSources

@Suite
struct ScriptMoneyTests {
    private func read(_ output: String) throws -> UsageSnapshot {
        let definition = DataSourceDefinition(kind: "api", fetch: .http(HTTPRequest(url: "https://example.test")),
                                              mapping: .script(ScriptMapping(file: "balance.js")))
        let source = DataSources.make(definition, providerId: "example", scripts: { _ in "function read() { return \(output); }" })
        return try source.read(Response(text: "{}"))
    }

    @Test
    func `a script returns an exact balance without a fabricated percentage`() throws {
        let usage = try read(#"{quotas:[{type:'model',name:'Balance',left:{money:'1234567890.123456789',currency:'CNY'}}]}"#)
        let quota = try #require(usage.quotas.first)
        #expect(quota.left == .money(Money(Decimal(string: "1234567890.123456789")!, currency: "CNY"), of: nil))
        #expect(quota.percentLeft == nil)
        #expect(quota.window == nil)
    }

    @Test
    func `a script can return money of a ceiling`() throws {
        let usage = try read(#"{quotas:[{type:'model',name:'Credits',left:{money:'12.50',of:'50',currency:'USD'}}]}"#)
        #expect(usage.quotas.first?.left == .money(Money(Decimal(string: "12.50")!, currency: "USD"), of: Money(50, currency: "USD")))
        #expect(usage.quotas.first?.percentLeft == 25)
    }

    @Test
    func `existing percentage scripts keep working`() throws {
        let usage = try read(#"{quotas:[{type:'session',percentRemaining:37}]}"#)
        #expect(usage.quotas.first?.left == .share(37))
    }

    @Test(arguments: [#"{type:'model',name:'Balance'}"#, #"{type:'model',name:'Balance',percentRemaining:50,left:{money:'1'}}"#, #"{type:'model',name:'Balance',left:{money:'nope'}}"#])
    func `missing ambiguous and invalid amounts are refused`(_ quota: String) {
        #expect(throws: DataSourceError.self) { try read("{quotas:[\(quota)]}") }
    }
}

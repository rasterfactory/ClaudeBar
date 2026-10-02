import Foundation
import Quotas
import Testing
@testable import DataSources

@Suite struct ScriptReportTests {
    private func read(_ script: String, input: String = "{}") throws -> UsageSnapshot {
        let definition = DataSourceDefinition(kind: "report", fetch: .http(HTTPRequest(url: "https://example.test")), mapping: .script(ScriptMapping(file:"report.js")))
        return try DataSources.make(definition, providerId:"example", scripts:{ _ in script }).read(Response(text:input))
    }
    @Test func `report metadata and notes survive the mapping boundary`() throws {
        let usage = try read("function read() { return {quotas:[{type:'time',name:'Pool 5h',percentRemaining:60,group:'Pool',compactTitle:'5h',menuBarTitle:'Pool',spend:{used:'1.01',limit:'12.50'}}],metrics:[{label:'Account',value:'No usage reported',unit:'',icon:'person',group:'Work'}]}; }")
        let quota = try #require(usage.quotas.first)
        #expect(quota.group == "Pool" && quota.compactTitle == "5h" && quota.menuBarTitle == "Pool")
        #expect(quota.dollarUsed == Decimal(string:"1.01") && quota.dollarCap == Decimal(string:"12.50"))
        #expect(quota.percentRemaining == 60)
        #expect(usage.extensionMetrics?.first?.group == "Work")
    }
    @Test(arguments:[("1.005","1.01"),("-1.005","-1.01"),("1.25e1","12.50"),("5e-3","0.01"),("123456789012345.005","123456789012345.01")])
    func `decimal helpers preserve the original JSON number token`(_ fixture: (String,String)) throws {
        let usage = try read("function read(r) { const j=jsonDecimal(r.text); return {quotas:[{type:'model',name:'Balance',left:{money:decimalCents(j.amount)}}],account:{email:j.email}}; }",input:"{\"amount\":\(fixture.0),\"email\":\"x1.005@example.test\"}")
        #expect(usage.quotas.first?.dollarRemaining == Decimal(string:fixture.1))
        #expect(usage.accountEmail == "x1.005@example.test")
    }
}

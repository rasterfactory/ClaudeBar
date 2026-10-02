import DataSources
import Domain
import Foundation
import Providers

enum AlibabaDefinitionFixtures {
    static func parse(_ data: Data, providerId: String) throws -> UsageSnapshot {
        let definition = try Providers.builtIn("alibaba")
        let source = DataSources.make(definition.dataSource("api")!, providerId:providerId,scripts:Providers.builtInScripts)
        do { return try source.read(Response(body:data)) }
        catch let error as DataSourceError { throw error.reason }
    }
}

import Mockable

extension AlibabaDefinitionFixtures {
    private static var flow: HTTPFlow {
        guard case .httpFlow(let flow) = try! Providers.builtIn("alibaba").dataSource("api")!.fetch else { fatalError("Expected HTTP flow") }
        return flow
    }
    static func apiQuotaURL(for region: AlibabaRegion) -> URL { URL(string:flow.requests["api"]!.urlBySetting!.values[region.rawValue]!)! }
    static func consoleRPCURL(for region: AlibabaRegion) -> URL { URL(string:flow.requests["console"]!.urlBySetting!.values[region.rawValue]!)! }
    private final class Requests: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [URLRequest] = []
        func add(_ request: URLRequest) { lock.lock(); defer { lock.unlock() }; stored.append(request) }
        var values: [URLRequest] { lock.lock(); defer { lock.unlock() }; return stored }
    }
    private struct Keys: SecretStore {
        let values: [String:String]
        func secret(_ name:String,provider:String) -> String? { values[name] }
    }
    private struct NoCookies: BrowserCookieReading { func stores(domains: [String], names: [String]) -> [[BrowserCookie]] { stores(domains: domains, names: names, includeEmpty: false) }
        func stores(domains:[String],names:[String],includeEmpty:Bool) -> [[BrowserCookie]] { [] } }
    static func capture(region: AlibabaRegion = .international, key: String? = nil, cookie: String? = nil, html: String = "") async -> [URLRequest] {
        let requests = Requests(), network = MockNetworkClient()
        given(network).request(.any).willProduce { @Sendable request in
            requests.add(request)
            let data = Data((request.httpMethod == "GET" ? html : "{}").utf8)
            return (data,HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:nil)!)
        }
        let definition = try! Providers.builtIn("alibaba")
        let keys = Keys(values:["apiKey":key,"cookie":cookie].compactMapValues { $0 })
        let source = DataSources.make(definition.dataSource("api")!,providerId:"alibaba",cliExecutor:MockCLIExecutor(),network:network,makeTransport:{_,_,_,_ in MockRPCTransport()},scripts:Providers.builtInScripts,settingValue:{ $0 == "region" ? region.rawValue : $0 == "cookieSource" ? "manual" : nil },browserCookies:NoCookies(),secrets:keys,environment:{_ in nil},homeDirectory:FileManager.default.temporaryDirectory,now:{Date()})
        _ = try? await source.fetchResponse()
        return requests.values
    }
    static func apiRequestBody(for region: AlibabaRegion) async -> Data { await capture(region:region,key:"fake-api-key").last?.httpBody ?? Data() }
    static func consoleRequestBody(for region: AlibabaRegion, secToken: String) async -> Data { await capture(region:region,cookie:"sec_token=\(secToken)").last?.httpBody ?? Data() }
    private static func token(in requests: [URLRequest]) -> String? {
        guard let request = requests.last,request.httpMethod == "POST",let body=request.httpBody,let text=String(data:body,encoding:.utf8) else { return nil }
        return URLComponents(string:"https://example.com/?"+text)?.queryItems?.first { $0.name == "sec_token" }?.value
    }
    static func extractCookieValue(name: String, from cookie: String) async -> String? { token(in:await capture(cookie:cookie)) }
    static func extractSecTokenFromHTML(_ html: String) async -> String? { token(in:await capture(cookie:"login_aliyunid_ticket=fake-ticket",html:html)) }
    struct Region {
        let source: AlibabaRegion
        let data: [String:String]
        var displayName: String { source.displayName }
        var gatewayBaseURLString: String { data["base"]! }
        var currentRegionID: String { data["region"]! }
        var commodityCode: String { data["commodity"]! }
        var consoleRPCAction: String { data["action"]! }
        var consoleRPCBaseURLString: String { data["rpc"]! }
        var dashboardURL: URL { URL(string:data["dashboard"]!)! }
    }
    static func region(_ region:AlibabaRegion) -> Region {
        let bytes = try! JSONEncoder().encode(flow.constants!["regions"]!)
        let values = try! JSONSerialization.jsonObject(with:bytes) as! [String:[String:String]]
        return Region(source:region,data:values[region.rawValue]!)
    }
}

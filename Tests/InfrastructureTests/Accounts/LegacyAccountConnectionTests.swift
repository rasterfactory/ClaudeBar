import Foundation
import Testing
import Domain
import Providers
@testable import Infrastructure

@Suite("Independent legacy API account connections")
@MainActor
struct LegacyAccountConnectionTests {
    nonisolated static let tokenProviders = ["antigravity", "zai", "copilot", "kimi", "minimax", "deepseek", "vercel-gateway", "alibaba"]

    @Test(arguments: tokenProviders)
    func twoKeysProduceDifferentUsageAndMissingKeyFailsClosed(_ id: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "account-connections-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let credentials = UserDefaultsCredentialRepository(defaults: defaults, keyPrefix: "test.")
        let connections = LegacyAccountConnections(credentials: credentials, networkClient: AccountUsageFixtureNetwork(providerId: id), settingsRoot: root)
        let personal = ProviderAccountConfig(accountId: "personal", label: "Personal", probeConfig: ["mode": "copilotAPI"])
        let work = ProviderAccountConfig(accountId: "work", label: "Work", probeConfig: ["mode": "copilotAPI"])
        try connections.saveSecret("personal-fixture-key", providerId: id, config: personal)
        try connections.saveSecret("work-fixture-key", providerId: id, config: work)
        let a = try connections.source(providerId: id, config: personal)
        let b = try connections.source(providerId: id, config: work)
        let personalUsage = try await a.refresh(.interactive)
        let workUsage = try await b.refresh(.background)
        #expect(!personalUsage.quotas.isEmpty)
        #expect(!workUsage.quotas.isEmpty)
        #expect(personalUsage.quotas != workUsage.quotas)
        #expect(connections.deleteSecret(providerId: id, config: work))
        await #expect(throws: (any Error).self) { try await b.refresh(.interactive) }
        #expect(try await a.refresh(.interactive).quotas == personalUsage.quotas)
        let restarted = LegacyAccountConnections(credentials: credentials, networkClient: AccountUsageFixtureNetwork(providerId: id), settingsRoot: root)
        #expect(try await restarted.source(providerId: id, config: personal).refresh(.interactive).quotas == personalUsage.quotas)
        await #expect(throws: (any Error).self) { try await restarted.source(providerId: id, config: work).refresh(.interactive) }
    }

    @Test
    func allLegacyBuiltInsHaveAConnectionRecipe() {
        let ids = ["gemini", "antigravity", "zai", "copilot", "bedrock", "ampcode", "kimi", "kiro", "cursor", "minimax", "deepseek", "vercel-gateway", "alibaba", "mistral", "opencode-go", "omp", "grok", "commandcode"]
        #expect(ids.allSatisfy { AccountConnectionRecipe.builtIn($0) != nil })
    }
}

/// Responses depend on the actual authorization value selected by each reader.
private struct AccountUsageFixtureNetwork: NetworkClient {
    let providerId: String
    func request(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let authentication = request.value(forHTTPHeaderField: "Authorization") ?? request.value(forHTTPHeaderField: "x-api-key") ?? ""
        guard authentication.contains("fixture-key") else { throw UsageError.authenticationRequired }
        let left = authentication.contains("work") ? 30 : 80
        let used = 100 - left
        let json: String = switch providerId {
        case "minimax": #"{"base_resp":{"status_code":0},"model_remains":[{"model_name":"minimax-m2","current_interval_total_count":100,"current_interval_usage_count":\#(used),"remains_time":1234,"end_time":2000000000000}]}"#
        case "zai": #"{"data":{"limits":[{"type":"TOKENS_LIMIT","percentage":\#(used)}]}}"#
        case "copilot": #"{"copilot_plan":"business","quota_reset_date":"2027-03-01","quota_snapshots":{"premium_interactions":{"entitlement":100,"percent_remaining":\#(left),"remaining":\#(left),"unlimited":false}}}"#
        case "kimi": #"{"usages":[{"scope":"FEATURE_CODING","detail":{"limit":"100","used":"\#(used)","remaining":"\#(left)","resetTime":"2027-03-01T00:00:00Z"},"limits":[{"window":{"duration":300,"timeUnit":"TIME_UNIT_MINUTE"},"detail":{"limit":"100","used":"\#(used)","remaining":"\#(left)","resetTime":"2027-03-01T00:00:00Z"}}]}]}"#
        case "vercel-gateway": #"{"balance":\#(left),"total_used":\#(used)}"#
        case "deepseek": #"{"is_available":true,"balance_infos":[{"currency":"USD","total_balance":"\#(left)","granted_balance":"0","topped_up_balance":"\#(left)"}]}"#
        case "alibaba": #"{"code":"200","success":true,"data":{"codingPlanInstanceInfos":[{"planName":"Fixture","status":"VALID","codingPlanQuotaInfo":{"per5HourUsedQuota":\#(used),"per5HourTotalQuota":100,"perWeekUsedQuota":\#(used),"perWeekTotalQuota":100,"perBillMonthUsedQuota":\#(used),"perBillMonthTotalQuota":100}}]}}"#
        case "antigravity": #"{"groups":[{"displayName":"Gemini","buckets":[{"bucketId":"gemini-5h","remainingFraction":\#(Double(left)/100)}]}]}"#
        default: throw UsageError.noData
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (Data(json.utf8), response)
    }
}

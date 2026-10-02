import DataSources
import Foundation
import Mockable
import Providers
import Quotas
import Testing

@MainActor @Suite
struct MiniMaxDefinitionTests {
    static let sampleSuccessResponse = """
    {
      "base_resp": { "status_code": 0, "status_msg": "success" },
      "model_remains": [
        {
          "model_name": "minimax-m2",
          "current_interval_total_count": 1500,
          "current_interval_usage_count": 255,
          "remains_time": 1234,
          "end_time": 1735689600000
        }
      ]
    }
    """

    /// Token Plan responses carry percentages; the count fields are 0 there.
    static let sampleTokenPlanResponse = """
    {
      "base_resp": { "status_code": 0, "status_msg": "success" },
      "model_remains": [
        {
          "model_name": "general",
          "current_interval_total_count": 0,
          "current_interval_usage_count": 0,
          "current_interval_remaining_percent": 100,
          "current_weekly_remaining_percent": 98,
          "start_time": 1787673600000,
          "end_time": 1787691600000,
          "weekly_start_time": 1787500800000,
          "weekly_end_time": 1788105600000
        },
        {
          "model_name": "video",
          "current_interval_total_count": 0,
          "current_interval_usage_count": 0,
          "current_interval_remaining_percent": 100,
          "current_weekly_remaining_percent": 100,
          "start_time": 1787673600000,
          "end_time": 1787760000000,
          "weekly_start_time": 1787500800000,
          "weekly_end_time": 1788105600000
        }
      ]
    }
    """

    static let sampleMultiModelResponse = """
    {
      "base_resp": { "status_code": 0, "status_msg": "success" },
      "model_remains": [
        {
          "model_name": "minimax-m2",
          "current_interval_total_count": 1500,
          "current_interval_usage_count": 255,
          "remains_time": 1234,
          "end_time": 1735689600000
        },
        {
          "model_name": "minimax-m1",
          "current_interval_total_count": 500,
          "current_interval_usage_count": 400,
          "remains_time": 1234,
          "end_time": 1735689600000
        }
      ]
    }
    """

    static let sampleErrorResponse = """
    {
      "base_resp": { "status_code": 1001, "status_msg": "invalid api key" },
      "model_remains": []
    }
    """

    static let sampleEmptyRemainsResponse = """
    {
      "base_resp": { "status_code": 0, "status_msg": "success" },
      "model_remains": []
    }
    """

    static let sampleNoEndTimeResponse = """
    {
      "base_resp": { "status_code": 0, "status_msg": "success" },
      "model_remains": [
        {
          "model_name": "minimax-m2",
          "current_interval_total_count": 1000,
          "current_interval_usage_count": 500
        }
      ]
    }
    """


    private func make(body: String = sampleSuccessResponse, status: Int = 200, region: String = "china",
                      vault: MemoryVault = MemoryVault(["minimax.apiKey":"personal"]), environment:[String:String] = [:]) throws -> Provider {
        let definition = try Providers.builtIn("minimax")
        let network = MockNetworkClient()
        given(network).request(.any).willProduce { @Sendable request in
            let auth = request.value(forHTTPHeaderField:"Authorization")
            let host = auth == "Bearer work" ? "api.minimax.io" : (region == "international" ? "api.minimax.io" : "api.minimaxi.com")
            guard request.url?.host == host, request.url?.path == "/v1/token_plan/remains", request.timeoutInterval == 30 else { return (Data(),StubbedProvider.response(400)) }
            return (Data(body.utf8),StubbedProvider.response(status))
        }
        let settings = InMemoryProviderSettings()
        settings.setStringValue(region,"region",forProvider:"minimax")
        return Provider(definition:definition,settings:settings,makeDataSource:{ source,login in
            DataSources.make(source,providerId:definition.id,cliExecutor:MockCLIExecutor(),network:network,
                makeTransport:{_,_,_,_ in MockRPCTransport()},scripts:Providers.builtInScripts,settingValue:{settings.stringValue($0,forProvider:"minimax")},secrets:vault.scoped(to:login),environment:{environment[$0]},
                homeDirectory:FileManager.default.temporaryDirectory,now:{Date()})
        },vault:vault)
    }
    @Test func `definition keeps identity and opt-in default`() throws {
        let p = try make()
        #expect(p.name == "MiniMax")
        #expect(!p.defaultAccount.isEnabled)
        #expect(p.definition.keyDestinations == ["api.minimax.io", "api.minimaxi.com"])
        #expect(p.definition.accounts?.ways == [.form])
    }
    @Test func `legacy counts are remaining and produce the original usage subtitle`() async throws {
        let q = try #require(try await make().defaultAccount.refresh().quotas.first)
        #expect(q.percentRemaining == 17)
        #expect(q.quotaType == .modelSpecific("minimax-m2"))
        #expect(q.resetText == "1245/1500 requests")
        #expect(q.resetsAt == Date(timeIntervalSince1970:1735689600))
        #expect(q.window?.length == nil)
    }
    @Test func `Token Plan percentages produce independent interval and weekly windows`() async throws {
        let qs = try await make(body:Self.sampleTokenPlanResponse).defaultAccount.refresh().quotas
        #expect(qs.count == 4)
        #expect(qs.map(\.percentRemaining) == [100,98,100,100])
        #expect(qs[1].quotaType == .timeLimit("general Weekly"))
        #expect(qs[0].window?.length == 18000)
        #expect(qs[1].window?.length == 604800)
        #expect(qs[1].resetText == "2% used")
    }
    @Test func `all original model and optional reset fixtures survive`() async throws {
        #expect(try await make(body:Self.sampleMultiModelResponse).defaultAccount.refresh().quotas.map(\.percentRemaining) == [17,80])
        let q = try #require(try await make(body:Self.sampleNoEndTimeResponse).defaultAccount.refresh().quotas.first)
        #expect(q.percentRemaining == 50)
        #expect(q.resetsAt == nil)
    }
    @Test func `body-level API errors and empty responses remain failures`() async throws {
        await #expect(throws:UsageError.executionFailed("MiniMax API error: invalid api key")) { try await make(body:Self.sampleErrorResponse).defaultAccount.refresh() }
        await #expect(throws:UsageError.noData) { try await make(body:Self.sampleEmptyRemainsResponse).defaultAccount.refresh() }
        await #expect(throws:UsageError.noData) { try await make(body:#"{"base_resp":{"status_code":0}}"#).defaultAccount.refresh() }
    }
    @Test(arguments:["not JSON",#"{"base_resp":{"status_code":0},"model_remains":[{}]}"#])
    func `malformed response fails mapping`(_ body:String) async throws {
        let account = try make(body:body).defaultAccount
        await #expect(throws:UsageError.self) { try await account.refresh() }
        #expect(account.lastFailedStep == .mapping)
    }
    @Test func `no reported remaining amount has no data`() async throws {
        let body = #"{"base_resp":{"status_code":0},"model_remains":[{"model_name":"general","current_interval_total_count":0,"current_interval_usage_count":0}]}"#
        await #expect(throws:UsageError.noData) { try await make(body:body).defaultAccount.refresh() }
    }
    @Test(arguments:["china","international"])
    func `default region selects its endpoint and dashboard`(_ region:String) async throws {
        let p = try make(region:region)
        #expect(try await p.defaultAccount.refresh().quotas.count == 1)
        #expect(p.defaultAccount.dashboardURL?.host == (region == "international" ? "platform.minimax.io" : "platform.minimaxi.com"))
    }
    @Test func `work account has its own region key and no environment fallback`() async throws {
        let vault = MemoryVault(["minimax.apiKey":"personal"])
        let p = try make(vault:vault,environment:["MINIMAX_API_KEY":"environment"])
        let work = try p.addAccount(filling:["apiKey":"work","region":"international"])
        #expect(work.isEnabled)
        #expect(try await work.refresh().quotas.first?.percentRemaining == 17)
        #expect(work.dashboardURL?.host == "platform.minimax.io")
        vault.secrets["\(work.id).apiKey"] = nil
        await #expect(throws:UsageError.authenticationRequired) { try await work.refresh() }
    }
    @Test(arguments:[401,403]) func `invalid keys require authentication`(_ code:Int) async throws {
        await #expect(throws:UsageError.authenticationRequired) { try await make(status:code).defaultAccount.refresh() }
    }
    @Test(arguments:[429,500]) func `HTTP failures remain fetch failures`(_ code:Int) async throws {
        let a = try make(status:code).defaultAccount
        await #expect(throws:UsageError.self) { try await a.refresh() }
        #expect(a.lastFailedStep == .fetch)
    }
}

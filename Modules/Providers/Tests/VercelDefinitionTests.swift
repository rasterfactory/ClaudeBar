import DataSources
import Foundation
import Mockable
import Providers
import Quotas
import Testing

@MainActor @Suite
struct VercelDefinitionTests {
    private func make(body: String = #"{"balance":95.50,"total_used":4.50}"#, status: Int = 200,
                      environment: [String:String] = [:], vault: MemoryVault = MemoryVault(["vercel-gateway.apiKey":"personal"]),
                      settings: InMemoryProviderSettings = InMemoryProviderSettings(), replies: [String:String]? = nil) throws -> Provider {
        let definition = try Providers.builtIn("vercel-gateway")
        let network = MockNetworkClient()
        given(network).request(.any).willProduce { @Sendable request in
            guard request.url?.absoluteString == "https://ai-gateway.vercel.sh/v1/credits", request.timeoutInterval == 30,
                  request.value(forHTTPHeaderField: "Accept") == "application/json" else { return (Data(), StubbedProvider.response(400)) }
            if let replies {
                guard let response = replies[request.value(forHTTPHeaderField: "Authorization") ?? ""] else { return (Data(), StubbedProvider.response(401)) }
                return (Data(response.utf8), StubbedProvider.response(200))
            }
            return (Data(body.utf8), StubbedProvider.response(status))
        }
        return Provider(definition: definition, settings: settings, accounts: settings.accounts(forProvider: definition.id), makeDataSource: { source, login in
            DataSources.make(source, providerId: definition.id, cliExecutor: MockCLIExecutor(), network: network,
                makeTransport: { _,_,_,_ in MockRPCTransport() }, secrets: vault.scoped(to: login), environment: { environment[$0] },
                homeDirectory: FileManager.default.temporaryDirectory, now: { Date() })
        }, vault: vault)
    }

    @Test func `identity and disabled default survive migration`() throws {
        let provider = try make()
        #expect(provider.id == "vercel-gateway")
        #expect(provider.name == "Vercel Gateway")
        #expect(!provider.defaultAccount.isEnabled)
        #expect(provider.definition.profile.links.dashboard == URL(string:"https://vercel.com/dashboard/ai-gateway"))
        #expect(provider.definition.accounts?.ways == [.form])
    }

    @Test(arguments: ["95.50", "0", "1245.67", "-1.25", "0.123456789"])
    func `balance is exact money with no invented ceiling`(_ amount: String) async throws {
        for value in [amount, "\"\(amount)\""] {
            let usage = try await make(body: "{\"balance\":\(value)}").defaultAccount.refresh()
            let quota = try #require(usage.quotas.first)
            #expect(quota.quotaType == .modelSpecific("AI Gateway Credits"))
            #expect(quota.left == .money(Money(Decimal(string: amount)!, currency:"USD"), of:nil))
            #expect(quota.percentLeft == nil)
            #expect(quota.window == nil)
        }
    }

    @Test(arguments: ["not JSON", "{}", #"{"balance":"abc"}"#, #"{"balance":null}"#, #"{"balance":true}"#])
    func `invalid or absent balance fails mapping`(_ body: String) async throws {
        let account = try make(body:body).defaultAccount
        await #expect(throws: UsageError.self) { try await account.refresh() }
        #expect(account.lastFailedStep == .mapping)
    }

    @Test(arguments: [401,403]) func `rejected keys need authentication`(_ status:Int) async throws {
        let account = try make(status:status).defaultAccount
        await #expect(throws: UsageError.authenticationRequired) { try await account.refresh() }
    }
    @Test(arguments:[429,500]) func `HTTP errors remain fetch errors`(_ status:Int) async throws {
        let account = try make(status:status).defaultAccount
        await #expect(throws: UsageError.self) { try await account.refresh() }
        #expect(account.lastFailedStep == .fetch)
    }
    @Test func `missing key is unavailable`() async throws {
        let account = try make(vault:MemoryVault()).defaultAccount
        #expect(await account.isAvailable() == false)
        await #expect(throws:UsageError.authenticationRequired) { try await account.refresh() }
    }
    @Test func `default environment wins but added accounts use only their own keys`() async throws {
        let vault = MemoryVault(["vercel-gateway.apiKey":"personal"])
        let settings = InMemoryProviderSettings()
        let provider = try make(environment:["AI_GATEWAY_API_KEY":"environment"], vault:vault, settings:settings,
            replies:["Bearer environment":#"{"balance":40}"#, "Bearer work":#"{"balance":"7.50"}"#])
        let work = try provider.addAccount(filling:["apiKey":"work"])
        #expect(work.isEnabled)
        #expect(try await provider.defaultAccount.refresh().quotas.first?.dollarRemaining == 40)
        #expect(try await work.refresh().quotas.first?.dollarRemaining == Decimal(string:"7.50"))
        #expect(settings.accounts(forProvider:provider.id).first?.probeConfig["apiKey"] == nil)
        vault.secrets["\(work.id).apiKey"] = nil
        await #expect(throws:UsageError.authenticationRequired) { try await work.refresh() }
    }
    @Test func `blank environment falls back to saved key`() async throws {
        let provider = try make(environment:["AI_GATEWAY_API_KEY":" \n "], replies:["Bearer personal":#"{"balance":10}"#])
        #expect(try await provider.defaultAccount.refresh().quotas.first?.dollarRemaining == 10)
    }
}

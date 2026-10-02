import DataSources
import Domain
import Foundation
import Infrastructure
import Mockable
import Providers
import Testing

@MainActor @Suite struct ZaiAccountTests {
    @Test func `accounts keep their own keys platforms names and secure migration across relaunch`() async throws {
        let suite = "Zai.Accounts.\(UUID())"
        // Unique domains prevent fixtures from sharing credentials.
        let legacy = UserDefaults(suiteName:suite)!
        defer { legacy.removePersistentDomain(forName:suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let config = root.appendingPathComponent("config.json")
        try Data(#"{"env":{"ANTHROPIC_BASE_URL":"https://dev.bigmodel.cn","ANTHROPIC_AUTH_TOKEN":"config-token"}}"#.utf8).write(to:config)
        let credentials = UserDefaultsCredentialRepository(defaults:legacy)
        let settings = JSONSettingsRepository(store:JSONSettingsStore(fileURL:root.appendingPathComponent("settings.json")),credentials:legacy,secureCredentials:credentials)
        legacy.set("personal-token",forKey:"com.claudebar.credentials.zai-api-key")
        let vault = ProviderVault(credentials:credentials,legacyStore:legacy)
        let network = MockNetworkClient(), executor = MockCLIExecutor()
        given(executor).locate(.any).willReturn(nil)
        given(network).request(.any).willProduce { @Sendable request in
            let token = request.value(forHTTPHeaderField:"Authorization"), host = request.url?.host
            let used: Int
            switch token {
            case "Bearer personal-token": #expect(host == "dev.bigmodel.cn"); used=10
            case "Bearer work-token": #expect(host == "open.bigmodel.cn"); used=65
            case "Bearer other-token": #expect(host == "api.z.ai"); used=30
            default: Issue.record("Unexpected credential or inherited login"); used=0
            }
            return (Data("{\"data\":{\"limits\":[{\"type\":\"TOKENS_LIMIT\",\"unit\":6,\"percentage\":\(used)}]}}".utf8),HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:nil)!)
        }
        let definition = try Providers.builtIn("zai")
        let factory: @MainActor () -> Provider = {
            Provider(definition:definition,settings:settings,accounts:settings.accounts(forProvider:"zai"),makeDataSource:{ source,login in
                DataSources.make(source,providerId:"zai",cliExecutor:executor,network:network,makeTransport:{_,_,_,_ in MockRPCTransport()},scripts:Providers.builtInScripts,secrets:vault.scoped(to:login),environment:{ name in
                    if name == "ZAI_CONFIG_PATH" { return config.path }
                    if name == "GLM_AUTH_NAME" { return "FIXTURE_TOKEN" }
                    return name == "FIXTURE_TOKEN" ? "env-token" : nil
                },homeDirectory:root,now:{Date()})
            },vault:vault)
        }
        let provider = factory()
        #expect(provider.defaultAccount.displayName == "Z.ai")
        #expect(provider.defaultAccount.isEnabled)
        #expect(provider.defaultAccount.cliCommand == "claude")
        #expect(provider.defaultAccount.dashboardURL?.absoluteString == "https://z.ai/subscribe")
        #expect(provider.defaultAccount.statusPageURL?.absoluteString == "https://docs.z.ai/devpack/faq")
        #expect((try await provider.defaultAccount.refresh()).quotas[0].percentRemaining == 90)
        #expect(credentials.get(forKey:CredentialKey.zaiApiKey) == "personal-token")
        #expect(legacy.object(forKey:"com.claudebar.credentials.zai-api-key") == nil)
        #expect(settings.getZaiApiKey() == "personal-token")
        let work = try provider.addAccount(filling:["apiKey":"work-token","platform":"open.bigmodel.cn"])
        let other = try provider.addAccount(filling:["apiKey":"other-token","platform":"api.z.ai"])
        provider.rename(work,to:"Work");provider.rename(other,to:"Personal")
        #expect((try await work.refresh()).quotas[0].percentRemaining == 35)
        #expect((try await other.refresh()).quotas[0].percentRemaining == 70)
        #expect(settings.accounts(forProvider:"zai").allSatisfy { $0.probeConfig["apiKey"] == nil })
        let restored = factory(), restoredWork = try #require(restored.accounts.first { $0.id == work.id })
        #expect(restoredWork.displayName == "Work")
        #expect((try await restoredWork.refresh()).quotas[0].percentRemaining == 35)
        vault.delete("apiKey",provider:work.id)
        await #expect(throws:UsageError.authenticationRequired) { try await restoredWork.refresh() }
        restored.remove(restoredWork)
        #expect(settings.accounts(forProvider:"zai").count == 1)
        #expect(vault.secret("apiKey",provider:"zai") == "personal-token")
    }
    private struct RefusingStore: CredentialRepository {
        func save(_ value:String,forKey key:String) {}
        func get(forKey key:String) -> String? { nil }
        func delete(forKey key:String) -> Bool { false }
        func exists(forKey key:String) -> Bool { false }
    }
    @Test func `refused legacy migration retains the default login and never exposes it to an added account`() {
        let suite = "Zai.Refused.\(UUID())"
        let store = UserDefaults(suiteName:suite)!
        defer { store.removePersistentDomain(forName:suite) }
        store.set("old-token",forKey:"com.claudebar.credentials.zai-api-key")
        let vault = ProviderVault(credentials:RefusingStore(),legacyStore:store)
        #expect(vault.secret("apiKey",provider:"zai") == "old-token")
        #expect(vault.secret("apiKey",provider:"zai.work") == nil)
        #expect(vault.delete("apiKey",provider:"zai") == false)
        #expect(store.string(forKey:"com.claudebar.credentials.zai-api-key") == "old-token")
    }
}

import DataSources
import Domain
import Foundation
import Infrastructure
import Mockable
import Providers
import Testing

@MainActor @Suite struct AlibabaAccountTests {
    private struct EmptyBrowser: BrowserCookieReading {
        func stores(domains: [String], names: [String]) -> [[BrowserCookie]] { stores(domains: domains, names: names, includeEmpty: false) }
        func stores(domains:[String],names:[String],includeEmpty:Bool) -> [[BrowserCookie]] { [] }
    }
    @Test func `API and cookie accounts retain independent credentials regions labels and state across relaunch`() async throws {
        let suite="Alibaba.Accounts.\(UUID())"
        let legacy=UserDefaults(suiteName:suite)!
        defer { legacy.removePersistentDomain(forName: suite) }
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let credentials=UserDefaultsCredentialRepository(defaults:legacy)
        let settings=JSONSettingsRepository(store:JSONSettingsStore(fileURL:root.appendingPathComponent("settings.json")),credentials:legacy,secureCredentials:credentials)
        legacy.set("personal-key",forKey:"com.claudebar.credentials.alibaba-api-key")
        legacy.set("sec_token=default-session",forKey:"com.claudebar.credentials.alibaba-manual-cookie")
        let vault=ProviderVault(credentials:credentials,legacyStore:legacy),network=MockNetworkClient()
        given(network).request(.any).willProduce { @Sendable request in
            let bearer=request.value(forHTTPHeaderField:"Authorization"),cookie=request.value(forHTTPHeaderField:"Cookie")
            let used: Int
            switch (bearer,cookie) {
            case ("Bearer personal-key",nil): #expect(request.url?.host == "modelstudio.console.alibabacloud.com"); used=10
            case ("Bearer work-key",nil): #expect(request.url?.host == "bailian.console.aliyun.com"); used=65
            case (nil,"sec_token=other-session"): #expect(request.url?.host == "bailian-singapore-cs.alibabacloud.com"); used=30
            default: Issue.record("Unexpected or inherited credential"); used=0
            }
            return (Data("{\"codingPlanQuotaInfo\":{\"per5HourUsedQuota\":\(used),\"per5HourTotalQuota\":100}}".utf8),HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:nil)!)
        }
        let definition=try Providers.builtIn("alibaba")
        let factory: @MainActor () -> Provider = {
            Provider(definition:definition,settings:settings,accounts:settings.accounts(forProvider:"alibaba"),makeDataSource:{ source,login in
                DataSources.make(source,providerId:"alibaba",cliExecutor:MockCLIExecutor(),network:network,makeTransport:{_,_,_,_ in MockRPCTransport()},scripts:Providers.builtInScripts,settingValue:{ settings.stringValue($0,forProvider:"alibaba") },browserCookies:EmptyBrowser(),secrets:vault.scoped(to:login),environment:{_ in nil},homeDirectory:root,now:{Date()})
            },vault:vault)
        }
        let provider=factory()
        #expect(provider.defaultAccount.displayName == "Alibaba")
        #expect(provider.defaultAccount.isEnabled == false)
        #expect(provider.defaultAccount.cliCommand == "alibaba-coding-plan")
        #expect(provider.defaultAccount.dashboardURL?.absoluteString == "https://modelstudio.console.alibabacloud.com")
        #expect(try await provider.defaultAccount.refresh().quotas[0].percentRemaining == 90)
        #expect(credentials.get(forKey:"provider.alibaba.apiKey") == "personal-key")
        #expect(legacy.object(forKey:"com.claudebar.credentials.alibaba-api-key") == nil)
        #expect(settings.getAlibabaManualCookie() == "sec_token=default-session")
        #expect(legacy.object(forKey:"com.claudebar.credentials.alibaba-manual-cookie") == nil)
        let work=try provider.addAccount(filling:["apiKey":"work-key","accountRegion":"cn"])
        let other=try provider.addAccount(filling:["source":"cookie","cookie":"sec_token=other-session"])
        provider.rename(work,to:"Work");provider.rename(other,to:"Personal")
        #expect(try await work.refresh().quotas[0].percentRemaining == 35)
        #expect(try await other.refresh().quotas[0].percentRemaining == 70)
        #expect(work.dashboardURL?.host == "bailian.console.aliyun.com")
        #expect(settings.accounts(forProvider:"alibaba").allSatisfy { $0.probeConfig["apiKey"] == nil && $0.probeConfig["cookie"] == nil })
        let restored=factory(),restoredWork=try #require(restored.accounts.first { $0.id == work.id })
        #expect(restoredWork.displayName == "Work")
        #expect(try await restoredWork.refresh().quotas[0].percentRemaining == 35)
        vault.delete("apiKey",provider:work.id)
        await #expect(throws:UsageError.authenticationRequired) { try await restoredWork.refresh() }
        restored.remove(restoredWork)
        #expect(settings.accounts(forProvider:"alibaba").count == 1)
        #expect(vault.secret("cookie",provider:other.id) == "sec_token=other-session")
        restored.remove(restored.accounts.first { $0.id == other.id }!)
        #expect(vault.secret("cookie",provider:other.id) == nil)
        #expect(vault.secret("apiKey",provider:"alibaba") == "personal-key")
    }
    private struct RefusingStore: CredentialRepository {
        func save(_ value:String,forKey key:String) {}
        func get(forKey key:String) -> String? { nil }
        func delete(forKey key:String) -> Bool { false }
        func exists(forKey key:String) -> Bool { false }
    }
    @Test func `refused migrations preserve both default sign-ins and cannot leak to named accounts`() {
        let suite="Alibaba.Refused.\(UUID())"
        let store=UserDefaults(suiteName:suite)!
        defer { store.removePersistentDomain(forName:suite) }
        store.set("old-key",forKey:"com.claudebar.credentials.alibaba-api-key")
        store.set("old-cookie",forKey:"com.claudebar.credentials.alibaba-manual-cookie")
        let vault=ProviderVault(credentials:RefusingStore(),legacyStore:store)
        #expect(vault.secret("apiKey",provider:"alibaba") == "old-key")
        #expect(vault.secret("cookie",provider:"alibaba") == "old-cookie")
        #expect(vault.secret("apiKey",provider:"alibaba.work") == nil)
        #expect(vault.secret("cookie",provider:"alibaba.work") == nil)
        #expect(vault.delete("cookie",provider:"alibaba") == false)
        #expect(store.string(forKey:"com.claudebar.credentials.alibaba-manual-cookie") == "old-cookie")
    }
}

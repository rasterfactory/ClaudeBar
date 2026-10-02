import DataSources
import Domain
import Foundation
import Infrastructure
import Mockable
import Providers
import Testing

@MainActor @Suite struct MistralAccountTests {
    private let instant = Date(timeIntervalSince1970: 1_759_406_400) // 2025-10-02 UTC
    private func write(_ folder: URL, name: String, cost: String, tokens: Int) throws {
        let session=folder.appendingPathComponent(name)
        try FileManager.default.createDirectory(at:session,withIntermediateDirectories:true)
        try Data("{\"stats\":{\"session_cost\":\(cost),\"session_total_llm_tokens\":\(tokens)}}".utf8).write(to:session.appendingPathComponent("meta.json"))
    }
    @Test func `separate log folders retain exact daily totals names and state across relaunch`() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let personal=root.appendingPathComponent(".vibe/logs/session"),work=root.appendingPathComponent("work")
        let now=Date(timeIntervalSince1970:1_759_406_400)
        let fmt=DateFormatter();fmt.dateFormat="yyyyMMdd_HHmmss";fmt.timeZone=TimeZone(secondsFromGMT:0)
        let name="session_\(fmt.string(from:now))_test"
        try write(personal,name:name,cost:"0.123456789012345678901",tokens:50)
        try write(work,name:name,cost:"0.2",tokens:7)
        try write(work,name:name+"other",cost:"0.1",tokens:3)
        let suite="Mistral.Accounts.\(UUID())",defaults=UserDefaults(suiteName:suite)!
        defer{defaults.removePersistentDomain(forName:suite)}
        let settings=JSONSettingsRepository(store:JSONSettingsStore(fileURL:root.appendingPathComponent("settings.json")),credentials:defaults)
        let definition=try Providers.builtIn("mistral")
        let factory:@MainActor () -> Provider = {
            Provider(definition:definition,settings:settings,accounts:settings.accounts(forProvider:"mistral"),makeDataSource:{source,_ in
                DataSources.make(source,providerId:"mistral",cliExecutor:MockCLIExecutor(),network:MockNetworkClient(),makeTransport:{_,_,_,_ in MockRPCTransport()},scripts:Providers.builtInScripts,environment:{_ in nil},homeDirectory:root,now:{now})
            })
        }
        let provider=factory()
        #expect(provider.defaultAccount.displayName == "Mistral")
        #expect(!provider.defaultAccount.isEnabled)
        #expect(provider.definition.profile.links.dashboard == URL(string:"https://console.mistral.ai"))
        #expect(try await provider.defaultAccount.refresh().dailyUsageReport?.today.totalCost == Decimal(string:"0.123456789012345678901"))
        let account=try provider.addAccount(filling:["home":work.path]);provider.rename(account,to:"Work")
        let usage=try await account.refresh()
        #expect(usage.providerId == account.id)
        #expect(usage.dailyUsageReport?.today.totalCost == Decimal(string:"0.3"))
        #expect(usage.dailyUsageReport?.today.totalTokens == 10)
        #expect(usage.dailyUsageReport?.today.workingTime == 0)
        let restored=factory(),restoredWork=try #require(restored.accounts.first{$0.id == account.id})
        #expect(restoredWork.displayName == "Work")
        #expect(try await restoredWork.refresh().dailyUsageReport?.today.totalTokens == 10)
        try FileManager.default.removeItem(at:work)
        #expect(try await restoredWork.refresh().dailyUsageReport?.today.totalTokens == 0)
        #expect(try await restored.defaultAccount.refresh().dailyUsageReport?.today.totalTokens == 50)
        restored.remove(restoredWork)
        #expect(settings.accounts(forProvider:"mistral").isEmpty)
        #expect(FileManager.default.fileExists(atPath:personal.path))
    }
    @Test func `unreadable sessions malformed dates and unrelated entries do not pollute totals`() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:root)}
        try write(root,name:"session_20250230_120000_bad",cost:"50",tokens:500)
        try write(root,name:"unrelated_20250302_120000_bad",cost:"50",tokens:500)
        let now=Date(timeIntervalSince1970:1_740_916_800)
        let report=try await MistralDefinitionAnalyzer(vibeSessionsDir:root,now:{now}).analyzeToday()
        #expect(report.today.totalCost == 0)
        #expect(report.today.totalTokens == 0)
    }
}

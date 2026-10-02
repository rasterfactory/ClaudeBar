import DataSources
import Domain
import Foundation
import Infrastructure
import Mockable
import Providers
import Testing

@MainActor @Suite struct BedrockAccountTests {
    @Test func `profile region budget and label remain independent after relaunch and removal`() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer{try? FileManager.default.removeItem(at:root)}
        let suite="Bedrock.Accounts.\(UUID())",defaults=UserDefaults(suiteName:suite)!
        defer{defaults.removePersistentDomain(forName:suite)}
        let settings=JSONSettingsRepository(store:JSONSettingsStore(fileURL:root.appendingPathComponent("settings.json")),credentials:defaults)
        settings.setAWSProfileName("personal");settings.setBedrockRegions(["us-east-1"]);settings.setBedrockDailyBudget(10)
        let definition=try Providers.builtIn("bedrock"),client=ProfileMetrics()
        let factory:@MainActor () -> Provider = {
            Provider(definition:definition,settings:settings,accounts:settings.accounts(forProvider:"bedrock"),makeDataSource:{source,_ in
                DataSources.make(source,providerId:"bedrock",cliExecutor:MockCLIExecutor(),network:MockNetworkClient(),makeTransport:{_,_,_,_ in MockRPCTransport()},scripts:Providers.builtInScripts,settingValue:{settings.stringValue($0,forProvider:"bedrock")},cloudWatch:client,environment:{_ in "ambient-other-account"},homeDirectory:root,now:{Date()})
            })
        }
        let provider=factory()
        #expect(provider.defaultAccount.displayName == "AWS Bedrock")
        #expect(!provider.defaultAccount.isEnabled)
        #expect(await provider.defaultAccount.isAvailable())
        let work=try provider.addAccount(filling:["profile":"work","regions":"us-west-2, eu-west-1","budget":"2"])
        provider.rename(work,to:"Work")
        let personalUsage=try await provider.defaultAccount.refresh(),workUsage=try await work.refresh()
        #expect(personalUsage.bedrockUsage?.totalCost == 1)
        #expect(personalUsage.quotas.first?.percentRemaining == 90)
        #expect(workUsage.bedrockUsage?.totalCost == 2)
        #expect(workUsage.quotas.first?.percentRemaining == 0)
        #expect(workUsage.providerId == work.id)
        #expect(workUsage.bedrockUsage?.region == "us-west-2")
        let relaunched=factory(),restored=try #require(relaunched.accounts.first{$0.id == work.id})
        #expect(restored.displayName == "Work")
        #expect(try await restored.refresh().bedrockUsage?.dailyBudget == 2)
        settings.setAWSProfileName("invalid")
        #expect(await relaunched.defaultAccount.isAvailable() == false)
        #expect(await restored.isAvailable())
        #expect(try await restored.refresh().bedrockUsage?.totalCost == 2)
        relaunched.remove(restored)
        #expect(settings.accounts(forProvider:"bedrock").isEmpty)
        #expect(settings.awsProfileName() == "invalid")
    }
    @Test func `a failed region retains successful regions and unknown pricing retains token counts`() async throws {
        let definition=try Providers.builtIn("bedrock")
        let source=try definition.dataSource("cloudwatch")!.patched(with:.object(["fetch":.object(["cloudWatch":.object(["profile":.string("work"),"regions":.array([.string("failed"),.string("us-west-2")]),"budget":.string("10")])])]))
        let dataSource=DataSources.make(source,providerId:"bedrock",cliExecutor:MockCLIExecutor(),network:MockNetworkClient(),makeTransport:{_,_,_,_ in MockRPCTransport()},scripts:Providers.builtInScripts,cloudWatch:ProfileMetrics(failPricing:true),environment:{_ in nil},homeDirectory:FileManager.default.temporaryDirectory,now:{Date()})
        let usage=try await dataSource.fetchUsage()
        #expect(usage.bedrockUsage?.modelUsages.count == 1)
        #expect(usage.bedrockUsage?.totalInputTokens == 1_000_000)
        #expect(usage.bedrockUsage?.totalCost == 0)
        #expect(usage.bedrockUsage?.modelUsages.first?.model.vendor == "Unknown")
    }
    @Test func `the definition retains bundled prices and regional identifiers`() throws {
        let definition=try Providers.builtIn("bedrock")
        guard case .cloudWatch(let query)=definition.dataSource("cloudwatch")?.fetch else{Issue.record("Missing CloudWatch");return}
        let model=try #require(query.defaultPrice("us.anthropic.claude-sonnet-4-20250514-v1:0"))
        #expect(model.id == "us.anthropic.claude-sonnet-4-20250514-v1:0")
        #expect(model.displayName == "Claude Sonnet 4")
        #expect(model.inputPricePer1M == 3)
        #expect(model.outputPricePer1M == 15)
        #expect(query.prices.count >= 18)
        #expect(query.defaultPrice("unknown.model") == nil)
    }
}
private struct ProfileMetrics:CloudWatchClient {
    var failPricing=false
    func verify(query:CloudWatchQuery,profile:String?) async -> Bool { profile == "personal" || profile == "work" }
    func metrics(query:CloudWatchQuery,profile:String?,region:String,startTime:Date,endTime:Date) async throws -> [CloudMetric] {
        #expect(endTime >= startTime)
        #expect(query.namespace == "AWS/Bedrock")
        if region == "failed" {throw UsageError.executionFailed("Unavailable region")}
        guard (profile == "personal" && region == "us-east-1") || (profile == "work" && ["us-west-2","eu-west-1"].contains(region)) else{throw UsageError.authenticationRequired}
        return [CloudMetric(modelId:"model",inputTokens:1_000_000,outputTokens:0,invocations:5)]
    }
    func pricing(query:CloudWatchQuery,profile:String?,modelId:String) async throws -> UnitPrices {
        if failPricing {throw UsageError.noData}
        return UnitPrices(id:modelId,displayName:"Model",vendor:"Example",inputPricePer1M:1,outputPricePer1M:0)
    }
}

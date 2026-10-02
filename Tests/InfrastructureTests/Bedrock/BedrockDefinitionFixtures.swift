import DataSources
import Domain
import Foundation
import Infrastructure
import Mockable
import Providers

struct BedrockDefinitionProbe {
    let cloudWatchClient:any BedrockCloudWatchClient
    let pricingService:any BedrockPricingService
    let settingsRepository:any BedrockSettingsRepository
    func source() throws -> DataSource {
        let definition=try Providers.builtIn("bedrock")
        let regions=String(decoding:try JSONEncoder().encode(settingsRepository.bedrockRegions()),as:UTF8.self)
        let budget=settingsRepository.bedrockDailyBudget().map{NSDecimalNumber(decimal:$0).stringValue}
        let profile=settingsRepository.awsProfileName()
        return DataSources.make(definition.dataSource("cloudwatch")!,providerId:"bedrock",cliExecutor:MockCLIExecutor(),network:MockNetworkClient(),makeTransport:{_,_,_,_ in MockRPCTransport()},scripts:Providers.builtInScripts,settingValue:{name in switch name {case "awsProfile":profile;case "regions":regions;case "dailyBudget":budget;default:nil}},cloudWatch:FixtureCloudWatch(client:cloudWatchClient,pricing:pricingService),environment:{_ in nil},homeDirectory:FileManager.default.temporaryDirectory,now:{Date()})
    }
    func isAvailable() async -> Bool { guard let source=try? source() else{return false};return await source.isReady() }
    func probe() async throws -> UsageSnapshot {
        do{return try await source().fetchUsage()}catch let error as DataSourceError{throw error.reason}
    }
}
private struct FixtureCloudWatch:CloudWatchClient {
    let client:any BedrockCloudWatchClient
    let pricing:any BedrockPricingService
    func verify(query:CloudWatchQuery,profile:String?) async -> Bool{await client.verifyCredentials()}
    func metrics(query:CloudWatchQuery,profile:String?,region:String,startTime:Date,endTime:Date) async throws -> [CloudMetric] {
        try await client.fetchBedrockMetrics(region:region,startTime:startTime,endTime:endTime).map{CloudMetric(modelId:$0.modelId,inputTokens:$0.inputTokens,outputTokens:$0.outputTokens,invocations:$0.invocations)}
    }
    func pricing(query:CloudWatchQuery,profile:String?,modelId:String) async throws -> UnitPrices {
        let model=try await pricing.getModelPricing(modelId:modelId)
        return UnitPrices(id:model.id,displayName:model.displayName,vendor:model.vendor,inputPricePer1M:model.inputPricePer1M,outputPricePer1M:model.outputPricePer1M)
    }
}

import Foundation
import Mockable
import Domain

// MARK: - CloudWatch Metric Data

/// Represents raw metric data from CloudWatch for a single model
public struct BedrockMetricData: Sendable, Equatable {
    public let modelId: String
    public let inputTokens: Int
    public let outputTokens: Int
    public let invocations: Int

    public init(modelId: String, inputTokens: Int, outputTokens: Int, invocations: Int) {
        self.modelId = modelId
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.invocations = invocations
    }
}

// MARK: - BedrockCloudWatchClient Protocol

/// Protocol for fetching Bedrock usage metrics from CloudWatch.
/// Abstracted for testability - production uses AWSCloudWatchClient.
public protocol BedrockCloudWatchClient: Sendable {
    /// Fetches Bedrock usage metrics for the specified time period
    /// - Parameters:
    ///   - region: AWS region to query
    ///   - startTime: Start of the time period
    ///   - endTime: End of the time period
    /// - Returns: Array of metric data per model
    func fetchBedrockMetrics(
        region: String,
        startTime: Date,
        endTime: Date
    ) async throws -> [BedrockMetricData]

    /// Verifies AWS credentials are valid
    /// - Returns: True if credentials can authenticate successfully
    func verifyCredentials() async -> Bool
}


public protocol BedrockPricingService: Sendable {
    /// Gets pricing information for a Bedrock model
    /// - Parameter modelId: The AWS Bedrock model ID (e.g., "anthropic.claude-opus-4-5-20251101-v1:0")
    /// - Returns: BedrockModel with pricing information
    func getModelPricing(modelId: String) async throws -> BedrockModel
}


import Foundation
import DataSources

/// The SDK boundary: signed requests and explicit profile resolvers; never mutates process environment.
public final class SDKCloudWatchClient: CloudWatchClient, @unchecked Sendable {
    private let lock=NSLock()
    private var pricingServices:[String:ProductPricingService]=[:]
    public init() {}
    public func verify(query:CloudWatchQuery,profile:String?) async -> Bool {
        await StatisticsService(profileName:profile,query:query).verifyCredentials()
    }
    public func metrics(query:CloudWatchQuery,profile:String?,region:String,startTime:Date,endTime:Date) async throws -> [CloudMetric] {
        try await StatisticsService(profileName:profile,query:query).fetchMetrics(region:region,startTime:startTime,endTime:endTime)
    }
    private func service(_ query:CloudWatchQuery,_ profile:String?) -> ProductPricingService {
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
        let key=(profile ?? "")+String(decoding:(try? encoder.encode(query)) ?? Data(),as:UTF8.self)
        lock.lock();defer{lock.unlock()}
        if let service=pricingServices[key]{return service}
        let service=ProductPricingService(query:query,profile:profile);pricingServices[key]=service;return service
    }
    public func pricing(query:CloudWatchQuery,profile:String?,modelId:String) async throws -> UnitPrices {
        try await service(query,profile).getModelPricing(modelId:modelId)
    }
}

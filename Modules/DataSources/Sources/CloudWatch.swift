import Foundation

public struct UnitPrices: Sendable, Equatable, Codable {
    public let id: String
    public let displayName: String
    public let vendor: String
    public let inputPricePer1M: Decimal
    public let outputPricePer1M: Decimal
    public init(id:String,displayName:String,vendor:String,inputPricePer1M:Decimal,outputPricePer1M:Decimal) {
        self.id=id;self.displayName=displayName;self.vendor=vendor;self.inputPricePer1M=inputPricePer1M;self.outputPricePer1M=outputPricePer1M
    }
}
public struct CloudMetric: Sendable, Equatable, Codable {
    public let modelId:String
    public let inputTokens:Int
    public let outputTokens:Int
    public let invocations:Int
    public init(modelId:String,inputTokens:Int,outputTokens:Int,invocations:Int) {
        self.modelId=modelId;self.inputTokens=inputTokens;self.outputTokens=outputTokens;self.invocations=invocations
    }
}
public struct CloudWatchQuery: Sendable, Equatable, Codable {
    public let namespace:String
    public let dimension:String
    public let inputMetric:String
    public let outputMetric:String
    public let countMetric:String
    public let serviceCode:String
    public let productFilter:String
    public let profileSetting:String?
    public let regionsSetting:String?
    public let budgetSetting:String?
    public let profile:String?
    public let regionsText:String?
    public let regions:[String]?
    public let budget:String?
    public let emptyRegionsError:String
    public let normalizePattern:String
    public let vendors:[String:String]
    public let prices:[String:UnitPrices]
    public func defaultPrice(_ id:String) -> UnitPrices? {
        let normalized=id.replacingOccurrences(of:normalizePattern,with:"",options:.regularExpression)
        let base=normalized.replacingOccurrences(of:":\\d+$",with:"",options:.regularExpression)
        guard let model=prices[normalized] ?? prices[base] else{return nil}
        return UnitPrices(id:id,displayName:model.displayName,vendor:model.vendor,inputPricePer1M:model.inputPricePer1M,outputPricePer1M:model.outputPricePer1M)
    }
}
public protocol CloudWatchClient: Sendable {
    func verify(query:CloudWatchQuery,profile:String?) async -> Bool
    func metrics(query:CloudWatchQuery,profile:String?,region:String,startTime:Date,endTime:Date) async throws -> [CloudMetric]
    func pricing(query:CloudWatchQuery,profile:String?,modelId:String) async throws -> UnitPrices
}

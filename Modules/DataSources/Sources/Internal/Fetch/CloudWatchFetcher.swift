import Foundation

protocol ReadinessChecking: Sendable { func checkReadiness() async -> Bool }
struct CloudWatchFetcher: Fetching, ReadinessChecking {
    let query:CloudWatchQuery
    let client:(any CloudWatchClient)?
    let settingValue:@Sendable(String)->String?
    let calendar:Calendar
    let now:@Sendable()->Date
    var profile:String? { let text=query.profile ?? query.profileSetting.flatMap(settingValue);return text?.isEmpty == false ? text : nil }
    var regions:[String] {
        if let text=query.regionsText{return text.split(separator:",").map{String($0).trimmingCharacters(in:.whitespacesAndNewlines)}}
        if let regions=query.regions{return regions}
        if let text=query.regionsSetting.flatMap(settingValue),let data=text.data(using:.utf8),let regions=try? JSONDecoder().decode([String].self,from:data){return regions}
        return []
    }
    var budget:Decimal? { (query.budget ?? query.budgetSetting.flatMap(settingValue)).flatMap{Decimal(string:$0,locale:Locale(identifier:"en_US_POSIX"))} }
    func isReady()->Bool { client != nil }
    func checkReadiness() async -> Bool { guard let client else{return false};return await client.verify(query:query,profile:profile) }
    func fetch(with credential:Credential?) async throws -> Response {
        guard !regions.isEmpty else{throw UsageError.executionFailed(query.emptyRegionsError)}
        guard let client else{throw UsageError.executionFailed("CloudWatch connection is unavailable")}
        let instant=now(),start=calendar.startOfDay(for:instant),tomorrow=calendar.date(byAdding:.day,value:1,to:start) ?? start.addingTimeInterval(86400)
        var records:[CloudMetric]=[]
        for region in regions {
            do { records += try await client.metrics(query:query,profile:profile,region:region,startTime:start,endTime:instant) }
            catch { if Task.isCancelled || error is CancellationError {throw CancellationError()} }
        }
        var lines:[Line]=[]
        for metric in records where metric.invocations>0 || metric.inputTokens>0 || metric.outputTokens>0 {
            let model:UnitPrices
            do{model=try await client.pricing(query:query,profile:profile,modelId:metric.modelId)}
            catch{
                if Task.isCancelled || error is CancellationError {throw CancellationError()}
                model=UnitPrices(id:metric.modelId,displayName:metric.modelId,vendor:"Unknown",inputPricePer1M:0,outputPricePer1M:0)
            }
            let cost=Decimal(metric.inputTokens)/1_000_000*model.inputPricePer1M+Decimal(metric.outputTokens)/1_000_000*model.outputPricePer1M
            lines.append(Line(id:model.id,name:model.displayName,vendor:model.vendor,inputPrice:NSDecimalNumber(decimal:model.inputPricePer1M).stringValue,outputPrice:NSDecimalNumber(decimal:model.outputPricePer1M).stringValue,inputTokens:metric.inputTokens,outputTokens:metric.outputTokens,invocations:metric.invocations,cost:cost))
        }
        lines.sort{$0.cost>$1.cost}
        let total=lines.reduce(Decimal.zero){$0+$1.cost}
        let percent=budget.flatMap{$0>0 ? max(0,100-NSDecimalNumber(decimal:total/$0*100).doubleValue) : nil}
        let envelope=Envelope(lines:lines,region:regions.first ?? "us-east-1",capturedAt:instant.timeIntervalSince1970,periodStart:start.timeIntervalSince1970,periodEnd:instant.timeIntervalSince1970,dailyBudget:budget.map{NSDecimalNumber(decimal:$0).stringValue},percentRemaining:records.isEmpty ? nil : percent,resetsAt:tomorrow.timeIntervalSince1970)
        return Response(body:try JSONEncoder().encode(envelope))
    }
    private struct Line:Encodable {let id:String;let name:String;let vendor:String;let inputPrice:String;let outputPrice:String;let inputTokens:Int;let outputTokens:Int;let invocations:Int;let cost:Decimal}
    private struct Envelope:Encodable {let lines:[Line];let region:String;let capturedAt:Double;let periodStart:Double;let periodEnd:Double;let dailyBudget:String?;let percentRemaining:Double?;let resetsAt:Double}
}

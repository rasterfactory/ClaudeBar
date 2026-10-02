import DataSources
import Domain
import Foundation
import Providers

struct MistralDefinitionAnalyzer {
    let vibeSessionsDir:URL
    let calendar:Calendar
    let now:@Sendable () -> Date
    init(vibeSessionsDir:URL,calendar:Calendar = .current,now:@escaping @Sendable () -> Date = {Date()}) {
        self.vibeSessionsDir=vibeSessionsDir;self.calendar=calendar;self.now=now
    }
    func source(reader:any DirectoryReading = SystemDirectoryReader()) throws -> DataSource {
        let definition=try Providers.builtIn("mistral")
        let source=try definition.dataSource("logs")!.patched(with:.object(["fetch":.object(["directory":.object(["path":.string(vibeSessionsDir.path)])])]))
        return DataSources.make(source,providerId:"mistral",cliExecutor:DefaultCLIExecutor(),network:URLSession.shared,makeTransport:{_,_,_,_ in fatalError("Unexpected RPC")},scripts:Providers.builtInScripts,environment:{_ in nil},homeDirectory:FileManager.default.temporaryDirectory,now:now,calendar:calendar,directoryReader:reader)
    }
    func analyzeToday() async throws -> DailyUsageReport {
        do { guard let report=try await source().fetchUsage().dailyUsageReport else { throw UsageError.noData };return report }
        catch let error as DataSourceError { throw error.reason }
    }
}

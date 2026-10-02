import Foundation

struct DirectoryFetcher: Fetching {
    let call: DirectoryCall
    let reader: any DirectoryReading
    let homeDirectory: URL
    let environment: @Sendable (String) -> String?
    let calendar: Calendar
    let now: @Sendable () -> Date
    var root: URL { URL(fileURLWithPath: Paths.expand(call.path, homeDirectory: homeDirectory, environment: environment)) }
    // Preserve file-existence readiness; reading an absent folder is an empty report.
    func isReady() -> Bool { FileManager.default.fileExists(atPath: root.path) }
    func fetch(with credential: Credential?) async throws -> Response {
        let today = calendar.startOfDay(for: now())
        guard let yesterday = calendar.date(byAdding: .day, value: -1, to: today) else { throw UsageError.executionFailed("Invalid day boundary") }
        let records = try reader.read(root, file: call.file, pattern: call.pattern)
        let output = Envelope(entries: records, todayStart: today.timeIntervalSince1970,
                              yesterdayStart: yesterday.timeIntervalSince1970, todayEnd: today.addingTimeInterval(86400).timeIntervalSince1970)
        return Response(body: try JSONEncoder().encode(output))
    }
    private struct Envelope: Encodable {
        let entries: [DirectoryRecord]
        let todayStart: Double
        let yesterdayStart: Double
        let todayEnd: Double
    }
}

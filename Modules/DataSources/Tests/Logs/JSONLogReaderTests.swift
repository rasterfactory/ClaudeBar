import Foundation
import Testing
@testable import DataSources

/// `json`: one document per file, one record; the time may come from the
/// file's path.
@Suite
struct JSONLogReaderTests {
    private let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)

    private func file(_ name: String, _ content: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private let rule = UsageLog.At.FromPath(pattern: #"run-(\d{8}T\d{4})"#, format: "yyyyMMdd'T'HHmm", timeZone: "UTC")

    private func reader(at: UsageLog.At) -> JSONLogReader {
        JSONLogReader(shape: RecordShape(UsageLog.Records(files: "~/runs/*/summary.json", format: .json, at: at,
                                                          tokens: UsageLog.Tokens(total: "$.used"), cost: "$.spent")))
    }

    @Test func `a file is one record, its time read from the path in the rule's zone`() throws {
        let url = try file("run-20261003T2330/summary.json", #"{"used":1200,"spent":"0.75"}"#)
        let records = reader(at: .fromPath(rule)).records(in: [url])
        #expect(records.count == 1)
        #expect(records[0].tokens == 1200)
        #expect(records[0].cost == Decimal(string: "0.75"))
        #expect(records[0].at == ISO8601DateFormatter().date(from: "2026-10-03T23:30:00Z"))
    }

    @Test func `a path without the pattern, a malformed file or one without usage is skipped`() throws {
        let noTime = try file("other/summary.json", #"{"used":1}"#)
        let broken = try file("run-20261003T0100/summary.json", "{ nope")
        let empty = try file("run-20261003T0200/summary.json", #"{"title":"x"}"#)
        #expect(reader(at: .fromPath(rule)).records(in: [noTime, broken, empty]).isEmpty)
    }

    @Test func `the time may be a field instead`() throws {
        let url = try file("a/summary.json", #"{"when":"2026-10-03T08:00:00Z","used":5}"#)
        #expect(reader(at: "$.when").records(in: [url]).first?.at == ISO8601DateFormatter().date(from: "2026-10-03T08:00:00Z"))
    }

    @Test(arguments: ["America/Los_Angeles", "Asia/Shanghai"])
    func `a field with a format is read in the rule's zone, local unless it names one`(zone: String) throws {
        let url = try file("desk/today.json", #"{"day":"2026-05-28","used":74422}"#)
        let local = UsageLog.At.Formatted(field: "$.day", format: "yyyy-MM-dd")
        let named = UsageLog.At.Formatted(field: "$.day", format: "yyyy-MM-dd", timeZone: zone)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        let midnight = calendar.date(from: DateComponents(year: 2026, month: 5, day: 28))

        #expect(reader(at: .formatted(named)).records(in: [url]).first?.at == midnight)
        calendar.timeZone = .current
        #expect(reader(at: .formatted(local)).records(in: [url]).first?.at == calendar.date(from: DateComponents(year: 2026, month: 5, day: 28)))
    }

    @Test(arguments: ["2026-02-30", "May 28 2026", "2026-05-28T08:00:00Z"])
    func `a field that doesn't read in the format is skipped`(text: String) throws {
        let url = try file("desk/today.json", #"{"day":"\#(text)","used":5}"#)
        #expect(reader(at: .formatted(.init(field: "$.day", format: "yyyy-MM-dd"))).records(in: [url]).isEmpty)
    }

    @Test(arguments: ["-5", "74422.5", "\"lots\""])
    func `a count that isn't a whole number of tokens is skipped`(count: String) throws {
        let url = try file("a/summary.json", #"{"when":"2026-10-03T08:00:00Z","used":\#(count)}"#)
        #expect(reader(at: "$.when").records(in: [url]).isEmpty)
    }

    @Test func `at decodes a field with a format`() throws {
        let formatted = try JSONDecoder().decode(UsageLog.At.self, from: Data(#"{"field":"$.day","format":"yyyy-MM-dd"}"#.utf8))
        #expect(formatted == .formatted(.init(field: "$.day", format: "yyyy-MM-dd")))
        #expect(try JSONDecoder().decode(UsageLog.At.self, from: JSONEncoder().encode(formatted)) == formatted)
    }

    @Test func `at decodes from text or from a path rule`() throws {
        let field = try JSONDecoder().decode(UsageLog.At.self, from: Data(#""$.ts""#.utf8))
        let path = try JSONDecoder().decode(UsageLog.At.self, from: Data(#"{"fromPath":"x_(\\d+)","format":"yyyyMMdd","timeZone":"UTC"}"#.utf8))
        #expect(field == .field("$.ts"))
        #expect(path == .fromPath(.init(pattern: #"x_(\d+)"#, format: "yyyyMMdd", timeZone: "UTC")))
        #expect(try JSONDecoder().decode(UsageLog.At.self, from: JSONEncoder().encode(path)) == path)
    }
}

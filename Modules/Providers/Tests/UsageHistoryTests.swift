import DataSources
import Quotas
import Foundation
import Providers
import Testing

/// *TODAY'S USAGE* — what a login used, day by day, read from its tool's own
/// logs. The login owns it: `account.usageHistory`, `nil` when the provider
/// offers none or the login's logs aren't read.
@MainActor
@Suite
struct UsageHistoryTests {
    private let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)

    private func history() -> UsageHistory {
        let definition = UsageLog.Definition(records: UsageLog.Records(
            files: "~/.acme/*.jsonl", at: "$.at", tokens: UsageLog.Tokens(total: "$.tokens"), cost: "$.cost"))
        return UsageHistory(log: DataSources.makeUsageLog(definition, environment: { _ in nil }, homeDirectory: home))
    }

    private func log(_ entries: [(cost: String, daysAgo: Int)]) throws {
        let dir = home.appendingPathComponent(".acme")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let lines = entries.map { entry -> String in
            let day = Calendar.current.date(byAdding: .day, value: -entry.daysAgo, to: Date())!
            let at = entry.daysAgo == 0 ? Date() : Calendar.current.startOfDay(for: day).addingTimeInterval(43_200)
            return #"{"at":\#(at.timeIntervalSince1970),"tokens":1000,"cost":\#(entry.cost)}"#
        }
        try lines.joined(separator: "\n").write(to: dir.appendingPathComponent("log.jsonl"), atomically: true, encoding: .utf8)
    }

    private func login(_ id: String) -> ProviderAccountConfig {
        ProviderAccountConfig(accountId: id, label: "", email: nil, probeConfig: ["directory": "/tmp/\(id)"])
    }

    // MARK: - Reading

    @Test
    func `reading keeps today's usage against yesterday's`() async throws {
        try log([("14", 0), ("41", 1)])
        let history = history()

        await history.read()

        #expect(history.report?.today.totalCost == 14)
        #expect(history.report?.previous.totalCost == 41)
    }

    @Test
    func `two days with nothing are kept as none`() async {
        let history = history()

        await history.read()

        #expect(history.report == nil)
    }

    @Test
    func `only yesterday's usage is still kept`() async throws {
        try log([("41", 1)])
        let history = history()

        await history.read()

        #expect(history.report?.previous.totalCost == 41)
        #expect(history.report?.today.isEmpty == true)
    }

    @Test
    func `reading also keeps the last thirty days, for the chart`() async throws {
        try log([("14", 0), ("41", 1), ("7", 29), ("99", 30)])
        let history = history()

        await history.read()

        #expect(history.lastThirtyDays.count == 30)
        #expect(history.lastThirtyDays.first?.totalCost == 7)
        #expect(history.lastThirtyDays.suffix(2).map(\.totalCost) == [41, 14])
    }

    @Test
    func `thirty days with nothing are no chart`() async {
        let history = history()

        await history.read()

        #expect(history.lastThirtyDays.isEmpty)
    }

    @Test
    func `days are any range, every date present`() async throws {
        try log([("14", 0), ("41", 1)])

        let days = await history().days(in: .last(30))

        #expect(days.count == 30)
        #expect(days.map(\.totalCost).suffix(2) == [41, 14])
    }

    // MARK: - The login owns it

    @Test
    func `the default login has the provider's usage history`() throws {
        let history = history()
        let provider = try ProviderFactory.make("grok", settings: InMemoryProviderSettings(), usageHistory: history)

        #expect(provider.defaultAccount.usageHistory === history)
    }

    @Test
    func `an added login whose logs aren't read has none`() throws {
        let provider = try ProviderFactory.make("grok", settings: InMemoryProviderSettings(), accounts: [login("work")],
                                          usageHistory: history())

        #expect(provider.accounts.first { !$0.isDefault }?.usageHistory == nil)
    }

    @Test
    func `a provider that offers no usage history has none`() throws {
        let provider = try ProviderFactory.make("grok", settings: InMemoryProviderSettings())

        #expect(provider.defaultAccount.usageHistory == nil)
    }

    // MARK: - Other apps

    private func desk(_ tokens: Int, daysAgo: Int = 0) throws {
        let day = Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date())!
        let dir = home.appendingPathComponent("Desk")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try #"{"at":\#(day.timeIntervalSince1970),"n":\#(tokens)}"#.write(to: dir.appendingPathComponent("today.json"), atomically: true, encoding: .utf8)
    }

    private var deskDefinition: UsageLog.Definition {
        UsageLog.Definition(
            records: UsageLog.Records(files: "~/.acme/*.jsonl", at: "$.at", tokens: UsageLog.Tokens(total: "$.tokens"), cost: "$.cost"),
            otherApps: [UsageLog.OtherApp(label: "Desk", records: UsageLog.Records(
                files: "~/Desk/today.json", format: .json, at: "$.at", tokens: UsageLog.Tokens(total: "$.n")))])
    }

    private func historyWithDesk(ledger: @escaping (String) -> DayLedger? = { _ in nil }) -> UsageHistory {
        UsageHistory(deskDefinition, login: "acme",
                     log: { DataSources.makeUsageLog($0, environment: { _ in nil }, homeDirectory: home) }, ledger: ledger)
    }

    @Test
    func `reading reads each other app under its own name, apart from the login's days`() async throws {
        try log([("14", 0)])
        try desk(74_422)
        let history = historyWithDesk()

        await history.read()

        let desk = try #require(history.otherApps.first)
        #expect(desk.label == "Desk")
        #expect(desk.report?.today.totalTokens == 74_422)
        #expect(desk.knowsCost == false)
        #expect(history.usedOtherApps.map(\.label) == ["Desk"])
        #expect(history.hasUsage)
        #expect(history.label == nil)
        #expect(history.report?.today.totalTokens == 1000)
    }

    @Test
    func `another app's usage alone is usage the login can show`() async throws {
        try desk(74_422)
        let history = historyWithDesk()

        await history.read()

        #expect(history.report == nil)
        #expect(history.hasUsage)
    }

    @Test
    func `an other app used neither today nor yesterday has no report`() async throws {
        try desk(500, daysAgo: 3)
        let history = historyWithDesk()

        await history.read()

        #expect(history.otherApps.first?.report == nil)
        #expect(history.usedOtherApps.isEmpty)
        #expect(!history.hasUsage)
    }

    @Test
    func `each other app keeps its days apart from the login's`() async throws {
        let store = InMemoryLedgerStore()
        try desk(500, daysAgo: 2)
        let history = historyWithDesk(ledger: { DayLedger(store: store, key: $0) })

        await history.read()

        #expect(store.keys.sorted() == ["acme", "acme/Desk"])
    }
}

/// Kept days in memory, by key.
private final class InMemoryLedgerStore: LedgerStore, @unchecked Sendable {
    private var pages: [String: LedgerPage] = [:]
    var keys: [String] { Array(pages.keys) }
    func load(_ key: String) -> LedgerPage? { pages[key] }
    func save(_ page: LedgerPage, for key: String) { pages[key] = page }
}

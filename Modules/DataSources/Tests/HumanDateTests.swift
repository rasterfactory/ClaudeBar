import Foundation
import Testing
@testable import DataSources

/// `humanDate(text)` — reset times as CLIs print them, turned into the next
/// instant they name. Ported from `ClaudeUsageProbeTests`' `parseResetDate`
/// tests, on a fixed clock so every expectation is exact.
@Suite
struct HumanDateTests {
    /// 2026-06-15 12:00:00 UTC.
    static let now = Date(timeIntervalSince1970: 1_781_524_800)

    private func parse(_ text: String, now: Date = now) -> Date? {
        HumanDate.parse(text, now: now)
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0, in zone: String = "UTC") -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    /// A wall-clock time in the zone the app runs in, for texts without a zone.
    private func local(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    // MARK: - Relative durations

    @Test
    func `should reset after the days, hours and minutes the CLI counts down`() {
        #expect(parse("resets in 2d") == Self.now.addingTimeInterval(2 * 86400))
        #expect(parse("resets in 2h 15m") == Self.now.addingTimeInterval(2 * 3600 + 15 * 60))
        #expect(parse("30m") == Self.now.addingTimeInterval(30 * 60))
        #expect(parse("in 2h") == Self.now.addingTimeInterval(7200))
    }

    @Test
    func `should reset after a countdown with its units spelled out`() {
        #expect(parse("Resets in 2 hours 5 min") == Self.now.addingTimeInterval(2 * 3600 + 5 * 60))
        #expect(parse("1 day") == Self.now.addingTimeInterval(86400))
        #expect(parse("10 minutes") == Self.now.addingTimeInterval(600))
    }

    @Test
    func `should know no reset time when the text holds none`() {
        #expect(parse("") == nil)
        #expect(parse("no time here") == nil)
    }

    // MARK: - Absolute times

    @Test
    func `should reset later today at a time the CLI gives in its time zone`() {
        // 8am in New York: 4:59pm is still ahead today.
        #expect(parse("Resets 4:59pm (America/New_York)") == date(2026, 6, 15, 16, 59, in: "America/New_York"))
    }

    @Test
    func `should reset tomorrow when the time given has already passed today`() {
        // 6pm in New York: 4:59pm has gone, so tomorrow's.
        let evening = date(2026, 6, 15, 18, 0, in: "America/New_York")

        #expect(parse("Resets 4:59pm (America/New_York)", now: evening) == date(2026, 6, 16, 16, 59, in: "America/New_York"))
    }

    @Test
    func `should reset at an hour the CLI gives without minutes in its time zone`() {
        // 8pm in Shanghai: 3pm has gone, so tomorrow's.
        #expect(parse("Resets 3pm (Asia/Shanghai)") == date(2026, 6, 16, 15, 0, in: "Asia/Shanghai"))
    }

    @Test
    func `should reset on the day and time the CLI gives in its time zone`() {
        #expect(parse("Resets Dec 25 at 4:59am (Asia/Shanghai)") == date(2026, 12, 25, 4, 59, in: "Asia/Shanghai"))
    }

    @Test
    func `should reset next year when the day the CLI gives has passed this year`() {
        // January 15 has passed this year, so next year's.
        #expect(parse("Resets Jan 15, 3:30pm (America/Los_Angeles)") == date(2027, 1, 15, 15, 30, in: "America/Los_Angeles"))
    }

    @Test
    func `should reset on the day and hour the CLI gives in its time zone`() {
        #expect(parse("Resets Feb 12 at 4pm (Asia/Shanghai)") == date(2027, 2, 12, 16, 0, in: "Asia/Shanghai"))
        #expect(parse("Resets Jul 2 at 4:59am (America/Chicago)") == date(2026, 7, 2, 4, 59, in: "America/Chicago"))
    }

    @Test
    func `should reset at the day and time the CLI gives in this Mac's time zone when it names none`() {
        #expect(parse("Resets Jan 15, 3:30pm") == local(2027, 1, 15, 15, 30))
    }

    @Test
    func `should reset on the full date the CLI gives in its time zone`() {
        #expect(parse("Resets Jan 1, 2027 (America/New_York)") == date(2027, 1, 1, 0, 0, in: "America/New_York"))
    }

    @Test
    func `should keep a reset date with a year even when it has passed`() {
        #expect(parse("Resets Jan 1, 2026 (America/New_York)") == date(2026, 1, 1, 0, 0, in: "America/New_York"))
    }

    @Test
    func `should reset at the start of the day the CLI gives when it names no time`() {
        // Start of that day.
        #expect(parse("Resets Dec 28") == local(2026, 12, 28))
    }

    @Test
    func `should reset at different moments for the same clock time in different time zones`() {
        // The same wall-clock time in different zones is a different instant.
        let eastern = parse("Resets 4:59pm (America/New_York)")
        let shanghai = parse("Resets 4:59pm (Asia/Shanghai)")

        #expect(eastern == date(2026, 6, 15, 20, 59))
        #expect(shanghai == date(2026, 6, 16, 8, 59))
        #expect(eastern != shanghai, "Same wall-clock time in different timezones should produce different Dates")
    }

    // MARK: - Text around the time

    @Test
    func `should find the reset time when a percentage shares its line`() {
        #expect(parse("Resets 3pm (Europe/Amsterdam)                      27% used") == date(2026, 6, 15, 15, 0, in: "Europe/Amsterdam"))
    }

    @Test
    func `should use the last reset time on a line that holds more than one`() {
        #expect(parse("$5.41 / $20.00 spent · Resets Jan 1, 2026 (America/New_York)") == date(2026, 1, 1, 0, 0, in: "America/New_York"))
        #expect(parse("Resets 4:59pm (America/New_York)Resets 4:59pm (America/New_York)") == date(2026, 6, 15, 16, 59, in: "America/New_York"))
    }
}

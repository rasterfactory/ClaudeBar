import Testing
import Foundation
@testable import Domain

@Suite
struct QuotaStatusTests {

    // MARK: - Factory Method Tests

    @Test
    func `should call a quota healthy when 50 percent or more is left`() {
        #expect(QuotaStatus.from(percentRemaining: 100) == .healthy)
        #expect(QuotaStatus.from(percentRemaining: 75) == .healthy)
        #expect(QuotaStatus.from(percentRemaining: 51) == .healthy)
        #expect(QuotaStatus.from(percentRemaining: 50) == .healthy)
    }

    @Test
    func `should warn when between 20 and 49 percent is left`() {
        #expect(QuotaStatus.from(percentRemaining: 49) == .warning)
        #expect(QuotaStatus.from(percentRemaining: 35) == .warning)
        #expect(QuotaStatus.from(percentRemaining: 20) == .warning)
    }

    @Test
    func `should call a quota critical when between 1 and 19 percent is left`() {
        #expect(QuotaStatus.from(percentRemaining: 19) == .critical)
        #expect(QuotaStatus.from(percentRemaining: 10) == .critical)
        #expect(QuotaStatus.from(percentRemaining: 1) == .critical)
    }

    @Test
    func `should call a quota depleted when nothing or less is left`() {
        #expect(QuotaStatus.from(percentRemaining: 0) == .depleted)
        #expect(QuotaStatus.from(percentRemaining: -1) == .depleted)
        #expect(QuotaStatus.from(percentRemaining: -100) == .depleted)
    }

    // MARK: - Needs Attention Tests

    @Test
    func `should not ask for attention when a quota is healthy`() {
        #expect(QuotaStatus.healthy.needsAttention == false)
    }

    @Test
    func `should ask for attention when a quota is in warning`() {
        #expect(QuotaStatus.warning.needsAttention == true)
    }

    @Test
    func `should ask for attention when a quota is critical`() {
        #expect(QuotaStatus.critical.needsAttention == true)
    }

    @Test
    func `should ask for attention when a quota is depleted`() {
        #expect(QuotaStatus.depleted.needsAttention == true)
    }

    // MARK: - Comparison Tests (Severity Order)

    @Test
    func `should rank healthy as less severe than warning`() {
        #expect(QuotaStatus.healthy < QuotaStatus.warning)
    }

    @Test
    func `should rank warning as less severe than critical`() {
        #expect(QuotaStatus.warning < QuotaStatus.critical)
    }

    @Test
    func `should rank critical as less severe than depleted`() {
        #expect(QuotaStatus.critical < QuotaStatus.depleted)
    }

    @Test
    func `should rank depleted as the most severe status`() {
        #expect(QuotaStatus.depleted > QuotaStatus.healthy)
        #expect(QuotaStatus.depleted > QuotaStatus.warning)
        #expect(QuotaStatus.depleted > QuotaStatus.critical)
    }

    @Test
    func `should pick the worst of several statuses`() {
        let statuses: [QuotaStatus] = [.healthy, .warning, .critical]
        #expect(statuses.max() == .critical)

        let mixedStatuses: [QuotaStatus] = [.warning, .depleted, .healthy]
        #expect(mixedStatuses.max() == .depleted)
    }

    // MARK: - Equality Tests

    @Test
    func `should treat each status as equal to itself`() {
        #expect(QuotaStatus.healthy == .healthy)
        #expect(QuotaStatus.warning == .warning)
        #expect(QuotaStatus.critical == .critical)
        #expect(QuotaStatus.depleted == .depleted)
    }

    @Test
    func `should tell different statuses apart`() {
        #expect(QuotaStatus.healthy != .warning)
        #expect(QuotaStatus.warning != .critical)
        #expect(QuotaStatus.critical != .depleted)
    }

    // MARK: - Hashable Tests

    @Test
    func `should let each status carry its own color in a lookup`() {
        var dict: [QuotaStatus: String] = [:]
        dict[.healthy] = "green"
        dict[.warning] = "yellow"

        #expect(dict[.healthy] == "green")
        #expect(dict[.warning] == "yellow")
    }

    @Test
    func `should count a repeated status once in a set of statuses`() {
        let statuses: Set<QuotaStatus> = [.healthy, .warning, .healthy]
        #expect(statuses.count == 2)
    }

    // MARK: - Burn Rate (Pace-Aware) Tests

    @Test
    func `should call a quota healthy when it burns slower than the threshold under pace-aware`() {
        // 57% used, 85% time elapsed → burn rate 0.67 → HEALTHY (issue example: Claude SESSION)
        let status = QuotaStatus.from(percentRemaining: 43, percentTimeElapsed: 85, burnRateThreshold: 1.5)
        #expect(status == .healthy)
    }

    @Test
    func `should warn when the quota burns faster than the threshold under pace-aware`() {
        // 53% used, 8.5% time elapsed → burn rate 6.2 → WARNING (issue example: Codex WEEKLY)
        let status = QuotaStatus.from(percentRemaining: 47, percentTimeElapsed: 8.5, burnRateThreshold: 1.5)
        #expect(status == .warning)
    }

    @Test
    func `should call an empty quota depleted under pace-aware however slowly it burned`() {
        // Depleted is always depleted, even if burn rate is low
        let status = QuotaStatus.from(percentRemaining: 0, percentTimeElapsed: 99, burnRateThreshold: 1.5)
        #expect(status == .depleted)
    }

    @Test
    func `should call a quota with under 20 percent left critical under pace-aware however slowly it burns`() {
        // Below 20% remaining is always critical (absolute safety net)
        let status = QuotaStatus.from(percentRemaining: 15, percentTimeElapsed: 90, burnRateThreshold: 1.5)
        #expect(status == .critical)
    }

    @Test
    func `should call a quota healthy under pace-aware when 90 percent is left despite a fast burn`() {
        // 10% used, 5% elapsed → burn rate 2.0, but 90% remaining — no warning yet
        let status = QuotaStatus.from(percentRemaining: 90, percentTimeElapsed: 5, burnRateThreshold: 1.5)
        #expect(status == .healthy)
    }

    @Test
    func `should fall back to absolute thresholds under pace-aware when the window has just started`() {
        // At the very start of a period, fall back to absolute thresholds
        let status = QuotaStatus.from(percentRemaining: 43, percentTimeElapsed: 0, burnRateThreshold: 1.5)
        #expect(status == .warning) // 43% remaining → absolute threshold says warning
    }

    @Test
    func `should warn or stay healthy under pace-aware depending on the threshold the person picks`() {
        // 55% used, 30% elapsed → burn rate ~1.83, remaining = 45% < 50
        // With threshold 1.5 → warning (1.83 > 1.5)
        let warningStatus = QuotaStatus.from(percentRemaining: 45, percentTimeElapsed: 30, burnRateThreshold: 1.5)
        #expect(warningStatus == .warning)

        // With threshold 2.5 → healthy (1.83 < 2.5)
        let healthyStatus = QuotaStatus.from(percentRemaining: 45, percentTimeElapsed: 30, burnRateThreshold: 2.5)
        #expect(healthyStatus == .healthy)
    }

    @Test
    func `should warn under pace-aware when 45 percent is left and the quota burns faster than the threshold`() {
        // Burn rate matters only when remaining < 50% (meaningful warning zone)
        // 55% used, 30% elapsed → burn rate ~1.83 > 1.5, remaining = 45% < 50 → warning
        let status = QuotaStatus.from(percentRemaining: 45, percentTimeElapsed: 30, burnRateThreshold: 1.5)
        #expect(status == .warning)
    }
}

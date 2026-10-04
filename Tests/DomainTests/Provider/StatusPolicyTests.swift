import Foundation
import Testing
@testable import Domain

/// One status per quota: every surface reads `status(under:)` with the
/// person's policy — absolute thresholds, or pace-aware with a burn rate.
@Suite
struct StatusPolicyTests {
    /// 40% left with 90% of a 5-hour window gone — on pace (burn rate 0.67).
    private func onPace() -> UsageQuota {
        UsageQuota(
            percentRemaining: 40, quotaType: .session, providerId: "claude",
            resetsAt: Date().addingTimeInterval(30 * 60), windowDuration: 5 * 3600
        )
    }

    /// 40% left with 20% of the window gone — burning fast (burn rate 3).
    private func burningFast() -> UsageQuota {
        UsageQuota(
            percentRemaining: 40, quotaType: .session, providerId: "claude",
            resetsAt: Date().addingTimeInterval(4 * 3600), windowDuration: 5 * 3600
        )
    }

    @Test
    func `should warn between 20 and 50 percent left under absolute thresholds, however fast the quota burns`() {
        #expect(onPace().status(under: .absolute) == .warning)
        #expect(burningFast().status(under: .absolute) == .warning)
    }

    @Test
    func `should call an on-pace quota healthy and a fast-burning one a warning when the person picks pace-aware`() {
        let policy = StatusPolicy.paceAware(burnRateThreshold: 1.5)

        #expect(onPace().status(under: policy) == .healthy)
        #expect(burningFast().status(under: policy) == .warning)
    }

    @Test
    func `should call 10 percent left critical even when the person picks pace-aware`() {
        let low = UsageQuota(
            percentRemaining: 10, quotaType: .session, providerId: "claude",
            resetsAt: Date().addingTimeInterval(60), windowDuration: 5 * 3600
        )

        #expect(low.status(under: .paceAware(burnRateThreshold: 1.5)) == .critical)
    }

    @Test
    func `should show the provider's status as its worst quota under the person's policy`() {
        let usage = UsageSnapshot(providerId: "claude", quotas: [onPace(), burningFast()], capturedAt: Date())
        let calm = UsageSnapshot(providerId: "claude", quotas: [onPace()], capturedAt: Date())

        #expect(usage.overallStatus(under: .paceAware(burnRateThreshold: 1.5)) == .warning)
        #expect(calm.overallStatus(under: .paceAware(burnRateThreshold: 1.5)) == .healthy)
        #expect(calm.overallStatus(under: .absolute) == .warning)
    }
}

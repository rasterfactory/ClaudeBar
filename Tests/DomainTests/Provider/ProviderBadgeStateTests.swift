import Testing
import Foundation
@testable import Domain

@Suite("ProviderBadgeState Tests")
struct ProviderBadgeStateTests {

    @Test
    func `a failed probe with no snapshot is unavailable, not healthy`() {
        let state = ProviderBadgeState(isSyncing: false, quotaStatus: nil, hasError: true)

        #expect(state == .unavailable)
        #expect(!state.hasData)
    }

    @Test
    func `no snapshot and no error yet is awaiting data, not healthy`() {
        let state = ProviderBadgeState(isSyncing: false, quotaStatus: nil, hasError: false)

        #expect(state == .awaitingData)
        #expect(!state.hasData)
    }

    @Test
    func `a provider waiting to be set up is not set up, not unavailable`() {
        let state = ProviderBadgeState(isSyncing: false, quotaStatus: nil, hasError: true, needsSetup: true)

        #expect(state == .notSetUp)
        #expect(!state.hasData)
    }

    @Test
    func `waiting for setup while its usage is read says nothing alarming`() {
        // A Claude Desktop user: no Claude Code, so no limits — but Desktop's
        // tokens today are read. They did set Claude up; NOT SET UP would blame them (#198).
        let state = ProviderBadgeState(isSyncing: false, quotaStatus: nil, hasError: true, needsSetup: true, readsUsage: true)

        #expect(state == .usageOnly)
        #expect(!state.hasData)
    }

    @Test
    func `stale numbers still win over a later setup failure`() {
        let state = ProviderBadgeState(isSyncing: false, quotaStatus: .healthy, hasError: true, needsSetup: true)

        #expect(state == .quota(.healthy))
    }

    @Test
    func `a snapshot reports its own quota status`() {
        let state = ProviderBadgeState(isSyncing: false, quotaStatus: .warning, hasError: false)

        #expect(state == .quota(.warning))
        #expect(state.hasData)
    }

    @Test
    func `stale numbers still show when a later refresh failed`() {
        let state = ProviderBadgeState(isSyncing: false, quotaStatus: .critical, hasError: true)

        #expect(state == .quota(.critical))
    }

    @Test
    func `syncing wins over every other state`() {
        #expect(ProviderBadgeState(isSyncing: true, quotaStatus: nil, hasError: true) == .syncing)
        #expect(ProviderBadgeState(isSyncing: true, quotaStatus: .healthy, hasError: false) == .syncing)
    }

    // MARK: - A tab of logins

    @MainActor @Test
    func `a tab whose every login waits for setup is not set up`() {
        let state = ProviderBadgeState(of: [Login(needsSetup: true), Login(needsSetup: true)], quotaStatus: nil)
        #expect(state == .notSetUp)
    }

    @MainActor @Test
    func `a tab where one login's usage is read says nothing alarming`() {
        let state = ProviderBadgeState(of: [Login(needsSetup: true, readsUsage: true)], quotaStatus: nil)
        #expect(state == .usageOnly)
        #expect(!state.showsBadge)
    }

    @MainActor @Test
    func `one login failing for real makes the tab unavailable, not waiting for setup`() {
        let state = ProviderBadgeState(of: [Login(needsSetup: true), Login(failed: true)], quotaStatus: nil)
        #expect(state == .unavailable)
        #expect(state.showsBadge)
    }

    @MainActor @Test
    func `a tab with no logins is awaiting data`() {
        #expect(ProviderBadgeState(of: [ProviderBadgeState.Login](), quotaStatus: nil) == .awaitingData)
    }

    @MainActor @Test
    func `a login syncing makes the tab syncing`() {
        #expect(ProviderBadgeState(of: [Login(syncing: true), Login(failed: true)], quotaStatus: nil) == .syncing)
    }
}

/// A login as the badge sees it.
private func Login(needsSetup: Bool = false, readsUsage: Bool = false, failed: Bool = false, syncing: Bool = false) -> ProviderBadgeState.Login {
    // A login waiting for setup also carries the error that says so.
    ProviderBadgeState.Login(isSyncing: syncing, failed: needsSetup || failed, needsSetup: needsSetup, readsUsage: readsUsage)
}

import Testing
import AppKit
import Domain
@testable import ClaudeBar

/// *Show Provider Logo*: a single readout can start with its provider's
/// logo too. Off by default — one readout has nothing to tell apart — and
/// several providers or accounts always show theirs.
@Suite @MainActor
struct MenuBarProviderLogoTests {
    @Test func `a single readout has no logo unless asked`() {
        #expect(!StatusItemLabelDriver.showsPrimaryLogo(showsQuota: true, hasOtherReadouts: false, hasAccountName: false, logoAlways: false))
        #expect(StatusItemLabelDriver.showsPrimaryLogo(showsQuota: true, hasOtherReadouts: false, hasAccountName: false, logoAlways: true))
    }

    @Test func `readouts to tell apart always have logos`() {
        #expect(StatusItemLabelDriver.showsPrimaryLogo(showsQuota: true, hasOtherReadouts: true, hasAccountName: false, logoAlways: false))
        #expect(StatusItemLabelDriver.showsPrimaryLogo(showsQuota: true, hasOtherReadouts: false, hasAccountName: true, logoAlways: false))
    }

    @Test func `without a readout there is no logo, only the status icon`() {
        #expect(!StatusItemLabelDriver.showsPrimaryLogo(showsQuota: false, hasOtherReadouts: true, hasAccountName: true, logoAlways: true))
    }

    @Test func `a logo waiting for its first reading shows alone, not beside a chart icon`() {
        #expect(!StatusItemLabelDriver.showsStatusIcon(hasLabel: false, showsLogo: true))
        #expect(StatusItemLabelDriver.showsStatusIcon(hasLabel: false, showsLogo: false))
        #expect(!StatusItemLabelDriver.showsStatusIcon(hasLabel: true, showsLogo: false))
    }

    @Test func `at launch the logo alone is narrower than logo and chart icon`() {
        var content = StatusItemLabelDriver.LabelContent(label: nil, fallbackStatus: .healthy, sessionPhase: nil, themeModeId: "dark")
        content.primaryProviderId = "claude"
        content.primaryProviderName = "Claude"
        let logoOnly = StatusItemLabelDriver.compose(content, theme: DarkTheme())
        content.primaryProviderId = nil
        content.primaryProviderName = nil
        let chartOnly = StatusItemLabelDriver.compose(content, theme: DarkTheme())
        // Two images joined with spacing would be wider than either alone.
        #expect(logoOnly.size.width < chartOnly.size.width + 12)
        #expect(logoOnly.size.width > 0)
    }

    @Test func `with the logo the label starts with it`() {
        var content = StatusItemLabelDriver.LabelContent(
            label: MenuBarLabel(text: "5h 81%", status: .healthy, segments: [.init(text: "5h 81%", status: .healthy)]),
            fallbackStatus: .healthy, sessionPhase: nil, themeModeId: "dark"
        )
        let plain = StatusItemLabelDriver.compose(content, theme: DarkTheme())
        content.primaryProviderId = "claude"
        content.primaryProviderName = "Claude"
        let withLogo = StatusItemLabelDriver.compose(content, theme: DarkTheme())
        #expect(withLogo.size.width > plain.size.width)
    }
}

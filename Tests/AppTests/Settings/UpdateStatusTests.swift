import Testing
@testable import ClaudeBar

/// What Settings says about updates. The Updates page and the sidebar footer
/// print the same status, so they can never disagree.
@Suite
struct UpdateStatusTests {
    private let ready = UpdateStatus(currentVersion: "0.5.3", availableVersion: "0.5.4")
    private let upToDate = UpdateStatus(currentVersion: "0.5.3", availableVersion: nil)

    @Test func `should name the new version on the Updates page when one is ready`() {
        #expect(ready.summary == "You're on version 0.5.3. Version 0.5.4 is ready to install.")
    }

    @Test func `should say only the version you're on when no update is found`() {
        #expect(upToDate.summary == "You're on version 0.5.3.")
    }

    @Test func `should name the new version in the sidebar when one is ready`() {
        #expect(ready.footer == "v0.5.3 · 0.5.4 available")
    }

    @Test func `should say up to date in the sidebar when no update is found`() {
        #expect(upToDate.footer == "v0.5.3 · up to date")
    }

    @Test func `should offer to install the update when one is ready`() {
        #expect(ready.actionTitle == "Version 0.5.4 is available")
        #expect(ready.buttonTitle == "Install Update")
    }

    @Test func `should offer to check for updates when no update is found`() {
        #expect(upToDate.actionTitle == "Check for Updates")
        #expect(upToDate.buttonTitle == "Check Now")
    }
}

import Testing
@testable import ClaudeBar

/// Xcode runs AppTests inside the ClaudeBar app. Launched that way, the app
/// must start nothing — no providers, no Keychain, no refreshes, no menu bar —
/// or every test run asks for Keychain access and reads real usage.
@Suite
struct LaunchModeTests {
    @Test func `should launch empty when Xcode runs ClaudeBar to host its tests`() {
        let mode = LaunchMode(environment: ["XCTestConfigurationFilePath": "/tmp/AppTests.xctestconfiguration"])

        #expect(mode == .testHost)
    }

    @Test func `should launch the menu bar app when the person opens ClaudeBar`() {
        #expect(LaunchMode(environment: [:]) == .menuBarApp)
    }

    @Test func `should know it is hosting these tests right now`() {
        #expect(LaunchMode.current == .testHost)
    }
}

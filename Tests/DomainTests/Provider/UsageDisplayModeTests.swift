import Testing
@testable import Domain

@Suite
struct UsageDisplayModeTests {

    // MARK: - Display Label

    @Test
    func `should label the remaining mode Remaining`() {
        // Given
        let mode = UsageDisplayMode.remaining

        // When & Then
        #expect(mode.displayLabel == "Remaining")
    }

    @Test
    func `should label the used mode Used`() {
        // Given
        let mode = UsageDisplayMode.used

        // When & Then
        #expect(mode.displayLabel == "Used")
    }

    // MARK: - Raw Value Persistence

    @Test
    func `should save the remaining mode as remaining in settings`() {
        #expect(UsageDisplayMode.remaining.rawValue == "remaining")
    }

    @Test
    func `should save the used mode as used in settings`() {
        #expect(UsageDisplayMode.used.rawValue == "used")
    }

    @Test
    func `should read back the saved mode and ignore an unknown one`() {
        #expect(UsageDisplayMode(rawValue: "remaining") == .remaining)
        #expect(UsageDisplayMode(rawValue: "used") == .used)
        #expect(UsageDisplayMode(rawValue: "invalid") == nil)
    }
}
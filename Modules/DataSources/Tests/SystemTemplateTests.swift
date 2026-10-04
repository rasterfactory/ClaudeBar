import Foundation
import Testing
@testable import DataSources

/// `{{system.timeZone}}` is the Mac's time zone, as a browser sends it.
@Suite
struct SystemTemplateTests {
    @Test
    func `should send the Mac's time zone even without a credential`() {
        #expect(Template.fill("tz={{system.timeZone}}", with: nil) == "tz=\(TimeZone.current.identifier)")
    }
}

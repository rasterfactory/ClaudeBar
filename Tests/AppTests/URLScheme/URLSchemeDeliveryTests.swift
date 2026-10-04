import Testing
import AppKit
@testable import ClaudeBar

/// The app delegate is the one object guaranteed to exist when a
/// `claudebar://` URL arrives, including when the URL is what launched the
/// app. These tests pin down that no action is lost across that gap.
@Suite @MainActor
struct URLSchemeDeliveryTests {

    @Test
    func `should act on links in the order they arrive`() {
        let delegate = AppDelegate()
        var received: [URLSchemeAction] = []
        delegate.onAction = { received.append($0) }

        delegate.application(NSApp, open: [
            URL(string: "claudebar://refresh")!,
            URL(string: "claudebar://open")!,
        ])

        #expect(received == [.refresh, .open])
    }

    @Test
    func `should act on a link that launched the app once the app is ready`() {
        let delegate = AppDelegate()
        delegate.application(NSApp, open: [URL(string: "claudebar://open")!])

        var received: [URLSchemeAction] = []
        delegate.onAction = { received.append($0) }

        #expect(received == [.open])
    }

    @Test
    func `should act on a held link only once`() {
        let delegate = AppDelegate()
        delegate.application(NSApp, open: [URL(string: "claudebar://open")!])
        var received: [URLSchemeAction] = []
        delegate.onAction = { received.append($0) }

        delegate.application(NSApp, open: [URL(string: "claudebar://settings")!])

        #expect(received == [.open, .settings])
    }

    @Test
    func `should do nothing for an unknown link`() {
        let delegate = AppDelegate()
        var received: [URLSchemeAction] = []
        delegate.onAction = { received.append($0) }

        delegate.application(NSApp, open: [URL(string: "claudebar://foo")!])

        #expect(received.isEmpty)
    }
}

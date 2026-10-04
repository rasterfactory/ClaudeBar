import SwiftUI
import Testing
@testable import ClaudeBar

/// Pop: cream paper, thick ink outlines, hard offset shadows, candy status
/// colours with ink text on them, and big numbers in Lilita One. Every
/// other theme keeps its thin outline, no hard shadow and white badge text.
@MainActor
@Suite
struct PopThemeTests {
    @Test func `should offer Pop among the built-in themes`() {
        #expect(ThemeRegistry.shared.theme(for: "pop")?.displayName == "Pop")
        #expect(ThemeMode(rawValue: "pop") == .pop)
    }

    @Test func `should outline Pop's cards in ink with a hard shadow`() {
        let pop = PopTheme()
        #expect(pop.cardBorderWidth == 2.5)
        #expect(pop.glassBorder == PopTheme.ink)
        #expect(pop.cardShadow == ThemeShadow(color: PopTheme.ink, radius: 0, x: 4, y: 4))
        // Outlined: Settings draws paper, inked selections and switches for it.
        #expect(pop.isOutlined)
    }

    @Test func `should write badges on Pop's candy colours in ink`() {
        #expect(PopTheme().textOnStatus == PopTheme.ink)
    }

    @Test func `should show Pop's big numbers in Lilita One`() {
        #expect(PopTheme().displayFontName == "LilitaOne")
    }

    @Test(arguments: ["light", "dark", "system", "cli", "christmas"])
    func `should keep every other theme's thin outline, no hard shadow and white badge text`(id: String) throws {
        let theme = try #require(ThemeRegistry.shared.theme(for: id))
        #expect(theme.cardBorderWidth == 1)
        #expect(theme.cardShadow == nil)
        #expect(theme.displayFontName == nil)
        #expect(theme.textOnStatus == .white)
        #expect(!theme.isOutlined)
    }
}

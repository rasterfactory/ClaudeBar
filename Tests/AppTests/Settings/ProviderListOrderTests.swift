import Testing
@testable import ClaudeBar

/// Settings → Providers lists the providers a person turned on first, so the
/// one that matters isn't at the bottom of 21 rows (#141). The order is taken
/// when the list appears, so a row never jumps while its switch is flipped.
@Suite
struct ProviderListOrderTests {
    @Test
    func `should list the providers that are on first, each group keeping its order (#141)`() {
        let listed = ProviderListOrder.listed([
            ("claude", true), ("gemini", false), ("codex", true), ("zai", false), ("custom-acme", true),
        ])

        #expect(listed == ["claude", "codex", "custom-acme", "gemini", "zai"])
    }

    @Test
    func `should keep rows in place while the list is open, adding new providers at the end`() {
        let kept = ProviderListOrder.keeping(["claude", "codex", "gemini"], current: ["gemini", "claude", "codex", "custom-new"])

        #expect(kept == ["claude", "codex", "gemini", "custom-new"])
    }

    @Test
    func `should drop a removed provider from the open list`() {
        let kept = ProviderListOrder.keeping(["claude", "custom-gone", "codex"], current: ["claude", "codex"])

        #expect(kept == ["claude", "codex"])
    }
}

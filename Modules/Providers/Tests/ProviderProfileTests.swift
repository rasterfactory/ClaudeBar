import Foundation
import Providers
import Testing

/// WHO IT IS — a built-in provider's name, links and face come from its
/// definition, with the exact values the `switch id` tables used to hold.
@Suite
struct ProviderProfileTests {
    @Test
    func `should show Claude with its name, status page, symbol, icon and colours`() throws {
        let profile = try ProviderFactory.builtIn("claude").profile

        #expect(profile.id == "claude")
        #expect(profile.name == "Claude")
        #expect(profile.origin == .builtIn)
        #expect(profile.look.symbol == "brain.fill")
        #expect(profile.look.icon == "ClaudeIcon")
        #expect(profile.look.color == .init(light: .init(0.95, 0.48, 0.38), dark: .init(0.98, 0.55, 0.45)))
        #expect(profile.look.gradientEnd == .init(light: .init(0.92, 0.45, 0.72), dark: .init(0.85, 0.35, 0.65)))
        #expect(profile.links.status == URL(string: "https://status.anthropic.com"))
    }

    @Test
    func `should show Codex with its name, symbol, icon and colours`() throws {
        let profile = try ProviderFactory.builtIn("codex").profile

        #expect(profile.name == "Codex")
        #expect(profile.look.symbol == "chevron.left.forwardslash.chevron.right")
        #expect(profile.look.icon == "CodexIcon")
        #expect(profile.look.color == .init(light: .init(0.18, 0.72, 0.68), dark: .init(0.35, 0.85, 0.78)))
        #expect(profile.look.gradientEnd == .init(light: .init(0.12, 0.52, 0.72), dark: .init(0.25, 0.65, 0.85)))
    }

    @Test
    func `should find a login's provider from the login's lineup id, and none for an unknown provider`() {
        #expect(ProviderFactory.builtInDefinition(forLineupId: "codex.4f2a")?.id == "codex")
        #expect(ProviderFactory.builtInDefinition(forLineupId: "claude")?.id == "claude")
        #expect(ProviderFactory.builtInDefinition(forLineupId: "acme-not-built-in") == nil)
    }

    @Test
    func `should mark a provider as custom when its file is the person's own, whatever the file says`() throws {
        let data = try ProviderFactory.builtInData("codex")

        #expect(try ProviderDefinition.parse(data, origin: .custom).profile.origin == .custom)
    }
}

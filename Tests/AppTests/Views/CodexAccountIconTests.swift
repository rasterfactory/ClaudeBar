import Testing
@testable import ClaudeBar

@Suite @MainActor
struct CodexAccountIconTests {
    @Test func `should show the Codex icon for every added Codex account`() {
        #expect(ProviderVisualIdentityLookup.iconAssetName(for: "codex.account-a") == "CodexIcon")
        #expect(ProviderVisualIdentityLookup.symbolIcon(for: "codex.account-b") ==
                ProviderVisualIdentityLookup.symbolIcon(for: "codex"))
        #expect(ProviderVisualIdentityLookup.iconAssetName(for: "not-codex.account") != "CodexIcon")
    }
}

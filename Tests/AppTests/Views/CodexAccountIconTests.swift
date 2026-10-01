import AppKit
import SwiftUI
import Domain
import Infrastructure
import Providers
import DataSources
import Testing
@testable import ClaudeBar

@Suite @MainActor
struct CodexAccountIconTests {
    @Test func `account instances keep the Codex icon`() {
        #expect(ProviderVisualIdentityLookup.iconAssetName(for: "codex.account-a") == "CodexIcon")
        #expect(ProviderVisualIdentityLookup.symbolIcon(for: "codex.account-b") ==
                ProviderVisualIdentityLookup.symbolIcon(for: "codex"))
        #expect(ProviderVisualIdentityLookup.iconAssetName(for: "not-codex.account") != "CodexIcon")
    }
}

@Suite @MainActor
struct CodexAccountPresentationTests {
    @Test func `compact account label uses substantially less menu bar width`() throws {
        let content = StatusItemLabelDriver.LabelContent(
            accountLabels: ["codex": "mclaugh…"],
            label: MenuBarLabel(text: "16% · 6d", status: .warning),
            primaryProviderId: "codex", primaryProviderName: "mclaughlin.ryan@gmail.com",
            fallbackStatus: .warning, sessionPhase: nil, themeModeId: "dark")
        let compact = StatusItemLabelDriver.compose(content, theme: DarkTheme())
        var full = content
        full.accountLabels = ["codex": "mclaughlin.ryan@gmail.com"]
        let wide = StatusItemLabelDriver.compose(full, theme: DarkTheme())
        #expect(compact.size.width < wide.size.width - 60)
        var single = content
        single.accountLabels = [:]
        single.primaryProviderName = "Codex"
        let unnamed = StatusItemLabelDriver.compose(single, theme: DarkTheme())
        #expect(unnamed.size.width < compact.size.width)
        try capture(compact, named: "menu-bar-multiple")
        try capture(unnamed, named: "menu-bar-single")
    }

    @Test func `setup fits its native sheet without terminal instructions`() throws {
        let monitor = QuotaMonitor(providers: AIProviders(providers: []), clock: SystemClock())
        let renderer = ImageRenderer(content: CodexAccountSetupSheet(monitor: monitor)
            .environment(\.appTheme, DarkTheme()))
        renderer.scale = 2
        let image = try #require(renderer.nsImage)
        #expect(image.size.width == 520)
        #expect(image.size.height < 450)
        try capture(image, named: "account-setup")
    }

    @Test func `optional name editor fits a native sheet`() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = JSONSettingsRepository(store: JSONSettingsStore(fileURL: directory.appendingPathComponent("settings.json")))
        let config = ProviderAccountConfig(accountId: "work", label: "Work", email: "work@example.com",
                                           probeConfig: ["codexHome": "/work", "chatgptAccountId": "work"])
        let provider = Provider(definition: try Providers.builtIn("codex"), settings: settings, accounts: [config],
                                makeDataSource: { DataSources.make($0, providerId: "codex") })
        let account = try #require(provider.accounts.last)
        let renderer = ImageRenderer(content: AccountNameSheet(account: account).environment(\.appTheme, DarkTheme()))
        renderer.scale = 2
        let image = try #require(renderer.nsImage)
        #expect(image.size.width == 420)
        #expect(image.size.height < 400)
        try capture(image, named: "account-name-editor")
    }

    private func capture(_ image: NSImage, named name: String) throws {
        // Optional visual QA artifacts, never user preferences or credentials.
        guard let folder = ProcessInfo.processInfo.environment["CLAUDEBAR_UI_CAPTURE_DIR"] else { return }
        let url = URL(fileURLWithPath: folder)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let tiff = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: tiff))
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: url.appendingPathComponent(name + ".png"))
    }
}

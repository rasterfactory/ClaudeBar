import DataSources
import Foundation
import Providers
import Quotas
import Testing

/// `Providers` — the providers you keep, the Providers pane (TARGET §12,
/// slice 3): create a custom one, read them and the lineup, order them,
/// delete a custom one.
@MainActor
@Suite
struct KeptProvidersTests {
    private let settings = InMemoryProviderSettings()
    private let vault = MemoryVault()
    private let catalog = ProviderCatalog(directory: FileManager.default.temporaryDirectory
        .appendingPathComponent("kept-providers-\(UUID().uuidString)", isDirectory: true))

    private func providers(_ ids: [String]) throws -> Providers {
        let settings = settings
        return Providers(try ids.map { try ProviderFactory.make($0, settings: settings) },
                         settings: settings, catalog: catalog, vault: vault,
                         make: { ProviderFactory.make($0, settings: settings) })
    }

    private func custom(_ name: String = "Acme") throws -> ProviderDefinition {
        var draft = ProviderDraft(start: .api)
        draft.url = "https://acme.example/usage"
        draft.key = .apiKey
        draft.sentAs = .bearer
        draft.measure = .percentLeft
        draft.remaining = "$.left"
        draft.name = name
        return try draft.definition(id: catalog.mintId(for: name))
    }

    // MARK: - Read

    @Test
    func `the providers are in the order they were kept`() throws {
        let kept = try providers(["claude", "codex"])

        #expect(kept.all.map(\.id) == ["claude", "codex"])
        #expect(kept.provider(id: "codex")?.name == "Codex")
        #expect(kept.login(id: "claude")?.providerId == "claude")
    }

    @Test
    func `the lineup is the enabled logins of enabled providers`() throws {
        let kept = try providers(["claude", "codex"])

        kept.provider(id: "codex")?.isEnabled = false

        #expect(kept.lineup.map(\.id) == ["claude"])
    }

    // MARK: - Update: the order

    @Test
    func `moving a provider saves the order, its logins together`() throws {
        let kept = try providers(["claude", "codex", "gemini"])

        kept.move("gemini", by: -2)

        #expect(kept.all.map(\.id) == ["gemini", "claude", "codex"])
        #expect(settings.providerOrder() == ["gemini", "claude", "codex"])
    }

    @Test
    func `the saved order is read back; a provider it doesn't name keeps its place after`() throws {
        settings.setProviderOrder(["codex", "gone"])

        let kept = try providers(["claude", "codex"])

        #expect(kept.all.map(\.id) == ["codex", "claude"])
    }

    @Test
    func `a move past the end stops at the end`() throws {
        let kept = try providers(["claude", "codex"])

        kept.move("claude", by: 5)

        #expect(kept.all.map(\.id) == ["codex", "claude"])
    }

    // MARK: - Create

    @Test
    func `adding a custom provider saves it and keeps it, after the others`() throws {
        defer { try? FileManager.default.removeItem(at: catalog.directory) }
        let kept = try providers(["claude"])
        let acme = try custom()

        let added = try kept.add(acme)

        #expect(kept.all.map(\.id) == ["claude", acme.id])
        #expect(added.id == acme.id)
        #expect(catalog.custom().map(\.id) == [acme.id])
    }

    @Test
    func `a provider is kept once`() throws {
        defer { try? FileManager.default.removeItem(at: catalog.directory) }
        let kept = try providers(["claude"])
        let acme = try custom()
        try kept.add(acme)

        #expect(throws: (any Error).self) { try kept.add(acme) }
        #expect(kept.all.count == 2)
    }

    // MARK: - Delete

    @Test
    func `deleting a custom provider removes its file, its keys and its place`() throws {
        defer { try? FileManager.default.removeItem(at: catalog.directory) }
        let kept = try providers(["claude"])
        let acme = try custom()
        try kept.add(acme)
        vault.save("sk-1", "apiKey", provider: acme.id)

        try kept.remove(acme.id)

        #expect(kept.all.map(\.id) == ["claude"])
        #expect(catalog.custom().isEmpty)
        #expect(vault.secret("apiKey", provider: acme.id) == nil)
        #expect(ProviderFactory.definition(forLineupId: acme.id) == nil)
    }

    @Test
    func `a built-in provider is never deleted, only turned off`() throws {
        let kept = try providers(["claude"])

        #expect(throws: (any Error).self) { try kept.remove("claude") }
        #expect(kept.all.map(\.id) == ["claude"])
    }
}

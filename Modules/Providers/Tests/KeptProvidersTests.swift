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
    func `should list the providers, and find each provider and login, in the order they were kept`() throws {
        let kept = try providers(["claude", "codex"])

        #expect(kept.all.map(\.id) == ["claude", "codex"])
        #expect(kept.provider(id: "codex")?.name == "Codex")
        #expect(kept.login(id: "claude")?.providerId == "claude")
    }

    @Test
    func `should leave a turned-off provider's logins out of the lineup`() throws {
        let kept = try providers(["claude", "codex"])

        kept.provider(id: "codex")?.isEnabled = false

        #expect(kept.lineup.map(\.id) == ["claude"])
    }

    // MARK: - Update: the order

    @Test
    func `should save the new order when the person moves a provider`() throws {
        let kept = try providers(["claude", "codex", "gemini"])

        kept.move("gemini", by: -2)

        #expect(kept.all.map(\.id) == ["gemini", "claude", "codex"])
        #expect(settings.providerOrder() == ["gemini", "claude", "codex"])
    }

    @Test
    func `should list providers in the saved order, with ones it doesn't name after`() throws {
        settings.setProviderOrder(["codex", "gone"])

        let kept = try providers(["claude", "codex"])

        #expect(kept.all.map(\.id) == ["codex", "claude"])
    }

    @Test
    func `should stop a provider at the end when it is moved past it`() throws {
        let kept = try providers(["claude", "codex"])

        kept.move("claude", by: 5)

        #expect(kept.all.map(\.id) == ["codex", "claude"])
    }

    // MARK: - Create

    @Test
    func `should save a new custom provider and list it after the others`() throws {
        defer { try? FileManager.default.removeItem(at: catalog.directory) }
        let kept = try providers(["claude"])
        let acme = try custom()

        let added = try kept.add(acme)

        #expect(kept.all.map(\.id) == ["claude", acme.id])
        #expect(added.id == acme.id)
        #expect(catalog.custom().map(\.id) == [acme.id])
    }

    @Test
    func `should refuse to add a provider that is already kept`() throws {
        defer { try? FileManager.default.removeItem(at: catalog.directory) }
        let kept = try providers(["claude"])
        let acme = try custom()
        try kept.add(acme)

        #expect(throws: (any Error).self) { try kept.add(acme) }
        #expect(kept.all.count == 2)
    }

    // MARK: - Delete

    @Test
    func `should remove a deleted custom provider's file, keys and place in the list`() throws {
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
    func `should refuse to delete a built-in provider`() throws {
        let kept = try providers(["claude"])

        #expect(throws: (any Error).self) { try kept.remove("claude") }
        #expect(kept.all.map(\.id) == ["claude"])
    }
}

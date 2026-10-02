import DataSources
import Foundation
import Mockable
import Providers
import Quotas
import Testing

@Suite @MainActor
struct KimiDefinitionTests {
    private func make(settings: InMemoryProviderSettings, vault: MemoryVault) throws -> Provider {
        let definition = try Providers.builtIn("kimi")
        let network = MockNetworkClient()
        given(network).request(.any).willProduce { @Sendable request in
            let token = request.value(forHTTPHeaderField: "Authorization") ?? ""
            let used = token == "Bearer work-session" ? 75 : token == "Bearer personal-session" ? 20 : 0
            return (Data("{\"usages\":[{\"scope\":\"FEATURE_CODING\",\"detail\":{\"limit\":\"100\",\"used\":\"\(used)\",\"resetTime\":\"\"}}]}".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        return Provider(definition: definition, settings: settings, accounts: settings.accounts(forProvider: "kimi"), makeDataSource: { source, login in
            DataSources.make(source, providerId: "kimi", cliExecutor: MockCLIExecutor(), network: network, makeTransport: { _, _, _, _ in MockRPCTransport() }, scripts: Providers.builtInScripts, browserCookies: EmptyCookies(), secrets: vault.scoped(to: login), environment: { _ in nil }, homeDirectory: FileManager.default.temporaryDirectory, now: { Date() })
        }, vault: vault)
    }
    @Test func `API accounts have independent sessions regions names and persisted metadata`() async throws {
        let settings = InMemoryProviderSettings(), vault = MemoryVault()
        let provider = try make(settings: settings, vault: vault)
        let personal = try provider.addAccount(filling: ["apiKey":"personal-session"])
        let work = try provider.addAccount(filling: ["apiKey":"work-session", "region":"international"])
        provider.rename(personal, to: "Personal")
        provider.rename(work, to: "Work")
        #expect(try await personal.refresh().quotas.first?.percentRemaining == 80)
        #expect(try await work.refresh().quotas.first?.percentRemaining == 25)
        #expect(provider.activeKind == "cli")
        #expect(provider.dataSourceKind(for: work) == "api")
        #expect(work.dashboardURL?.host == "www.kimi.ai")
        #expect(settings.accounts(forProvider: "kimi").allSatisfy { $0.probeConfig["apiKey"] == nil && $0.probeConfig["home"] == nil })
        let relaunched = try make(settings: settings, vault: vault)
        #expect(relaunched.accounts[2].label == "Work")
        #expect(try await relaunched.accounts[2].refresh().quotas.first?.percentRemaining == 25)
        vault.secrets["\(work.id).apiKey"] = nil
        await #expect(throws: (any Error).self) { try await work.refresh() }
        #expect(work.lastFailedStep == .lookup)
        provider.remove(personal)
        #expect(vault.secrets["\(personal.id).apiKey"] == nil)
    }
    @Test func `CLI accounts isolate both generations of the vendor data folder`() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let definition = try Providers.builtIn("kimi")
        let sources = try definition.dataSources(forAccount: ["source":"cli", "home":folder.path, "region":"china"])
        #expect(sources.map(\.kind) == ["cli"])
        guard case .cli(let call) = sources[0].fetch else { Issue.record("Expected CLI"); return }
        #expect(call.environment.set["KIMI_SHARE_DIR"] == folder.path)
        #expect(call.environment.set["KIMI_CODE_HOME"] == folder.path)
        #expect(call.environment.unset.contains("KIMI_API_KEY"))
        #expect(call.inputDelay == 1.5)
        let provider = try make(settings: InMemoryProviderSettings(), vault: MemoryVault())
        let account = try provider.addAccount(filling: ["source":"cli", "home":folder.path])
        provider.remove(account)
        #expect(FileManager.default.fileExists(atPath: folder.path))
        #expect(throws: UsageError.self) { try provider.addAccount(filling: ["source":"cli", "home":"relative"]) }
        #expect(throws: UsageError.self) { try provider.addAccount(filling: ["source":"cli", "home":folder.appendingPathComponent("missing").path]) }
        #expect(throws: UsageError.self) { try provider.addAccount(filling: ["source":"cli", "home":DataSources.expandPath("${KIMI_SHARE_DIR:-~/.kimi}")]) }
    }
    @Test func `an account source retains all reachable fallbacks even when branches revisit a source`() throws {
        let json = #"{"profile":{"id":"flow","name":"Flow"},"defaultDataSource":"first","accounts":{"dataSourceField":"source"},"dataSources":[{"kind":"first","fallback":{"to":"second"},"fallbackOn":{"authenticationRequired":"third"},"fetch":{"file":{"path":"/tmp/first"}},"mapping":{"json":{"quotas":[]}}},{"kind":"second","fallback":{"to":"first"},"fetch":{"file":{"path":"/tmp/second"}},"mapping":{"json":{"quotas":[]}}},{"kind":"third","fallback":{"to":"second"},"fetch":{"file":{"path":"/tmp/third"}},"mapping":{"json":{"quotas":[]}}}]}"#
        // Decode without validation: this deliberately exercises cyclic input.
        let definition = try JSONDecoder().decode(ProviderDefinition.self,from:Data(json.utf8))
        #expect(try definition.dataSources(forAccount:["source":"first"]).map(\.kind) == ["first","second","third"])
    }

}
private struct EmptyCookies: BrowserCookieReading { func stores(domains: [String], names: [String]) -> [[BrowserCookie]] { [] } }

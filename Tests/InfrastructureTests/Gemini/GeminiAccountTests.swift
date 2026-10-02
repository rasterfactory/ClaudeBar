import DataSources
import Domain
import Foundation
import Infrastructure
import Mockable
import Providers
import Testing

@MainActor @Suite struct GeminiAccountTests {
    private func write(_ token:String,root:URL) throws {
        try FileManager.default.createDirectory(at:root.appendingPathComponent(".gemini"),withIntermediateDirectories:true)
        let data=try JSONSerialization.data(withJSONObject:["access_token":token,"ownerMetadata":"keep"])
        try data.write(to:root.appendingPathComponent(".gemini/oauth_creds.json"))
    }
    @Test func `personal and work logins retain separate files labels quotas and state across relaunch`() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let work=root.appendingPathComponent("work"),other=root.appendingPathComponent("other")
        try write("personal-token",root:root); try write("work-token",root:work); try write("other-token",root:other)
        let suite="Gemini.Accounts.\(UUID())",store=UserDefaults(suiteName:suite)!
        defer { store.removePersistentDomain(forName:suite) }
        let settings=JSONSettingsRepository(store:JSONSettingsStore(fileURL:root.appendingPathComponent("settings.json")),credentials:store)
        let network=MockNetworkClient()
        given(network).request(.any).willProduce { @Sendable request in
            let bearer=request.value(forHTTPHeaderField:"Authorization")
            #expect(["Bearer personal-token","Bearer work-token","Bearer other-token"].contains(bearer))
            let fraction=bearer == "Bearer work-token" ? 0.2 : bearer == "Bearer other-token" ? 0.6 : 0.9
            let text=request.url!.absoluteString.contains("loadCodeAssist") ? #"{"cloudaicompanionProject":"personal-project"}"# : "{\"buckets\":[{\"modelId\":\"gemini-pro\",\"remainingFraction\":\(fraction)}]}"
            return (Data(text.utf8),HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:nil)!)
        }
        let definition=try Providers.builtIn("gemini")
        let factory: @MainActor () -> Provider = {
            Provider(definition:definition,settings:settings,accounts:settings.accounts(forProvider:"gemini"),makeDataSource:{source,_ in
                DataSources.make(source,providerId:"gemini",cliExecutor:MockCLIExecutor(),network:network,makeTransport:{_,_,_,_ in MockRPCTransport()},scripts:Providers.builtInScripts,environment:{_ in nil},homeDirectory:root,now:{Date()},sleep:{_ in})
            })
        }
        let provider=factory()
        #expect(provider.defaultAccount.displayName == "Gemini")
        #expect(provider.definition.defaultDataSource == "api")
        #expect(try await provider.defaultAccount.refresh().quotas[0].percentRemaining == 90)
        let workAccount=try provider.addAccount(filling:["home":work.path])
        let otherAccount=try provider.addAccount(filling:["home":other.path])
        provider.rename(workAccount,to:"Work");provider.rename(otherAccount,to:"Personal")
        #expect(try await workAccount.refresh().quotas[0].percentRemaining == 20)
        #expect(try await otherAccount.refresh().quotas[0].percentRemaining == 60)
        let restored=factory(),restoredWork=try #require(restored.accounts.first{$0.id == workAccount.id})
        #expect(restoredWork.displayName == "Work")
        #expect(try await restoredWork.refresh().quotas[0].percentRemaining == 20)
        try FileManager.default.removeItem(at:work.appendingPathComponent(".gemini/oauth_creds.json"))
        await #expect(throws:UsageError.authenticationRequired) { try await restoredWork.refresh() }
        restored.remove(restoredWork)
        #expect(FileManager.default.fileExists(atPath:other.appendingPathComponent(".gemini/oauth_creds.json").path))
        #expect(try await restored.defaultAccount.refresh().quotas[0].percentRemaining == 90)
        #expect(settings.accounts(forProvider:"gemini").count == 1)
    }
    @Test func `default OAuth refresh uses the home containing the same credential file`() throws {
        let definition=try Providers.builtIn("gemini")
        guard case .refreshingWithCLI(_,let refresh)?=definition.dataSource("api")?.credential else{Issue.record("Missing refresh");return}
        #expect(refresh.call.environment.unset.contains("GEMINI_CLI_HOME"))
        #expect(refresh.call.environment.unset.contains("GEMINI_API_KEY"))
        #expect(refresh.call.environment.unset.contains("GOOGLE_GENAI_USE_VERTEXAI"))
    }
    @Test func `named API refresh and CLI quota use the same isolated home and configured binary`() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let definition=try Providers.builtIn("gemini").runningCLI("/fake/custom-gemini")
        let source=try definition.dataSource("api")!.patched(with:definition.accounts!.patch["api"]!)
        // Fill exactly the definition patch used when an account is added.
        let data=String(decoding:try JSONEncoder().encode(source),as:UTF8.self).replacingOccurrences(of:"{{account.home}}",with:root.path)
        let filled=try JSONDecoder().decode(DataSourceDefinition.self,from:Data(data.utf8))
        guard case .refreshingWithCLI(_,let refresh)?=filled.credential else { Issue.record("Missing refresh");return }
        #expect(refresh.call.cli == "/fake/custom-gemini")
        #expect(refresh.call.environment.set["GEMINI_CLI_HOME"] == root.path)
        #expect(refresh.call.environment.unset.contains("GEMINI_API_KEY"))
        #expect(filled.requiresFiles == [root.path+"/.gemini/oauth_creds.json"])
        #expect(filled.verifyBeforeBackground)
        #expect(definition.commands.contains("/fake/custom-gemini"))
    }
}

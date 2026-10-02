import DataSources
import Domain
import Foundation
import Infrastructure
import Mockable
import Providers
import Testing

@MainActor @Suite struct AntigravityAccountTests {
    @Test func `named accounts cannot inherit the desktop process or default Keychain token`() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let suite="Antigravity.Accounts.\(UUID())",store=UserDefaults(suiteName:suite)!
        defer { store.removePersistentDomain(forName:suite) }
        let credentials=UserDefaultsCredentialRepository(defaults:store)
        let settings=JSONSettingsRepository(store:JSONSettingsStore(fileURL:root.appendingPathComponent("settings.json")),credentials:store,secureCredentials:credentials)
        let vault=ProviderVault(credentials:credentials,legacyStore:store),cli=MockCLIExecutor(),local=MockNetworkClient(),remote=MockNetworkClient()
        given(cli).execute(binary:.any,args:.any,input:.any,timeout:.any,workingDirectory:.any,autoResponses:.any).willProduce { @Sendable binary,_,_,_,_,_ in
            if binary.hasSuffix("pgrep") { return CLIResult(output:"42 /antigravity/language_server --csrf_token desktop-only --extension_server_port 9999") }
            if binary.hasSuffix("lsof") { return CLIResult(output:"server 42 TCP 127.0.0.1:9999 (LISTEN)") }
            Issue.record("Running desktop account must not read Keychain");return CLIResult(output:"",exitCode:44)
        }
        given(local).request(.any).willProduce { @Sendable request in
            #expect(request.url?.host == "127.0.0.1")
            #expect(request.value(forHTTPHeaderField:"X-Codeium-Csrf-Token") == "desktop-only")
            return (Data(#"{"groups":[{"buckets":[{"bucketId":"gemini-5h","remainingFraction":0.9}]}]}"#.utf8),HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:nil)!)
        }
        given(remote).request(.any).willProduce { @Sendable request in
            let token=request.value(forHTTPHeaderField:"Authorization")
            #expect(["Bearer work-token","Bearer other-token"].contains(token))
            #expect(request.url?.host == "daily-cloudcode-pa.googleapis.com")
            let fraction=token == "Bearer work-token" ? 0.2 : 0.6
            let body=request.url!.absoluteString.contains("loadCodeAssist") ? #"{"paidTier":{"name":"Pro"}}"# : "{\"groups\":[{\"buckets\":[{\"bucketId\":\"gemini-5h\",\"remainingFraction\":\(fraction)}]}]}"
            return (Data(body.utf8),HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:nil)!)
        }
        let definition=try Providers.builtIn("antigravity")
        let factory: @MainActor () -> Provider = {
            Provider(definition:definition,settings:settings,accounts:settings.accounts(forProvider:"antigravity"),makeDataSource:{source,login in
                DataSources.make(source,providerId:"antigravity",cliExecutor:cli,network:remote,loopbackNetwork:local,makeTransport:{_,_,_,_ in MockRPCTransport()},scripts:Providers.builtInScripts,secrets:vault.scoped(to:login),environment:{_ in nil},homeDirectory:root,now:{Date()})
            },vault:vault)
        }
        let provider=factory()
        #expect(provider.defaultAccount.name == "Antigravity")
        #expect(provider.defaultAccount.cliCommand == "antigravity")
        #expect(provider.defaultAccount.dashboardURL == nil)
        #expect(try await provider.defaultAccount.refresh().quotas[0].percentRemaining == 90)
        let work=try provider.addAccount(filling:["apiKey":"work-token"]),other=try provider.addAccount(filling:["apiKey":"other-token"])
        provider.rename(work,to:"Work");provider.rename(other,to:"Personal")
        #expect(try await work.refresh().quotas[0].percentRemaining == 20)
        #expect(try await other.refresh().quotas[0].percentRemaining == 60)
        #expect(work.snapshot?.accountTier == .custom("PRO"))
        #expect(settings.accounts(forProvider:"antigravity").allSatisfy { $0.probeConfig["apiKey"] == nil })
        let restored=factory(),restoredWork=try #require(restored.accounts.first{$0.id == work.id})
        #expect(restoredWork.displayName == "Work")
        #expect(try await restoredWork.refresh().quotas[0].percentRemaining == 20)
        vault.delete("apiKey",provider:work.id)
        await #expect(throws:UsageError.authenticationRequired) { try await restoredWork.refresh() }
        restored.remove(restoredWork)
        #expect(vault.secret("apiKey",provider:other.id) == "other-token")
        #expect(try await restored.defaultAccount.refresh().quotas[0].percentRemaining == 90)
        restored.remove(restored.accounts.first{$0.id == other.id}!)
        #expect(vault.secret("apiKey",provider:other.id) == nil)
    }
}

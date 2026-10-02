import Foundation
import Mockable
import Providers
import Quotas
import Testing
@testable import DataSources

@MainActor @Suite struct OmpAccountTests {
    @Test func `agent profiles stay isolated and missing profiles do not fall back`() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:home,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:home) }
        let path=home.path
        let definition=try Providers.builtIn("omp")
        let personal=MockCLIExecutor(), work=MockCLIExecutor()
        given(personal).locate(.any).willReturn("/usr/local/bin/omp")
        given(work).locate(.any).willReturn("/usr/local/bin/omp")
        given(personal).execute(binary:.any,args:.any,input:.any,timeout:.any,workingDirectory:.any,autoResponses:.any)
            .willReturn(CLIResult(output:#"{"reports":[{"provider":"anthropic","limits":[{"scope":{"windowId":"5h"},"amount":{"remainingFraction":0.8}}]}]}"#))
        given(work).execute(binary:.any,args:.any,input:.any,timeout:.any,workingDirectory:.any,autoResponses:.any)
            .willProduce { @Sendable _, args, input, timeout, directory, _ in
                #expect(args == ["usage","--json"] && input == nil && timeout == 30)
                #expect(directory?.path == path)
                return CLIResult(output:#"{"reports":[{"provider":"anthropic","limits":[{"scope":{"windowId":"5h"},"amount":{"remainingFraction":0.2}}]}]}"#)
            }
        let provider=Provider(definition:definition,settings:InMemoryProviderSettings(),makeDataSource:{ source,_ in
            DataSources.make(source,providerId:"omp",makeCLIExecutor:{ @Sendable call in
                if let directory=call.environment.set["PI_CODING_AGENT_DIR"] {
                    #expect(directory == path && call.environment.set["HOME"] == path)
                    #expect(call.environment.set["OMP_PROFILE"] == "default" && call.environment.set["PI_PROFILE"] == "default")
                    #expect(call.environment.unset.contains("XDG_DATA_HOME") && call.environment.unset.contains("GITHUB_TOKEN"))
                    #expect(call.environment.unset.contains("OMP_AUTH_BROKER_URL"))
                    return work
                }
                return personal
            },network:MockNetworkClient(),makeTransport:{_,_,_,_ in MockRPCTransport()},security:{_ in (1,"")},scripts:Providers.builtInScripts,secrets:nil,environment:{_ in nil},homeDirectory:FileManager.default.temporaryDirectory,now:{ Date() })
        })
        let added=try provider.addAccount(filling:["directory":path])
        #expect(try await added.refresh().quotas.first?.percentRemaining == 20)
        #expect(try await provider.defaultAccount.refresh().quotas.first?.percentRemaining == 80)
        #expect(provider.backgroundRefreshFloor == .seconds(300))
        try FileManager.default.removeItem(at:home)
        await #expect(throws:UsageError.authenticationRequired) { try await added.refresh() }
        #expect(try await provider.defaultAccount.refresh().quotas.first?.percentRemaining == 80)
    }
}

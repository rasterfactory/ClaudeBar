import DataSources
import Foundation
import Mockable
import Providers
import Quotas
import Testing

@Suite @MainActor
struct OpenCodeDefinitionTests {
    static let usage = #"{"usage":{"rolling":{"status":"ok","percent":1,"resetsAt":"2026-08-24T15:34:00.000Z"},"weekly":{"status":"ok","percent":17,"resetsAt":"2026-08-29T00:00:00Z"},"monthly":{"status":"rate-limited","percent":98}}}"#
    static let now = Date(timeIntervalSince1970: 1775044800) // Apr 1, 2026 12:00 UTC
    private func make(body: String = usage, status: Int = 200, key: String? = "personal", local: String = #"[{"five_hour_cost":2.5,"weekly_cost":7.5,"five_hour_oldest_ms":1710000000000,"anchor_ms":1700000000000}]"#, exit: Int32 = 0, monthly: String = #"[{"monthly_cost":15}]"#, clock: Date = now, home: URL = FileManager.default.temporaryDirectory, env: [String:String]? = nil, available: Bool = true, vault: MemoryVault = MemoryVault()) throws -> Provider {
        let now = clock
        let def = try Providers.builtIn("opencode-go")
        let net = MockNetworkClient()
        given(net).request(.any).willProduce { @Sendable request in
            #expect(request.url?.absoluteString == "https://opencode.ai/zen/go/v1/usage")
            #expect(request.timeoutInterval == 15)
            #expect(["Bearer personal", "Bearer work", "Bearer file-key"].contains(request.value(forHTTPHeaderField:"Authorization") ?? ""))
            return (Data(body.utf8), HTTPURLResponse(url:request.url!,statusCode:status,httpVersion:nil,headerFields:nil)!)
        }
        let cli = MockCLIExecutor()
        given(cli).locate(.any).willReturn(available ? "/test/opencode" : nil)
        given(cli).execute(binary:.any,args:.any,input:.any,timeout:.any,workingDirectory:.any,autoResponses:.any).willProduce { @Sendable binary,args,_,timeout,_,_ in
            #expect(binary == "/test/opencode")
            #expect(timeout == 15)
            #expect(args.first == "db")
            #expect(args.suffix(2) == ["--format","json"])
            let sql = args[1]
            #expect(sql.contains("json_valid(data)"))
            #expect(sql.contains("'opencode-go'"))
            #expect(sql.contains("'assistant'"))
            return CLIResult(output: sql.contains("AS monthly_cost") ? monthly : local,exitCode:exit)
        }
        return Provider(definition:def,settings:InMemoryProviderSettings(),makeDataSource:{source,login in
            DataSources.make(source,providerId:def.id,cliExecutor:cli,network:net,makeTransport:{_,_,_,_ in MockRPCTransport()},scripts:Providers.builtInScripts,secrets:vault.scoped(to:login),environment:{ name in env.map { $0[name] } ?? (name == "OPENCODE_API_KEY" ? key : nil) },homeDirectory:home,now:{now})
        },vault:vault)
    }
    @Test func `server fixture retains quotas resets and durations`() async throws {
        let p = try make()
        #expect(p.name == "OpenCode Go")
        #expect(p.defaultAccount.isEnabled)
        let qs = try await p.defaultAccount.refresh().quotas
        #expect(qs.map(\.percentRemaining) == [99,83,0])
        #expect(qs.map(\.quotaType) == [.session,.weekly,.timeLimit("Monthly")])
        #expect(qs[0].resetsAt == Date(timeIntervalSince1970:1787585640))
        #expect(qs[0].window?.length == 18000)
        #expect(qs[1].window?.length == 604800)
        #expect(qs[2].window?.length == nil)
    }
    @Test(arguments:[("rolling","\"12.5\"",87.5),("weekly","130",0.0),("monthly","-4",100.0)])
    func `partial numeric and string windows are clamped`(_ fixture:(String,String,Double)) async throws {
        let qs = try await make(body:"{\"usage\":{\"\(fixture.0)\":{\"percent\":\(fixture.1)}}}").defaultAccount.refresh().quotas
        #expect(qs.count == 1)
        #expect(qs[0].percentRemaining == fixture.2)
    }
    @Test(arguments:["<html>","{}",#"{"usage":{}}"#])
    func `malformed or empty API responses remain failures`(_ body:String) async throws {
        await #expect(throws:UsageError.self) { try await make(body:body).defaultAccount.refresh() }
    }
    @Test func `401 does not fall back to the local account`() async throws {
        await #expect(throws:UsageError.sessionExpired(hint:"Run `opencode auth login` and pick OpenCode Zen to refresh your API key.")) { try await make(status:401).defaultAccount.refresh() }
    }
    @Test func `403 preserves subscription required`() async throws {
        await #expect(throws:UsageError.subscriptionRequired) { try await make(status:403).defaultAccount.refresh() }
    }
    @Test(arguments:[429,500]) func `other HTTP errors do not fall back`(_ status:Int) async throws {
        await #expect(throws:UsageError.executionFailed("HTTP error: \(status)")) { try await make(status:status).defaultAccount.refresh() }
    }
    @Test func `missing default key preserves local DB fallback`() async throws {
        let p = try make(key:nil)
        #expect(await p.defaultAccount.isAvailable())
        let qs = try await p.defaultAccount.refresh().quotas
        #expect(qs.count == 3)
        #expect(abs(qs[0].percentRemaining - (1-2.5/12)*100) < 0.00001)
        #expect(qs[1].percentRemaining == 75)
        #expect(qs[2].percentRemaining == 75)
        #expect(qs[0].resetsAt == Date(timeIntervalSince1970:1710018000))
        #expect(qs[1].resetsAt == Date(timeIntervalSince1970:1775433600))
    }
    @Test func `no local usage skips monthly query and reports full windows`() async throws {
        let qs = try await make(key:nil,local:#"[{"five_hour_cost":0,"weekly_cost":0,"five_hour_oldest_ms":null,"anchor_ms":null}]"#).defaultAccount.refresh().quotas
        #expect(qs.map(\.percentRemaining) == [100,100,100])
        #expect(qs[0].resetsAt == Self.now.addingTimeInterval(18000))
        #expect(qs[2].resetsAt == Self.now.addingTimeInterval(30*86400))
    }
    @Test(arguments:["not JSON","[]",#"[{}]"#]) func `malformed local primary results fail`(_ local:String) async throws {
        await #expect(throws:UsageError.self) { try await make(key:nil,local:local).defaultAccount.refresh() }
    }
    @Test func `nonzero DB exit is never healthy usage`() async throws {
        await #expect(throws:UsageError.executionFailed("opencode db exited with code 1")) { try await make(key:nil,exit:1).defaultAccount.refresh() }
    }
    @Test func `added key account never falls back to the default local database`() async throws {
        let vault = MemoryVault()
        let p = try make(vault:vault)
        let work = try p.addAccount(filling:["apiKey":"work"])
        #expect(p.dataSources(for:work).map(\.kind) == ["api"])
        #expect(try await work.refresh().quotas.map(\.percentRemaining) == [99,83,0])
        vault.secrets["\(work.id).apiKey"] = nil
        await #expect(throws:UsageError.authenticationRequired) { try await work.refresh() }
    }
    @Test(arguments:[-5.0,6.0,20.0]) func `local quotas clamp remaining costs`(_ cost:Double) async throws {
        let body = "[{\"five_hour_cost\":\(cost),\"weekly_cost\":0,\"anchor_ms\":null}]"
        let qs = try await make(key:nil,local:body).defaultAccount.refresh().quotas
        #expect(abs(qs[0].percentRemaining-max(0,min(100,(12-cost)/12*100))) < 0.00001)
    }
    @Test func `original monthly cost fixture preserves its percentage`() async throws {
        let qs = try await make(key:nil,monthly:#"[{"monthly_cost":42.5}]"#).defaultAccount.refresh().quotas
        #expect(abs(qs[2].percentRemaining-(60-42.5)/60*100) < 0.00001)
    }
    @Test func `empty monthly rows preserve zero cost`() async throws {
        let qs = try await make(key:nil,monthly:"[]").defaultAccount.refresh().quotas
        #expect(qs[2].percentRemaining == 100)
    }
    @Test(arguments:["bad",#"[{}]"#]) func `invalid monthly output remains a failure`(_ body:String) async throws {
        await #expect(throws:UsageError.self) { try await make(key:nil,monthly:body).defaultAccount.refresh() }
    }
    @Test func `missing key and CLI remain unavailable`() async throws {
        let p = try make(key:nil,available:false)
        #expect(!(await p.defaultAccount.isAvailable()))
        await #expect(throws:UsageError.cliNotFound("opencode")) { try await p.defaultAccount.refresh() }
    }
    @Test(arguments:[("2024-03-14T14:30:00Z","2024-04-02T10:00:00Z","2024-04-14T14:30:00Z"),
        ("2024-01-20T09:00:00Z","2024-04-05T12:00:00Z","2024-04-20T09:00:00Z"),
        ("2024-01-31T09:00:00Z","2024-02-05T12:00:00Z","2024-03-02T09:00:00Z")])
    func `anchored monthly windows preserve legacy Calendar boundaries`(_ fixture:(String,String,String)) async throws {
        let formatter = ISO8601DateFormatter()
        let anchor = try #require(formatter.date(from:fixture.0))
        let now = try #require(formatter.date(from:fixture.1))
        let expected = try #require(formatter.date(from:fixture.2))
        let body = "[{\"five_hour_cost\":0,\"weekly_cost\":0,\"anchor_ms\":\(Int64(anchor.timeIntervalSince1970*1000))}]"
        let qs = try await make(key:nil,local:body,clock:now).defaultAccount.refresh().quotas
        #expect(qs[2].resetsAt == expected)
    }
    @Test(arguments:["opencode-go","opencode","both"])
    func `both legacy auth file entries remain readable in XDG data home`(_ entry:String) async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:home) }
        let data = home.appendingPathComponent("data/opencode")
        try FileManager.default.createDirectory(at:data,withIntermediateDirectories:true)
        let auth = entry == "both" ? #"{"opencode-go":{"key":"file-key"},"opencode":{"key":"other-key"}}"# : "{\"\(entry)\":{\"type\":\"api\",\"key\":\"file-key\"}}"
        try Data(auth.utf8).write(to:data.appendingPathComponent("auth.json"))
        let p = try make(key:nil,home:home,env:["XDG_DATA_HOME":home.appendingPathComponent("data").path])
        #expect(try await p.defaultAccount.refresh().quotas.map(\.percentRemaining) == [99,83,0])
    }

}

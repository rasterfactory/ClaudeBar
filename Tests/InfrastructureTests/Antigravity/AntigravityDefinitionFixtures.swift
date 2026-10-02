import DataSources
import Domain
import Foundation
import JavaScriptCore
import Providers
import Testing

/// All quota fixtures run the bundled definition's actual shared mapper.
enum AntigravityDefinitionFixtures {
    static func scriptValue(_ function:String,_ arguments:[Any]) -> Any? {
        do {
            _ = try Providers.builtIn("antigravity")
            guard let source=Providers.builtInScripts("antigravity.js"),let context=JSContext() else { throw DefinitionError.missingFile("antigravity.js") }
            var failed=false
            context.exceptionHandler={_,_ in failed=true}
            let data=try JSONSerialization.data(withJSONObject:arguments)
            context.setObject(String(decoding:data,as:UTF8.self),forKeyedSubscript:"__arguments" as NSString)
            context.evaluateScript(source)
            let value=context.evaluateScript("JSON.stringify(\(function).apply(null,JSON.parse(__arguments)))")?.toString()
            guard !failed,let value else { Issue.record("Script helper failed");return nil }
            return try JSONSerialization.jsonObject(with:Data(value.utf8),options:[.fragmentsAllowed])
        } catch { Issue.record(error);return nil }
    }
    static func extractCSRFToken(from text:String) -> String? { scriptValue("flag",[text,"--csrf_token"]) as? String }
    static func extractExtensionPort(from text:String) -> Int? { (scriptValue("flag",[text,"--extension_server_port"]) as? String).flatMap(Int.init) }
    static func extractPID(from text:String) -> Int? { (scriptValue("pid",[text]) as? NSNumber)?.intValue }
    static func isAntigravityProcess(_ text:String) -> Bool { scriptValue("isProcess",[text]) as? Bool ?? false }
    static func parseListeningPorts(from text:String) -> [Int] { (scriptValue("ports",[text]) as? [NSNumber])?.map(\.intValue) ?? [] }
    static func credential(raw:String) -> AntigravityFixtureCredentials? { AntigravityFixtureCredentials.from(scriptValue("credentials",[raw])) }
    static func read(_ data: Data, format: String, providerId: String) throws -> UsageSnapshot {
        let definition=try Providers.builtIn("antigravity")
        let source=DataSources.make(definition.dataSource("auto")!,providerId:providerId,scripts:Providers.builtInScripts)
        let object:[String:Any]=["format":format,"payloadText":String(decoding:data,as:UTF8.self)]
        do { return try source.read(Response(body:try JSONSerialization.data(withJSONObject:object))) }
        catch let error as DataSourceError { throw error.reason }
    }
    static func parseUserStatusResponse(_ data:Data,providerId:String) throws -> UsageSnapshot { try read(data,format:"userStatus",providerId:providerId) }
    static func parseCommandModelResponse(_ data:Data,providerId:String) throws -> UsageSnapshot { try read(data,format:"command",providerId:providerId) }
    static func summary(_ data:Data,providerId:String) -> [UsageQuota]? {
        do { return try read(data,format:"summary",providerId:providerId).quotas }
        catch let error as DefinitionError { Issue.record(error);return nil }
        catch { return nil }
    }
}

struct AntigravityDefinitionProbe {
    let cliExecutor: any CLIExecutor
    let networkClient: any NetworkClient
    let remoteNetworkClient: any NetworkClient
    let timeout: TimeInterval
    let now: @Sendable () -> Date
    init(cliExecutor: (any CLIExecutor)? = nil, networkClient: (any NetworkClient)? = nil,
         remoteNetworkClient: (any NetworkClient)? = nil, timeout: TimeInterval = 8,
         now: @escaping @Sendable () -> Date = Date.init) {
        self.cliExecutor=cliExecutor ?? DefaultCLIExecutor()
        self.networkClient=networkClient ?? InsecureLocalhostNetworkClient(timeout:timeout)
        self.remoteNetworkClient=remoteNetworkClient ?? URLSession.shared
        self.timeout=timeout;self.now=now
    }
    func source() throws -> DataSource {
        let definition=try Providers.builtIn("antigravity")
        let source=try definition.dataSource("auto")!.patched(with:.object(["fetch":.object(["workflow":.object([
            "commands":.object(["process":.object(["timeout":.number(timeout)]),"ports":.object(["timeout":.number(timeout)]),"keychain":.object(["timeout":.number(timeout)])]),
            "requests":.object(["local":.object(["timeout":.number(timeout)])])
        ])])]))
        return DataSources.make(source,providerId:"antigravity",cliExecutor:cliExecutor,network:remoteNetworkClient,loopbackNetwork:networkClient,
            makeTransport:{_,_,_,_ in fatalError("Unexpected RPC")},scripts:Providers.builtInScripts,environment:{_ in nil},homeDirectory:FileManager.default.temporaryDirectory,now:now)
    }
    func probe() async throws -> UsageSnapshot {
        do { return try await source().fetchUsage() } catch let error as DataSourceError { throw error.reason }
    }
    func isAvailable() async -> Bool { (try? await source().isReady()) ?? false }
}
struct AntigravityFixtureCredentials {
    let accessToken:String?
    let refreshToken:String?
    let expiresAt:Date?
    func hasUsableAccessToken(at now:Date) -> Bool {
        let json:[String:Any]=["accessToken":accessToken.map{$0 as Any} ?? NSNull(),"refreshToken":refreshToken.map{$0 as Any} ?? NSNull(),"expiresAt":expiresAt.map{$0.timeIntervalSince1970 as Any} ?? NSNull()]
        return AntigravityDefinitionFixtures.scriptValue("usable",[json,now.timeIntervalSince1970]) as? Bool ?? false
    }
    static func from(_ value:Any?) -> Self? {
        guard let object=value as? [String:Any] else { return nil }
        return Self(accessToken:object["accessToken"] as? String,refreshToken:object["refreshToken"] as? String,
            expiresAt:(object["expiresAt"] as? NSNumber).map{Date(timeIntervalSince1970:$0.doubleValue)})
    }
}
struct AntigravityDefinitionCredentialLoader {
    let cliExecutor:any CLIExecutor
    init(cliExecutor:any CLIExecutor) { self.cliExecutor=cliExecutor }
    func load() async -> AntigravityFixtureCredentials? {
        do {
            let definition=try Providers.builtIn("antigravity")
            let source=try definition.dataSource("auto")!.patched(with:.object(["fetch":.object(["workflow":.object(["script":.string("credential-fixture.js")])])]))
            let script=Providers.builtInScripts("antigravity.js")!+"\nfunction next(r){if(!r.keychain)return {command:'keychain'};return {result:r.keychain.exitCode===0?credentials(r.keychain.text):null};}"
            let live=DataSources.make(source,providerId:"antigravity",cliExecutor:cliExecutor,network:URLSession.shared,makeTransport:{_,_,_,_ in fatalError("Unexpected RPC")},scripts:{_ in script},environment:{_ in nil},homeDirectory:FileManager.default.temporaryDirectory,now:{Date()})
            let value=try JSONSerialization.jsonObject(with:await live.fetchResponse().body,options:[.fragmentsAllowed])
            return AntigravityFixtureCredentials.from(value)
        } catch { return nil }
    }
}

final class AntigravityFixtureCounter: @unchecked Sendable {
    private let lock=NSLock();private var count=0
    func increment() -> Int { lock.lock();defer{lock.unlock()};count+=1;return count }
}

final class AntigravityHeaderRecorder: @unchecked Sendable {
    private let lock=NSLock();private var values:[String]=[]
    func add(_ value:String) { lock.lock();defer{lock.unlock()};values.append(value) }
    func read() -> [String] { lock.lock();defer{lock.unlock()};return values }
}

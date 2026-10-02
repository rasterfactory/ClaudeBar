@testable import Infrastructure
import DataSources
import Domain
import Foundation
import Providers

enum GeminiDefinitionFixtures {
    static func cli(_ text: String) throws -> UsageSnapshot {
        let definition = try Providers.builtIn("gemini")
        let source = DataSources.make(definition.dataSource("cli")!, providerId: "gemini", scripts: Providers.builtInScripts)
        do { return try source.read(Response(text: text)) }
        catch let error as DataSourceError { throw error.reason }
    }
}

/// Test adapter: every operation delegates to the bundled JSON and shared engine.
struct GeminiDefinitionProbe {
    let kind: String
    let homeDirectory: String
    let timeout: TimeInterval
    let networkClient: any NetworkClient
    let maxRetries: Int
    let cliExecutor: any CLIExecutor
    let clock: any Clock
    init(homeDirectory: String = NSHomeDirectory(), timeout: TimeInterval, networkClient: any NetworkClient = URLSession.shared,
         maxRetries: Int = 3, cliExecutor: any CLIExecutor = DefaultCLIExecutor(), clock: any Clock = SystemClock(), kind: String = "api") {
        self.homeDirectory = homeDirectory; self.timeout = timeout; self.networkClient = networkClient
        self.maxRetries = maxRetries; self.cliExecutor = cliExecutor; self.clock = clock; self.kind = kind
    }
    func source() throws -> DataSource {
        let definition = try Providers.builtIn("gemini")
        let fetch: JSONValue = kind == "api" ? .object(["httpFlow": .object([
            "requests": .object(["project": .object(["timeout": .number(timeout)]), "quota": .object(["timeout": .number(timeout)])]),
            "constants": .object(["projectAttempts": .number(Double(maxRetries))])
        ])]) : .object(["cli": .object(["timeout": .number(timeout)])])
        let source = try definition.dataSource(kind)!.patched(with: .object(["fetch": fetch]))
        return DataSources.make(source, providerId: "gemini", cliExecutor: cliExecutor, network: networkClient,
            makeTransport: { _,_,_,_ in fatalError("Unexpected RPC") }, scripts: Providers.builtInScripts,
            environment: { _ in nil }, homeDirectory: URL(fileURLWithPath: homeDirectory), now: { Date() },
            sleep: { try await clock.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) })
    }
    func probe() async throws -> UsageSnapshot {
        do { return try await source().fetchUsage() }
        catch let error as DataSourceError { throw error.reason }
    }
}

final class GeminiCallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
}

import Foundation
import Testing
import Domain
import Providers
@testable import Infrastructure

@Suite("Independent legacy CLI account connections")
@MainActor
struct LegacyCLIAccountConnectionTests {
    nonisolated static let ids = ["ampcode", "kiro", "omp"]

    @Test(arguments: ids)
    func eachReaderUsesItsSelectedHomeAndRetainsUpstreamGroups(_ id: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("personal")
        let b = root.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        let authPath: String = switch id {
        case "ampcode": ".local/share/amp/secrets.json"
        case "kiro": "Library/Application Support/kiro-cli/data.sqlite3"
        default: ".omp/agent/agent.db"
        }
        for home in [a, b] {
            let file = home.appendingPathComponent(authPath)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("fixture".utf8).write(to: file)
        }
        try Data(output(id, work: false).utf8).write(to: a.appendingPathComponent("usage-fixture.txt"))
        try Data(output(id, work: true).utf8).write(to: b.appendingPathComponent("usage-fixture.txt"))
        let connections = LegacyAccountConnections(makeCLI: { FixtureScopedCLI(context: $0) }, settingsRoot: root.appendingPathComponent("settings"))
        let personal = ProviderAccountConfig(accountId: "personal", label: "Personal", probeConfig: ["source": a.path])
        let work = ProviderAccountConfig(accountId: "work", label: "Work", probeConfig: ["source": b.path])
        let p = try connections.source(providerId: id, config: personal)
        let w = try connections.source(providerId: id, config: work)
        let personalUsage = try await p.refresh(.interactive)
        let workUsage = try await w.refresh(.interactive)
        #expect(personalUsage.lowestQuota?.percentRemaining != workUsage.lowestQuota?.percentRemaining)
        if id == "omp" {
            #expect(personalUsage.quotas.count == 7)
            #expect(workUsage.quotas.count == 7)
            #expect(personalUsage.hasQuotaGroups)
            #expect(workUsage.hasQuotaGroups)
        }
        try FileManager.default.removeItem(at: b.appendingPathComponent("usage-fixture.txt"))
        await #expect(throws: (any Error).self) { try await w.refresh(.interactive) }
        #expect(try await p.refresh(.interactive).lowestQuota?.percentRemaining == personalUsage.lowestQuota?.percentRemaining)
    }

    private func output(_ id: String, work: Bool) -> String {
        switch id {
        case "ampcode": "Signed in as \(work ? "work" : "personal")@example.com (fixture)\nAmp Free: $\(work ? "6" : "16")/$20 remaining\n"
        case "kiro": "Credits (\(work ? "35" : "10").0 of 50 covered in plan)\nresets on 03/15\n"
        default: OmpUsageProbeParsingTests.sampleResponse.replacingOccurrences(of: "0.92", with: work ? "0.32" : "0.92").replacingOccurrences(of: "0.2", with: work ? "0.1" : "0.2")
        }
    }
}

private struct FixtureScopedCLI: CLIExecutor {
    let context: AccountCommandContext
    func locate(_ binary: String) -> String? { "/fixture/\(binary)" }
    func execute(binary: String, args: [String], input: String?, timeout: TimeInterval, workingDirectory: URL?, autoResponses: [String: String]) async throws -> CLIResult {
        guard context.environment["HOME"] == context.directory.path,
              context.environment["XDG_DATA_HOME"] == context.directory.appendingPathComponent(".local/share").path,
              context.exclusions.contains("AMP_API_KEY"), context.exclusions.contains("KIRO_API_KEY"),
              context.exclusions.contains("OMP_AUTH_BROKER_TOKEN") else { throw UsageError.authenticationRequired }
        let text = try String(contentsOf: context.directory.appendingPathComponent("usage-fixture.txt"), encoding: .utf8)
        return CLIResult(output: text)
    }
}

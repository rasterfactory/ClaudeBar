import Domain
import Foundation
import Providers
import Testing
@testable import Infrastructure

@Suite("Independent file-backed account readers")
@MainActor
struct LegacyFileAccountConnectionTests {
    nonisolated static let ids = ["gemini", "grok", "opencode-go", "commandcode"]
    @Test(arguments: ids)
    func twoHomesReadOwnCredentialsAndMissingFileNeverUsesSibling(_ id: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let personal = try home(root, id: id, name: "personal")
        let work = try home(root, id: id, name: "work")
        let connections = LegacyAccountConnections(networkClient: HomeUsageNetwork(id: id), makeCLI: { _ in UnavailableHomeCLI() }, settingsRoot: root)
        let a = try connections.source(providerId: id, config: personal)
        let b = try connections.source(providerId: id, config: work)
        let first = try await a.refresh(.interactive)
        let second = try await b.refresh(.interactive)
        #expect(first.quotas != second.quotas)
        try FileManager.default.removeItem(at: URL(fileURLWithPath: work.probeConfig["source"]!))
        await #expect(throws: (any Error).self) { try await b.refresh(.interactive) }
        #expect(try await a.refresh(.interactive).quotas == first.quotas)
    }

    @Test
    func separateVibeLogsRetainDailyUsage() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let formatter = DateFormatter(); formatter.dateFormat = "yyyyMMdd_HHmmss"; formatter.timeZone = TimeZone(identifier: "UTC")
        let name = "session_\(formatter.string(from: Date()))_fixture"
        let connections = LegacyAccountConnections(settingsRoot: root)
        var snapshots: [UsageSnapshot] = []
        for (id, tokens) in [("personal", 100), ("work", 500)] {
            let home = root.appendingPathComponent(id)
            let session = home.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
            try Data("{\"stats\":{\"session_total_llm_tokens\":\(tokens),\"session_cost\":0.1}}".utf8).write(to: session.appendingPathComponent("meta.json"))
            let source = try connections.source(providerId: "mistral", config: .init(accountId: id, label: id, probeConfig: ["source": home.path]))
            snapshots.append(try await source.refresh(.interactive))
        }
        #expect(snapshots[0].dailyUsageReport?.today.totalTokens == 100)
        #expect(snapshots[1].dailyUsageReport?.today.totalTokens == 500)
    }

    @Test
    func cursorDatabasesHaveIndependentIdentityAndRejectSwitchedLogin() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func write(_ db: URL, user: String) async throws {
            let payload = Data("{\"sub\":\"\(user)\"}".utf8).base64EncodedString()
            let token = "header.\(payload).signature"
            let output = try await SubprocessSupport.run(executablePath: "/usr/bin/sqlite3", arguments: [db.path, "CREATE TABLE IF NOT EXISTS ItemTable (key TEXT, value TEXT); DELETE FROM ItemTable; INSERT INTO ItemTable VALUES ('cursorAuth/accessToken', '\(token)');"], outputLimit: 1024)
            #expect(output.isSuccess)
        }
        let personal = root.appendingPathComponent("personal.vscdb")
        let work = root.appendingPathComponent("work.vscdb")
        try await write(personal, user: "personal")
        try await write(work, user: "work")
        let connections = LegacyAccountConnections(networkClient: CursorAccountNetwork(), settingsRoot: root)
        let a = try connections.source(providerId: "cursor", config: .init(accountId: "personal", label: "Personal", probeConfig: ["source": personal.path, "identity": "personal"]))
        let b = try connections.source(providerId: "cursor", config: .init(accountId: "work", label: "Work", probeConfig: ["source": work.path, "identity": "work"]))
        let first = try await a.refresh(.interactive)
        let second = try await b.refresh(.interactive)
        #expect(first.quotas != second.quotas)
        #expect(b.connectionIdentity == "work")
        try await write(work, user: "switched")
        await #expect(throws: (any Error).self) { try await b.refresh(.interactive) }
        #expect(try await a.refresh(.interactive).quotas == first.quotas)
    }

    private func home(_ root: URL, id: String, name: String) throws -> ProviderAccountConfig {
        let home = root.appendingPathComponent(name)
        let token = name + "-key"
        let relative: String
        let data: [String: Any]
        switch id {
        case "gemini": relative = ".gemini/oauth_creds.json"; data = ["access_token": token, "expiry_date": 2_000_000_000_000]
        case "grok": relative = ".grok/auth.json"; data = ["https://auth.x.ai::fixture": ["key": token, "email": name + "@example.com", "expires_at": "2099-01-01T00:00:00Z"]]
        case "opencode-go": relative = ".local/share/opencode/auth.json"; data = ["opencode-go": ["type": "api", "key": token]]
        default: relative = ".commandcode/auth.json"; data = ["apiKey": token]
        }
        let file = home.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: data).write(to: file)
        return .init(accountId: name, label: name, probeConfig: ["source": home.path])
    }
}
private struct UnavailableHomeCLI: CLIExecutor {
    func locate(_ binary: String) -> String? { nil }
    func execute(binary: String, args: [String], input: String?, timeout: TimeInterval, workingDirectory: URL?, autoResponses: [String: String]) async throws -> CLIResult { throw UsageError.authenticationRequired }
}
private struct HomeUsageNetwork: NetworkClient {
    let id: String
    func request(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let work = request.value(forHTTPHeaderField: "Authorization")?.contains("work-key") == true
        let left = work ? 30 : 80
        let json: String
        switch id {
        case "gemini": json = request.url!.path.contains("loadCodeAssist") ? #"{"cloudaicompanionProject":"fixture"}"# : "{\"buckets\":[{\"modelId\":\"gemini-pro\",\"remainingFraction\":\(Double(left)/100)}]}"
        case "grok": json = "{\"config\":{\"creditUsagePercent\":\(100-left),\"productUsage\":[{\"product\":\"GrokBuild\",\"usagePercent\":\(100-left)}]}}"
        case "opencode-go": json = "{\"usage\":{\"rolling\":{\"status\":\"ok\",\"percent\":\(100-left),\"resetsAt\":\"2026-12-01T00:00:00.000Z\"}}}"
        default: json = request.url!.path.contains("whoami") ? "{\"user\":{\"userName\":\"\(work ? "work" : "personal")@example.com\"}}" : CommandCodeUsageProbeParsingTests.sampleResponse.replacingOccurrences(of: "8.5", with: work ? "3.0" : "8.0")
        }
        return (Data(json.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

private struct CursorAccountNetwork: NetworkClient {
    func request(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let used = request.value(forHTTPHeaderField: "Cookie")?.contains("work::") == true ? 70 : 20
        let json = "{\"membershipType\":\"pro\",\"individualUsage\":{\"plan\":{\"enabled\":true,\"used\":\(used),\"limit\":100,\"remaining\":\(100-used)}}}"
        return (Data(json.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

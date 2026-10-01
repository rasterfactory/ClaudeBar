import CryptoKit
import DataSources
import Foundation
import Mockable
import Providers
import Quotas
import Testing

@Suite("Independent Claude subscription accounts")
@MainActor
struct ClaudeAccountsTests {
    @Test
    func separateFoldersReadSeparateCredentialsAndRejectChangedLoginEvenWhenCached() async throws {
        let stub = try StubbedProvider(dataSourceKind: "api", providerId: "claude")
        defer { stub.cleanUp() }
        let personal = try folder(stub.home, name: "personal", email: "personal@example.com", token: "personal-token")
        let work = try folder(stub.home, name: "work", email: "work@example.com", token: "work-token")
        given(stub.network).request(.any).willProduce { @Sendable request in
            let used = request.value(forHTTPHeaderField: "Authorization") == "Bearer work-token" ? 70 : 20
            return (Data(#"{"five_hour":{"utilization":\#(used)}}"#.utf8), StubbedProvider.response(200))
        }
        let provider = try stub.makeProvider("claude", accounts: [personal, work])
        let a = try #require(provider.accounts.first { $0.accountId == "personal" })
        let b = try #require(provider.accounts.first { $0.accountId == "work" })
        #expect(try await a.refresh().sessionQuota?.percentRemaining == 80)
        #expect(try await b.refresh().sessionQuota?.percentRemaining == 30)
        #expect(a.accountEmail == "personal@example.com")
        #expect(b.accountEmail == "work@example.com")
        #expect(b.snapshot?.providerId == "claude.work")
        let configFile = URL(fileURLWithPath: work.probeConfig["configDirectory"]!).appendingPathComponent(".claude.json")
        try Data(#"{"oauthAccount":{"emailAddress":"wrong@example.com"}}"#.utf8).write(to: configFile)
        await #expect(throws: UsageError.self) { try await b.refresh() }
        #expect(b.snapshot == nil)
        #expect(a.snapshot?.sessionQuota?.percentRemaining == 80)
        #expect(a.guestPasses == nil)
    }

    @Test
    func folderSetupReadsIdentityAndDerivesOnlyThatFoldersKeychainEntry() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let login = try folder(root, name: "work", email: "work@example.com", token: "work-token")
        let selected = login.probeConfig["configDirectory"]!
        let config = try AddedAccounts.configuration("claude", folder: selected, existing: [], defaultFolder: "/nonexistent-default-claude", security: { _ in (44, "") })
        #expect(config.email == "work@example.com")
        #expect(config.probeConfig["loginEmail"] == "work@example.com")
        let hash = SHA256.hash(data: Data(selected.utf8)).map { String(format: "%02x", $0) }.joined()
        #expect(config.probeConfig["credentialService"] == "Claude Code-credentials-\(hash.prefix(8))")
        #expect(throws: UsageError.self) { try AddedAccounts.configuration("claude", folder: selected, existing: [config], defaultFolder: "/nonexistent-default-claude", security: { _ in (44, "") }) }
    }

    private func folder(_ root: URL, name: String, email: String, token: String) throws -> ProviderAccountConfig {
        let path = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        let metadata = ["oauthAccount": ["emailAddress": email]]
        let credential: [String: Any] = ["claudeAiOauth": ["accessToken": token, "expiresAt": 2_000_000_000_000, "subscriptionType": "pro"]]
        try JSONSerialization.data(withJSONObject: metadata).write(to: path.appendingPathComponent(".claude.json"))
        try JSONSerialization.data(withJSONObject: credential).write(to: path.appendingPathComponent(".credentials.json"))
        return .init(accountId: name, label: name.capitalized, email: email,
                     probeConfig: ["configDirectory": path.path, "loginEmail": email, "credentialService": "fixture-\(name)"])
    }
}

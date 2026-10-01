import DataSources
import Quotas
import Foundation
import Mockable
import Providers
import Testing

/// Codex's added accounts (#326) and its passive background (#216), all from
/// `codex.json`: the default login, and each login added by its folder.
@MainActor
@Suite
struct CodexAccountsTests {
    private static let usage = #"{"id":2,"result":{"rateLimits":{"planType":"pro","primary":{"usedPercent":20}}}}"#

    // MARK: - The default login stays passive until checked (#216)

    @Test
    func `background refresh does not start codex before an explicit refresh succeeded`() async throws {
        let stub = try StubbedProvider(providerId: "codex")
        defer { stub.cleanUp() }
        stub.answerRPC(Self.usage)
        let codex = try stub.make("codex")

        await #expect(throws: UsageError.self) { try await codex.refresh(.background) }

        #expect(stub.launches.count == 0)
        #expect(codex.lastError?.localizedDescription.contains("Click Refresh or Connect") == true)
    }

    @Test
    func `opening the popover does not start an unchecked codex`() async throws {
        let stub = try StubbedProvider(providerId: "codex")
        defer { stub.cleanUp() }
        stub.answerRPC(Self.usage)
        let codex = try stub.make("codex")

        await #expect(throws: UsageError.self) { try await codex.refresh(.passive) }

        #expect(stub.launches.count == 0)
    }

    @Test
    func `an explicit refresh checks the session for later background refreshes`() async throws {
        let stub = try StubbedProvider(providerId: "codex")
        defer { stub.cleanUp() }
        stub.answerRPC(Self.usage)
        let codex = try stub.make("codex")

        try await codex.refresh()
        let background = try await codex.refresh(.background)

        #expect(stub.settings.isOn("verifiedAtLeastOnce", forProvider: "codex") == true)
        #expect(background.quota(for: .session)?.percentRemaining == 80)
        #expect(stub.launches.count == 2)
    }

    @Test
    func `a refresh through the api does not check the rpc session`() async throws {
        let stub = try StubbedProvider(dataSourceKind: "api", providerId: "codex")
        defer { stub.cleanUp() }
        try stub.writeCodexAuth(accountId: "account")
        stub.answerHTTP(#"{"rate_limit":{"primary_window":{"used_percent":10}}}"#)

        try await stub.make("codex").refresh()

        #expect(stub.settings.isOn("verifiedAtLeastOnce", forProvider: "codex") == nil)
    }

    @Test
    func `codex never starts without a login`() async throws {
        let stub = try StubbedProvider(providerId: "codex")
        defer { stub.cleanUp() }
        try FileManager.default.removeItem(at: stub.home.appendingPathComponent(".codex/auth.json"))
        stub.answerRPC(Self.usage)
        stub.answerTerminal("5h limit: 99% left")

        await #expect(throws: UsageError.authenticationRequired) { try await stub.make("codex").refresh() }

        #expect(stub.launches.count == 0)
    }

    @Test
    func `a keychain login gets its email from the cli`() async throws {
        let stub = try StubbedProvider(providerId: "codex")
        defer { stub.cleanUp() }
        stub.answerRPC(Self.usage, account: #"{"id":3,"result":{"account":{"type":"chatgpt","email":"keychain@example.com"}}}"#)

        let usage = try await stub.make("codex").refresh()

        #expect(usage.accountEmail == "keychain@example.com")
        #expect(usage.lowestQuota?.percentRemaining == 80)
    }

    @Test func `one account keeps the product name and removing the second restores it`() async throws {
        let stub = try StubbedProvider(providerId: "codex")
        defer { stub.cleanUp() }
        stub.answerRPC(Self.usage, account: #"{"id":3,"result":{"account":{"type":"chatgpt","email":"personal@example.com"}}}"#)
        let account = try stub.make("codex")
        try await account.refresh()
        #expect(account.name == "Codex")
        #expect(!account.isNamedByAccount)
        let second = try #require(account.provider.add(config(
            "work", folder: stub.home.appendingPathComponent("work"), accountId: "work", email: "work@example.com")))
        #expect(account.name == "personal@example.com")
        #expect(second.name == "work@example.com")
        account.provider.remove(second)
        #expect(account.name == "Codex")
        #expect(account.accountEmail == "personal@example.com")
    }

    // MARK: - Added accounts

    @Test
    func `an added account runs codex in its own folder with file credentials only`() async throws {
        let stub = try StubbedProvider(providerId: "codex")
        defer { stub.cleanUp() }
        let folder = try writeLogin(in: stub.home, "work", email: "work@example.com", accountId: "work")
        stub.answerRPC(Self.usage)
        let account = try stub.make("codex", account: config("a", folder: folder, accountId: "work"))

        try await account.refresh(.background)

        let launch = try #require(stub.launches.last)
        #expect(launch.environment?["CODEX_HOME"] == folder.path)
        #expect(launch.environment?["OPENAI_API_KEY"] == nil)
        #expect(launch.arguments.contains(#"cli_auth_credentials_store="file""#))
        #expect(stub.settings.isOn("verifiedAtLeastOnce", forProvider: "codex") == nil)
    }

    @Test
    func `added accounts keep their own ids, names and usage`() async throws {
        let stub = try StubbedProvider(providerId: "codex")
        defer { stub.cleanUp() }
        let a = try writeLogin(in: stub.home, "a", email: "a@example.com", accountId: "a")
        stub.answerRPC(Self.usage)
        let first = try stub.make("codex", account: config("a", folder: a, accountId: "a", email: "a@example.com"))
        let second = try stub.make("codex", account: config(
            "b", folder: stub.home.appendingPathComponent("signed-out"), accountId: "b", email: "b@example.com"
        ))

        let usage = try await first.refresh()
        await #expect(throws: UsageError.self) { try await second.refresh() }

        #expect(first.id == "codex.a")
        #expect(second.id == "codex.b")
        #expect(first.name == "a@example.com")
        #expect(second.name == "b@example.com")
        #expect(usage.providerId == "codex.a")
        #expect(usage.quotas.first?.providerId == "codex.a")
        #expect(second.snapshot == nil)
        #expect(second.lastError != nil)
    }

    @Test
    func `both data sources show the login's email`() async throws {
        let stub = try StubbedProvider(providerId: "codex")
        defer { stub.cleanUp() }
        let folder = try writeLogin(in: stub.home, "work", email: "signed-in@example.com", accountId: "work")
        stub.answerRPC(Self.usage)
        stub.answerHTTP(#"{"rate_limit":{"primary_window":{"used_percent":10}}}"#)
        let account = try stub.make("codex", account: config("a", folder: folder, accountId: "work"))

        let viaRPC = try await account.refresh()
        account.provider.use("api")
        let viaAPI = try await account.refresh()

        #expect(viaRPC.accountEmail == "signed-in@example.com")
        #expect(viaAPI.accountEmail == "signed-in@example.com")
    }

    @Test
    func `a folder signed in to another account fails closed`() async throws {
        let stub = try StubbedProvider(providerId: "codex")
        defer { stub.cleanUp() }
        let folder = try writeLogin(in: stub.home, "work", email: "other@example.com", accountId: "other")
        stub.answerRPC(Self.usage)
        given(stub.cli).locate(.any).willReturn("/usr/local/bin/codex")
        let account = try stub.make("codex", account: config("a", folder: folder, accountId: "original"))

        #expect(await account.isAvailable() == false)
        await #expect(throws: UsageError.self) { try await account.refresh() }

        #expect(stub.launches.count == 0)
        #expect(account.lastError?.localizedDescription.contains("original account") == true)
    }

    // MARK: - Adding an account by its folder

    @Test
    func `two folders become two accounts with their own emails`() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try writeLogin(in: root, "account a", email: "a@example.com", accountId: "account-a")
        let b = try writeLogin(in: root, "account b", email: "b@example.com", accountId: "account-b")

        let first = try add(a, to: [], root: root)
        let second = try add(b, to: [first], root: root)

        #expect(first.email == "a@example.com")
        #expect(second.email == "b@example.com")
        #expect(first.accountId != second.accountId)
        #expect(first.probeConfig["chatgptAccountId"] == "account-a")
        #expect(first.probeConfig["codexHome"] == a.resolvingSymlinksInPath().path)
    }

    @Test
    func `one login is not added twice from another folder`() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try writeLogin(in: root, "a", email: "same@example.com", accountId: "same")
        let b = try writeLogin(in: root, "b", email: "same@example.com", accountId: "same")
        let first = try add(a, to: [], root: root)

        #expect(throws: UsageError.executionFailed("This Codex account is already listed.")) {
            try add(b, to: [first], root: root)
        }
    }

    @Test
    func `one email in two workspaces is two accounts`() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try writeLogin(in: root, "a", email: "same@example.com", accountId: "workspace-a")
        let b = try writeLogin(in: root, "b", email: "same@example.com", accountId: "workspace-b")

        let first = try add(a, to: [], root: root)
        let second = try add(b, to: [first], root: root)

        #expect(first.probeConfig["chatgptAccountId"] != second.probeConfig["chatgptAccountId"])
    }

    @Test
    func `a folder without a login is refused`() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(throws: UsageError.executionFailed("No ChatGPT account found in this folder. Sign in with Codex using file credential storage, then choose the folder again.")) {
            try add(root.appendingPathComponent("missing"), to: [], root: root)
        }
    }

    @Test
    func `the default login's folder is refused`() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let defaultFolder = try writeLogin(in: root, "default", email: "me@example.com", accountId: "me")

        #expect(throws: UsageError.executionFailed("This is the default Codex login, which is already listed.")) {
            try add(defaultFolder, to: [], root: root)
        }
    }

    @Test
    func `saved accounts come back as logins of one Codex provider`() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try writeLogin(in: root, "a", email: "a@example.com", accountId: "a")
        let b = try writeLogin(in: root, "b", email: "b@example.com", accountId: "b")
        let first = try add(a, to: [], root: root)
        let second = try add(b, to: [first], root: root)
        let settings = InMemoryProviderSettings()

        let codex = try Providers.make("codex", settings: settings, accounts: [first, second])
        let added = Array(codex.accounts.dropFirst())
        added[0].isEnabled = false

        #expect(codex.accounts.count == 3)
        #expect(codex.defaultAccount.id == "codex")
        #expect(added.map(\.name) == ["a@example.com", "b@example.com"])
        #expect(Set(codex.accounts.map(\.id)).count == 3)
        #expect(added[1].isEnabled)
        #expect(settings.isEnabled(forProvider: added[0].id) == false)
    }

    // MARK: - One provider, many logins

    @Test
    func `every login runs the one definition, patched for added logins`() throws {
        let stub = try StubbedProvider(providerId: "codex")
        defer { stub.cleanUp() }
        let folder = try writeLogin(in: stub.home, "work", email: "work@example.com", accountId: "work")
        let codex = try stub.makeProvider("codex", accounts: [config("a", folder: folder, accountId: "work")])

        let defaultKinds = codex.dataSources(for: codex.defaultAccount).map(\.kind)
        let addedSources = codex.dataSources(for: codex.accounts[1])

        #expect(defaultKinds == ["rpc", "api", "tty"])
        #expect(addedSources.map(\.kind) == ["rpc", "api"])
        #expect(addedSources.first?.definition.fallback == nil)
        #expect(addedSources.first?.definition.requiresFiles == ["\(folder.path)/auth.json"])
        #expect(addedSources.first?.definition.identity?.equals == "work")
    }

    @Test
    func `the data source choice covers every login`() throws {
        let stub = try StubbedProvider(providerId: "codex")
        defer { stub.cleanUp() }
        let folder = try writeLogin(in: stub.home, "work", email: "work@example.com", accountId: "work")
        let codex = try stub.makeProvider("codex", accounts: [config("a", folder: folder, accountId: "work")])

        codex.use("api")

        #expect(codex.activeKind == "api")
        #expect(stub.settings.dataSourceKind(forProvider: "codex") == "api")
    }

    @Test
    func `a login whose saved values are incomplete is not added`() throws {
        let stub = try StubbedProvider(providerId: "codex")
        defer { stub.cleanUp() }
        let codex = try stub.makeProvider("codex")

        let added = codex.add(ProviderAccountConfig(accountId: "a", label: "", probeConfig: ["codexHome": "/tmp/x"]))

        #expect(added == nil)
        #expect(codex.accounts.count == 1)
    }

    @Test
    func `a login is listed once, and the default can't be removed`() throws {
        let stub = try StubbedProvider(providerId: "codex")
        defer { stub.cleanUp() }
        let folder = try writeLogin(in: stub.home, "work", email: "work@example.com", accountId: "work")
        let codex = try stub.makeProvider("codex")
        let work = config("a", folder: folder, accountId: "work")

        let first = try #require(codex.add(work))
        let again = codex.add(work)
        codex.remove(codex.defaultAccount)
        codex.remove(first)

        #expect(again == nil)
        #expect(codex.accounts.map(\.id) == ["codex"])
    }

    @Test
    func `status is the worst enabled login, and the best has the most left`() async throws {
        let stub = try StubbedProvider(dataSourceKind: "api", providerId: "codex")
        defer { stub.cleanUp() }
        try stub.writeCodexAuth(accountId: "me")
        let folder = try writeLogin(in: stub.home, "work", email: "work@example.com", accountId: "work")
        let codex = try stub.makeProvider("codex", accounts: [config("a", folder: folder, accountId: "work")])
        let me = codex.defaultAccount
        let work = codex.accounts[1]
        given(stub.network).request(.matching { @Sendable in $0.value(forHTTPHeaderField: "ChatGPT-Account-Id") == "me" })
            .willReturn((Data(#"{"rate_limit":{"primary_window":{"used_percent":90}}}"#.utf8), StubbedProvider.response(200)))
        given(stub.network).request(.matching { @Sendable in $0.value(forHTTPHeaderField: "ChatGPT-Account-Id") == "work" })
            .willReturn((Data(#"{"rate_limit":{"primary_window":{"used_percent":10}}}"#.utf8), StubbedProvider.response(200)))

        try await me.refresh()
        try await work.refresh()

        #expect(me.status == .critical)
        #expect(work.status == .healthy)
        #expect(codex.status == .critical)
        #expect(codex.bestAccount === work)

        me.isEnabled = false

        #expect(codex.status == .healthy)
    }

    // MARK: - Helpers

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("codex-accounts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func add(_ folder: URL, to existing: [ProviderAccountConfig], root: URL) throws -> ProviderAccountConfig {
        try AddedAccounts.configuration(
            "codex", folder: folder.path, existing: existing,
            defaultFolder: root.appendingPathComponent("default").path
        )
    }

    private func config(_ id: String, folder: URL, accountId: String, email: String? = nil) -> ProviderAccountConfig {
        ProviderAccountConfig(
            accountId: id, label: "", email: email,
            probeConfig: ["codexHome": folder.path, "chatgptAccountId": accountId]
        )
    }

    /// A Codex folder signed in with file credentials: `auth.json` with an
    /// account id and an id token carrying the email.
    @discardableResult
    private func writeLogin(in root: URL, _ name: String, email: String, accountId: String) throws -> URL {
        let folder = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let claims = try JSONSerialization.data(withJSONObject: ["email": email])
        let jwt = "header." + claims.base64EncodedString().replacingOccurrences(of: "=", with: "") + ".signature"
        let auth: [String: Any] = [
            "tokens": ["access_token": "token-\(name)", "refresh_token": "refresh-\(name)",
                       "account_id": accountId, "id_token": jwt],
            "last_refresh": ISO8601DateFormatter().string(from: Date()),
        ]
        try JSONSerialization.data(withJSONObject: auth).write(to: folder.appendingPathComponent("auth.json"))
        return folder
    }
}

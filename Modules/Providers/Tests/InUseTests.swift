import DataSources
import Foundation
import Mockable
import Providers
import Quotas
import Testing

/// *In use* — which login new terminal sessions start with. Two Codex logins
/// are *me* (the plain login) and *work* (an added folder); choosing one
/// writes only its folder, and only new sessions follow it.
@MainActor
@Suite
struct InUseTests {
    // MARK: - Offered, or not

    @Test
    func `a product whose CLI starts on a login's folder offers In use, the plain login first in use`() throws {
        let (stub, codex, _) = try InUseFixture.twoLogins()
        defer { stub.cleanUp() }

        let inUse = try #require(codex.inUse)
        #expect(inUse.login === codex.defaultAccount)
        #expect(inUse.command == TerminalCommand(name: "codex", variable: "CODEX_HOME"))
    }

    @Test
    func `a product whose CLI has no login folder has no In use`() throws {
        let stub = try StubbedProvider(providerId: "gemini")
        defer { stub.cleanUp() }

        #expect(try stub.makeProvider("gemini").inUse == nil)
    }

    @Test
    func `without a place to record the choice, there is no In use`() throws {
        let stub = try StubbedProvider(providerId: "codex")
        defer { stub.cleanUp() }

        let codex = try ProviderFactory.make("codex", settings: stub.settings)

        #expect(codex.inUse == nil)
        #expect(codex.inUse == nil)
    }

    @Test
    func `the logins offered are the plain login and every folder login; one login is no choice`() throws {
        let (stub, codex, work) = try InUseFixture.twoLogins()
        defer { stub.cleanUp() }
        let alone = try StubbedProvider(providerId: "codex")
        defer { alone.cleanUp() }

        #expect(codex.inUse?.logins.map(\.id) == [codex.defaultAccount.id, work.id])
        #expect(codex.inUse?.offersChoice == true)
        #expect(try alone.makeProvider("codex").inUse?.offersChoice == false)
    }

    // MARK: - Choosing

    @Test
    func `choosing a login puts it in use, and records only its folder`() throws {
        let (stub, codex, work) = try InUseFixture.twoLogins()
        defer { stub.cleanUp() }

        try #require(codex.inUse).use(work)

        #expect(codex.inUse?.isInUse(work) == true)
        #expect(codex.inUse?.isInUse(codex.defaultAccount) != true)
        #expect(stub.loginsInUse.folder(for: "codex") == work.folder?.url)
    }

    @Test
    func `the choice is recorded under the CLI's name, so two products on one CLI share it`() throws {
        let (stub, codex, work) = try InUseFixture.twoLogins()
        defer { stub.cleanUp() }
        // A second product running the same CLI, on the same record.
        let other = try stub.makeProvider("codex", accounts: stub.settings.accounts(forProvider: "codex"))

        try #require(codex.inUse).use(work)
        try #require(other.inUse).use(other.defaultAccount)

        #expect(stub.loginsInUse.folder(for: "codex") == nil)
        let again = try stub.makeProvider("codex", accounts: stub.settings.accounts(forProvider: "codex"))
        #expect(again.inUse?.login === again.defaultAccount)
        #expect(codex.inUse?.command.name == "codex")
    }

    @Test
    func `the login in use is still in use after a relaunch`() throws {
        let (stub, codex, work) = try InUseFixture.twoLogins()
        defer { stub.cleanUp() }
        try #require(codex.inUse).use(work)

        let again = try stub.makeProvider("codex", accounts: stub.settings.accounts(forProvider: "codex"))

        #expect(again.inUse?.login.accountId == work.accountId)
    }

    @Test
    func `choosing the plain login clears the record`() throws {
        let (stub, codex, work) = try InUseFixture.twoLogins()
        defer { stub.cleanUp() }
        try #require(codex.inUse).use(work)

        try #require(codex.inUse).use(codex.defaultAccount)

        #expect(codex.inUse?.isInUse(codex.defaultAccount) == true)
        #expect(stub.loginsInUse.folder(for: "codex") == nil)
    }

    @Test
    func `removing the login in use goes back to the plain login`() throws {
        let (stub, codex, work) = try InUseFixture.twoLogins()
        defer { stub.cleanUp() }
        try #require(codex.inUse).use(work)

        codex.accounts.remove(work)

        #expect(codex.inUse?.login === codex.defaultAccount)
        #expect(stub.loginsInUse.folder(for: "codex") == nil)
    }

    @Test
    func `a record naming a folder no login has is the plain login`() throws {
        let (stub, _, _) = try InUseFixture.twoLogins()
        defer { stub.cleanUp() }
        try stub.loginsInUse.use(URL(fileURLWithPath: "/tmp/gone"), for: "codex")

        let codex = try stub.makeProvider("codex", accounts: stub.settings.accounts(forProvider: "codex"))

        #expect(codex.inUse?.isInUse(codex.defaultAccount) == true)
    }

    @Test
    func `another product's login can't be put in use`() throws {
        let (stub, codex, _) = try InUseFixture.twoLogins()
        defer { stub.cleanUp() }
        let claudeStub = try StubbedProvider(providerId: "claude")
        defer { claudeStub.cleanUp() }
        let claude = try claudeStub.makeProvider("claude")

        #expect(throws: (any Error).self) { try codex.inUse?.use(claude.defaultAccount) }
        #expect(codex.inUse?.isInUse(codex.defaultAccount) == true)
    }

    @Test
    func `a login is found by its name, its id, or default for the plain login`() throws {
        let (stub, codex, work) = try InUseFixture.twoLogins()
        defer { stub.cleanUp() }

        #expect(codex.accounts.named("Work") === work)
        #expect(codex.accounts.named(work.id) === work)
        #expect(codex.accounts.named("default") === codex.defaultAccount)
        #expect(codex.accounts.named("someone") == nil)
    }

    // MARK: - Worth switching

    @Test
    func `when the login in use is low, the one with more left is worth switching to`() async throws {
        let (stub, codex, work) = try InUseFixture.twoLogins()
        defer { stub.cleanUp() }
        try await InUseFixture.usage(stub, codex, me: 92, work: 15)

        #expect(codex.inUse?.worthSwitchingTo === work)
    }

    @Test
    func `nothing is worth switching to while the login in use has room, or no login has more`() async throws {
        let (stub, codex, _) = try InUseFixture.twoLogins()
        defer { stub.cleanUp() }

        try await InUseFixture.usage(stub, codex, me: 40, work: 10)
        #expect(codex.inUse?.worthSwitchingTo == nil)

        try await InUseFixture.usage(stub, codex, me: 92, work: 95)
        #expect(codex.inUse?.worthSwitchingTo == nil)
    }

    // MARK: - After each refresh: what is worth telling

    @Test
    func `a login worth switching to is told once, not on every refresh`() async throws {
        let (stub, codex, work) = try InUseFixture.twoLogins()
        defer { stub.cleanUp() }
        try await InUseFixture.usage(stub, codex, me: 92, work: 15)
        let inUse = try #require(codex.inUse)

        #expect(try inUse.review() == .worthSwitching(from: codex.defaultAccount, to: work))
        #expect(try inUse.review() == nil)
    }

    @Test
    func `after the login in use recovers, the next low is told again`() async throws {
        let (stub, codex, work) = try InUseFixture.twoLogins()
        defer { stub.cleanUp() }
        let inUse = try #require(codex.inUse)
        try await InUseFixture.usage(stub, codex, me: 92, work: 15)
        _ = try inUse.review()

        try await InUseFixture.usage(stub, codex, me: 30, work: 15)
        #expect(try inUse.review() == nil)
        try await InUseFixture.usage(stub, codex, me: 95, work: 15)

        #expect(try inUse.review() == .worthSwitching(from: codex.defaultAccount, to: work))
    }

    @Test
    func `with switch when low on, the switch is what is told`() async throws {
        let (stub, codex, work) = try InUseFixture.twoLogins()
        defer { stub.cleanUp() }
        let inUse = try #require(codex.inUse)
        inUse.switchWhenLow.isOn = true
        try await InUseFixture.usage(stub, codex, me: 95, work: 15)

        #expect(try inUse.review() == .switched(from: codex.defaultAccount, to: work))
        #expect(codex.inUse?.isInUse(work) == true)
    }
}

/// Codex with the plain login *me* and an added folder login *work*, and
/// their usage on demand.
@MainActor
enum InUseFixture {
    static func twoLogins() throws -> (StubbedProvider, Provider, Account) {
        let stub = try StubbedProvider(dataSourceKind: "api", providerId: "codex")
        try stub.writeCodexAuth(accountId: "me")
        let folder = stub.home.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let auth: [String: Any] = ["tokens": ["access_token": "token-work", "refresh_token": "refresh-work", "account_id": "work"],
                                   "last_refresh": ISO8601DateFormatter().string(from: Date())]
        try JSONSerialization.data(withJSONObject: auth).write(to: folder.appendingPathComponent("auth.json"))
        let config = ProviderAccountConfig(accountId: "work", label: "work", probeConfig: ["codexHome": folder.path, "chatgptAccountId": "work"])
        stub.settings.addAccount(config, forProvider: "codex")
        let codex = try stub.makeProvider("codex", accounts: stub.settings.accounts(forProvider: "codex"))
        return (stub, codex, codex.accounts[1])
    }

    /// Both logins refreshed with these percentages used.
    static func usage(_ stub: StubbedProvider, _ codex: Provider, me: Int, work: Int) async throws {
        stub.network.reset([.given])
        for (id, used) in [("me", me), ("work", work)] {
            given(stub.network).request(.matching { @Sendable in $0.value(forHTTPHeaderField: "ChatGPT-Account-Id") == id })
                .willReturn((Data(#"{"rate_limit":{"primary_window":{"used_percent":\#(used)}}}"#.utf8), StubbedProvider.response(200)))
        }
        try await codex.refreshPlain()
        try await codex.refresh(codex.accounts[1])
    }
}

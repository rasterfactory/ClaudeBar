import DataSources
import Foundation
import Mockable
import Providers
import Quotas
import Testing

/// THE lifecycle, once for every provider — pinned on a provider no vendor
/// ships: "Acme", whose `api` falls back to a `backup` the person can switch
/// off. Every rule here holds for Claude, Codex and any provider someone adds.
@MainActor
@Suite
struct ProviderTests {
    // MARK: - Acme, as data

    private static func source(_ json: String) -> DataSourceDefinition {
        try! JSONDecoder().decode(DataSourceDefinition.self, from: Data(json.utf8))
    }

    /// An added login asks with its own `login` value.
    private static let loginPatch = try! JSONDecoder().decode([String: JSONValue].self, from: Data("""
    { "api": { "fetch": { "http": { "url": "https://api.acme.test/usage?login={{account.login}}" } } },
      "backup": { "fetch": { "http": { "url": "https://backup.acme.test/usage?login={{account.login}}" } } } }
    """.utf8))

    private static func acme(verifyBeforeBackground: Bool = false, together: Bool = false, patch: [String: JSONValue] = loginPatch) -> ProviderDefinition {
        ProviderDefinition(
            profile: ProviderProfile(id: "acme", name: "Acme"),
            dataSources: [
                source("""
                { "kind": "api", "label": "API",
                  "fetch": { "http": { "url": "https://api.acme.test/usage" } },
                  "mapping": { "json": { "quotas": [ { "kind": "session", "at": "$", "usedPercent": "used" } ] } },
                  "cache": { "ttl": 600 },
                  "verifyBeforeBackground": \(verifyBeforeBackground),
                  "fallback": { "to": "backup", "enabledBySetting": "backupEnabled" } }
                """),
                source("""
                { "kind": "backup", "label": "Backup",
                  "fetch": { "http": { "url": "https://backup.acme.test/usage" } },
                  "mapping": { "json": { "quotas": [ { "kind": "session", "at": "$", "usedPercent": "used" } ] } } }
                """),
            ],
            defaultDataSource: "api",
            together: together,
            accounts: .init(patch: patch)
        )
    }

    /// The network Acme talks to: each host answers what it was told, and
    /// every request is remembered — a fake, so an answer can be held back.
    private final class AcmeNetwork: NetworkClient, @unchecked Sendable {
        private let lock = NSLock()
        private var answers: [String: (status: Int, body: String)] = [:]
        private var asked: [String] = []
        /// Hold every answer until `release()` — to overlap two refreshes.
        var held = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func request(_ request: URLRequest) async throws -> (Data, URLResponse) {
            let host = request.url?.host ?? ""
            let login = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "login" }?.value ?? ""
            lock.withLock { asked.append(host) }
            await waitIfHeld()
            let answer: (status: Int, body: String) = lock.withLock { answers["\(host)/\(login)"] ?? answers[host] } ?? (500, "{}")
            let headers = answer.status == 429 ? ["Retry-After": "60"] : [:]
            return (Data(answer.body.utf8),
                    HTTPURLResponse(url: request.url!, statusCode: answer.status, httpVersion: nil, headerFields: headers)!)
        }

        func answer(_ host: String, login: String? = nil, used: Int) {
            lock.withLock { answers[login.map { "\(host)/\($0)" } ?? host] = (200, #"{"used":\#(used)}"#) }
        }

        func fail(_ host: String, status: Int = 500) {
            lock.withLock { answers[host] = (status, "{}") }
        }

        func requests(to host: String) -> Int { lock.withLock { asked.filter { $0 == host }.count } }

        private func waitIfHeld() async {
            guard lock.withLock({ held }) else { return }
            await withCheckedContinuation { continuation in lock.withLock { waiters.append(continuation) } }
        }

        func waitForHeldRequest() async throws {
            for _ in 0..<1000 {
                if lock.withLock({ !waiters.isEmpty }) { return }
                try await Task.sleep(for: .milliseconds(1))
            }
            throw UsageError.executionFailed("The fixture request never started")
        }

        func release() {
            let waiting = lock.withLock { held = false; defer { waiters = [] }; return waiters }
            waiting.forEach { $0.resume() }
        }
    }

    private static let api = "api.acme.test"
    private static let backup = "backup.acme.test"

    private func acme(
        _ network: AcmeNetwork,
        settings: InMemoryProviderSettings = InMemoryProviderSettings(),
        definition: ProviderDefinition = ProviderTests.acme(),
        logins: [String] = []
    ) -> Provider {
        Provider(
            definition: definition,
            settings: settings,
            accounts: logins.map { ProviderAccountConfig(accountId: $0, label: "", probeConfig: ["login": $0]) },
            makeDataSource: {
                DataSources.make($0, providerId: "acme", cliExecutor: MockCLIExecutor(), network: network,
                                 makeTransport: { _, _, _, _ in MockRPCTransport() },
                                 environment: { _ in nil }, homeDirectory: FileManager.default.temporaryDirectory, now: { Date() })
            }
        )
    }

    @Test func `cancellation never starts a fallback or publishes a snapshot`() async throws {
        let network = MockNetworkClient()
        let primaryHost = Self.api
        given(network).request(.any).willProduce { @Sendable request in
            if request.url?.host == primaryHost { throw CancellationError() }
            return (Data(#"{"used":30}"#.utf8), StubbedProvider.response(200))
        }
        let provider = Provider(definition: Self.acme(), settings: InMemoryProviderSettings(), makeDataSource: { source, login in
            DataSources.make(source, providerId: login, cliExecutor: MockCLIExecutor(), network: network,
                makeTransport: { _, _, _, _ in MockRPCTransport() }, environment: { _ in nil },
                homeDirectory: FileManager.default.temporaryDirectory, now: { Date() })
        })
        await #expect(throws: CancellationError.self) { try await provider.refresh(provider.defaultAccount) }
        #expect(provider.defaultAccount.snapshot == nil)
        #expect(provider.defaultAccount.lastError == nil)
    }

    // MARK: - Refresh

    @Test
    func `a refresh records the usage, under the login's own id, and who answered`() async throws {
        let network = AcmeNetwork()
        network.answer(Self.api, used: 30)
        let acme = acme(network, logins: ["work"])
        let work = acme.accounts[1]

        let usage = try await acme.refresh(work)

        #expect(usage.providerId == "acme.work")
        #expect(work.snapshot?.sessionQuota?.percentRemaining == 70)
        #expect(work.answeredBy == "api")
        #expect(work.lastError == nil)
    }

    @Test
    func `a failed refresh keeps the last usage and says which step failed`() async throws {
        let network = AcmeNetwork()
        network.answer(Self.backup, used: 30)
        let acme = acme(network)
        acme.configuration.use("backup")
        try await acme.refreshPlain()
        network.fail(Self.backup)

        await #expect(throws: (any Error).self) { try await acme.refreshPlain() }

        #expect(acme.defaultAccount.snapshot?.sessionQuota?.percentRemaining == 70)
        #expect(acme.defaultAccount.lastError != nil)
        #expect(acme.defaultAccount.lastFailedStep == .fetch)
    }

    @Test
    func `one login failing leaves another's usage alone`() async throws {
        let network = AcmeNetwork()
        network.answer(Self.api, login: "home", used: 10)
        network.fail(Self.backup)
        let acme = acme(network, logins: ["home", "work"])

        try await acme.refresh(acme.accounts[1])
        await #expect(throws: (any Error).self) { try await acme.refresh(acme.accounts[2]) }

        #expect(acme.accounts[1].snapshot?.sessionQuota?.percentRemaining == 90)
        #expect(acme.accounts[1].lastError == nil)
        #expect(acme.accounts[2].snapshot == nil)
    }

    @Test
    func `overlapping refreshes of one login share one request`() async throws {
        let network = AcmeNetwork()
        network.answer(Self.api, used: 30)
        network.held = true
        let acme = acme(network)

        async let first = acme.refreshPlain()
        async let second = acme.refreshPlain()
        try await Task.sleep(for: .milliseconds(50))
        network.release()
        _ = try await (first, second)

        #expect(network.requests(to: Self.api) == 1)
    }

    @Test(arguments: [false, true])
    func `should discard a cancelled refresh even when its worker returns success`(together: Bool) async throws {
        let network = AcmeNetwork()
        network.answer(Self.api, used: 30)
        network.answer(Self.backup, used: 30)
        network.held = true
        let provider = acme(network, definition: Self.acme(together: together))
        let caller = Task { try await provider.refreshPlain() }
        try await network.waitForHeldRequest()
        caller.cancel()
        network.release()
        await #expect(throws: CancellationError.self) { try await caller.value }
        #expect(provider.defaultAccount.snapshot == nil)
        #expect(provider.defaultAccount.lastError == nil)
        #expect(provider.defaultAccount.isSyncing == false)
        // A later caller starts a fresh request rather than inheriting cancellation.
        _ = try await provider.refreshPlain()
        #expect(network.requests(to: Self.api) == 2)
    }

    @Test func `should start fresh when a new caller arrives during cancellation`() async throws {
        let network = AcmeNetwork()
        network.answer(Self.api, used: 30)
        network.held = true
        let provider = acme(network)
        let first = Task { try await provider.refreshPlain() }
        try await network.waitForHeldRequest()
        first.cancel()
        var nextStarted = false
        let next = Task { nextStarted = true; return try await provider.refreshPlain() }
        while !nextStarted { await Task.yield() }
        network.release()
        await #expect(throws: CancellationError.self) { try await first.value }
        let result = try await next.value
        #expect(result.sessionQuota?.percentRemaining == 70)
        #expect(provider.defaultAccount.snapshot == result)
        #expect(provider.defaultAccount.isSyncing == false)
        #expect(network.requests(to: Self.api) == 2)
    }

    @Test func `should preserve a shared refresh for its remaining caller`() async throws {
        let network = AcmeNetwork()
        network.answer(Self.api, used: 30)
        network.held = true
        let provider = acme(network)
        let first = Task { try await provider.refreshPlain() }
        try await network.waitForHeldRequest()
        var secondStarted = false
        let second = Task { secondStarted = true; return try await provider.refreshPlain() }
        while !secondStarted { await Task.yield() }
        first.cancel()
        network.release()
        await #expect(throws: CancellationError.self) { try await first.value }
        let result = try await second.value
        #expect(result.sessionQuota?.percentRemaining == 70)
        #expect(provider.defaultAccount.snapshot == result)
        #expect(network.requests(to: Self.api) == 1)
    }

    @Test func `should cancel a shared refresh when every caller cancels`() async throws {
        let network = AcmeNetwork()
        network.answer(Self.api, used: 30)
        network.held = true
        let provider = acme(network)
        let first = Task { try await provider.refreshPlain() }
        try await network.waitForHeldRequest()
        var secondStarted = false
        let second = Task { secondStarted = true; return try await provider.refreshPlain() }
        while !secondStarted { await Task.yield() }
        first.cancel()
        second.cancel()
        network.release()
        await #expect(throws: CancellationError.self) { try await first.value }
        await #expect(throws: CancellationError.self) { try await second.value }
        #expect(provider.defaultAccount.snapshot == nil)
        #expect(provider.defaultAccount.lastError == nil)
    }

    // MARK: - Fallback

    @Test
    func `when the active data source fails its fallback answers, and says so`() async throws {
        let network = AcmeNetwork()
        network.fail(Self.api)
        network.answer(Self.backup, used: 40)
        let acme = acme(network)

        let usage = try await acme.refreshPlain()

        #expect(usage.sessionQuota?.percentRemaining == 60)
        #expect(acme.defaultAccount.answeredBy == "backup")
    }

    @Test
    func `when every data source fails the active one's failure is reported`() async throws {
        let network = AcmeNetwork()
        network.fail(Self.api, status: 401)
        network.fail(Self.backup, status: 500)
        let acme = acme(network)

        await #expect(throws: (any Error).self) { try await acme.refreshPlain() }

        #expect((acme.defaultAccount.lastError as? UsageError)?.tag == "authenticationRequired")
    }

    @Test
    func `a fallback switched off is not tried`() async throws {
        let network = AcmeNetwork()
        network.fail(Self.api)
        network.answer(Self.backup, used: 40)
        let acme = acme(network)
        acme.configuration.setFallbackEnabled(false, from: "api")

        await #expect(throws: (any Error).self) { try await acme.refreshPlain() }

        #expect(network.requests(to: Self.backup) == 0)
    }

    @Test
    func `a rate limit is not a reason to ask the fallback`() async throws {
        let network = AcmeNetwork()
        network.fail(Self.api, status: 429)
        network.answer(Self.backup, used: 40)
        let acme = acme(network)

        await #expect(throws: (any Error).self) { try await acme.refreshPlain() }

        #expect(network.requests(to: Self.backup) == 0)
    }

    @Test
    func `a login whose patch leaves out the active data source uses the next on its fallback chain`() async throws {
        let network = AcmeNetwork()
        network.answer(Self.backup, used: 25)
        var patch = Self.loginPatch
        patch["api"] = try JSONDecoder().decode(JSONValue.self, from: Data("null".utf8))
        let acme = acme(network, definition: Self.acme(patch: patch), logins: ["work"])

        let usage = try await acme.refresh(acme.accounts[1])

        #expect(usage.sessionQuota?.percentRemaining == 75)
        #expect(acme.accounts[1].answeredBy == "backup")
        #expect(network.requests(to: Self.api) == 0)
    }

    // MARK: - The data source choice — one for every login

    @Test
    func `choosing a data source is saved, and an unknown one is refused`() {
        let settings = InMemoryProviderSettings()
        let acme = acme(AcmeNetwork(), settings: settings)

        #expect(acme.configuration.use("backup"))
        #expect(acme.configuration.use("tty") == false)

        #expect(acme.configuration.activeKind == "backup")
        #expect(settings.dataSourceKind(forProvider: "acme") == "backup")
    }

    @Test
    func `a cached data source sets how often the background may ask`() {
        let acme = acme(AcmeNetwork())

        #expect(acme.backgroundRefreshFloor == .seconds(600))
        acme.configuration.use("backup")
        #expect(acme.backgroundRefreshFloor == nil)
    }

    // MARK: - Held back until checked (#216)

    @Test
    func `a background refresh waits for one the person asked for`() async throws {
        let network = AcmeNetwork()
        network.answer(Self.api, used: 30)
        let acme = acme(network, definition: Self.acme(verifyBeforeBackground: true))

        await #expect(throws: (any Error).self) { try await acme.refreshPlain(.background) }
        #expect(network.requests(to: Self.api) == 0)

        try await acme.refreshPlain(.interactive)
        try await acme.refreshPlain(.background)
        #expect(network.requests(to: Self.api) == 1)
    }

    // MARK: - Status across logins

    @Test
    func `status is the worst enabled login, and the best has the most left`() async throws {
        let network = AcmeNetwork()
        network.answer(Self.api, used: 40)
        network.answer(Self.api, login: "low", used: 90)
        network.answer(Self.api, login: "high", used: 10)
        let acme = acme(network, logins: ["low", "high"])
        for account in acme.accounts { try await acme.refresh(account) }

        #expect(acme.status == .critical)
        #expect(acme.accounts.best?.accountId == "high")

        acme.accounts[1].isEnabled = false
        #expect(acme.status == .healthy)
    }

    @Test
    func `the worst login is the one that makes the provider's status, and nobody when all is well`() async throws {
        let network = AcmeNetwork()
        network.answer(Self.api, used: 40)
        network.answer(Self.api, login: "low", used: 90)
        let acme = acme(network, logins: ["low"])

        #expect(acme.accounts.worst == nil)
        for account in acme.accounts { try await acme.refresh(account) }

        #expect(acme.accounts.worst?.accountId == "low")
        acme.accounts[1].isEnabled = false
        #expect(acme.accounts.worst == nil)
    }
}

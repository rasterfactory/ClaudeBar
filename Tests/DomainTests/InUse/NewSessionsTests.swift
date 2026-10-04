import Foundation
import Testing
@testable import Domain
@testable import Infrastructure

/// *New terminal sessions*: choosing which login each CLI starts with, and
/// the shell lines that make the choice count.
@MainActor
@Suite
struct NewSessionsTests {
    /// The shell lines, kept in memory.
    private final class Lines: ShellLines, @unchecked Sendable {
        var installed: Set<LoginShell> = []
        var failing = false
        func lines(for shell: LoginShell) -> String { "# lines for \(shell.rawValue)" }
        func file(for shell: LoginShell) -> URL { URL(fileURLWithPath: "/Users/you/.\(shell.rawValue)rc") }
        func isInstalled(_ shell: LoginShell) -> Bool { installed.contains(shell) }
        func install(_ shell: LoginShell) throws {
            if failing { throw CocoaError(.fileWriteNoPermission) }
            installed.insert(shell)
        }
        func remove(_ shell: LoginShell) throws { installed.remove(shell) }
    }

    private let temp = FileManager.default.temporaryDirectory.appendingPathComponent("new-sessions-\(UUID().uuidString)")
    private let lines = Lines()

    /// Codex with its plain login and an added folder login, *work*.
    private func codex() -> Provider {
        let settings = JSONSettingsRepository(store: JSONSettingsStore(fileURL: temp.appendingPathComponent("settings.json")))
        let work = ProviderAccountConfig(accountId: "work", label: "work",
                                         probeConfig: ["codexHome": "/Users/you/.codex-work", "chatgptAccountId": "work"])
        return try! ProviderFactory.make("codex", settings: settings, accounts: [work],
                                   loginsInUse: DiskLoginsInUse(root: temp.appendingPathComponent("in-use")))
    }

    @Test
    func `with the lines in the shell, a chosen login is in use at once`() {
        lines.installed = [.zsh]
        let codex = codex()
        let sessions = NewSessions(products: [codex], shellLines: lines, shell: .zsh)

        sessions.use(codex.accounts[1])

        #expect(codex.inUse?.isInUse(codex.accounts[1]) == true)
        #expect(sessions.waiting == nil)
    }

    @Test
    func `without the lines, the choice waits for the setup`() {
        let codex = codex()
        let sessions = NewSessions(products: [codex], shellLines: lines, shell: .zsh)

        sessions.use(codex.accounts[1])

        #expect(codex.inUse?.isInUse(codex.accounts[1]) != true)
        #expect(sessions.isWaiting(in: codex))
    }

    @Test
    func `setting up writes the lines and makes the waiting choice`() {
        let codex = codex()
        let sessions = NewSessions(products: [codex], shellLines: lines, shell: .bash)
        sessions.use(codex.accounts[1])

        sessions.setUp()

        #expect(sessions.isSetUp)
        #expect(lines.installed == [.bash])
        #expect(codex.inUse?.isInUse(codex.accounts[1]) == true)
        #expect(sessions.waiting == nil)
    }

    @Test
    func `adding the lines by hand makes the choice and hands over the lines`() {
        let codex = codex()
        let sessions = NewSessions(products: [codex], shellLines: lines, shell: .zsh)
        sessions.use(codex.accounts[1])

        let copied = sessions.setUpByHand()

        #expect(copied == "# lines for zsh")
        #expect(codex.inUse?.isInUse(codex.accounts[1]) == true)
    }

    @Test
    func `cancelling leaves the login in use as it was`() {
        let codex = codex()
        let sessions = NewSessions(products: [codex], shellLines: lines, shell: .zsh)
        sessions.use(codex.accounts[1])

        sessions.cancel()

        #expect(codex.inUse?.isInUse(codex.defaultAccount) == true)
        #expect(sessions.waiting == nil)
    }

    @Test
    func `the plain login never waits for the lines`() {
        lines.installed = [.zsh]
        let codex = codex()
        let sessions = NewSessions(products: [codex], shellLines: lines, shell: .zsh)
        sessions.use(codex.accounts[1])
        lines.installed = []

        sessions.use(codex.defaultAccount)

        #expect(codex.inUse?.isInUse(codex.defaultAccount) == true)
        #expect(sessions.waiting == nil)
    }

    @Test
    func `turning off takes the lines out and every CLI back to its plain login`() {
        lines.installed = [.zsh]
        let codex = codex()
        let sessions = NewSessions(products: [codex], shellLines: lines, shell: .zsh)
        sessions.use(codex.accounts[1])

        sessions.turnOff()

        #expect(!sessions.isSetUp)
        #expect(lines.installed.isEmpty)
        #expect(codex.inUse?.isInUse(codex.defaultAccount) == true)
    }

    @Test
    func `a setup that can't write says so, and keeps the choice waiting`() {
        lines.failing = true
        let codex = codex()
        let sessions = NewSessions(products: [codex], shellLines: lines, shell: .zsh)
        sessions.use(codex.accounts[1])

        sessions.setUp()

        #expect(sessions.problem?.contains("/Users/you/.zshrc") == true)
        #expect(sessions.isWaiting(in: codex))
    }

    // MARK: - What the strip shows

    @Test
    func `the strip shows the login in use`() {
        let codex = codex()
        let sessions = NewSessions(products: [codex], shellLines: lines, shell: .zsh)

        #expect(sessions.state(of: codex) == .using(codex.defaultAccount))
    }

    @Test
    func `while a choice waits, the strip shows the setup`() {
        let codex = codex()
        let sessions = NewSessions(products: [codex], shellLines: lines, shell: .zsh)
        sessions.use(codex.accounts[1])

        #expect(sessions.state(of: codex) == .waitingForSetup)
    }

    @Test
    func `a product with one login shows nothing`() throws {
        let settings = JSONSettingsRepository(store: JSONSettingsStore(fileURL: temp.appendingPathComponent("one.json")))
        let alone = try ProviderFactory.make("codex", settings: settings,
                                       loginsInUse: DiskLoginsInUse(root: temp.appendingPathComponent("in-use")))
        let sessions = NewSessions(products: [alone], shellLines: lines, shell: .zsh)

        #expect(sessions.state(of: alone) == nil)
    }

    @Test
    func `each CLI is named once, however many products run it`() {
        let sessions = NewSessions(products: [codex(), codex()], shellLines: lines, shell: .zsh)

        #expect(sessions.commands == ["codex"])
    }

    // MARK: - claudebar://use

    @Test
    func `a link names a login by its product and name`() {
        lines.installed = [.zsh]
        let codex = codex()
        let sessions = NewSessions(products: [codex], shellLines: lines, shell: .zsh)

        #expect(sessions.use(providerId: "codex", account: "work") == .used)
        #expect(codex.inUse?.isInUse(codex.accounts[1]) == true)
    }

    @Test
    func `a link before the setup waits for it`() {
        let codex = codex()
        let sessions = NewSessions(products: [codex], shellLines: lines, shell: .zsh)

        #expect(sessions.use(providerId: "codex", account: "work") == .waitingForSetup)
    }

    @Test
    func `a link to no such product or login does nothing`() {
        let codex = codex()
        let sessions = NewSessions(products: [codex], shellLines: lines, shell: .zsh)

        #expect(sessions.use(providerId: "gemini", account: "work") == .unknown)
        #expect(sessions.use(providerId: "codex", account: "someone") == .unknown)
        #expect(codex.inUse?.isInUse(codex.defaultAccount) == true)
    }

    // MARK: - The alert a notice becomes

    @Test
    func `a switch's alert links back to where sessions were; a suggestion's links on`() {
        let codex = codex()
        let (me, work) = (codex.defaultAccount, codex.accounts[1])

        let switched = InUseAlert(.switched(from: me, to: work), of: codex)
        let suggested = InUseAlert(.worthSwitching(from: me, to: work), of: codex)

        #expect(switched.kind == .switched && switched.to == "work")
        #expect(switched.link.absoluteString == "claudebar://use?provider=codex&account=default")
        #expect(suggested.kind == .worthSwitching)
        #expect(suggested.link.absoluteString == "claudebar://use?provider=codex&account=work")
    }

    @Test
    func `only products whose new sessions can be chosen are listed`() throws {
        let settings = JSONSettingsRepository(store: JSONSettingsStore(fileURL: temp.appendingPathComponent("s.json")))
        let gemini = try ProviderFactory.make("gemini", settings: settings)
        let codex = codex()

        let sessions = NewSessions(products: [gemini, codex], shellLines: lines, shell: .zsh)

        #expect(sessions.products.map(\.id) == ["codex"])
        #expect(sessions.product("codex") === codex)
        #expect(sessions.product("gemini") == nil)
    }
}

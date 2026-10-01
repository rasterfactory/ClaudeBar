import Foundation
import Testing
@testable import Infrastructure

@Suite @MainActor
struct BrowserAccountLoginTests {
    @Test func `missing executable gives recovery before creating a folder`() async throws {
        let home = temporaryHome()
        let login = BrowserAccountLogin(locate: { nil })
        await #expect(throws: BrowserAccountLogin.Failure.executableMissing) {
            try await login.signIn(home: home)
        }
        #expect(!FileManager.default.fileExists(atPath: home.path))
    }

    @Test func `login isolates credentials and uses arguments without a shell`() async throws {
        let home = temporaryHome()
        defer { try? FileManager.default.removeItem(at: home.deletingLastPathComponent()) }
        let process = StubLoginProcess()
        let login = BrowserAccountLogin(locate: { "/App With Spaces/codex" }, makeProcess: { process })
        try await login.signIn(home: home)
        #expect(process.executable == "/App With Spaces/codex")
        #expect(process.arguments == ["-c", "cli_auth_credentials_store=\"file\"", "login"])
        #expect(process.environment["CODEX_HOME"] == home.path)
        let attributes = try FileManager.default.attributesOfItem(atPath: home.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    }

    @Test func `unsuccessful login gives a safe error`() async throws {
        let home = temporaryHome()
        defer { try? FileManager.default.removeItem(at: home.deletingLastPathComponent()) }
        let process = StubLoginProcess(status: 1)
        let login = BrowserAccountLogin(locate: { "/codex" }, makeProcess: { process })
        await #expect(throws: BrowserAccountLogin.Failure.loginFailed) {
            try await login.signIn(home: home)
        }
    }

    @Test func `cancellation stops the login process`() async throws {
        let home = temporaryHome()
        defer { try? FileManager.default.removeItem(at: home.deletingLastPathComponent()) }
        let process = StubLoginProcess(running: true)
        let login = BrowserAccountLogin(locate: { "/codex" }, makeProcess: { process })
        let task = Task { try await login.signIn(home: home) }
        while process.executable == nil { await Task.yield() }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!process.isRunning)
    }

    @Test func `timeout stops the login and allows retry`() async throws {
        let home = temporaryHome()
        defer { try? FileManager.default.removeItem(at: home.deletingLastPathComponent()) }
        let process = StubLoginProcess(running: true)
        let login = BrowserAccountLogin(locate: { "/codex" }, makeProcess: { process }, timeout: 0)
        await #expect(throws: BrowserAccountLogin.Failure.timedOut) {
            try await login.signIn(home: home)
        }
        #expect(!process.isRunning)
    }

    private func temporaryHome() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("account with spaces")
    }
}

@MainActor private final class StubLoginProcess: BrowserLoginProcess {
    var executable: String?
    var arguments: [String] = []
    var environment: [String: String] = [:]
    var isRunning: Bool
    var terminationStatus: Int32
    init(status: Int32 = 0, running: Bool = false) {
        terminationStatus = status
        isRunning = running
    }
    func start(executable: String, arguments: [String], environment: [String: String], directory: URL) throws {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
    }
    func terminate() { isRunning = false }
}

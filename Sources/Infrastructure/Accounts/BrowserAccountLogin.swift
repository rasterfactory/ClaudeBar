import Foundation
import Mockable

/// Owns a browser-login subprocess, not the user's default CLI session.
/// Output is deliberately discarded: authentication diagnostics can contain secrets.
@Mockable @MainActor
public protocol BrowserLoginProcess {
    var isRunning: Bool { get }
    var terminationStatus: Int32 { get }
    func start(executable: String, arguments: [String], environment: [String: String], directory: URL) throws
    func terminate()
}

public struct BrowserAccountLogin: Sendable {
    public enum Failure: Error, LocalizedError {
        case executableMissing, loginFailed, timedOut
        public var errorDescription: String? {
            switch self {
            case .executableMissing:
                "Codex wasn’t found. Install the Codex CLI or desktop app, then try again. You can also choose an existing signed-in folder."
            case .loginFailed:
                "Sign-in didn’t finish. Try again and complete the sign-in in your browser."
            case .timedOut:
                "Sign-in timed out. Try again and complete the sign-in within five minutes."
            }
        }
    }

    private let locate: @Sendable () -> String?
    private let makeProcess: @MainActor @Sendable () -> any BrowserLoginProcess
    private let timeout: TimeInterval

    public init(
        locate: @escaping @Sendable () -> String?,
        makeProcess: @escaping @MainActor @Sendable () -> any BrowserLoginProcess = { FoundationBrowserLoginProcess() },
        timeout: TimeInterval = 300
    ) {
        self.locate = locate
        self.makeProcess = makeProcess
        self.timeout = timeout
    }

    @MainActor public func signIn(home: URL) async throws {
        // Shell discovery may block; keep it off the UI actor.
        let executable = await Task.detached { locate() }.value
        try Task.checkCancellation()
        guard let executable else { throw Failure.executableMissing }
        let fm = FileManager.default
        try fm.createDirectory(at: home.deletingLastPathComponent(), withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        // Never reuse or overwrite a desktop login, or a previous attempt.
        guard !fm.fileExists(atPath: home.path) else { throw Failure.loginFailed }
        try fm.createDirectory(at: home, withIntermediateDirectories: false,
                               attributes: [.posixPermissions: 0o700])
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_HOME"] = home.path
        // Inherited keys or tokens must not select another authentication mode.
        environment.removeValue(forKey: "OPENAI_API_KEY")
        environment.removeValue(forKey: "CODEX_API_KEY")
        environment.removeValue(forKey: "CODEX_AUTH_TOKEN")
        environment.removeValue(forKey: "OPENAI_ACCESS_TOKEN")
        environment.removeValue(forKey: "OPENAI_IDENTITY_TOKEN_FILE")
        environment.removeValue(forKey: "OPENAI_IDENTITY_PROVIDER_ID")
        let process = makeProcess()
        defer { if process.isRunning { process.terminate() } }
        try process.start(executable: executable,
                          arguments: ["-c", "cli_auth_credentials_store=\"file\"", "login"],
                          environment: environment, directory: home)
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning {
            try Task.checkCancellation()
            guard Date() < deadline else { throw Failure.timedOut }
            try await Task.sleep(for: .milliseconds(100))
        }
        try Task.checkCancellation()
        guard process.terminationStatus == 0 else { throw Failure.loginFailed }
    }
}

@MainActor public final class FoundationBrowserLoginProcess: BrowserLoginProcess {
    private let process = Process()
    public init() {}
    public var isRunning: Bool { process.isRunning }
    public var terminationStatus: Int32 { process.terminationStatus }
    public func start(executable: String, arguments: [String], environment: [String: String], directory: URL) throws {
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = directory
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }
    public func terminate() { process.terminate() }
}

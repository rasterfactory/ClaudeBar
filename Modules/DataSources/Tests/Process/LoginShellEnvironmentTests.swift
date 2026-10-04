import Testing
import Foundation
import Mockable
@testable import DataSources
import Quotas

@Suite("LoginShellEnvironment Tests")
struct LoginShellEnvironmentTests {

    // MARK: - Test Helpers

    private func makeExecutor(output: String, exitCode: Int32 = 0) -> MockCLIExecutor {
        let mock = MockCLIExecutor()
        given(mock).execute(
            binary: .any,
            args: .any,
            input: .any,
            timeout: .any,
            workingDirectory: .any,
            autoResponses: .any
        ).willReturn(CLIResult(output: output, exitCode: exitCode))
        return mock
    }

    // MARK: - Name Validation

    @Test
    func `should accept conventional environment variable names`() {
        #expect(LoginShellEnvironment.isValidName("GLM_AUTH_TOKEN"))
        #expect(LoginShellEnvironment.isValidName("_PRIVATE"))
        #expect(LoginShellEnvironment.isValidName("z"))
    }

    @Test
    func `should refuse a variable name that could break out of the shell command`() {
        #expect(!LoginShellEnvironment.isValidName(""))
        #expect(!LoginShellEnvironment.isValidName("9TOKEN"))
        #expect(!LoginShellEnvironment.isValidName("GLM;rm -rf /"))
        #expect(!LoginShellEnvironment.isValidName("GLM TOKEN"))
        #expect(!LoginShellEnvironment.isValidName("GLM$(touch /tmp/pwned)"))
        #expect(!LoginShellEnvironment.isValidName("GLM`id`"))
        #expect(!LoginShellEnvironment.isValidName("GLM_TOKÉN"))
        #expect(!LoginShellEnvironment.isValidName("TOKEN٣"))
    }

    // MARK: - Value Resolution

    private func markerWrapped(_ value: String) -> String {
        "\(LoginShellEnvironment.beginMarker)\(value)\(LoginShellEnvironment.endMarker)\n"
    }

    @Test
    func `should find the key the user's shell profile exports`() async {
        let shell = LoginShellEnvironment(cliExecutor: makeExecutor(output: markerWrapped("shell-token")))
        #expect(await shell.value(ofEnvVar: "GLM_TOKEN") == "shell-token")
    }

    @Test
    func `should find no key when the shell profile exports it empty`() async {
        let shell = LoginShellEnvironment(cliExecutor: makeExecutor(output: markerWrapped("")))
        #expect(await shell.value(ofEnvVar: "GLM_TOKEN") == nil)
    }

    @Test
    func `should find no key when the login shell fails`() async {
        let shell = LoginShellEnvironment(
            cliExecutor: makeExecutor(output: markerWrapped("partial"), exitCode: 1)
        )
        #expect(await shell.value(ofEnvVar: "GLM_TOKEN") == nil)
    }

    @Test
    func `should find no key when the login shell cannot be started`() async {
        let mock = MockCLIExecutor()
        given(mock).execute(
            binary: .any,
            args: .any,
            input: .any,
            timeout: .any,
            workingDirectory: .any,
            autoResponses: .any
        ).willThrow(UsageError.executionFailed("shell failed"))
        let shell = LoginShellEnvironment(cliExecutor: mock)
        #expect(await shell.value(ofEnvVar: "GLM_TOKEN") == nil)
    }

    @Test
    func `should never ask the shell for a variable whose name is unsafe`() async {
        let shell = LoginShellEnvironment(cliExecutor: makeExecutor(output: "shell-token"))
        #expect(await shell.value(ofEnvVar: "GLM_TOKEN; rm -rf /") == nil)
    }

    @Test
    func `should find the key without the whitespace around it`() async {
        let shell = LoginShellEnvironment(cliExecutor: makeExecutor(output: markerWrapped("  shell-token  ")))
        #expect(await shell.value(ofEnvVar: "GLM_TOKEN") == "shell-token")
    }

    @Test
    func `should find the key when the shell profile prints a greeting first`() async {
        let output = "Welcome to zsh\n" + markerWrapped("shell-token")
        let shell = LoginShellEnvironment(cliExecutor: makeExecutor(output: output))
        #expect(await shell.value(ofEnvVar: "GLM_TOKEN") == "shell-token")
    }

    @Test
    func `should find no key when the variable is unset and the shell profile prints a greeting`() async {
        let output = "Welcome to zsh\n" + markerWrapped("")
        let shell = LoginShellEnvironment(cliExecutor: makeExecutor(output: output))
        #expect(await shell.value(ofEnvVar: "GLM_TOKEN") == nil)
    }

    @Test
    func `should find no key when the shell's answer is not the one ClaudeBar asked for`() async {
        let shell = LoginShellEnvironment(cliExecutor: makeExecutor(output: "shell-token\n"))
        #expect(await shell.value(ofEnvVar: "GLM_TOKEN") == nil)
    }

    @Test
    func `should find the key only an interactive login shell exports`() async {
        let mock = MockCLIExecutor()
        given(mock).execute(
            binary: .any,
            args: .matching { args in
                args.contains("-i") && args.contains { $0.contains("\"$GLM_TOKEN\"") }
            },
            input: .any,
            timeout: .any,
            workingDirectory: .any,
            autoResponses: .any
        ).willReturn(CLIResult(output: markerWrapped("shell-token"), exitCode: 0))

        let shell = LoginShellEnvironment(cliExecutor: mock)
        #expect(await shell.value(ofEnvVar: "GLM_TOKEN") == "shell-token")
    }
}

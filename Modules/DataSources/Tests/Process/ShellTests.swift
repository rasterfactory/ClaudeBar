import Foundation
import Testing
@testable import DataSources

@Suite
struct ShellTests {

    // MARK: - Detection Tests

    @Test
    func `should recognise nushell from its path`() {
        #expect(Shell.detect(from: "/opt/homebrew/bin/nu") == .nushell)
        #expect(Shell.detect(from: "/usr/local/bin/nushell") == .nushell)
        #expect(Shell.detect(from: "/home/user/.nix-profile/bin/nu") == .nushell)
    }

    @Test
    func `should recognise nushell whatever the case of its name`() {
        #expect(Shell.detect(from: "/bin/Nu") == .nushell)
        #expect(Shell.detect(from: "/bin/NUSHELL") == .nushell)
    }

    @Test
    func `should recognise fish from its path`() {
        #expect(Shell.detect(from: "/opt/homebrew/bin/fish") == .fish)
        #expect(Shell.detect(from: "/usr/local/bin/fish") == .fish)
        #expect(Shell.detect(from: "/usr/bin/fish") == .fish)
    }

    @Test
    func `should treat zsh, bash and sh as POSIX shells`() {
        #expect(Shell.detect(from: "/bin/zsh") == .posix)
        #expect(Shell.detect(from: "/bin/bash") == .posix)
        #expect(Shell.detect(from: "/bin/sh") == .posix)
        #expect(Shell.detect(from: "/usr/local/bin/zsh") == .posix)
        #expect(Shell.detect(from: "/opt/homebrew/bin/bash") == .posix)
    }

    @Test
    func `should treat a shell it does not know as POSIX`() {
        #expect(Shell.detect(from: "/some/unknown/shell") == .posix)
        #expect(Shell.detect(from: "/bin/ksh") == .posix)
        #expect(Shell.detect(from: "/bin/dash") == .posix)
    }

    // MARK: - Command Generation Tests

    @Test
    func `should ask a POSIX login shell where a CLI lives with which`() {
        let args = Shell.posix.whichArguments(for: "claude")
        #expect(args == ["-l", "-c", "which claude"])
    }

    @Test
    func `should ask fish where a CLI lives with which`() {
        let args = Shell.fish.whichArguments(for: "codex")
        #expect(args == ["-l", "-c", "which codex"])
    }

    @Test
    func `should ask nushell where a CLI lives with the external which`() {
        let args = Shell.nushell.whichArguments(for: "claude")
        #expect(args == ["-l", "-c", "^which claude"])
    }

    @Test
    func `should look up a CLI whose name has dots and hyphens`() {
        let args = Shell.posix.whichArguments(for: "my-tool.sh")
        #expect(args == ["-l", "-c", "which my-tool.sh"])
    }

    @Test
    func `should look up nothing when a CLI name holds shell metacharacters`() {
        let args1 = Shell.posix.whichArguments(for: "claude; rm -rf /")
        #expect(args1 == ["-l", "-c", "which ''"])

        let args2 = Shell.posix.whichArguments(for: "$(whoami)")
        #expect(args2 == ["-l", "-c", "which ''"])

        let args3 = Shell.posix.whichArguments(for: "`id`")
        #expect(args3 == ["-l", "-c", "which ''"])

        let args4 = Shell.posix.whichArguments(for: "tool'injection")
        #expect(args4 == ["-l", "-c", "which ''"])

        let args5 = Shell.posix.whichArguments(for: "tool with spaces")
        #expect(args5 == ["-l", "-c", "which ''"])

        let args6 = Shell.nushell.whichArguments(for: "claude; rm -rf /")
        #expect(args6 == ["-l", "-c", "which ''"])
    }

    @Test
    func `should ask a POSIX login shell for its PATH`() {
        let args = Shell.posix.pathArguments()
        #expect(args == ["-l", "-c", "echo $PATH"])
    }

    @Test
    func `should ask fish for its PATH`() {
        let args = Shell.fish.pathArguments()
        #expect(args == ["-l", "-c", "echo $PATH"])
    }

    @Test
    func `should ask nushell for its PATH joined with colons`() {
        let args = Shell.nushell.pathArguments()
        #expect(args == ["-l", "-c", "$env.PATH | str join ':'"])
    }

    // MARK: - Output Parsing Tests

    @Test
    func `should find the CLI where a POSIX shell says it lives`() {
        let output = "/usr/local/bin/claude\n"
        #expect(Shell.posix.parseWhichOutput(output) == "/usr/local/bin/claude")
    }

    @Test
    func `should find the CLI when a POSIX shell pads its path with whitespace`() {
        let output = "  /usr/local/bin/claude  \n"
        #expect(Shell.posix.parseWhichOutput(output) == "/usr/local/bin/claude")
    }

    @Test
    func `should find no CLI when a POSIX shell prints nothing`() {
        #expect(Shell.posix.parseWhichOutput("") == nil)
        #expect(Shell.posix.parseWhichOutput("   \n") == nil)
    }

    @Test
    func `should find the CLI where fish says it lives`() {
        let output = "/opt/homebrew/bin/gemini\n"
        #expect(Shell.fish.parseWhichOutput(output) == "/opt/homebrew/bin/gemini")
    }

    @Test
    func `should find the CLI where nushell says it lives`() {
        let output = "/Users/user/.local/bin/claude\n"
        #expect(Shell.nushell.parseWhichOutput(output) == "/Users/user/.local/bin/claude")
    }

    @Test
    func `should find no CLI when nushell prints a table instead of a path`() {
        let tableOutput = """
        ╭───┬─────────┬─────────────────────────────────────────────────────┬──────────╮
        │ # │ command │                        path                         │   type   │
        ├───┼─────────┼─────────────────────────────────────────────────────┼──────────┤
        │ 0 │ claude  │ /Users/user/.local/bin/claude                       │ external │
        ╰───┴─────────┴─────────────────────────────────────────────────────┴──────────╯
        """
        #expect(Shell.nushell.parseWhichOutput(tableOutput) == nil)
    }

    @Test
    func `should find no CLI when nushell prints part of a table`() {
        #expect(Shell.nushell.parseWhichOutput("│ some output") == nil)
        #expect(Shell.nushell.parseWhichOutput("╭───") == nil)
        #expect(Shell.nushell.parseWhichOutput("╰───╯") == nil)
    }

    @Test
    func `should find no CLI when the answer holds any table box-drawing character`() {
        #expect(Shell.nushell.parseWhichOutput("╮───") == nil)
        #expect(Shell.nushell.parseWhichOutput("╯───") == nil)
        #expect(Shell.nushell.parseWhichOutput("path─with─box") == nil)
        #expect(Shell.nushell.parseWhichOutput("├──┼──┤") == nil)
        #expect(Shell.nushell.parseWhichOutput("─┬─") == nil)
        #expect(Shell.nushell.parseWhichOutput("─┴─") == nil)
        #expect(Shell.nushell.parseWhichOutput("┌──┐") == nil)
        #expect(Shell.nushell.parseWhichOutput("└──┘") == nil)
    }

    @Test
    func `should read the login shell's PATH without the whitespace around it`() {
        let output = "  /usr/bin:/bin:/usr/local/bin  \n"
        #expect(Shell.posix.parsePathOutput(output) == "/usr/bin:/bin:/usr/local/bin")
        #expect(Shell.nushell.parsePathOutput(output) == "/usr/bin:/bin:/usr/local/bin")
    }

    // MARK: - Shell.current Tests

    @Test
    func `should use the shell the SHELL environment variable names`() {
        let current = Shell.current
        let shellPath = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let expected = Shell.detect(from: shellPath)
        #expect(current == expected)
    }
}

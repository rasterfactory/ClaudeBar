import Foundation
import Testing
@testable import DataSources

/// Each fetch case answers for itself: where it may send a key, what it runs.
@Suite
struct ConnectionTests {
    @Test
    func `should name the URL an HTTP fetch reaches and run no command`() {
        let fetch = Fetch.http(HTTPRequest(url: "https://acme.test/usage"))
        #expect(fetch.connection.urls == ["https://acme.test/usage"])
        #expect(fetch.connection.commands.isEmpty)
    }

    @Test
    func `should name the URL of every step in a multi-step HTTP fetch`() {
        let fetch = Fetch.httpSteps(HTTPSteps(steps: [
            HTTPStep(name: "a", request: HTTPRequest(url: "https://a.test")),
            HTTPStep(name: "b", request: HTTPRequest(url: "https://b.test")),
        ]))
        #expect(fetch.connection.urls == ["https://a.test", "https://b.test"])
    }

    @Test
    func `should name the command line that a piped command, a terminal CLI and JSON-RPC run`() {
        #expect(Fetch.command(CommandCall(cli: "acme", args: ["usage"])).connection.commands == [["acme", "usage"]])
        #expect(Fetch.cli(CLICall(cli: "acme", args: ["--tui"])).connection.commands == [["acme", "--tui"]])
        #expect(Fetch.jsonRpc(JSONRPCCall(cli: "acme", args: ["serve"], call: "usage")).connection.commands == [["acme", "serve"]])
    }

    @Test
    func `should run the CLI from the location found for it, leaving other CLIs and files alone`() {
        let fetch = Fetch.command(CommandCall(cli: "acme", args: ["usage"]))
        #expect(fetch.runningCLI("acme", at: "/opt/acme") == .command(CommandCall(cli: "/opt/acme", args: ["usage"])))
        #expect(fetch.runningCLI("other", at: "/opt/other") == fetch)
        #expect(Fetch.file(FileCall(path: "~/x")).runningCLI("acme", at: "/opt/acme") == .file(FileCall(path: "~/x")))
    }
}

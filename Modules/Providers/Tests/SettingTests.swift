import Foundation
import Testing
import DataSources
import Quotas
import Mockable
@testable import Providers

/// A setting's kind owns its rule; a choice's options carry their values.
@Suite
struct SettingTests {
    private func decode(_ json: String) throws -> Setting {
        try JSONDecoder().decode(Setting.self, from: Data(json.utf8))
    }

    private let region = """
    {"id":"region","label":"Region","scope":"account","default":"china",
     "kind":{"choice":[{"id":"china","label":"China","site":"acme.cn"},{"id":"international","label":"International","site":"acme.com"}]}}
    """

    @Test
    func `a choice's option fills the setting and every value it carries`() throws {
        let setting = try decode(region)
        #expect(setting.fills(for: "international") == ["region": "international", "region.site": "acme.com"])
    }

    @Test
    func `a blank is the default, and a choice without one takes its first option`() throws {
        #expect(try decode(region).value(from: "  ") == "china")
        let noDefault = try decode(#"{"id":"plan","label":"Plan","kind":{"choice":["pro","max"]}}"#)
        #expect(noDefault.value(from: nil) == "pro")
        #expect(noDefault.value(from: " max ") == "max")
    }

    @Test
    func `a secret fills nothing — a key reaches a fetch only by its lookup`() throws {
        let key = try decode(#"{"id":"apiKey","label":"API key","kind":"secret"}"#)
        #expect(key.fills(for: "sk-1").isEmpty)
    }

    @Test
    func `a secret with a default is refused`() {
        #expect(throws: DecodingError.self) {
            try decode(#"{"id":"apiKey","label":"API key","kind":"secret","default":"sk-0"}"#)
        }
    }

    @Test
    func `the form before kinds still decodes`() throws {
        #expect(try decode(#"{"id":"apiKey","label":"API key","secret":true}"#).kind == .secret)
        #expect(try decode(#"{"id":"region","label":"Region","choices":["a","b"]}"#).kind
            == .choice([Setting.Option(id: "a"), Setting.Option(id: "b")]))
    }

    @Test
    func `each kind checks its own value`() throws {
        let paths = FakePaths(folders: ["/Users/me/.acme-work"])
        #expect(try decode(region).check("mars", paths: paths) == "Choose a Region from the list.")
        #expect(try decode(region).check("china", paths: paths) == nil)
        let profile = try decode(#"{"id":"profile","label":"Profile","kind":{"text":{"pattern":"^[a-z]+$"}}}"#)
        #expect(profile.check("Work 1", paths: paths) == "Enter a valid Profile.")
        let folder = try decode(#"{"id":"home","label":"CLI data folder","kind":{"path":{"mustExist":true}}}"#)
        #expect(folder.check("relative/dir", paths: paths) == "Enter a full path for CLI data folder.")
        #expect(folder.check("/Users/me/missing", paths: paths) == "Choose an existing folder for CLI data folder.")
        #expect(folder.check("/Users/me/.acme-work", paths: paths) == nil)
        #expect(folder.check("", paths: paths) == "Fill in CLI data folder.")
    }

    @Test
    func `a path setting tells its own value among a login's values`() throws {
        let folder = try decode(#"{"id":"home","label":"Folder","scope":"account","kind":"path"}"#)
        #expect(folder.path(in: ["home": "/Users/me/work"]) == "/Users/me/work")
        #expect(try decode(region).path(in: ["region": "china"]) == nil)
    }

    @Test
    func `only a path can be the same place as another login's`() throws {
        let paths = FakePaths(folders: [], aliases: ["~/.acme": "/Users/me/.acme"])
        let folder = try decode(#"{"id":"home","label":"Folder","kind":"path"}"#)
        #expect(folder.isSamePlace("~/.acme", as: "/Users/me/.acme", paths: paths))
        #expect(try decode(region).isSamePlace("china", as: "china", paths: paths) == false)
    }

    @Test
    func `a setting round-trips as written`() throws {
        let setting = try decode(region)
        #expect(try JSONDecoder().decode(Setting.self, from: JSONEncoder().encode(setting)) == setting)
    }
}

/// The file system as a test needs it: these folders exist, and these
/// spellings are the same place.
struct FakePaths: PathChecking {
    var folders: Set<String>
    var aliases: [String: String] = [:]

    func isFolder(_ path: String) -> Bool { folders.contains(canonical(path)) }
    func canonical(_ path: String) -> String { aliases[path] ?? path }
}

@MainActor @Suite struct DefaultPathIsolationTests {
    struct Paths: PathChecking {
        func isFolder(_ path: String) -> Bool { true }
        func canonical(_ path: String) -> String {
            DataSources.expandPath(path, homeDirectory: URL(fileURLWithPath: "/Users/me"), environment: { _ in nil })
        }
    }
    private func provider(_ id: String, accounts: [ProviderAccountConfig] = []) throws -> Provider {
        Provider(definition: try Providers.builtIn(id), settings: InMemoryProviderSettings(), accounts: accounts,
            makeDataSource: { source, login in
                DataSources.make(source, providerId: login, cliExecutor: MockCLIExecutor(), network: MockNetworkClient(),
                    makeTransport: { _, _, _, _ in MockRPCTransport() }, environment: { _ in nil },
                    homeDirectory: URL(fileURLWithPath: "/Users/me"), now: { Date() })
            }, paths: Paths())
    }
    @Test(arguments: [("gemini", "home", "~"), ("kiro", "home", "~"), ("grok", "directory", "~/.grok"), ("kimi", "home", "~/.kimi")])
    func `an added login cannot reuse the provider default folder`(_ entry: (String, String, String)) throws {
        let account = try provider(entry.0)
        #expect(throws: UsageError.self) { try account.addAccount(filling: [entry.1: entry.2]) }
        #expect(account.accounts.count == 1)
    }
    @Test func `a saved tilde path is normalized when its account is restored`() throws {
        let owner = try provider("kiro", accounts: [ProviderAccountConfig(
            accountId: "work", label: "Work", probeConfig: ["home": "~/work"], madeBy: .form)])
        let account = try #require(owner.accounts.first { $0.accountId == "work" })
        #expect(account.values["home"] == "/Users/me/work")
    }
    @Test func `a path entered with a tilde is saved as the absolute folder the CLI needs`() throws {
        let owner = try provider("kiro")
        let account = try owner.addAccount(filling: ["home": "~/work"])
        #expect(account.values["home"] == "/Users/me/work")
    }
}

import Foundation
import Providers
import Quotas
import Testing

@MainActor @Suite struct AccountPathTests {
    private func make() throws -> Provider {
        let json = #"{"profile":{"id":"example","name":"Example"},"defaultDataSource":"file","dataSources":[{"kind":"file","fetch":{"file":{"path":"/tmp/example.json"}},"mapping":{"json":{"quotas":[]}}}],"accounts":{"form":[{"id":"home","label":"Home Folder","absolutePath":true}],"patch":{"file":{"fetch":{"file":{"path":"{{account.home}}/usage.json"}}}}}}"#
        let definition = try ProviderDefinition.parse(Data(json.utf8))
        return Providers.make(definition, settings: InMemoryProviderSettings())
    }
    @Test(arguments:["relative/path", "~/profile", "file:///tmp/profile"]) func `profile paths cannot silently resolve against the default home`(_ path: String) throws {
        let provider = try make()
        #expect(throws: UsageError.self) { try provider.addAccount(filling: ["home":path]) }
        #expect(provider.accounts.count == 1)
    }
    @Test func `absolute profile paths stay in the added account metadata`() throws {
        let provider = try make()
        let account = try provider.addAccount(filling: ["home":"/tmp/work profile"])
        #expect(account.values["home"] == "/tmp/work profile")
    }
}

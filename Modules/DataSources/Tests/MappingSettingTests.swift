import DataSources
import Foundation
import Mockable
import Quotas
import Testing

@Suite struct MappingSettingTests {
    final class Store: SettingStore, @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: JSONValue] = ["count": .number(3)]
        func value(_ name: String) -> JSONValue? { lock.withLock { values[name] } }
        func setValue(_ value: JSONValue?, for name: String) { lock.withLock { values[name] = value } }
    }
    private func make(_ store: Store, error: Bool = false) throws -> DataSource {
        let definition = try JSONDecoder().decode(DataSourceDefinition.self, from: Data("""
        {"kind":"api","settings":{"count":{"key":"count","writable":true},"readOnly":{"key":"readOnly"}},"fetch":{"http":{"url":"https://example.com"}},"mapping":{"script":{"file":"usage.js"}}}
        """.utf8))
        let network = MockNetworkClient()
        given(network).request(.any).willReturn((Data("{}".utf8), HTTPURLResponse(url: URL(string: "https://example.com")!, statusCode: 200, httpVersion: nil, headerFields: nil)!))
        return DataSources.make(definition, providerId: "test", cliExecutor: MockCLIExecutor(), network: network,
            makeTransport: { _,_,_,_ in MockRPCTransport() }, scripts: { _ in """
            function read(response, context) {
                return {settings:{count:context.settings.count+1,readOnly:99,undeclared:100},
                    \(error ? "error:{executionFailed:'Enter a value'}" : "quotas:[]")};
            }
            """ }, settings: store, environment: { _ in nil }, homeDirectory: FileManager.default.temporaryDirectory, now: { Date() })
    }
    @Test func `only declared writable settings are changed and each read sees current values`() async throws {
        let store = Store(), source = try make(store)
        _ = try await source.fetchUsage()
        _ = try await source.fetchUsage()
        #expect(store.value("count") == .number(5))
        #expect(store.value("readOnly") == nil)
        #expect(store.value("undeclared") == nil)
    }
    @Test func `preview does not write state`() throws {
        let store = Store()
        _ = try make(store).read(Response(text: "{}"))
        #expect(store.value("count") == .number(3))
    }
    @Test func `declared state updates survive a mapping error`() async throws {
        let store = Store(), source = try make(store, error: true)
        await #expect(throws: DataSourceError(.mapping, .executionFailed("Enter a value"))) { try await source.fetchUsage() }
        #expect(store.value("count") == .number(4))
    }
}

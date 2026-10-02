import Foundation
import Providers
import Testing

@MainActor @Suite struct BackgroundFloorTests {
    @Test func `a provider background floor survives binary overrides without caching manual refresh`() throws {
        let data = Data(#"{"profile":{"id":"example","name":"Example"},"cli":"example","backgroundRefreshSeconds":300,"defaultDataSource":"cli","dataSources":[{"kind":"cli","fetch":{"cli":{"cli":"example"}},"mapping":{"json":{"quotas":[]}}}]}"#.utf8)
        let definition = try ProviderDefinition.parse(data).runningCLI("/tmp/example")
        let provider = Providers.make(definition, settings:InMemoryProviderSettings())
        #expect(provider.backgroundRefreshFloor == .seconds(300))
        #expect(definition.dataSources.first?.cache == nil)
    }
}

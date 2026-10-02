import Foundation
import Quotas
import Testing
import Mockable
@testable import DataSources

@Suite struct FileAvailabilityTests {
    @Test func `a desktop source remains available when its file exists even before sign-in`() async throws {
        let file=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data().write(to:file)
        defer {try? FileManager.default.removeItem(at:file)}
        let json="{\"kind\":\"api\",\"availability\":\"files\",\"requiresFiles\":[\"\(file.path)\"],\"missingFilesError\":{\"cliNotFound\":\"Example desktop login\"},\"credential\":{\"environment\":\"ABSENT_TEST_TOKEN\"},\"fetch\":{\"http\":{\"url\":\"https://example.test\"}},\"mapping\":{\"json\":{\"quotas\":[]}}}"
        let definition=try JSONDecoder().decode(DataSourceDefinition.self,from:Data(json.utf8))
        let source=DataSources.make(definition,providerId:"example",cliExecutor:MockCLIExecutor(),network:MockNetworkClient(),makeTransport:{_,_,_,_ in MockRPCTransport()},environment:{_ in nil},homeDirectory:FileManager.default.temporaryDirectory,now:{Date()})
        #expect(await source.isReady())
        await #expect(throws:DataSourceError(.lookup,.authenticationRequired)) {try await source.fetchResponse()}
        try FileManager.default.removeItem(at:file)
        #expect(!(await source.isReady()))
        await #expect(throws:DataSourceError(.lookup,.cliNotFound("Example desktop login"))) {try await source.fetchResponse()}
    }
}

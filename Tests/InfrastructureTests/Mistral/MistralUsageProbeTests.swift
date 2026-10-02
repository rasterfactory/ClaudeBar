import DataSources
import Testing
import Foundation
import Mockable
@testable import Infrastructure
@testable import Domain

@Suite("MistralUsageProbe Tests")
struct MistralUsageProbeTests {

    private func makeTempSessionDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vibe-probe-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func cleanup(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - isAvailable Tests

    @Test func `isAvailable returns true when vibe sessions directory exists`() async {
        let tempDir = makeTempSessionDir()
        defer { cleanup(tempDir) }

        let probe = try! MistralDefinitionAnalyzer(vibeSessionsDir: tempDir).source()

        #expect(await probe.isReady() == true)
    }

    @Test func `isAvailable returns false when directory does not exist`() async {
        let nonExistentDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vibe-nonexistent-\(UUID().uuidString)")

        let probe = try! MistralDefinitionAnalyzer(vibeSessionsDir: nonExistentDir).source()

        #expect(await probe.isReady() == false)
    }

    // MARK: - probe Tests

    @Test func `probe returns UsageSnapshot with costUsage and dailyUsageReport`() async throws {
        let dir = makeTempSessionDir()
        defer { cleanup(dir) }
        let snapshot = try await MistralDefinitionAnalyzer(vibeSessionsDir: dir).source().fetchUsage()

        #expect(snapshot.providerId == "mistral")
        #expect(snapshot.quotas.isEmpty)
        #expect(snapshot.costUsage == nil)
        #expect(snapshot.dailyUsageReport != nil)
    }

    @Test func `probe throws when log analyzer throws`() async {
        let dir = makeTempSessionDir()
        defer { cleanup(dir) }
        let analyzer = MistralDefinitionAnalyzer(vibeSessionsDir: dir)
        await #expect(throws: UsageError.self) {
            do { _ = try await analyzer.source(reader: FailingDirectoryReader()).fetchUsage() }
            catch let error as DataSourceError { throw error.reason }
        }
    }
}

private struct FailingDirectoryReader: DirectoryReading {
    func read(_ root: URL, file: String, pattern: String) throws -> [DirectoryRecord] { throw UsageError.noData }
}

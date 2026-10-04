import Foundation
import Testing
@testable import DataSources

/// `freeWhen.localEndpoint`: a base URL on this Mac means nobody bills per
/// token. The first entry that answers decides.
@Suite
struct LocalEndpointTests {
    private static let url = [["$.env.BASE_URL"], ["$.routes[*].base_url", "$.routes[*].env.BASE_URL"]]

    private func isLocal(_ json: String?) throws -> Bool {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("config.json")
        if let json { try json.write(to: file, atomically: true, encoding: .utf8) }
        return LocalEndpoint(file: file.path, url: Self.url).isLocal()
    }

    @Test func `should count usage as billed when the config is missing or names no address`() throws {
        #expect(try isLocal(nil) == false)
        #expect(try isLocal(#"{"account":{"email":"a@b.c"}}"#) == false)
    }

    @Test func `should count usage as free when the tool's route points at this Mac`() throws {
        #expect(try isLocal(#"{"env":{"BASE_URL":"http://localhost:11434"}}"#))
        #expect(try isLocal(#"{"env":{"BASE_URL":"http://127.0.0.1:1234/v1"}}"#))
    }

    @Test func `should count usage as billed when the tool's route points at a paid gateway`() throws {
        #expect(try isLocal(#"{"env":{"BASE_URL":"https://gateway.example.com/api"}}"#) == false)
    }

    @Test func `should count usage as free when there is no route and any listed one points at this Mac`() throws {
        #expect(try isLocal(#"{"routes":[{"base_url":"https://api.example.com"},{"base_url":"http://127.0.0.1:8080"}]}"#))
        #expect(try isLocal(#"{"routes":[{"env":{"BASE_URL":"http://[::1]:11434"}}]}"#))
    }

    @Test func `should go by the tool's route over its list of others, either way`() throws {
        // The list is a menu the tool may switch between; the route is the one it takes.
        #expect(try isLocal(#"{"env":{"BASE_URL":"https://gateway.example.com"},"routes":[{"base_url":"http://localhost:11434"}]}"#) == false)
        #expect(try isLocal(#"{"env":{"BASE_URL":"http://127.0.0.1:11434"},"routes":[{"base_url":"https://api.example.com"}]}"#))
    }

    @Test(arguments: ["http://localhost:11434", "http://LOCALHOST:1234", "https://models.localhost/v1", "http://0.0.0.0:8000"])
    func `should recognise an address on this Mac`(url: String) {
        #expect(LocalEndpoint.isLoopback(url))
    }

    @Test(arguments: ["https://api.example.com", "http://192.168.1.10:11434", "https://my-localhost.example.com/v1", "not a url"])
    func `should not take another machine's address for this Mac`(url: String) {
        #expect(LocalEndpoint.isLoopback(url) == false)
    }
}

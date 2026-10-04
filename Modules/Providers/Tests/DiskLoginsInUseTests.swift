import Foundation
import Providers
import Testing

/// The *In use* record on disk: one file per provider, holding a folder, read
/// by the shell on every `claude` / `codex`.
@Suite
struct DiskLoginsInUseTests {
    private let root = FileManager.default.temporaryDirectory.appendingPathComponent("in-use-\(UUID().uuidString)", isDirectory: true)

    @Test
    func `should use the plain login when nothing is recorded in use`() {
        #expect(DiskLoginsInUse(root: root).folder(for: "claude") == nil)
    }

    @Test
    func `should record a chosen login's folder as a plain path the shell can read`() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let record = DiskLoginsInUse(root: root)

        try record.use(URL(fileURLWithPath: "/Users/you/.claude-work/"), for: "claude")

        #expect(try String(contentsOf: record.file(for: "claude"), encoding: .utf8) == "/Users/you/.claude-work")
        #expect(record.folder(for: "claude")?.path == "/Users/you/.claude-work")
    }

    @Test
    func `should leave an empty record when the person goes back to the plain login`() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let record = DiskLoginsInUse(root: root)
        try record.use(URL(fileURLWithPath: "/Users/you/.claude-work"), for: "claude")

        try record.use(nil, for: "claude")

        #expect(try String(contentsOf: record.file(for: "claude"), encoding: .utf8) == "")
        #expect(record.folder(for: "claude") == nil)
    }

    @Test
    func `should keep a separate in-use record for each provider`() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let record = DiskLoginsInUse(root: root)

        try record.use(URL(fileURLWithPath: "/tmp/codex-work"), for: "codex")

        #expect(record.folder(for: "codex")?.path == "/tmp/codex-work")
        #expect(record.folder(for: "claude") == nil)
    }
}

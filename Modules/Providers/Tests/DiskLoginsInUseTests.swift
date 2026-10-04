import Foundation
import Providers
import Testing

/// The *In use* record on disk: one file per provider, holding a folder, read
/// by the shell on every `claude` / `codex`.
@Suite
struct DiskLoginsInUseTests {
    private let root = FileManager.default.temporaryDirectory.appendingPathComponent("in-use-\(UUID().uuidString)", isDirectory: true)

    @Test
    func `nothing recorded is the plain login`() {
        #expect(DiskLoginsInUse(root: root).folder(for: "claude") == nil)
    }

    @Test
    func `a chosen folder is written as a plain path the shell can read`() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let record = DiskLoginsInUse(root: root)

        try record.use(URL(fileURLWithPath: "/Users/you/.claude-work/"), for: "claude")

        #expect(try String(contentsOf: record.file(for: "claude"), encoding: .utf8) == "/Users/you/.claude-work")
        #expect(record.folder(for: "claude")?.path == "/Users/you/.claude-work")
    }

    @Test
    func `going back to the plain login leaves an empty file`() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let record = DiskLoginsInUse(root: root)
        try record.use(URL(fileURLWithPath: "/Users/you/.claude-work"), for: "claude")

        try record.use(nil, for: "claude")

        #expect(try String(contentsOf: record.file(for: "claude"), encoding: .utf8) == "")
        #expect(record.folder(for: "claude") == nil)
    }

    @Test
    func `each provider has its own record`() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let record = DiskLoginsInUse(root: root)

        try record.use(URL(fileURLWithPath: "/tmp/codex-work"), for: "codex")

        #expect(record.folder(for: "codex")?.path == "/tmp/codex-work")
        #expect(record.folder(for: "claude") == nil)
    }
}

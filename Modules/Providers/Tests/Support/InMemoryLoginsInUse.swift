import Foundation
import Providers

/// The *In use* records kept in memory: what the shell would read after
/// switching, without touching `~/.claudebar`.
final class InMemoryLoginsInUse: LoginsInUse, @unchecked Sendable {
    private let lock = NSLock()
    private var folders: [String: URL] = [:]

    init(_ existing: [String: URL] = [:]) {
        folders = existing
    }

    func folder(for command: String) -> URL? {
        lock.withLock { folders[command] }
    }

    func use(_ folder: URL?, for command: String) throws {
        lock.withLock { folders[command] = folder?.standardizedFileURL }
    }
}

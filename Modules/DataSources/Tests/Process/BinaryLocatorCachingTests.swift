import Foundation
import Testing

@testable import DataSources

/// Covers the caching layer wired onto `BinaryLocator`. The lookup logic itself
/// is exercised by `SingleFlightCacheTests`; these confirm the wiring keeps the
/// public contract intact, since every provider depends on it each refresh.
/// Serialized: these share process-wide static caches, so a concurrent
/// `invalidateCaches()` from a sibling test would corrupt the measurements.
@Suite("BinaryLocator caching", .serialized)
struct BinaryLocatorCachingTests {

    @Test
    func `should find a CLI at the same runnable path every time it is looked up`() {
        // `sh` is guaranteed present on macOS and lives on the default PATH.
        let first = BinaryLocator.which("sh")
        let second = BinaryLocator.which("sh")

        #expect(first == second)
        if let first {
            #expect(FileManager.default.isExecutableFile(atPath: first))
        }
    }

    @Test
    func `should keep finding nothing for a CLI that isn't installed`() {
        let name = "claudebar-definitely-not-a-real-binary"

        #expect(BinaryLocator.which(name) == nil)
        #expect(BinaryLocator.which(name) == nil)
    }

    @Test
    func `should still find a CLI at the same path after the remembered paths are forgotten`() {
        let before = BinaryLocator.which("sh")

        BinaryLocator.invalidateCaches()

        let after = BinaryLocator.which("sh")
        #expect(before == after)
    }

    @Test
    func `should use a runnable full path as it is`() {
        // The shell `which` guard rejects '/', so absolute paths must be
        // short-circuited or every executor handed a resolved path fails.
        #expect(BinaryLocator.which("/bin/echo") == "/bin/echo")
    }

    @Test
    func `should find nothing at a full path that isn't runnable or isn't there`() {
        #expect(BinaryLocator.which("/etc/hosts") == nil)
        #expect(BinaryLocator.which("/bin/claudebar-not-here") == nil)
    }

    @Test
    func `should know the shell's search path, the same every time`() {
        let first = BinaryLocator.shellPath()
        let second = BinaryLocator.shellPath()

        #expect(!first.isEmpty)
        #expect(first == second)
    }

    @Test
    func `should start the login shell only once to learn its search path`() {
        BinaryLocator.invalidateCaches()

        // First call pays for a login-shell spawn; the cached call must not.
        let coldStart = CFAbsoluteTimeGetCurrent()
        _ = BinaryLocator.shellPath()
        let cold = CFAbsoluteTimeGetCurrent() - coldStart

        let warmStart = CFAbsoluteTimeGetCurrent()
        for _ in 0..<50 { _ = BinaryLocator.shellPath() }
        let warm = CFAbsoluteTimeGetCurrent() - warmStart

        // 50 cached reads should cost far less than one spawn. Deliberately a
        // loose bound — this asserts "no subprocess", not a latency budget.
        #expect(warm < max(cold, 0.001))
    }
}

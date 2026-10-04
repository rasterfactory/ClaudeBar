import Quotas
import Foundation
import Testing

@testable import DataSources

/// Guards the issue-#204 behaviour through the async `CLIExecutor` boundary.
///
/// `FetchContext.qualityOfService` is a task local, and task locals do
/// not survive a hop onto a plain thread or GCD queue. `DefaultCLIExecutor` now
/// makes exactly that hop to keep blocking PTY work off the cooperative pool, so
/// the QoS must be captured into `Options` beforehand — otherwise background
/// refreshes silently spawn at `.default` and the idle heat #204 fixed returns.
@Suite("Probe quality of service")
struct FetchQualityOfServiceTests {

    @Test
    func `should run a CLI at the priority of the refresh that asked for it (#204)`() async {
        await FetchContext.$qualityOfService.withValue(.utility) {
            let options = InteractiveRunner.Options()
            #expect(options.qualityOfService == .utility)
        }
    }

    @Test
    func `should run a CLI at default priority when no refresh set one`() {
        let options = InteractiveRunner.Options()
        #expect(options.qualityOfService == .default)
    }

    @Test
    func `should run a CLI at an explicitly given priority over the refresh's`() async {
        await FetchContext.$qualityOfService.withValue(.utility) {
            let options = InteractiveRunner.Options(qualityOfService: .userInitiated)
            #expect(options.qualityOfService == .userInitiated)
        }
    }

    @Test
    func `should keep a background refresh's low priority once the CLI work leaves the async pool (#204)`() async throws {
        // Reading the task local from the queue the executor dispatches to would
        // yield `.default`; reading the captured copy must still yield `.utility`.
        let captured: QualityOfService = await FetchContext.$qualityOfService
            .withValue(.utility) {
                let options = InteractiveRunner.Options()
                return await withCheckedContinuation { continuation in
                    DispatchQueue.global().async {
                        continuation.resume(returning: options.qualityOfService)
                    }
                }
            }

        #expect(captured == .utility)
    }

    @Test
    func `should lose a background refresh's priority if it were read only after leaving the async pool (#204)`() async {
        // Documents *why* the capture exists: this is the value the runner would
        // have read had it kept consulting the task local directly.
        let observed: QualityOfService = await FetchContext.$qualityOfService
            .withValue(.utility) {
                await withCheckedContinuation { continuation in
                    DispatchQueue.global().async {
                        continuation.resume(returning: FetchContext.qualityOfService)
                    }
                }
            }

        #expect(observed == .default)
    }
}

import Domain
import Foundation

/// A CLI invocation's explicit account scope, passed to the executor factory.
public struct AccountCommandContext: Sendable {
    public let environment: [String: String]
    public let exclusions: [String]
    public let directory: URL
    public let interactive: Bool

    public func executor() -> any CLIExecutor {
        if interactive {
            return DefaultCLIExecutor(environmentExclusions: exclusions, environmentAdditions: environment, isolatedDirectory: directory)
        }
        return SimpleCLIExecutor(environmentExclusions: exclusions, environmentAdditions: environment, isolatedDirectory: directory)
    }
}

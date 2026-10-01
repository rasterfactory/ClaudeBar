import Domain
import Foundation
import Providers

/// Keeps a legacy implementation behind the shared Provider account lifecycle.
@MainActor
public final class LegacyAccountUsageSource: AccountUsageSource {
    public let implementation: any AIProvider
    public init(_ implementation: any AIProvider) { self.implementation = implementation }
    public var dashboardURL: URL? { implementation.dashboardURL }
    public var backgroundRefreshFloor: Duration? { implementation.backgroundRefreshFloor }
    public func isAvailable() async -> Bool { await implementation.isAvailable() }
    public func refresh(_ kind: RefreshKind) async throws -> UsageSnapshot { try await implementation.refresh(kind) }
}

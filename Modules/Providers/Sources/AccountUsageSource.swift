import Foundation
import Mockable
import Quotas
import Foundation

/// Transitional port for a source not yet represented by a DataSource definition.
/// A separate instance belongs to each login; the Provider still owns its lifecycle.
@Mockable
@MainActor
public protocol AccountUsageSource: Sendable {
    var dashboardURL: URL? { get }
    var connectionIdentity: String? { get }
    var backgroundRefreshFloor: Duration? { get }
    func isAvailable() async -> Bool
    func refresh(_ kind: RefreshKind) async throws -> UsageSnapshot
}

public extension AccountUsageSource {
    var dashboardURL: URL? { nil }
    /// Stable authenticated identity when the source can report one.
    var connectionIdentity: String? { nil }
}

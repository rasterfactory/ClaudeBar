import Foundation
import Providers
import Quotas

/// Tests ask a product about its plain login, as the app asks it about any
/// login: a login never refers to its provider (TARGET §12, slice 7).
@MainActor
extension Provider {
    @discardableResult
    func refreshPlain(_ kind: RefreshKind = .interactive) async throws -> UsageSnapshot {
        try await refresh(defaultAccount, kind)
    }

    func isPlainAvailable() async -> Bool { await isAvailable(defaultAccount) }

    var plainDashboardURL: URL? { dashboardURL(of: defaultAccount) }

    var plainIsInLineup: Bool { isInLineup(defaultAccount) }
}

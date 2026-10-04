import Foundation
import Providers

/// A pill in the popover: one product, with every enabled login of it — so
/// three Claude logins are one *Claude* tab, side by side, not three tabs.
/// Its logins come in the order the person gave them.
@MainActor
public struct ProductTab: Identifiable {
    /// The product's id — `codex`, never `codex.<acct>`.
    public let id: String
    public let name: String
    /// The product.
    public let provider: Provider
    /// Its logins in the lineup, in the person's order.
    public let accounts: [Account]

    init(provider: Provider, accounts: [Account]) {
        self.id = provider.id
        self.name = provider.name
        self.provider = provider
        self.accounts = accounts
    }

    /// The product's own switch (TARGET §12).
    public var isEnabled: Bool { provider.isEnabled }

    /// A login's name on the product's row — only when there are several to
    /// tell apart; one login is just the product.
    public func loginName(_ login: Account) -> String? {
        accounts.count > 1 ? login.displayName : nil
    }

    /// What the product's page configures: its plain login, whose id the
    /// configuration is keyed by.
    public var page: Account { provider.defaultAccount }

    public func contains(_ lineupId: String) -> Bool {
        accounts.contains { $0.id == lineupId }
    }

    /// The lineup as tabs, in the order products first appear in it — each
    /// login's product found through the root.
    public static func tabs(of lineup: [Account], in providers: Providers) -> [ProductTab] {
        let shown = Set(lineup.map(\.id))
        var seen: Set<String> = []
        return lineup.compactMap { login in
            guard let product = providers.provider(of: login), seen.insert(product.id).inserted else { return nil }
            return ProductTab(provider: product, accounts: product.accounts.filter { shown.contains($0.id) })
        }
    }
}

import Foundation

/// Menu-bar identifiers stay within eight characters. Full addresses remain
/// in account details and tooltips; collisions never expand into full emails.
public enum CodexAccountLabel {
    public static func compact(_ email: String, among emails: [String]) -> String {
        let candidate = abbreviated(email)
        let collisions = Set((emails + [email]).filter { abbreviated($0) == candidate }).sorted()
        guard collisions.count > 1, let index = collisions.firstIndex(of: email) else { return candidate }
        return numbered(candidate, index: index)
    }

    public static func labels(for accounts: [String: String]) -> [String: String] {
        guard accounts.count > 1 else { return [:] }
        let ids = accounts.keys.sorted {
            let lhs = accounts[$0] ?? "", rhs = accounts[$1] ?? ""
            return lhs == rhs ? $0 < $1 : lhs < rhs
        }
        var result: [String: String] = [:]
        for id in ids {
            let candidate = abbreviated(accounts[id] ?? "")
            let collisions = ids.filter { abbreviated(accounts[$0] ?? "") == candidate }
            result[id] = collisions.count > 1
                ? numbered(candidate, index: collisions.firstIndex(of: id) ?? 0) : candidate
        }
        return result
    }

    private static func numbered(_ candidate: String, index: Int) -> String {
        let suffix = "·\(index + 1)"
        return String(candidate.prefix(max(1, 8 - suffix.count))) + suffix
    }

    private static func abbreviated(_ email: String) -> String {
        let local = String(email.split(separator: "@", maxSplits: 1).first ?? "")
        return local.count > 8 ? String(local.prefix(7)) + "…" : local
    }
}

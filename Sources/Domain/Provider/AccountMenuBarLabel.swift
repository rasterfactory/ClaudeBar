import Foundation

/// Short automatic identifiers and optional chosen names. Full names remain
/// in account details and tooltips; collisions never expand into full emails.
public enum AccountMenuBarLabel {
    public static func compact(_ email: String, among emails: [String]) -> String {
        let candidate = abbreviated(email)
        let collisions = Set((emails + [email]).filter { abbreviated($0) == candidate }).sorted()
        guard collisions.count > 1, let index = collisions.firstIndex(of: email) else { return candidate }
        return numbered(candidate, index: index)
    }

    public static func labels(for accounts: [String: String], customNames: [String: String] = [:]) -> [String: String] {
        guard accounts.count > 1 else { return [:] }
        let ids = accounts.keys.sorted {
            let lhs = accounts[$0] ?? "", rhs = accounts[$1] ?? ""
            return lhs == rhs ? $0 < $1 : lhs < rhs
        }
        var candidates: [String: String] = [:]
        var limits: [String: Int] = [:]
        for id in ids {
            let custom = customNames[id]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            limits[id] = custom.isEmpty ? 8 : 12
            candidates[id] = custom.isEmpty ? abbreviated(accounts[id] ?? "") : shortened(custom, limit: 12)
        }
        let reserved = Set(candidates.values)
        var used = Set<String>()
        var result: [String: String] = [:]
        for id in ids {
            let candidate = candidates[id] ?? "Account"
            let collisions = ids.filter { candidates[$0] == candidate }
            var label = candidate
            if collisions.count > 1 || used.contains(label) {
                var index = collisions.firstIndex(of: id) ?? 0
                repeat {
                    label = numbered(candidate, index: index, limit: limits[id] ?? 8)
                    index += 1
                } while reserved.contains(label) || used.contains(label)
            }
            used.insert(label)
            result[id] = label
        }
        return result
    }

    private static func numbered(_ candidate: String, index: Int, limit: Int = 8) -> String {
        let suffix = "·\(index + 1)"
        return String(candidate.prefix(max(1, limit - suffix.count))) + suffix
    }

    private static func shortened(_ name: String, limit: Int) -> String {
        name.count > limit ? String(name.prefix(limit - 1)) + "…" : name
    }

    private static func abbreviated(_ email: String) -> String {
        let local = String(email.split(separator: "@", maxSplits: 1).first ?? "")
        return local.count > 8 ? String(local.prefix(7)) + "…" : local
    }
}

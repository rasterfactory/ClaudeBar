import Foundation
import Quotas

/// `usage` — ClaudeBar's own documented output, read as extensions always
/// were: a quota's `type` says its kind, its window is the kind's
/// conventional one, and `costUsage` is money spent against a budget.
struct UsageMapper: Reading {
    let now: @Sendable () -> Date

    func read(_ response: Response, facts: MappingFacts, providerId: String) throws -> UsageSnapshot {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let output = try? decoder.decode(Output.self, from: response.body) else {
            throw UsageError.parseFailed("Output is not ClaudeBar's usage JSON")
        }
        guard output.quotas != nil || output.costUsage != nil else {
            throw UsageError.parseFailed("Output has neither quotas nor costUsage")
        }
        return UsageSnapshot(
            providerId: providerId,
            quotas: (output.quotas ?? []).map { $0.quota(providerId: providerId) },
            capturedAt: now(),
            costUsage: output.costUsage?.cost(providerId: providerId)
        )
    }

    private struct Output: Decodable {
        let quotas: [Quota]?
        let costUsage: Cost?
    }

    private struct Quota: Decodable {
        let type: String
        let percentRemaining: Double
        let resetsAt: Date?
        let resetText: String?
        let dollarRemaining: Double?

        func quota(providerId: String) -> UsageQuota {
            let kind: QuotaType = switch type {
            case "session": .session
            case "weekly": .weekly
            case let name where name.hasPrefix("model:"): .modelSpecific(String(name.dropFirst(6)))
            default: .timeLimit(type)
            }
            return UsageQuota(percentRemaining: percentRemaining, quotaType: kind, providerId: providerId,
                              resetsAt: resetsAt, resetText: resetText, windowDuration: kind.conventionalWindow.seconds,
                              dollarRemaining: dollarRemaining.map { Decimal($0) })
        }
    }

    private struct Cost: Decodable {
        let totalCost: Double
        let budget: Double?
        let apiDuration: TimeInterval
        let wallDuration: TimeInterval?
        let linesAdded: Int?
        let linesRemoved: Int?

        func cost(providerId: String) -> CostUsage {
            CostUsage(totalCost: Decimal(totalCost), budget: budget.map { Decimal($0) }, apiDuration: apiDuration,
                      wallDuration: wallDuration ?? 0, linesAdded: linesAdded ?? 0, linesRemoved: linesRemoved ?? 0,
                      providerId: providerId)
        }
    }
}

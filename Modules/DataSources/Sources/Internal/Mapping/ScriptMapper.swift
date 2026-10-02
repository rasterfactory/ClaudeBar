import Diagnostics
import Quotas
import Foundation
import JavaScriptCore

/// `script` — reads a response with a JavaScript file in JavaScriptCore.
///
/// The script defines `read(response, context)`:
///
/// - `response` — `{ status, headers, text, json }` (`json` is the parsed body, or `null`)
/// - `context` — `{ now, timeZone, credential, ...files }`: epoch seconds, the
///   current zone's identifier, the credential values the definition lets it
///   see, and each declared context file's fields
///
/// and returns `{ quotas, plan, cost, account }` or `{ error }`. It may call
/// `humanDate(text)` for an epoch-seconds reset time, or `null`.
///
/// The context has no file, network or process access: the script turns text
/// into numbers and nothing else.
struct ScriptMapper: Reading {
    let file: String
    let source: String?
    let now: @Sendable () -> Date

    func read(_ response: Response, facts: MappingFacts, providerId: String) throws -> UsageSnapshot {
        guard let source else {
            throw UsageError.parseFailed("Mapping script '\(file)' is missing")
        }
        guard let context = JSContext() else {
            throw UsageError.executionFailed("JavaScriptCore is unavailable")
        }

        var exception: String?
        context.exceptionHandler = { _, value in
            exception = value?.toString()
        }

        let clock = now
        let humanDate: @convention(block) (String) -> Any = { text in
            HumanDate.parse(text, now: clock()).map { $0.timeIntervalSince1970 } ?? NSNull()
        }
        context.setObject(humanDate, forKeyedSubscript: "humanDate" as NSString)
        context.setObject(try Self.inputJSON(response, facts: facts, now: now()), forKeyedSubscript: "__input" as NSString)

        context.evaluateScript(source)
        if let exception {
            throw UsageError.parseFailed("Mapping script '\(file)' failed to load: \(exception)")
        }

        let output = context.evaluateScript("JSON.stringify(read(JSON.parse(__input).response, JSON.parse(__input).context))")
        if let exception {
            AppLog.probes.error("\(providerId) mapping script '\(file)' threw: \(exception)")
            throw UsageError.parseFailed(exception)
        }
        guard let text = output?.toString(), let data = text.data(using: .utf8), text != "undefined" else {
            throw UsageError.parseFailed("Mapping script '\(file)' returned nothing")
        }

        let result: ScriptOutput
        do {
            result = try JSONDecoder().decode(ScriptOutput.self, from: data)
        } catch {
            throw UsageError.parseFailed("Mapping script '\(file)' returned an unexpected shape: \(error.localizedDescription)")
        }
        return try result.snapshot(providerId: providerId, capturedAt: now())
    }

    private static func inputJSON(_ response: Response, facts: MappingFacts, now: Date) throws -> String {
        var context: [String: Any] = [
            "now": now.timeIntervalSince1970,
            "timeZone": TimeZone.current.identifier,
            "credential": facts.credential,
        ]
        for (name, fields) in facts.context {
            context[name] = fields
        }
        let input: [String: Any] = [
            "response": [
                "status": response.status.map { $0 as Any } ?? NSNull(),
                "headers": response.headers,
                "text": response.text,
                "json": (try? JSONSerialization.jsonObject(with: response.body, options: [.fragmentsAllowed])) ?? NSNull(),
            ],
            "context": context,
        ]
        let data = try JSONSerialization.data(withJSONObject: input)
        return String(decoding: data, as: UTF8.self)
    }
}

/// What a mapping script returns.
struct ScriptOutput: Decodable {
    struct Quota: Decodable {
        let type: QuotaKind
        let name: String?
        /// Exactly one measure: the old percentage or money, optionally of a ceiling.
        let left: Left
        /// Epoch seconds.
        let resetsAt: Double?
        let resetText: String?
        let windowSeconds: Double?

        private enum CodingKeys: String, CodingKey {
            case type, name, percentRemaining, left, resetsAt, resetText, windowSeconds
        }

        private struct MoneyLeft: Decodable {
            let money: Money
            let of: Money?
            let currency: String?
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            type = try container.decode(QuotaKind.self, forKey: .type)
            name = try container.decodeIfPresent(String.self, forKey: .name)
            let percent = try container.decodeIfPresent(Double.self, forKey: .percentRemaining)
            let money = try container.decodeIfPresent(MoneyLeft.self, forKey: .left)
            switch (percent, money) {
            case (let percent?, nil): left = .share(percent)
            case (nil, let money?):
                let currency = money.currency ?? "USD"
                guard !currency.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw DecodingError.dataCorruptedError(forKey: .left, in: container, debugDescription: "Empty currency")
                }
                left = .money(Quotas.Money(money.money.value, currency: currency),
                              of: money.of.map { Quotas.Money($0.value, currency: currency) })
            default:
                throw DecodingError.dataCorruptedError(forKey: .left, in: container,
                                                       debugDescription: "A quota must contain exactly one of percentRemaining or left")
            }
            resetsAt = try container.decodeIfPresent(Double.self, forKey: .resetsAt)
            resetText = try container.decodeIfPresent(String.self, forKey: .resetText)
            windowSeconds = try container.decodeIfPresent(Double.self, forKey: .windowSeconds)
        }
    }

    struct Cost: Decodable {
        let kind: CostRule.Kind?
        /// Decimal strings keep money exact; numbers are accepted too.
        let used: Money
        let limit: Money?
        let apiDurationSeconds: Double?
        let resetsAt: Double?
        let resetText: String?
    }

    struct Account: Decodable {
        let email: String?
        let organization: String?
        let loginMethod: String?
    }

    /// `"12.50"` or `12.5`, read as an exact `Decimal` from its text.
    struct Money: Decodable {
        let value: Decimal

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            let text: String
            if let string = try? container.decode(String.self) {
                text = string
            } else {
                text = String(try container.decode(Double.self))
            }
            guard text.range(of: #"^[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?$"#, options: .regularExpression) != nil,
                  let value = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not an amount: \(text)")
            }
            self.value = value
        }
    }

    let quotas: [Quota]?
    let plan: String?
    let cost: Cost?
    let account: Account?
    let error: ErrorRef?

    func snapshot(providerId: String, capturedAt: Date) throws -> UsageSnapshot {
        if let error { throw error.usageError }
        let quotas = (quotas ?? []).compactMap { quota -> UsageQuota? in
            guard let type = JSONMapper.quotaType(quota.type, name: quota.name) else { return nil }
            return UsageQuota(
                left: quota.left,
                quotaType: type,
                providerId: providerId,
                resetsAt: quota.resetsAt.map { Date(timeIntervalSince1970: $0) },
                resetText: quota.resetText,
                windowDuration: quota.windowSeconds
            )
        }
        let costUsage = cost.map { cost in
            CostUsage(
                totalCost: cost.used.value,
                budget: cost.limit?.value,
                apiDuration: cost.apiDurationSeconds ?? 0,
                providerId: providerId,
                kind: cost.kind == .extraUsage ? .extraUsage : .apiCost,
                capturedAt: capturedAt,
                resetsAt: cost.resetsAt.map { Date(timeIntervalSince1970: $0) },
                resetText: cost.resetText
            )
        }
        return UsageSnapshot(
            providerId: providerId,
            quotas: quotas,
            capturedAt: capturedAt,
            accountEmail: account?.email,
            accountOrganization: account?.organization,
            loginMethod: account?.loginMethod,
            accountTier: plan.map(Self.tier),
            costUsage: costUsage
        )
    }

    /// The well-known tiers by name; anything else is a badge as written.
    static func tier(_ plan: String) -> AccountTier {
        switch plan {
        case "claudeMax": .claudeMax
        case "claudePro": .claudePro
        case "claudeApi": .claudeApi
        default: .custom(plan)
        }
    }
}

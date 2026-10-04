# Rich Domain Model Patterns

## User's Mental Model

Domain models should match how users think about the domain:

```swift
// User thinks: "What's my quota status?"
public struct UsageQuota: Sendable, Equatable {
    public let percentRemaining: Double
    public let quotaType: QuotaType
    public let providerId: String
    public let resetsAt: Date?

    // User asks: "Am I running low?"
    public var status: QuotaStatus {
        QuotaStatus.from(percentRemaining: percentRemaining)
    }

    // User asks: "Is it empty?"
    public var isDepleted: Bool { percentRemaining <= 0 }

    // User asks: "Should I worry?"
    public var needsAttention: Bool { status.needsAttention }

    // User asks: "When does it reset?"
    public var resetDescription: String? {
        guard let timeUntilReset else { return nil }
        // Human-readable format
    }
}
```

## Behavior Over Data

Encapsulate domain rules in the model:

```swift
public struct UsageSnapshot: Sendable, Equatable {
    public let providerId: String
    public let quotas: [UsageQuota]
    public let capturedAt: Date

    // Domain rule: overall status is worst quota
    public var overallStatus: QuotaStatus {
        quotas.map(\.status).max() ?? .healthy
    }

    // Domain rule: lowest quota needs attention first
    public var lowestQuota: UsageQuota? {
        quotas.min()
    }

    // Domain rule: stale after 5 minutes
    public var isStale: Bool {
        capturedAt.timeIntervalSinceNow < -300
    }

    public var ageDescription: String {
        // Human-readable age
    }
}
```

## Capabilities as Handles

A capability a product may or may not offer is declared in its definition and
reached through a handle that is `nil` when it isn't — never a flag, a cast
or a protocol every provider half-implements:

```swift
@MainActor @Observable
public final class Provider {
    public let definition: ProviderDefinition
    public private(set) var accounts: [Account]   // its logins
    /// *In use* — nil when the definition declares no sign-in to choose from.
    public var inUse: InUse? { ... }
}

if let inUse = provider.inUse { try inUse.use(account) }   // ask the product, never the login
```

## Value Types for Data

Use structs for immutable data with behavior:

```swift
public struct UsageQuota: Sendable, Equatable, Hashable, Comparable {
    // Immutable data
    public let percentRemaining: Double

    // Computed behavior
    public var percentUsed: Double { 100 - percentRemaining }

    // Comparable for sorting
    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.percentRemaining < rhs.percentRemaining
    }
}
```

## Enums for States

Use enums with behavior for finite states:

```swift
public enum QuotaStatus: Int, Comparable, Sendable {
    case healthy = 0
    case warning = 1
    case critical = 2
    case depleted = 3

    public var needsAttention: Bool {
        self >= .warning
    }

    public var displayColor: Color {
        switch self {
        case .healthy: return .green
        case .warning: return .orange
        case .critical, .depleted: return .red
        }
    }

    public static func from(percentRemaining: Double) -> QuotaStatus {
        switch percentRemaining {
        case 0: return .depleted
        case 0..<20: return .critical
        case 20..<50: return .warning
        default: return .healthy
        }
    }
}
```

## Actors for Thread Safety

Use actors for stateful domain services:

```swift
@MainActor @Observable
public final class QuotaMonitor {
    public let providers: Providers               // the providers you keep
    private var previousStatuses: [String: QuotaStatus] = [:]

    public func refreshAll() async {
        await withTaskGroup(of: Void.self) { group in
            for login in providers.lineup {
                group.addTask { await self.refresh(login) }
            }
        }
    }

    public var overallStatus: QuotaStatus {
        providers.lineup.compactMap { $0.snapshot?.overallStatus }.max() ?? .healthy
    }
}
```

## Factory Methods

Use static methods for complex construction:

```swift
extension UsageQuota {
    static func from(cliOutput: String, providerId: String) throws -> UsageQuota {
        // Parse CLI output into domain model
    }
}

extension QuotaStatus {
    static func from(percentRemaining: Double) -> QuotaStatus {
        // Business rule encapsulated here
    }
}
```
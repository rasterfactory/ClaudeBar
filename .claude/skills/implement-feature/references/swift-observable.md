# Swift 6.2 @Observable Patterns

## @Observable vs ObservableObject

Swift 6.2 introduces `@Observable` macro replacing `ObservableObject`:

```swift
// Swift 6.2 - Use this
@MainActor @Observable
public final class QuotaMonitor {
    public let providers: Providers
    public private(set) var isMonitoring = false
}

// Old pattern - Don't use
final class QuotaMonitor: ObservableObject {
    @Published var isMonitoring = false
}
```

## No ViewModel Layer

Views consume domain models directly:

```swift
// Direct domain model consumption
struct ProviderSectionView: View {
    let snapshot: UsageSnapshot  // Domain model

    var body: some View {
        VStack {
            Text(snapshot.overallStatus.displayName)
            ForEach(snapshot.quotas, id: \.quotaType) { quota in
                QuotaCardView(quota: quota)
            }
        }
    }
}
```

## @State with @Observable

Use `@State` to own `@Observable` objects in views:

```swift
@main
struct ClaudeBarApp: App {
    @State private var monitor: QuotaMonitor   // built in init(), the composition root

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(monitor: monitor)
        }
    }
}
```

## Sendable Conformance

Isolate `@Observable` domain classes to the main actor: a `@MainActor` class
is implicitly `Sendable`, and its writes land where SwiftUI reads them. Heavy
work still runs off-main behind an `await`:

```swift
@MainActor @Observable
public final class Account: Identifiable {
    public let id: String
    public private(set) var isSyncing = false
    public private(set) var snapshot: UsageSnapshot?
}
```

## Computed Properties

Use computed properties for derived state:

```swift
@MainActor @Observable
public final class Providers {
    public private(set) var all: [Provider] = []

    // Derived, never stored
    public var logins: [Account] { all.flatMap(\.accounts) }
    public var lineup: [Account] { logins.filter(\.isInLineup) }
}
```

## Environment with @Observable

Pass `@Observable` objects through environment when needed:

```swift
struct MenuContentView: View {
    let monitor: QuotaMonitor

    var body: some View {
        LoginListView()
            .environment(monitor)
    }
}

struct LoginListView: View {
    @Environment(QuotaMonitor.self) var monitor

    var body: some View {
        ForEach(monitor.lineup, id: \.id) { login in
            ProviderRow(provider: login)
        }
    }
}
```
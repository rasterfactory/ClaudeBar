import Foundation
import Quotas

/// Distinguishes how much work a refresh should do and whether it counts as
/// explicit user intent.
///
/// - `.interactive`: a genuine click (Refresh button, Touch Bar / notch
///   refresh, `claudebar://refresh`, provider switch). Providers may do their
///   most expensive work and treat success as "the user connected".
/// - `.background`: the periodic menu-bar poll. Must stay cheap — skipping
///   non-glanceable work like the daily-usage JSONL scan keeps idle energy
///   use low (issue #204).
/// - `.passive`: the app initiated the refresh without a click, e.g. when the
///   popover opens. Providers choose what that means: the default behaves
///   exactly like `.interactive`, Claude keeps attaching the daily-usage
///   report the popover renders, and Codex treats it like `.background` —
///   never spawning the CLI before the session was explicitly verified
///   (issue #216).
public enum RefreshKind: Sendable {
    case interactive
    case background
    case passive
}

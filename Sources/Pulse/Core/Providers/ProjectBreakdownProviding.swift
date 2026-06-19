import Foundation

/// Capability for providers whose local data carries a project + session
/// dimension (Claude Code, Codex). It is deliberately *separate* from
/// `UsageProvider`: the breakdown is heavy, lazily-computed detail the live
/// menu-bar panel never needs, so it is queried on demand by the breakdown
/// window rather than produced on every refresh tick.
///
/// Implementations must remain read-only and reuse the warm aggregation cache
/// the live `fetch()` already maintains — a breakdown query must never trigger
/// a second full parse of the log tree.
protocol ProjectBreakdownProviding: Sendable {
    var id: ProviderID { get }

    /// Per-project/session usage over `timeframe`. Returns `nil` when the
    /// provider has no attributable usage in the window (the window shows an
    /// empty state). Never throws: a breakdown is a best-effort read over local
    /// files, and a transient read failure should degrade to "nothing yet",
    /// not surface an error in the analytics view.
    func projectBreakdown(timeframe: BreakdownTimeframe, now: Date) async -> ProjectBreakdown?
}

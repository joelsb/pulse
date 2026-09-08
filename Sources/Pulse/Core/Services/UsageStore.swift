import Foundation
import Observation

/// Per-provider UI state: the last good snapshot plus whatever is currently
/// going wrong, so errors degrade the display (stale badge) instead of
/// blanking it.
struct ProviderRecord: Sendable {
    var snapshot: UsageSnapshot?
    var lastError: ProviderFetchError?
    var notConnectedHint: String?
    var isRefreshing = false
    var lastSuccess: Date?
    var hasLoadedOnce = false
    /// Consecutive not-connected probes. The probe can fail transiently
    /// (SQLite torn read, slow securityd after wake), so one bad probe must
    /// not wipe a good snapshot — see `UsageStore.applyNotConnected`.
    var notConnectedStrikes = 0

    /// Trend arrows (vs ~1h ago), computed by the scheduler from history.
    var primaryTrend: Trend?
    var secondaryTrend: Trend?
    var tertiaryTrend: Trend?
    /// Usage-rate series for the chart, recomputed after each sample.
    var rateSeries: [RatePoint] = []

    enum DisplayState: Sendable, Equatable {
        case loading
        case data
        case notConnected(hint: String)
        case error(ProviderFetchError)
    }

    var displayState: DisplayState {
        if snapshot != nil { return .data }
        if let notConnectedHint { return .notConnected(hint: notConnectedHint) }
        if let lastError { return .error(lastError) }
        return .loading
    }

    /// True when the last refresh failed but old data is still on screen.
    var isStale: Bool { snapshot != nil && lastError != nil }

    /// Whether the provider saw any use in the last 7 days (or is mid-window
    /// right now). Drives menu-bar visibility: dormant or unconnected
    /// providers keep their tab but stay out of the bar.
    var isActiveRecently: Bool {
        guard let snapshot else { return false }
        if let primary = snapshot.primary, primary.utilization > 0 { return true }
        // Primary-only hid accounts whose 5-hour session just reset but whose
        // weekly window still shows real use (e.g. Codex with providerLogs off,
        // where dailyUsage is empty too) — check secondary before giving up.
        if let secondary = snapshot.secondary, secondary.utilization > 0 { return true }
        return snapshot.dailyUsage.contains { $0.totals.total > 0 }
    }
}

/// Single source of truth the UI observes. All mutation happens on the main
/// actor via the refresh scheduler.
@MainActor
@Observable
final class UsageStore {
    private(set) var records: [ProviderID: ProviderRecord] = [:]

    func record(for id: ProviderID) -> ProviderRecord {
        records[id] ?? ProviderRecord()
    }

    /// Most recent successful update across providers (footer timestamp).
    var lastUpdated: Date? {
        records.values.compactMap(\.lastSuccess).max()
    }

    var isAnyRefreshing: Bool {
        records.values.contains(where: \.isRefreshing)
    }

    func setRefreshing(_ id: ProviderID, _ refreshing: Bool) {
        var record = record(for: id)
        record.isRefreshing = refreshing
        records[id] = record
    }

    func apply(_ snapshot: UsageSnapshot) {
        var record = record(for: snapshot.providerID)
        var incoming = snapshot

        // Limits source blipped but the rest of the snapshot is good: keep the
        // previous gauges on screen rather than blanking the headline cards.
        if incoming.limitsUnavailable, let previous = record.snapshot {
            if incoming.primary == nil { incoming.primary = previous.primary }
            if incoming.secondary == nil { incoming.secondary = previous.secondary }
            if incoming.tertiary == nil { incoming.tertiary = previous.tertiary }
            if incoming.extraWindows.isEmpty { incoming.extraWindows = previous.extraWindows }
            // The gauges on screen are from the last successful capture, not
            // this failed attempt — carry that timestamp forward so the age
            // caption stays honest instead of resetting to "just now".
            incoming.limitsCapturedAt = previous.limitsCapturedAt
        }

        record.snapshot = incoming
        // A carried-forward failure must stay visible on the record: clearing
        // this unconditionally (as before) made `isStale` —
        // `snapshot != nil && lastError != nil` — unreachable on this path,
        // so a failed limits fetch rendered exactly like a fresh success.
        record.lastError = incoming.limitsError
        record.notConnectedHint = nil
        // Only a real limits success moves the freshness clock. Bumping it on
        // a carried-forward FAILURE was the other half of the honesty bug:
        // the footer stamped "Updated just now" over numbers that were, in
        // fact, hours old.
        //
        // Keyed on `limitsError == nil`, not `!limitsUnavailable` — the two
        // are NOT the same thing. Cursor sets `limitsUnavailable` for an
        // account that simply has no plan gauge to report (a permanent,
        // successful property of that plan, `CursorProvider.swift`) and
        // Codex can set it with `limitsError == nil` when the usage call
        // succeeded but produced no primary window
        // (`CodexProvider.swift`). Neither carries `lastError` (see above),
        // so `isStale` stays false and the card renders normally — but
        // keying this on `limitsUnavailable` alone froze `lastSuccess` at nil
        // forever for both, which froze `PanelFooter`'s "Updated Xm ago" at
        // "Waiting for first update…" permanently AND defeated
        // `RefreshScheduler.refreshAll(ifOlderThan:)` (`lastSuccess ??
        // .distantPast` never ages), so opening the panel re-ran every fetch
        // every time. Claude always sets `limitsUnavailable` and
        // `limitsError` together (`ClaudeProvider.swift`), so this changes
        // nothing for the case this file's `apply` fix is about.
        if incoming.limitsError == nil {
            record.lastSuccess = incoming.fetchedAt
        }
        record.hasLoadedOnce = true
        record.isRefreshing = false
        record.notConnectedStrikes = 0
        records[snapshot.providerID] = record
    }

    func applyError(_ id: ProviderID, _ error: ProviderFetchError) {
        var record = record(for: id)
        record.lastError = error
        record.notConnectedHint = nil
        record.hasLoadedOnce = true
        record.isRefreshing = false
        record.notConnectedStrikes = 0
        records[id] = record
    }

    func applyNotConnected(_ id: ProviderID, hint: String) {
        var record = record(for: id)
        record.notConnectedStrikes += 1
        // A genuinely signed-out provider loses its stale data (the empty
        // state is truthful), but only after a second consecutive probe so a
        // transient probe failure can't wipe a good snapshot.
        if record.notConnectedStrikes >= 2 || record.snapshot == nil {
            record.snapshot = nil
            record.notConnectedHint = hint
            record.lastError = nil
        }
        record.hasLoadedOnce = true
        record.isRefreshing = false
        records[id] = record
    }

    func applyDerived(
        _ id: ProviderID,
        primaryTrend: Trend?,
        secondaryTrend: Trend?,
        tertiaryTrend: Trend? = nil,
        rateSeries: [RatePoint]
    ) {
        var record = record(for: id)
        record.primaryTrend = primaryTrend
        record.secondaryTrend = secondaryTrend
        record.tertiaryTrend = tertiaryTrend
        record.rateSeries = rateSeries
        records[id] = record
    }
}

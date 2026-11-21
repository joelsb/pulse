import SwiftUI

/// The menu bar label: one compact two-row block per visible provider —
/// stacked 2+1 letter code, threshold-colored dot + session %, trend arrow +
/// delta. Width changes are rare by construction (monospaced digits, fixed
/// placeholders), so the status item never jitters.
struct StatusBarLabelView: View {
    let store: UsageStore
    let settings: SettingsStore
    let descriptors: [ProviderID: ProviderDescriptor]
    /// NSStatusItem cannot size itself from a hosted SwiftUI view — the
    /// controller sets `statusItem.length` from this measurement.
    var onWidthChange: (CGFloat) -> Void = { _ in }
    /// The name each account is shown by (Joel's own when set, JSB-112).
    var name: (ProviderID) -> String = { $0.rawValue }
    /// The status item's tooltip names the shown accounts; the hosted label
    /// itself is click-through, so the button carries it.
    var onTooltipChange: (String) -> Void = { _ in }

    /// Enabled ∩ user-allowed ∩ recently active. Dormant or unconnected
    /// providers keep their tab but never occupy menu bar width.
    private var activeProviders: [ProviderID] {
        Self.menuBarAccounts(selected: settings.visibleMenuBarProviders, store: store, showIdle: settings.showIdleAccounts)
    }

    /// The status item's tooltip: which accounts the blocks belong to, by the
    /// names Joel gave them (the 3-letter codes stay as they are).
    static func tooltip(shown: [ProviderID], name: (ProviderID) -> String) -> String {
        shown.isEmpty ? "Byte Pulse — AI usage" : "Byte Pulse — " + shown.map(name).joined(separator: ", ")
    }

    /// Selected accounts (Menu icon switch on) that get a block. Normally only
    /// recently used ones; with "Show idle accounts" (JSB-112) also those whose
    /// last refresh succeeded with measured limits at zero use. Never an
    /// account with no data, a failed refresh or a sign-in problem: a block
    /// must not show a 0 nobody measured.
    static func menuBarAccounts(selected: [ProviderID], store: UsageStore, showIdle: Bool) -> [ProviderID] {
        selected.filter { id in
            let record = store.record(for: id)
            if record.isActiveRecently { return true }
            guard showIdle, let snapshot = record.snapshot,
                  record.lastError == nil, record.notConnectedStrikes == 0
            else { return false }
            return snapshot.primary != nil || snapshot.secondary != nil
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            if settings.menuBarStyle == .icon || activeProviders.isEmpty {
                Image(nsImage: PulseIcons.byteMark)
                    .renderingMode(.template)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 14, height: 14)
                    .foregroundStyle(.primary)
            } else {
                ForEach(activeProviders) { id in
                    ProviderStatBlock(
                        code: descriptors[id]?.shortCode ?? id.rawValue.uppercased(),
                        record: store.record(for: id),
                        direction: settings.gaugeDirection,
                        secondaryRow: settings.menuBarSecondaryRow
                    )
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(name(id))
                }
            }
        }
        .padding(.horizontal, 4)
        .fixedSize()
        .onGeometryChange(for: CGFloat.self, of: \.size.width) { width in
            onWidthChange(width)
        }
        .onChange(of: Self.tooltip(shown: settings.menuBarStyle == .icon ? [] : activeProviders, name: name), initial: true) { _, tip in
            onTooltipChange(tip)
        }
        .allowsHitTesting(false)
    }
}

private struct ProviderStatBlock: View {
    let code: String
    let record: ProviderRecord
    /// Same setting the panel uses. The menu bar shows the *same* number as
    /// the card behind it, so a reversed panel with a non-reversed menu bar is
    /// a contradiction the user reads before anything else.
    var direction: SettingsStore.GaugeDirection = .remaining
    /// Whether the bottom line is the weekly limit or the session trend.
    var secondaryRow: SettingsStore.MenuBarSecondaryRow = .weekly

    /// Raw utilization, for colour and trend (both always key off consumption).
    private var utilization: Double? { record.snapshot?.primary?.utilization }

    /// The number actually rendered, in the user's chosen direction.
    private var displayValue: Double? {
        utilization.map(direction.displayValue(utilization:))
    }

    /// Raw weekly utilization, when the provider publishes a weekly window.
    private var weeklyUtilization: Double? { record.snapshot?.secondary?.utilization }

    private var weeklyDisplayValue: Double? {
        weeklyUtilization.map(direction.displayValue(utilization:))
    }

    private func dotColor(for value: Double?) -> Color {
        guard let value else { return Color.primary.opacity(0.25) }
        if record.isStale { return PulseColor.warnStrong }
        return PulseColor.threshold(utilization: value)
    }

    private var dotColor: Color { dotColor(for: utilization) }

    var body: some View {
        HStack(spacing: 2.5) {
            codeColumn
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 2.5) {
                    Circle()
                        .fill(dotColor)
                        .frame(width: 5, height: 5)
                        .animation(Motion.staleTint, value: record.isStale)
                    Text(displayValue.map(Formatters.percent) ?? "––")
                        .font(Typo.menuBarValue)
                        .foregroundStyle(.primary)
                        .contentTransition(.numericText(value: displayValue ?? 0))
                        .animation(Motion.numberTick, value: displayValue)
                }
                secondaryLine
            }
        }
    }

    @ViewBuilder
    private var secondaryLine: some View {
        switch secondaryRow {
        case .weekly: weeklyRow
        case .trend: trendRow
        }
    }

    /// The 7-day cap, drawn with the same dot + number shape as the session
    /// line above it so the two read as one column, not two unrelated stats.
    @ViewBuilder
    private var weeklyRow: some View {
        if let weeklyDisplayValue {
            HStack(spacing: 2.5) {
                Circle()
                    .fill(dotColor(for: weeklyUtilization))
                    .frame(width: 4, height: 4)
                    .animation(Motion.staleTint, value: record.isStale)
                Text(Formatters.percent(weeklyDisplayValue))
                    .font(Typo.menuBarDelta)
                    .foregroundStyle(.primary)
                    .contentTransition(.numericText(value: weeklyDisplayValue))
                    .animation(Motion.numberTick, value: weeklyDisplayValue)
            }
        } else {
            Text("–")
                .font(Typo.menuBarDelta)
                .foregroundStyle(.secondary)
        }
    }

    /// "CLA" rendered as "CL" over "A", matching the reference design.
    private var codeColumn: some View {
        VStack(alignment: .leading, spacing: -1) {
            Text(String(code.prefix(2)))
            Text(String(code.dropFirst(2)))
        }
        .font(Typo.menuBarCode)
        .tracking(0.5)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var trendRow: some View {
        if let trend = record.primaryTrend, utilization != nil {
            HStack(spacing: 1.5) {
                Image(systemName: trend.direction == .down ? "arrowtriangle.down.fill" : "arrowtriangle.up.fill")
                    .font(.system(size: 5.5, weight: .bold))
                    .opacity(trend.direction == .flat ? 0 : 1)
                Text(Formatters.deltaPercent(trend.delta))
                    .font(Typo.menuBarDelta)
                    .contentTransition(.numericText(value: abs(trend.delta)))
            }
            .foregroundStyle(PulseColor.trend(delta: trend.delta))
            .animation(Motion.iconSwap, value: trend.direction == .up)
        } else {
            Text("–")
                .font(Typo.menuBarDelta)
                .foregroundStyle(.secondary)
        }
    }
}

import SwiftUI

/// JSB-112: one labeled row per account of a multi-account provider, each
/// with its own session and weekly gauge, so two Codex subscriptions are read
/// side by side without signing either out.
struct AccountUsageCard: View {
    let accounts: [AccountUsage]
    var direction: SettingsStore.GaugeDirection = .remaining

    /// The number shown next to a gauge; a dash when the account has no
    /// value for that window rather than a made-up 0%.
    nonisolated static func valueText(_ window: LimitWindow?, direction: SettingsStore.GaugeDirection) -> String {
        guard let window else { return "–" }
        return Formatters.percent(direction.displayValue(utilization: window.utilization))
    }

    var body: some View {
        CardView {
            VStack(alignment: .leading, spacing: 8) {
                CardTitleRow(systemImage: "person.2", title: "Accounts") { EmptyView() }
                VStack(spacing: 8) {
                    ForEach(accounts) { account in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(account.label)
                                .font(Typo.tableLabel)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            if let note = account.note {
                                Text(note)
                                    .font(Typo.footer)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            } else {
                                HStack(spacing: 10) {
                                    gauge("Session", account.session)
                                    gauge("Weekly", account.weekly)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }

    private func gauge(_ title: String, _ window: LimitWindow?) -> some View {
        HStack(spacing: 5) {
            Text(title)
                .font(Typo.caption)
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .leading)
            GaugeBar(utilization: window?.utilization ?? 0, paceMarker: nil, direction: direction)
                .opacity(window == nil ? 0.3 : 1)
            Text(Self.valueText(window, direction: direction))
                .font(Typo.captionValue)
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .trailing)
        }
        .help(window?.resetsAt.map { "\(title) resets in \(Formatters.countdown(to: $0))" } ?? title)
    }
}

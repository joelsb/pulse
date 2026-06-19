import SwiftUI

/// Fixed numeric column widths so project and session rows line up under the
/// header regardless of window width (only the name column flexes).
private enum Col {
    static let sessions: CGFloat = 70
    static let tokens: CGFloat = 96
    static let cost: CGFloat = 84
    static let lastActive: CGFloat = 96
    static let rowInset: CGFloat = 12
    /// Chevron + accent dot width, so the header's "Project" label and session
    /// rows align under the project name.
    static let nameIndent: CGFloat = 28
}

/// The breakdown window's root: provider/timeframe/sort toolbar, totals summary,
/// and a project → session outline. Reads everything through `BreakdownViewModel`.
struct BreakdownView: View {
    let model: BreakdownViewModel

    var body: some View {
        VStack(spacing: 0) {
            BreakdownToolbar(model: model)
            Divider()
            content
        }
        .frame(minWidth: 560, minHeight: 360)
        // Loads on first appear and whenever the selection (provider/timeframe)
        // changes. Periodic liveness refresh is driven by the window controller,
        // gated on actual window visibility (see BreakdownWindowController).
        .task(id: model.reloadKey) { await model.load() }
    }

    @ViewBuilder
    private var content: some View {
        if model.breakdown == nil, model.isLoading {
            BreakdownLoadingState()
        } else if let breakdown = model.breakdown, !breakdown.isEmpty {
            VStack(spacing: 0) {
                BreakdownSummaryBar(breakdown: breakdown, showsCost: model.showsCost)
                Divider().opacity(0.5)
                BreakdownColumnHeader(showsCost: model.showsCost)
                projectList(breakdown)
            }
        } else {
            BreakdownEmptyState(message: model.emptyMessage)
        }
    }

    private func projectList(_ breakdown: ProjectBreakdown) -> some View {
        let projects = model.sortedProjects
        let accent = PulseColor.accent(model.selectedProvider)
        return ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(projects) { project in
                    BreakdownProjectRow(
                        project: project,
                        accent: accent,
                        showsCost: model.showsCost,
                        isExpanded: model.isExpanded(project.id),
                        toggle: { withAnimation(Motion.tabPill) { model.toggleExpanded(project.id) } }
                    )
                    Divider().opacity(0.4).padding(.leading, Col.rowInset)
                    if model.isExpanded(project.id) {
                        ForEach(project.sessions) { session in
                            BreakdownSessionRow(session: session, showsCost: model.showsCost)
                            Divider().opacity(0.25).padding(.leading, Col.rowInset + Col.nameIndent)
                        }
                    }
                }
            }
        }
        .scrollBounceBehavior(.basedOnSize)
    }
}

// MARK: - Toolbar

private struct BreakdownToolbar: View {
    let model: BreakdownViewModel

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 12) {
            ProviderTabBar(
                providers: model.supportedProviders,
                names: { model.descriptor(for: $0).name },
                selection: $model.selectedProvider
            )
            .frame(width: 200)
            .onChange(of: model.selectedProvider) { _, _ in
                model.expandedProjects.removeAll()
                model.persistPreferences()
            }

            Picker("", selection: $model.timeframe) {
                ForEach(BreakdownTimeframe.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .onChange(of: model.timeframe) { _, _ in model.persistPreferences() }

            sortMenu

            Spacer(minLength: 8)

            if model.isLoading, model.breakdown != nil {
                ProgressView().controlSize(.small)
            }
            updatedLabel
            GhostIconButton(systemImage: "arrow.clockwise", help: "Refresh (⌘R)") {
                Task { await model.load() }
            }
        }
        .padding(.horizontal, Col.rowInset)
        .padding(.vertical, 10)
    }

    private var sortMenu: some View {
        Menu {
            ForEach(BreakdownSort.allCases) { option in
                if option != .cost || model.showsCost {
                    Button {
                        model.sort = option
                        model.persistPreferences()
                    } label: {
                        if model.sort == option {
                            Label(option.label, systemImage: "checkmark")
                        } else {
                            Text(option.label)
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text("Sort: \(model.sort.label)").font(Typo.barButton)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    @ViewBuilder
    private var updatedLabel: some View {
        if let loaded = model.lastLoaded {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text("Updated \(Formatters.relativeAge(of: loaded, now: context.date))")
                    .font(Typo.footer)
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
        }
    }
}

// MARK: - Summary

private struct BreakdownSummaryBar: View {
    let breakdown: ProjectBreakdown
    let showsCost: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 20) {
            metric("Projects", "\(breakdown.projects.count)")
            metric("Sessions", "\(breakdown.sessionCount)")
            metric("Tokens", Formatters.tokenCount(breakdown.grandTotal.total))
            if showsCost {
                metric("Cost", breakdown.grandTotal.costUSD.map(Formatters.money) ?? "—")
            }
            Spacer()
        }
        .padding(.horizontal, Col.rowInset)
        .padding(.vertical, 10)
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(Typo.gaugeValue).foregroundStyle(.primary)
            Text(label).font(Typo.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Column header

private struct BreakdownColumnHeader: View {
    let showsCost: Bool

    var body: some View {
        HStack(spacing: 10) {
            Text("Project")
                .padding(.leading, Col.nameIndent)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Sessions").frame(width: Col.sessions, alignment: .trailing)
            Text("Tokens").frame(width: Col.tokens, alignment: .trailing)
            if showsCost { Text("Cost").frame(width: Col.cost, alignment: .trailing) }
            Text("Last active").frame(width: Col.lastActive, alignment: .trailing)
        }
        .font(Typo.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, Col.rowInset)
        .padding(.vertical, 6)
    }
}

// MARK: - Project row

private struct BreakdownProjectRow: View {
    let project: ProjectUsage
    let accent: Color
    let showsCost: Bool
    let isExpanded: Bool
    let toggle: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    Circle().fill(accent).frame(width: 6, height: 6)
                }
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(project.name)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1).truncationMode(.middle)
                        if project.isActive { BreakdownActiveBadge() }
                    }
                    Text(project.displayPath)
                        .font(Typo.footer)
                        .foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 8)
                valueCell("\(project.sessionCount)", width: Col.sessions, color: .secondary)
                valueCell(Formatters.tokenCount(project.totals.total), width: Col.tokens)
                if showsCost {
                    valueCell(project.totals.costUSD.map(Formatters.money) ?? "—", width: Col.cost)
                }
                valueCell(Formatters.relativeAge(of: project.lastActivity), width: Col.lastActive, color: .secondary)
            }
            .padding(.horizontal, Col.rowInset)
            .padding(.vertical, 8)
            .background(isHovered ? PulseColor.cardFillHover : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in withAnimation(Motion.hover) { isHovered = hovering } }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(isExpanded ? "Expanded. Activate to collapse sessions." : "Collapsed. Activate to show sessions.")
    }

    private var accessibilityLabel: String {
        var parts = ["\(project.name), \(project.sessionCount) sessions, \(project.totals.total) tokens"]
        if showsCost, let cost = project.totals.costUSD { parts.append(Formatters.money(cost)) }
        if project.isActive { parts.append("active now") }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Session row

private struct BreakdownSessionRow: View {
    let session: SessionUsage
    let showsCost: Bool

    var body: some View {
        HStack(spacing: 10) {
            Color.clear.frame(width: Col.nameIndent, height: 1)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(Typo.tableLabel)
                        .foregroundStyle(.primary)
                        .lineLimit(1).truncationMode(.middle)
                    if session.isActive { BreakdownActiveBadge() }
                }
                HStack(spacing: 6) {
                    if let branch = session.gitBranch, !branch.isEmpty {
                        BreakdownBranchChip(branch: branch)
                    }
                    if let models = modelSummary {
                        Text(models).font(Typo.footer).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 8)
            Color.clear.frame(width: Col.sessions, height: 1)
            valueCell(Formatters.tokenCount(session.totals.total), width: Col.tokens, color: .secondary)
            if showsCost {
                valueCell(session.totals.costUSD.map(Formatters.money) ?? "—", width: Col.cost, color: .secondary)
            }
            valueCell(Formatters.relativeAge(of: session.lastActivity), width: Col.lastActive, color: .secondary)
        }
        .padding(.horizontal, Col.rowInset)
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        var parts = [title, "\(session.totals.total) tokens"]
        if showsCost, let cost = session.totals.costUSD { parts.append(Formatters.money(cost)) }
        if let branch = session.gitBranch, !branch.isEmpty { parts.append("branch \(branch)") }
        if session.isActive { parts.append("active now") }
        return parts.joined(separator: ", ")
    }

    private var title: String {
        if let title = session.title, !title.isEmpty { return title }
        return "Session \(session.id.prefix(8))"
    }

    private var modelSummary: String? {
        let names = session.modelBreakdown.map(\.model)
        guard !names.isEmpty else { return nil }
        let shown = names.prefix(2).joined(separator: ", ")
        return names.count > 2 ? "\(shown) +\(names.count - 2)" : shown
    }
}

// MARK: - Small components

/// Green "Active" pill for sessions/projects touched within the live threshold.
private struct BreakdownActiveBadge: View {
    var body: some View {
        HStack(spacing: 3) {
            Circle().fill(PulseColor.ok).frame(width: 5, height: 5)
            Text("Active").font(.system(size: 9, weight: .semibold)).foregroundStyle(PulseColor.ok)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(Capsule().fill(PulseColor.ok.opacity(0.12)))
        .accessibilityLabel("Active now")
    }
}

private struct BreakdownBranchChip: View {
    let branch: String

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "arrow.triangle.branch").font(.system(size: 8, weight: .semibold))
            Text(branch).font(.system(size: 9, weight: .medium)).lineLimit(1)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(Capsule().fill(PulseColor.trackFill))
    }
}

private struct BreakdownEmptyState: View {
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            ThemedIcon(symbol: "chart.bar.fill", pointSize: 28, weight: .light)
                .foregroundStyle(.tertiary)
            Text(message)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

private struct BreakdownLoadingState: View {
    var body: some View {
        VStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("Reading sessions…").font(Typo.footer).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

/// Right-aligned, fixed-width monospaced numeric cell, shared by both row types
/// so columns line up.
@ViewBuilder
private func valueCell(_ text: String, width: CGFloat, color: Color = .primary) -> some View {
    Text(text)
        .font(Typo.tableValue)
        .foregroundStyle(color)
        .lineLimit(1)
        .frame(width: width, alignment: .trailing)
}

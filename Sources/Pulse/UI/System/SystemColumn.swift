import SwiftUI

/// Machine stats column, pinned left of the providers.
///
/// Exists because the panel's whole job changed once agents started running
/// locally: a provider limit says whether the *account* can keep going, and
/// this says whether the *Mac* can. Deliberately narrower than a provider
/// column - it is a glanceable sidebar, not a monitoring app.
struct SystemColumn: View {
    let monitor: SystemMonitor
    let showProcesses: Bool

    var body: some View {
        VStack(spacing: Layout.cardGap) {
            SystemColumnHeader(sample: monitor.sample, hasSample: monitor.hasSample)

            CPUCard(sample: monitor.sample, history: monitor.cpuHistory, hasSample: monitor.hasSample)
            MemoryCard(sample: monitor.sample, history: monitor.memoryHistory)
            StorageCard(sample: monitor.sample)

            if showProcesses {
                TopProcessesCard(
                    title: "Top by CPU",
                    systemImage: "gauge.with.needle",
                    processes: monitor.sample.topProcesses,
                    metric: .cpu
                )
                TopProcessesCard(
                    title: "Top by RAM",
                    systemImage: "memorychip",
                    processes: monitor.sample.topMemoryProcesses,
                    metric: .memory
                )
            }

            Spacer(minLength: 0)
        }
        .frame(width: Layout.systemColumnWidth)
        // Ref-counted polling: the sampler runs only while this column is on
        // screen, so a closed panel costs nothing.
        .task {
            monitor.addSubscriber()
            // Kick one reading immediately; the loop's first tick establishes
            // the CPU baseline and reports 0 until the second.
            await monitor.poll()
        }
        .onDisappear { monitor.removeSubscriber() }
    }
}

/// Header matching `ProviderColumnHeader`'s pill so the sidebar reads as a
/// peer of the provider columns, not as chrome.
private struct SystemColumnHeader: View {
    let sample: SystemSample
    let hasSample: Bool

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)
            Text("This Mac")
                .font(Typo.tabLabel)
                .foregroundStyle(.primary)
            Spacer(minLength: 4)
            if sample.thermal != .nominal {
                Image(systemName: "thermometer.medium")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(thermalColor)
                    .help("Thermal state: \(thermalLabel). The system is throttling.")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: Layout.tabBarHeight)
        .background(Capsule().fill(PulseColor.trackFill))
        .help(hasSample ? headline : "Sampling…")
    }

    /// One dot for "can this Mac take more work": the worst of CPU, memory
    /// pressure, disk and thermal state, since any one of them alone can be the
    /// thing that makes another agent a bad idea. Disk is in here because a
    /// volume at 97% kills a long run just as dead as an exhausted CPU, and it
    /// is the failure that gives the least warning.
    private var statusColor: Color {
        if sample.memoryPressure == .critical || sample.thermal == .critical || sample.diskUtilization >= 95 {
            return PulseColor.critical
        }
        if sample.memoryPressure == .warning || sample.thermal == .serious || sample.diskUtilization >= 90 {
            return PulseColor.warn
        }
        return PulseColor.threshold(utilization: max(sample.cpuTotal, sample.loadUtilization, performancePressure))
    }

    /// Saturated Performance cores count as CPU pressure even when the
    /// aggregate is comfortable: the E-cores being free does not help a build
    /// that is waiting on a fast core.
    private var performancePressure: Double {
        guard let performance = sample.cpuPerformance, sample.hasCoreSplit else { return 0 }
        return performance
    }

    private var thermalColor: Color {
        switch sample.thermal {
        case .critical: PulseColor.critical
        case .serious: PulseColor.warnStrong
        default: PulseColor.warn
        }
    }

    private var thermalLabel: String {
        switch sample.thermal {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }

    private var headline: String {
        "CPU \(Formatters.percent(sample.cpuTotal)) · RAM \(Formatters.percent(sample.memoryUtilization)) · load \(String(format: "%.2f", sample.load1)) on \(sample.coreCount) cores"
    }
}

/// CPU: headline percent, user/system split, sparkline, load average.
private struct CPUCard: View {
    let sample: SystemSample
    let history: [Double]
    let hasSample: Bool

    var body: some View {
        CardView {
            VStack(alignment: .leading, spacing: 8) {
                CardTitleRow(systemImage: "cpu", title: "CPU") {
                    Text(hasSample ? Formatters.percent(sample.cpuTotal) : "—")
                        .font(Typo.gaugeValue)
                        .contentTransition(.numericText(value: sample.cpuTotal))
                        .animation(Motion.numberTick, value: sample.cpuTotal)
                }

                // Always `.used`: a CPU bar is consumption, and inverting it
                // with the provider gauges would mean a full bar reads as
                // "idle" on one card and "pinned" on the next.
                GaugeBar(utilization: sample.cpuTotal, direction: .used)

                Sparkline(values: history, color: PulseColor.threshold(utilization: sample.cpuTotal))
                    .frame(height: 26)

                // The P/E split, when the machine has one. The aggregate hides
                // the case that actually matters: on a 4P+6E Mac, a build
                // pegging all four P-cores reads as ~40% overall, which looks
                // like headroom and is not.
                if sample.hasCoreSplit {
                    VStack(spacing: 4) {
                        clusterRow(
                            label: "P",
                            count: sample.performanceCoreCount,
                            busy: sample.cpuPerformance
                        )
                        clusterRow(
                            label: "E",
                            count: sample.efficiencyCoreCount,
                            busy: sample.cpuEfficiency
                        )
                    }
                    .help("Performance and Efficiency cores, measured separately. The combined percentage can look comfortable while every fast core is already taken, which is what decides whether another agent gets real cycles.")
                }

                HStack(spacing: 4) {
                    Text("usr \(Formatters.percent(sample.cpuUser))")
                    Text("·")
                    Text("sys \(Formatters.percent(sample.cpuSystem))")
                    Spacer(minLength: 4)
                    Text(String(format: "%.2f", sample.load1))
                        .foregroundStyle(loadColor)
                    Text("/ \(sample.coreCount)c")
                }
                .font(Typo.caption)
                .foregroundStyle(.secondary)
                .help("Load average 1m / 5m / 15m: \(loadText). Above \(sample.coreCount) means more runnable work than cores.")
            }
        }
    }

    private var loadColor: Color {
        PulseColor.threshold(utilization: sample.loadUtilization)
    }

    /// One cluster: "P 4c ▓▓▓▓░ 92%". Compact enough that two of them cost less
    /// vertical space than one more card would.
    @ViewBuilder
    private func clusterRow(label: String, count: Int, busy: Double?) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(Typo.captionValue)
                .foregroundStyle(.secondary)
                .frame(width: 9, alignment: .leading)
            Text("\(count)c")
                .font(Typo.caption)
                .foregroundStyle(.tertiary)
                .frame(width: 18, alignment: .leading)

            GaugeBar(utilization: busy ?? 0, direction: .used)

            // An em dash rather than 0% for the first tick, when there is no
            // delta yet: showing 0% would claim the cluster is idle.
            Text(busy.map(Formatters.percent) ?? "—")
                .font(Typo.captionValue)
                .foregroundStyle(busy.map { PulseColor.threshold(utilization: $0) } ?? .secondary)
                .lineLimit(1)
                .fixedSize()
                .frame(width: 32, alignment: .trailing)
        }
    }

    private var loadText: String {
        String(format: "%.2f / %.2f / %.2f", sample.load1, sample.load5, sample.load15)
    }
}

/// Memory: used/total gauge, history, kernel pressure, compressed and swap.
private struct MemoryCard: View {
    let sample: SystemSample
    let history: [Double]

    var body: some View {
        CardView {
            VStack(alignment: .leading, spacing: 8) {
                CardTitleRow(systemImage: "memorychip", title: "Memory") {
                    Text(Formatters.percent(sample.memoryUtilization))
                        .font(Typo.gaugeValue)
                        .contentTransition(.numericText(value: sample.memoryUtilization))
                        .animation(Motion.numberTick, value: sample.memoryUtilization)
                }

                GaugeBar(
                    utilization: sample.memoryUtilization,
                    color: pressureColor,
                    direction: .used
                )
                .help("Used \(Formatters.bytes(sample.memoryUsed)) of \(Formatters.bytes(sample.memoryTotal)). Kernel memory pressure: \(sample.memoryPressure.label).")

                // Same treatment as CPU: the number says how full memory is,
                // the shape says whether it is still climbing - which is the
                // part that decides whether to start another agent.
                Sparkline(values: history, color: pressureColor)
                    .frame(height: 26)

                HStack(spacing: 4) {
                    Text(Formatters.bytes(sample.memoryUsed))
                        .foregroundStyle(.primary)
                    Text("/ \(Formatters.bytes(sample.memoryTotal))")
                    Spacer(minLength: 4)
                    if sample.memoryPressure != .normal {
                        Text(sample.memoryPressure.label)
                            .foregroundStyle(pressureColor)
                    }
                }
                .font(Typo.captionValue)
                .foregroundStyle(.secondary)

                HStack(spacing: 4) {
                    Text("compressed \(Formatters.bytes(sample.memoryCompressed))")
                    Spacer(minLength: 4)
                    Text("swap \(Formatters.bytes(sample.swapUsed))")
                        .foregroundStyle(sample.swapUsed > 0 ? AnyShapeStyle(swapColor) : AnyShapeStyle(.secondary))
                }
                .font(Typo.caption)
                .foregroundStyle(.secondary)
                .help("Compressed memory and swap both mean the machine ran out of room for the pages it wanted. Swap in use while an agent runs is the first thing to look at when everything feels slow.")
            }
        }
    }

    /// Pressure, not the ratio, drives the colour: macOS keeps memory nominally
    /// full of cache on purpose, so a red bar at 85% "used" with normal
    /// pressure would cry wolf on every healthy Mac.
    private var pressureColor: Color {
        switch sample.memoryPressure {
        case .normal: PulseColor.threshold(utilization: sample.memoryUtilization)
        case .warning: PulseColor.warnStrong
        case .critical: PulseColor.critical
        }
    }

    private var swapColor: Color {
        sample.swapUsed > 2_000_000_000 ? PulseColor.critical : PulseColor.warn
    }
}

/// Disk free on the boot volume - the thing that silently kills a long agent
/// run that is writing logs, caches and node_modules.
///
/// No sparkline here on purpose: free space moves in gigabytes over hours, so a
/// two-minute history would be a flat line on every healthy machine and would
/// imply the number is worth watching second by second. The reclaimable figure
/// is the useful extra instead.
private struct StorageCard: View {
    let sample: SystemSample

    var body: some View {
        CardView {
            VStack(alignment: .leading, spacing: 8) {
                CardTitleRow(systemImage: "internaldrive", title: "Disk") {
                    Text(Formatters.bytes(sample.diskFree))
                        .font(Typo.gaugeValue)
                }

                GaugeBar(utilization: sample.diskUtilization, direction: .used)

                HStack {
                    Text("free of \(Formatters.bytes(sample.diskTotal))")
                    Spacer(minLength: 4)
                    Text(Formatters.percent(sample.diskUtilization) + " used")
                }
                .font(Typo.caption)
                .foregroundStyle(.secondary)

                // Only shown when there is something to reclaim: a permanent
                // "reclaimable 0 B" row would be noise on a machine with no
                // cache to evict.
                if sample.diskPurgeable > 0 {
                    HStack {
                        Text("reclaimable cache")
                        Spacer(minLength: 4)
                        Text(Formatters.bytes(sample.diskPurgeable))
                            .foregroundStyle(.primary)
                    }
                    .font(Typo.caption)
                    .foregroundStyle(.secondary)
                    .help("Caches, snapshots and downloads macOS will evict when something needs the space. Counted inside the free figure above, so it is already promised to you - but it is not empty space today.")
                }
            }
        }
    }
}

/// The few processes actually eating the machine right now, ranked by one
/// metric. Two instances of this sit in the column - CPU and memory - because
/// the two rankings answer different questions: what is burning the machine
/// *now* versus what is holding the RAM a new agent would need.
private struct TopProcessesCard: View {
    /// Which column is the ranking, and therefore which one is emphasised. The
    /// other metric still shows, dimmed, so a row is never missing the number
    /// the neighbouring card ranks by.
    enum Metric { case cpu, memory }

    let title: String
    let systemImage: String
    let processes: [ProcessSample]
    let metric: Metric

    var body: some View {
        CardView {
            VStack(alignment: .leading, spacing: 8) {
                CardTitleRow(systemImage: systemImage, title: title) { EmptyView() }

                if processes.isEmpty {
                    Text("Sampling…")
                        .font(Typo.footer)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 5) {
                        ForEach(processes) { process in
                            row(process)
                        }
                    }
                }
            }
        }
    }

    private func row(_ process: ProcessSample) -> some View {
        HStack(spacing: 6) {
            Text(ProcessSample.displayName(process.name))
                .font(Typo.tableLabel)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
                // The name is the only field that identifies the row, so it
                // wins the space fight with the numeric columns rather than
                // being squeezed into "com....ntent".
                .layoutPriority(1)

            Spacer(minLength: 4)

            // Secondary metric first, dimmed: it is context for the ranked
            // number, and putting it last would compete with the value the
            // card is sorted by. Fixed width and no wrapping - a long process
            // name otherwise squeezes this column until "15%" wraps to two
            // lines and the row doubles in height.
            Text(secondaryText(process))
                .font(Typo.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()

            Text(primaryText(process))
                .font(Typo.captionValue)
                .foregroundStyle(primaryColor(process))
                .lineLimit(1)
                .fixedSize()
                .frame(width: 38, alignment: .trailing)
        }
        .help("PID \(process.pid) · \(process.name) · \(Formatters.percent(process.cpu)) of one core · \(Formatters.bytes(process.memory)) resident")
    }

    private func primaryText(_ process: ProcessSample) -> String {
        switch metric {
        case .cpu: Formatters.percent(process.cpu)
        case .memory: Formatters.compactBytes(process.memory)
        }
    }

    private func secondaryText(_ process: ProcessSample) -> String {
        switch metric {
        case .cpu: Formatters.compactBytes(process.memory)
        case .memory: Formatters.percent(process.cpu)
        }
    }

    /// Only the CPU ranking is threshold-coloured. There is no equivalent
    /// "too much" line for a single process's memory - a 4 GB browser is
    /// normal on a 32 GB Mac and alarming on an 8 GB one - and colouring it
    /// against an invented threshold would signal a problem that is not there.
    private func primaryColor(_ process: ProcessSample) -> Color {
        switch metric {
        case .cpu: PulseColor.threshold(utilization: process.cpu)
        case .memory: .primary
        }
    }
}

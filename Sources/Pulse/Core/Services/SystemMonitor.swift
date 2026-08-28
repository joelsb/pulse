import Darwin
import Foundation
import Observation

/// One reading of the local machine's resources.
///
/// Deliberately a plain value: the sampler produces it off the main actor, the
/// UI only ever renders one. Every byte count is raw bytes so formatting stays
/// a UI concern.
struct SystemSample: Sendable, Equatable {
    /// 0...100 across all cores combined (what Activity Monitor's "% CPU"
    /// column sums to divided by core count).
    var cpuTotal: Double = 0
    var cpuUser: Double = 0
    var cpuSystem: Double = 0
    var coreCount: Int = 1

    /// Unix load averages. Read against `coreCount`: load == cores means the
    /// run queue is exactly saturated, which is the number that actually
    /// predicts whether one more local agent will thrash.
    var load1: Double = 0
    var load5: Double = 0
    var load15: Double = 0

    /// Activity Monitor's "Memory Used": app memory + wired + compressed.
    var memoryUsed: Int64 = 0
    var memoryTotal: Int64 = 0
    var memoryCompressed: Int64 = 0
    var memoryPressure: MemoryPressure = .normal

    var swapUsed: Int64 = 0
    var swapTotal: Int64 = 0

    var diskFree: Int64 = 0
    var diskTotal: Int64 = 0
    /// Reclaimable space: caches, snapshots and downloads macOS would evict on
    /// demand. It is `...ForImportantUsage - ...AvailableCapacity`, i.e. the gap
    /// between what the system promises an important write and what is free
    /// right now. Worth showing because "11 GB free" and "11 GB free of which
    /// 0.8 GB is cache the system will hand back" are different situations.
    var diskPurgeable: Int64 = 0

    var thermal: ProcessInfo.ThermalState = .nominal

    /// Heaviest processes by CPU, already trimmed to what the card shows.
    var topProcesses: [ProcessSample] = []
    /// Heaviest processes by resident memory. A separate list, not a re-sort of
    /// `topProcesses`: the two rankings overlap by only a row or two in
    /// practice, and sorting a CPU top-5 by memory would just show the memory
    /// of whatever happened to be busy.
    var topMemoryProcesses: [ProcessSample] = []

    /// Utilization 0...100 for the gauges, guarding division by an unknown total.
    var memoryUtilization: Double {
        guard memoryTotal > 0 else { return 0 }
        return min(100, Double(memoryUsed) / Double(memoryTotal) * 100)
    }

    var diskUtilization: Double {
        guard diskTotal > 0 else { return 0 }
        return min(100, Double(diskTotal - diskFree) / Double(diskTotal) * 100)
    }

    /// Load as a share of the machine's parallelism, capped for display.
    var loadUtilization: Double {
        guard coreCount > 0 else { return 0 }
        return min(100, load1 / Double(coreCount) * 100)
    }

    /// The kernel's own memory-pressure verdict, which is NOT the same as the
    /// used/total ratio: macOS keeps memory nominally "full" of cache and only
    /// reports warn/critical once it starts fighting for pages.
    enum MemoryPressure: Int, Sendable, Equatable {
        case normal = 1
        case warning = 2
        case critical = 4

        var label: String {
            switch self {
            case .normal: "normal"
            case .warning: "warning"
            case .critical: "critical"
            }
        }
    }
}

/// One process row: pid, command, CPU share and resident bytes.
struct ProcessSample: Sendable, Equatable, Identifiable {
    var id: Int32 { pid }
    var pid: Int32
    var name: String
    /// Percent of ONE core, exactly as `ps` reports it, so a busy compiler can
    /// legitimately exceed 100.
    var cpu: Double
    var memory: Int64

    /// Short label for a 210pt column.
    ///
    /// macOS process names are often reverse-DNS bundle ids
    /// (`com.apple.WebKit.WebContent`), and truncating one from the middle
    /// produces `com....ntent`, which identifies nothing. The informative part
    /// is the tail, so the domain prefix is dropped instead.
    static func displayName(_ raw: String) -> String {
        guard raw.hasPrefix("com.") || raw.hasPrefix("org.") || raw.hasPrefix("net.") else {
            return raw
        }
        let parts = raw.split(separator: ".")
        // "com.apple.WebKit.WebContent" -> "WebKit.WebContent": the last two
        // components, since the final one alone ("WebContent") loses which
        // subsystem it belongs to.
        guard parts.count > 3 else {
            return parts.dropFirst(2).joined(separator: ".")
        }
        return parts.suffix(2).joined(separator: ".")
    }
}

/// Reads host counters. An actor because CPU percentage is a delta between two
/// readings, so the previous tick's ticks are state that must not be raced.
actor SystemSampler {
    private var previousTicks: CPUTicks?

    private struct CPUTicks {
        var user: UInt64
        var system: UInt64
        var idle: UInt64
        var nice: UInt64

        var total: UInt64 { user &+ system &+ idle &+ nice }
    }

    /// Number of process rows kept per card. Five is what fits a 210pt column
    /// without the card becoming a scroll surface.
    private let processLimit = 5

    func sample(includeProcesses: Bool = true) -> SystemSample {
        var result = SystemSample()
        result.coreCount = ProcessInfo.processInfo.activeProcessorCount
        result.memoryTotal = Int64(ProcessInfo.processInfo.physicalMemory)
        result.thermal = ProcessInfo.processInfo.thermalState

        applyCPU(to: &result)
        applyMemory(to: &result)
        applyLoad(to: &result)
        applySwap(to: &result)
        applyDisk(to: &result)
        if includeProcesses {
            let all = Self.readProcessTable()
            result.topProcesses = Self.top(all, by: { $0.cpu }, limit: processLimit)
            result.topMemoryProcesses = Self.top(all, by: { Double($0.memory) }, limit: processLimit)
        }
        return result
    }

    // MARK: - CPU

    private func applyCPU(to sample: inout SystemSample) {
        guard let ticks = Self.readCPUTicks() else { return }
        defer { previousTicks = ticks }

        // The first reading has no baseline. Reporting the since-boot average
        // there would show a number that is real but answers a different
        // question ("was this Mac busy this month"), so it stays at zero for
        // one tick instead.
        guard let previous = previousTicks else { return }

        let deltaTotal = Double(ticks.total &- previous.total)
        guard deltaTotal > 0 else { return }

        let user = Double((ticks.user &- previous.user) &+ (ticks.nice &- previous.nice))
        let system = Double(ticks.system &- previous.system)
        sample.cpuUser = min(100, user / deltaTotal * 100)
        sample.cpuSystem = min(100, system / deltaTotal * 100)
        sample.cpuTotal = min(100, sample.cpuUser + sample.cpuSystem)
    }

    private static func readCPUTicks() -> CPUTicks? {
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return CPUTicks(
            user: UInt64(info.cpu_ticks.0),
            system: UInt64(info.cpu_ticks.1),
            idle: UInt64(info.cpu_ticks.2),
            nice: UInt64(info.cpu_ticks.3)
        )
    }

    // MARK: - Memory

    private func applyMemory(to sample: inout SystemSample) {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride
        )
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return }

        // `vm_kernel_page_size` is a global var and therefore not
        // concurrency-safe under Swift 6; `host_page_size` asks the kernel for
        // the same number through a call.
        var rawPageSize: vm_size_t = 0
        guard host_page_size(mach_host_self(), &rawPageSize) == KERN_SUCCESS else { return }
        let pageSize = Int64(rawPageSize)
        // Activity Monitor's "Memory Used": app memory (internal, minus what is
        // purgeable) + wired + compressed. Plain `total - free` would report a
        // permanently near-full Mac, because the kernel keeps freed pages as
        // cache on purpose.
        let appPages = Int64(stats.internal_page_count) - Int64(stats.purgeable_count)
        let wiredPages = Int64(stats.wire_count)
        let compressedPages = Int64(stats.compressor_page_count)
        sample.memoryUsed = max(0, (appPages + wiredPages + compressedPages) * pageSize)
        sample.memoryCompressed = compressedPages * pageSize
        sample.memoryPressure = Self.readMemoryPressure()
    }

    private static func readMemoryPressure() -> SystemSample.MemoryPressure {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else {
            return .normal
        }
        return SystemSample.MemoryPressure(rawValue: Int(level)) ?? .normal
    }

    // MARK: - Load, swap, disk

    private func applyLoad(to sample: inout SystemSample) {
        var loads = [Double](repeating: 0, count: 3)
        guard getloadavg(&loads, 3) == 3 else { return }
        sample.load1 = loads[0]
        sample.load5 = loads[1]
        sample.load15 = loads[2]
    }

    private func applySwap(to sample: inout SystemSample) {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return }
        sample.swapUsed = Int64(usage.xsu_used)
        sample.swapTotal = Int64(usage.xsu_total)
    }

    private func applyDisk(to sample: inout SystemSample) {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        guard let values = try? url.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey,
            .volumeTotalCapacityKey,
        ]) else { return }
        // "Important usage" is the number Finder shows: it counts purgeable
        // space the system would evict for you, unlike volumeAvailableCapacity.
        //
        // Reading the HOME directory, not "/": on APFS the root is a read-only
        // system snapshot, so `df /` reports 51% while the data volume holding
        // the user's files is at 97%. A clean, plausible, wrong answer.
        sample.diskFree = values.volumeAvailableCapacityForImportantUsage ?? 0
        sample.diskTotal = Int64(values.volumeTotalCapacity ?? 0)
        // The difference between the two available-capacity keys IS the
        // reclaimable cache; there is no direct "purgeable" key.
        let immediatelyFree = Int64(values.volumeAvailableCapacity ?? 0)
        sample.diskPurgeable = max(0, sample.diskFree - immediatelyFree)
    }

    // MARK: - Processes

    /// Full process table via `ps`, ranked afterwards. libproc would avoid the
    /// spawn, but it has no per-process CPU *percentage* — only cumulative
    /// time, which would need its own per-pid delta bookkeeping for a card that
    /// refreshes every two seconds while a panel is open.
    ///
    /// One spawn serves both cards: asking `ps` twice with different sort flags
    /// would double the cost and, worse, let the two lists come from different
    /// instants, so a process could appear with disagreeing figures in the two
    /// cards at the same moment.
    private static func readProcessTable() -> [ProcessSample] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        // -c shows the executable name without its full path. No sort flag:
        // ranking happens here, once per metric.
        process.arguments = ["-Aceo", "pid,pcpu,rss,comm"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return []
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard let text = String(data: data, encoding: .utf8) else { return [] }
        // No limit here: the table must be complete before it can be ranked, or
        // the memory card would only ever rank the first N lines `ps` printed.
        return parseProcessList(text, limit: Int.max)
    }

    /// Highest `metric` first. Split out so both rankings are one tested path.
    static func top(
        _ processes: [ProcessSample],
        by metric: (ProcessSample) -> Double,
        limit: Int
    ) -> [ProcessSample] {
        processes.sorted { metric($0) > metric($1) }.prefix(limit).map { $0 }
    }

    /// Split out from the spawn so the parsing is testable against captured
    /// `ps` output rather than whatever happens to be running.
    static func parseProcessList(_ text: String, limit: Int) -> [ProcessSample] {
        var rows: [ProcessSample] = []
        for line in text.split(separator: "\n").dropFirst() {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 4,
                  let pid = Int32(fields[0]),
                  let cpu = Double(fields[1]),
                  let rss = Int64(fields[2])
            else { continue }
            // A command can contain spaces, so everything after RSS is the name.
            let name = fields.dropFirst(3).joined(separator: " ")
            rows.append(ProcessSample(pid: pid, name: name, cpu: cpu, memory: rss * 1024))
            if rows.count == limit { break }
        }
        return rows
    }
}

/// Observable machine stats for the panel: polls only while something is
/// rendering it, keeps a short CPU history for the sparkline.
@MainActor
@Observable
final class SystemMonitor {
    private(set) var sample = SystemSample()
    /// Newest last, oldest first. Bounded so an all-day panel cannot grow it.
    private(set) var cpuHistory: [Double] = []
    /// Memory utilization history, same cadence and bound as `cpuHistory`.
    /// Kept separate rather than as a tuple series so each card animates on
    /// its own value and neither redraws when only the other moved.
    private(set) var memoryHistory: [Double] = []
    /// False until the first delta-based reading lands, so the card can show a
    /// placeholder instead of a fake 0%.
    private(set) var hasSample = false

    /// Seconds between readings while visible. Fast enough to watch an agent
    /// spin up a build, slow enough that the `ps` spawn is noise.
    var interval: TimeInterval = 2

    static let historyLimit = 60

    private let sampler = SystemSampler()
    private var subscribers = 0
    private var loop: Task<Void, Never>?

    /// Ref-counted so several views (both panel layouts, previews) can hold the
    /// monitor alive without one disappearing stopping the others.
    func addSubscriber() {
        subscribers += 1
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.poll()
                try? await Task.sleep(for: .seconds(self.interval))
            }
        }
    }

    func removeSubscriber() {
        subscribers = max(0, subscribers - 1)
        guard subscribers == 0 else { return }
        loop?.cancel()
        loop = nil
    }

    func poll() async {
        let next = await sampler.sample()
        apply(next)
    }

    /// Separated from `poll` so tests can drive the observable state without a
    /// real host reading.
    func apply(_ next: SystemSample) {
        sample = next
        hasSample = true
        Self.append(next.cpuTotal, to: &cpuHistory)
        Self.append(next.memoryUtilization, to: &memoryHistory)
    }

    /// Appends and trims in one place, so the two series can never drift out of
    /// step on length or trimming rule.
    private static func append(_ value: Double, to series: inout [Double]) {
        series.append(value)
        if series.count > historyLimit {
            series.removeFirst(series.count - historyLimit)
        }
    }
}

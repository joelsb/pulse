// Assertions for the system-stats sidebar, compiled against the real sources
// by scripts/verify-system-stats.sh. Prints "ALL PASS" only when every check
// holds; the script's planted-defect run requires each defect to break at
// least one of these.
//
// Two kinds of check here, on purpose:
//   1. Fabricated input (captured `ps` output, synthetic samples) for the
//      parsing and arithmetic, so the expected values are exact.
//   2. A live read of THIS machine, because the whole feature is host counters
//      and a sampler that compiles but reads nothing would pass every
//      fixture-only test.

import Foundation

// Top-level bindings in `main.swift` are main-actor isolated, but the check
// helpers are called from ordinary top-level code that the compiler treats as
// nonisolated. Everything here runs on one thread in sequence, so the unsafe
// opt-out is accurate rather than a papering-over.
nonisolated(unsafe) var failures: [String] = []

func check(_ condition: Bool, _ label: String) {
    if !condition { failures.append(label) }
}

func checkEqual<T: Equatable>(_ lhs: T, _ rhs: T, _ label: String) {
    if lhs != rhs { failures.append("\(label): got \(lhs), expected \(rhs)") }
}

func checkClose(_ lhs: Double, _ rhs: Double, _ label: String, tolerance: Double = 0.001) {
    if abs(lhs - rhs) > tolerance { failures.append("\(label): got \(lhs), expected \(rhs)") }
}

// MARK: - 1. `ps` parsing

// Real shape of `ps -Aceo pid,pcpu,rss,comm -r`: padded columns, RSS in KB,
// and a command containing a space.
let psOutput = """
  PID  %CPU    RSS COMM
  412  92.4 1048576 Xcode
    1   7.1   32768 launchd
  903   3.4  524288 Google Chrome
   77   0.0    4096 loginwindow
   88   0.0    2048 sleepimage
"""

let rows = SystemSampler.parseProcessList(psOutput, limit: 4)
checkEqual(rows.count, 4, "row limit honored")
checkEqual(rows.first?.pid ?? 0, 412, "pid parsed")
checkEqual(rows.first?.name ?? "", "Xcode", "command parsed")
checkClose(rows.first?.cpu ?? 0, 92.4, "cpu parsed")
// RSS is KILOBYTES. Treating it as bytes understates memory by 1024x, which
// looks plausible on screen ("1 MB") and is the whole reason this is asserted.
checkEqual(rows.first?.memory ?? 0, 1_048_576 * 1024, "rss converted from KB to bytes")
checkEqual(rows[2].name, "Google Chrome", "multi-word command not truncated")
checkEqual(SystemSampler.parseProcessList(psOutput, limit: 99).count, 5, "limit above row count")

let garbage = """
PID %CPU RSS COMM
notapid x y z
5 1.0 1024 kernel_task
"""
let garbageRows = SystemSampler.parseProcessList(garbage, limit: 4)
checkEqual(garbageRows.count, 1, "malformed lines skipped")
checkEqual(garbageRows.first?.name ?? "", "kernel_task", "valid line after garbage still parsed")

// MARK: - 2. Derived utilizations

var sample = SystemSample()
sample.memoryUsed = 24_000_000_000
sample.memoryTotal = 32_000_000_000
sample.diskTotal = 1_000_000_000_000
sample.diskFree = 250_000_000_000
sample.coreCount = 10
sample.load1 = 5

checkClose(sample.memoryUtilization, 75, "memory utilization")
// Disk gauge shows USED, so 250 GB free of 1 TB is 75% used, not 25%.
checkClose(sample.diskUtilization, 75, "disk utilization is used, not free")
checkClose(sample.loadUtilization, 50, "load as share of cores")

let empty = SystemSample()
checkEqual(empty.memoryUtilization, 0, "unknown memory total does not divide by zero")
checkEqual(empty.diskUtilization, 0, "unknown disk total does not divide by zero")
checkEqual(empty.loadUtilization, 0, "zero load reads zero")

var overloaded = SystemSample()
overloaded.coreCount = 4
overloaded.load1 = 40
checkEqual(overloaded.loadUtilization, 100, "load saturates at 100")

var overfull = SystemSample()
overfull.memoryTotal = 100
overfull.memoryUsed = 300
checkEqual(overfull.memoryUtilization, 100, "memory utilization caps at 100")

// MARK: - 3. Byte formatting

checkEqual(Formatters.bytes(512), "512 B", "bytes under 1k")
checkEqual(Formatters.bytes(1500), "1.5 KB", "kilobytes")
checkEqual(Formatters.bytes(24_000_000_000), "24 GB", "gigabytes")
checkEqual(Formatters.bytes(1_250_000_000_000), "1.3 TB", "terabytes")

// MARK: - 3a. Two independent rankings

// Deliberately built so the two rankings DISAGREE: the biggest CPU consumer is
// not the biggest memory consumer, and one heavy-memory process is idle. A
// memory card that merely re-sorted the CPU top-N would miss `bigidle`
// entirely, which is the whole reason the two lists are gathered separately.
let table = [
    ProcessSample(pid: 1, name: "spinner", cpu: 95, memory: 100_000_000),
    ProcessSample(pid: 2, name: "medium", cpu: 40, memory: 800_000_000),
    ProcessSample(pid: 3, name: "bigidle", cpu: 0.2, memory: 6_000_000_000),
    ProcessSample(pid: 4, name: "small", cpu: 12, memory: 20_000_000),
    ProcessSample(pid: 5, name: "hog", cpu: 60, memory: 3_000_000_000),
    ProcessSample(pid: 6, name: "tiny", cpu: 1, memory: 5_000_000),
]

let byCPU = SystemSampler.top(table, by: { $0.cpu }, limit: 5)
checkEqual(byCPU.map(\.name), ["spinner", "hog", "medium", "small", "tiny"], "CPU ranking order")

let byMemory = SystemSampler.top(table, by: { Double($0.memory) }, limit: 5)
checkEqual(byMemory.map(\.name), ["bigidle", "hog", "medium", "spinner", "small"], "memory ranking order")

// The specific defect: an idle memory hog must appear in the memory card even
// though it is nowhere near the top of the CPU card.
check(byMemory.first?.name == "bigidle", "idle memory hog leads the memory ranking")
check(!byCPU.prefix(2).map(\.name).contains("bigidle"), "idle memory hog is not near the top by CPU")

checkEqual(SystemSampler.top(table, by: { $0.cpu }, limit: 2).count, 2, "ranking honors its limit")
checkEqual(SystemSampler.top([], by: { $0.cpu }, limit: 5).count, 0, "empty table ranks empty")

// MARK: - 3b. Narrow-column display helpers

// Reverse-DNS bundle ids are the case that broke on screen: middle-truncation
// rendered `com.apple.WebKit.WebContent` as "com....ntent", which names nothing.
checkEqual(ProcessSample.displayName("com.apple.WebKit.WebContent"), "WebKit.WebContent", "bundle id keeps the informative tail")
checkEqual(ProcessSample.displayName("com.apple.Safari"), "Safari", "short bundle id drops the domain")
// A plain command name must survive untouched — mangling `rustc` would be worse
// than the problem being fixed.
checkEqual(ProcessSample.displayName("rustc"), "rustc", "plain command untouched")
checkEqual(ProcessSample.displayName("WindowServer"), "WindowServer", "capitalised command untouched")
checkEqual(ProcessSample.displayName("kernel_task"), "kernel_task", "underscored command untouched")

checkEqual(Formatters.compactBytes(1_600_000_000), "1.6G", "compact gigabytes")
checkEqual(Formatters.compactBytes(310_000_000), "310M", "compact megabytes")
checkEqual(Formatters.compactBytes(512), "512B", "compact bytes")
// No space: the whole point is fitting a narrow column beside the process name.
check(!Formatters.compactBytes(1_600_000_000).contains(" "), "compact bytes carry no space")

// MARK: - 4. Live host counters
//
// The point of the feature. Every number below comes from this Mac.

let sampler = SystemSampler()

// A top-level `main.swift` runs ON the main actor, so blocking it with a
// semaphore while an actor-isolated Task needs to be scheduled deadlocks
// outright (17 minutes of nothing, observed 2026-08-28). `RunLoop` is not a fix
// either: the sampler's actor hops need the main thread free. Instead the async
// work runs on a detached thread and the main thread waits on a plain lock that
// nothing async needs.
final class Box: @unchecked Sendable {
    var first = SystemSample()
    var second = SystemSample()
}
let sampleBox = Box()
let done = DispatchSemaphore(value: 0)

Thread.detachNewThread {
    let inner = DispatchSemaphore(value: 0)
    Task.detached {
        // First reading only establishes the CPU tick baseline.
        sampleBox.first = await sampler.sample(includeProcesses: false)
        // Burn CPU so the delta between readings is provably non-zero: asserting
        // cpuTotal > 0 on an idle machine would be flaky, after spinning it is not.
        let deadline = Date().addingTimeInterval(0.4)
        var spin = 0.0
        while Date() < deadline { spin += Double.random(in: 0...1) }
        if spin < 0 { print("unreachable \(spin)") }
        sampleBox.second = await sampler.sample()
        inner.signal()
    }
    // A hard cap, so a future regression that never completes fails the run in
    // 30 seconds instead of hanging the verifier forever.
    if inner.wait(timeout: .now() + 30) == .timedOut {
        print("FAIL: sampling did not complete within 30s")
        exit(1)
    }
    done.signal()
}
if done.wait(timeout: .now() + 40) == .timedOut {
    print("FAIL: sampler thread never finished")
    exit(1)
}

let live = sampleBox.first
let second = sampleBox.second

check(live.coreCount >= 1, "core count read from host")
checkEqual(live.coreCount, ProcessInfo.processInfo.activeProcessorCount, "core count matches ProcessInfo")
checkEqual(live.memoryTotal, Int64(ProcessInfo.processInfo.physicalMemory), "physical memory matches ProcessInfo")

// First reading has no baseline, so it must report 0 rather than the
// since-boot average (a real number that answers the wrong question).
checkEqual(live.cpuTotal, 0, "first CPU reading has no baseline")

check(second.memoryUsed > 0, "memory used is read")
check(second.memoryUsed < second.memoryTotal, "memory used below physical total")
// Cross-check the memory figure against an INDEPENDENT implementation: the
// `/usr/bin/vm_stat` binary, parsed from its text output, rather than the Mach
// call the sampler uses. A loose bound ("< 97%") is NOT enough — the classic
// wrong formula (everything not free counted as used) lands inside any
// plausible range and sails straight through, which is the whole defect this
// assertion exists to catch.
//
// NOTE ON THE ORACLE: `top` reports "PhysMem: 14G used" on this machine while
// the correct figure is ~10.8 GB. That is not a bug in either — `top` uses
// total-minus-free, which counts the file cache the kernel holds on purpose,
// whereas Activity Monitor's "Memory Used" is app + wired + compressed and
// excludes it. Pulse follows Activity Monitor, because that is the number the
// user can actually check against. `top` was tried as the oracle first and
// rejected for measuring a different thing.
func vmStatPages() -> [String: Double]? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/vm_stat")
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard let text = String(data: data, encoding: .utf8) else { return nil }

    var pages: [String: Double] = [:]
    for line in text.split(separator: "\n") {
        guard let colon = line.firstIndex(of: ":") else { continue }
        let key = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces)
        let raw = line[line.index(after: colon)...]
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: ".", with: "")
        if let value = Double(raw) { pages[key] = value }
    }
    // The header carries the page size: "(page size of 16384 bytes)".
    if let range = text.range(of: #"page size of (\d+) bytes"#, options: .regularExpression) {
        let digits = text[range].filter(\.isNumber)
        if let size = Double(digits) { pages["__pagesize"] = size }
    }
    return pages
}

if let pages = vmStatPages(),
   let pageSize = pages["__pagesize"],
   let wired = pages["Pages wired down"],
   let purgeable = pages["Pages purgeable"],
   let compressor = pages["Pages occupied by compressor"],
   let anonymous = pages["Anonymous pages"],
   let free = pages["Pages free"] {

    // `vm_stat` prints "Anonymous pages" directly, which IS Activity Monitor's
    // app memory before the purgeable subtraction — no reconstruction from
    // active/inactive/speculative needed, and no chance of double-counting the
    // file cache while doing it.
    let expectedUsed = (anonymous - purgeable + wired + compressor) * pageSize
    let ours = Double(second.memoryUsed)
    // Both readings come seconds apart from a live machine, so exact equality
    // is not available; 1.2 GB of slack covers real drift and stays far below
    // the multi-gigabyte error a wrong formula introduces.
    let deltaGB = abs(ours - expectedUsed) / 1_073_741_824
    check(
        deltaGB < 1.2,
        "memory used agrees with vm_stat (ours \(Formatters.bytes(second.memoryUsed)), vm_stat \(Formatters.bytes(Int64(expectedUsed))), off by \(String(format: "%.2f", deltaGB)) GB)"
    )

    // The specific wrong formula, asserted directly: whatever the sampler
    // reports, it must NOT be total-minus-free, or the file cache is counted as
    // consumed memory and the gauge sits red on a perfectly healthy Mac.
    let total = Double(ProcessInfo.processInfo.physicalMemory)
    let totalMinusFree = total - free * pageSize
    check(
        abs(ours - totalMinusFree) / 1_073_741_824 > 1.0,
        "memory used is not total-minus-free (ours \(Formatters.bytes(second.memoryUsed)), total-free \(Formatters.bytes(Int64(totalMinusFree))))"
    )
} else {
    failures.append("could not read vm_stat to cross-check memory")
}

check(second.diskTotal > 0, "disk total read")
check(second.diskFree > 0, "disk free read")
check(second.diskFree <= second.diskTotal, "disk free within total")
check(second.load1 >= 0, "load average read")
check(second.cpuTotal > 0, "second CPU reading sees the spin (got \(second.cpuTotal)%)")
check(second.cpuTotal <= 100, "CPU capped at 100")
checkClose(second.cpuUser + second.cpuSystem, second.cpuTotal, "cpu total is user + system", tolerance: 0.01)

// This process is always running, so an empty list means the spawn or the
// parser broke, not that the machine is quiet.
check(!second.topProcesses.isEmpty, "top processes read from the live machine")
check(second.topProcesses.allSatisfy { $0.pid > 0 }, "live pids are positive")
check(second.topProcesses.allSatisfy { !$0.name.isEmpty }, "live process names non-empty")
check(second.topProcesses.allSatisfy { $0.memory > 0 }, "live processes report resident memory")

// Both cards must be populated from the SAME `ps` pass.
check(!second.topMemoryProcesses.isEmpty, "memory ranking read from the live machine")
checkEqual(second.topProcesses.count, 5, "CPU card shows five rows")
checkEqual(second.topMemoryProcesses.count, 5, "memory card shows five rows")
check(
    zip(second.topMemoryProcesses, second.topMemoryProcesses.dropFirst()).allSatisfy { $0.memory >= $1.memory },
    "live memory ranking is sorted by resident bytes descending"
)
// The re-sort defect's exact signature: if the memory card were built by
// re-sorting the CPU top-5, every pid in it would necessarily also be in the
// CPU list. Comparing the two ORDERS is not enough — a re-sort is a
// permutation, so the orders differ and the check passes while the bug is
// live. Subset is the property that actually distinguishes the two
// implementations.
let cpuPIDs = Set(second.topProcesses.map(\.pid))
let memoryPIDs = Set(second.topMemoryProcesses.map(\.pid))
check(
    !memoryPIDs.isSubset(of: cpuPIDs),
    "memory ranking is drawn from the whole process table, not a re-sort of the CPU top-5 (cpu \(cpuPIDs.sorted()), mem \(memoryPIDs.sorted()))"
)
// Corollary: the heaviest process by memory on the machine must be at least as
// heavy as anything the CPU card happened to include.
if let heaviest = second.topMemoryProcesses.first,
   let heaviestInCPUList = second.topProcesses.map(\.memory).max() {
    check(
        heaviest.memory >= heaviestInCPUList,
        "top memory process outranks everything in the CPU card"
    )
}
// Every row in either card must exist in the other's source table, i.e. one
// process cannot report different memory in the two cards.
for row in second.topMemoryProcesses {
    if let twin = second.topProcesses.first(where: { $0.pid == row.pid }) {
        checkEqual(twin.memory, row.memory, "pid \(row.pid) reports one memory figure in both cards")
        checkEqual(twin.cpu, row.cpu, "pid \(row.pid) reports one CPU figure in both cards")
    }
}
// `ps -r` sorts by CPU descending; if it did not, the card would show four
// arbitrary processes and still look correct.
check(
    zip(second.topProcesses, second.topProcesses.dropFirst()).allSatisfy { $0.cpu >= $1.cpu },
    "top processes are sorted by CPU descending"
)

// MARK: - 5. Sparkline geometry

let box = CGSize(width: 100, height: 50)
let points = Sparkline.points([0, 50, 100], in: box, maximum: 100)
checkEqual(points.count, 3, "one point per sample")
checkEqual(points[0], CGPoint(x: 0, y: 50), "0% sits on the baseline")
checkEqual(points[1], CGPoint(x: 50, y: 25), "50% sits mid-box")
// y grows downward in SwiftUI, so 100% must be y == 0, not y == height.
checkEqual(points[2], CGPoint(x: 100, y: 0), "100% touches the top edge")

let clamped = Sparkline.points([-20, 300], in: CGSize(width: 10, height: 10), maximum: 100)
checkEqual(clamped[0].y, 10, "negative values clamp to the baseline")
checkEqual(clamped[1].y, 0, "over-range values clamp to the top")

check(Sparkline.points([42], in: box, maximum: 100).isEmpty, "single sample draws no path")
check(Sparkline.points([], in: box, maximum: 100).isEmpty, "empty history draws no path")

// MARK: - Report

if failures.isEmpty {
    print("ALL PASS")
    print("live: \(live.coreCount) cores, RAM \(Formatters.bytes(second.memoryUsed))/\(Formatters.bytes(second.memoryTotal)) (\(Int(second.memoryUtilization))%), pressure \(second.memoryPressure.label), CPU \(String(format: "%.1f", second.cpuTotal))%, load \(String(format: "%.2f", second.load1)), swap \(Formatters.bytes(second.swapUsed)), disk free \(Formatters.bytes(second.diskFree))")
    print("top: " + second.topProcesses.map { "\($0.name) \(String(format: "%.1f", $0.cpu))%" }.joined(separator: ", "))
} else {
    for failure in failures { print("FAIL: \(failure)") }
    exit(1)
}

import Foundation
import Testing
@testable import Pulse

// Fixtures are fabricated: realistic record shapes (docs/RESEARCH) with fake
// ids/paths — never real tokens or real on-disk data.

// MARK: - Shared helpers

private func gregorian(secondsFromGMT: Int = 2 * 3600) -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: secondsFromGMT)!
    return calendar
}

private func day(_ string: String, calendar: Calendar) -> Date {
    let formatter = ClaudeLogParser.localDayFormatter()
    formatter.calendar = calendar
    formatter.timeZone = calendar.timeZone
    return formatter.date(from: string)!
}

// MARK: - Breakdown models & shared utilities

@Suite("Breakdown models")
struct BreakdownModelTests {
    @Test func timeframeDaysAndLabels() {
        #expect(BreakdownTimeframe.last7Days.days == 7)
        #expect(BreakdownTimeframe.last30Days.days == 30)
        #expect(BreakdownTimeframe.lastYear.days == 366)
        #expect(BreakdownTimeframe.allCases.map(\.label) == ["7 days", "30 days", "1 year"])
    }

    @Test func abbreviatesHomeDirectoryOnly() {
        let home = AppPaths.home.path
        #expect(AppPaths.abbreviatingHome("\(home)/Code/x") == "~/Code/x")
        #expect(AppPaths.abbreviatingHome(home) == "~")
        // A path that merely *starts with* the home string but isn't under it
        // must not be collapsed.
        #expect(AppPaths.abbreviatingHome("\(home)-backup/x") == "\(home)-backup/x")
        #expect(AppPaths.abbreviatingHome("/opt/other") == "/opt/other")
    }

    @Test func projectDisplayNameAndPath() {
        #expect(ProjectDisplay.name(cwd: "/Users/me/usage-tracker", fallback: "k") == "usage-tracker")
        #expect(ProjectDisplay.name(cwd: nil, fallback: "fallback-key") == "fallback-key")
        #expect(ProjectDisplay.name(cwd: "", fallback: "fallback-key") == "fallback-key")
        #expect(ProjectDisplay.displayPath(cwd: "/opt/x", fallback: "k") == "/opt/x")
        #expect(ProjectDisplay.displayPath(cwd: nil, fallback: "raw-key") == "raw-key")
    }

    @Test func modelSharesSumToOneHundredAndSort() {
        let shares = UsageMath.modelShares([
            "opus-4.8": TokenTotals(input: 600, output: 150),   // 750
            "haiku-4.5": TokenTotals(input: 200, output: 50),   // 250
        ])
        #expect(shares.map(\.model) == ["opus-4.8", "haiku-4.5"])
        #expect(abs(shares[0].share - 75) < 0.001)
        #expect(abs(shares[1].share - 25) < 0.001)
    }

    @Test func aggregatorMergesSessionsIntoProjects() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        var aggregator = ProjectUsageAggregator()
        aggregator.add(
            SessionUsage(id: "s1", totals: TokenTotals(input: 100), startedAt: nil, lastActivity: now, isActive: false),
            projectKey: "proj-a", displayPath: "~/a", name: "a"
        )
        aggregator.add(
            SessionUsage(id: "s2", totals: TokenTotals(input: 300), startedAt: nil, lastActivity: now.addingTimeInterval(60), isActive: true),
            projectKey: "proj-a", displayPath: "~/a", name: "a"
        )
        aggregator.add(
            SessionUsage(id: "s3", totals: TokenTotals(input: 50), startedAt: nil, lastActivity: now, isActive: false),
            projectKey: "proj-b", displayPath: "~/b", name: "b"
        )

        let projects = aggregator.projects()
        // proj-a (400) sorts before proj-b (50).
        #expect(projects.map(\.id) == ["proj-a", "proj-b"])
        let a = projects[0]
        #expect(a.sessionCount == 2)
        #expect(a.totals.input == 400)
        #expect(a.isActive) // any active session marks the project active
        #expect(a.lastActivity == now.addingTimeInterval(60))
        // Sessions within the project are sorted by total desc.
        #expect(a.sessions.map(\.id) == ["s2", "s1"])
    }
}

// MARK: - Claude breakdown: parse (identity capture)

@Suite("Claude breakdown parse")
struct ClaudeBreakdownParseTests {
    private func assistantLine(
        cwd: String = "/Users/test/myproj",
        gitBranch: String = "main",
        timestamp: String = "2026-06-18T10:00:00.000Z",
        model: String = "claude-opus-4-8",
        input: Int64 = 1000,
        output: Int64 = 500,
        id: String = "msg_1",
        requestID: String = "req_1"
    ) -> String {
        #"{"type":"assistant","cwd":"\#(cwd)","gitBranch":"\#(gitBranch)","sessionId":"s","timestamp":"\#(timestamp)","requestId":"\#(requestID)","message":{"id":"\#(id)","model":"\#(model)","usage":{"input_tokens":\#(input),"output_tokens":\#(output),"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}"#
    }

    private func writeSession(projectDir: String, fileName: String, lines: [String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pulse-bd-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(projectDir, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent(fileName)
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test func capturesIdentityBranchTitleAndSpan() throws {
        let url = try writeSession(
            projectDir: "-Users-test-myproj",
            fileName: "session-abc.jsonl",
            lines: [
                #"{"type":"ai-title","aiTitle":"Refactor the parser","sessionId":"session-abc"}"#,
                assistantLine(timestamp: "2026-06-18T10:00:00.000Z", input: 100),
                assistantLine(gitBranch: "feature/x", timestamp: "2026-06-18T11:30:00.000Z", input: 200, id: "msg_2", requestID: "req_2"),
            ]
        )
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent().deletingLastPathComponent()) }

        let session = try ClaudeLogParser.parseSession(url, captureTitles: true)
        #expect(session.projectKey == "-Users-test-myproj")
        #expect(session.projectPath == "/Users/test/myproj")
        #expect(session.sessionID == "session-abc")
        #expect(session.title == "Refactor the parser")
        #expect(session.gitBranch == "feature/x") // last-seen branch wins
        #expect(session.entries.count == 2)

        let iso = ClaudeISO8601()
        #expect(session.firstActivity == iso.date(from: "2026-06-18T10:00:00.000Z"))
        #expect(session.lastActivity == iso.date(from: "2026-06-18T11:30:00.000Z"))
    }

    @Test func contentBlindModeSkipsTitle() throws {
        let url = try writeSession(
            projectDir: "-Users-test-proj",
            fileName: "s.jsonl",
            lines: [
                #"{"type":"ai-title","aiTitle":"Sensitive prompt summary","sessionId":"s"}"#,
                assistantLine(cwd: "/Users/test/proj"),
            ]
        )
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent().deletingLastPathComponent()) }

        let blind = try ClaudeLogParser.parseSession(url, captureTitles: false)
        #expect(blind.title == nil) // never read in content-blind mode
        #expect(blind.entries.count == 1) // usage still parsed
        #expect(blind.projectPath == "/Users/test/proj") // cwd is metadata, still captured
    }

    @Test func endToEndBreakdownGroupsByProject() async throws {
        let calendar = gregorian()
        let now = day("2026-06-18", calendar: calendar).addingTimeInterval(12 * 3600)

        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("pulse-bd-e2e-\(UUID().uuidString)", isDirectory: true)
        let projA = base.appendingPathComponent("-Users-test-alpha", isDirectory: true)
        let projB = base.appendingPathComponent("-Users-test-beta", isDirectory: true)
        for dir in [projA, projB] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: base) }

        try [assistantLine(cwd: "/Users/test/alpha", input: 1000, output: 1000)]
            .joined(separator: "\n")
            .write(to: projA.appendingPathComponent("a1.jsonl"), atomically: true, encoding: .utf8)
        try [assistantLine(cwd: "/Users/test/alpha", input: 500, output: 0, id: "msg_a2", requestID: "req_a2")]
            .joined(separator: "\n")
            .write(to: projA.appendingPathComponent("a2.jsonl"), atomically: true, encoding: .utf8)
        try [assistantLine(cwd: "/Users/test/beta", input: 100, output: 0, id: "msg_b", requestID: "req_b")]
            .joined(separator: "\n")
            .write(to: projB.appendingPathComponent("b1.jsonl"), atomically: true, encoding: .utf8)

        let parser = ClaudeLogParser(projectsRoot: base, captureTitles: true, cacheName: "test-\(UUID().uuidString)")
        let projects = await parser.breakdown(timeframe: .lastYear, now: now)

        #expect(projects.map(\.name) == ["alpha", "beta"]) // alpha (2500 tokens) first
        let alpha = try #require(projects.first)
        #expect(alpha.sessionCount == 2)
        #expect(alpha.displayPath == "~/test/alpha" || alpha.displayPath == "/Users/test/alpha")
        #expect(alpha.totals.total == 2500) // a1: 1000+1000, a2: 500+0
        #expect(alpha.sessions.map(\.id).sorted() == ["a1", "a2"])
    }
}

// MARK: - Claude breakdown: rollup (grouping, timeframe, liveness)

@Suite("Claude breakdown rollup")
struct ClaudeBreakdownRollupTests {
    private let calendar = gregorian()

    private var now: Date { day("2026-06-18", calendar: calendar).addingTimeInterval(12 * 3600) }

    private func entry(day: String, model: String = "claude-opus-4-8", input: Int64) -> ClaudeLogParser.Entry {
        ClaudeLogParser.Entry(key: nil, day: day, model: model, input: input, output: 0, cacheRead: 0, cacheWrite5m: 0, cacheWrite1h: 0)
    }

    private func session(
        key: String,
        id: String,
        entries: [ClaudeLogParser.Entry],
        lastActivity: Date?
    ) -> ClaudeLogParser.SessionFile {
        ClaudeLogParser.SessionFile(
            projectKey: key,
            projectPath: "/Users/test/\(key.split(separator: "-").last ?? "x")",
            sessionID: id,
            gitBranch: "main",
            title: "Title \(id)",
            firstActivity: lastActivity,
            lastActivity: lastActivity,
            entries: entries
        )
    }

    @Test func timeframeFiltersByEntryDay() {
        let s = session(
            key: "-p", id: "s1",
            entries: [
                entry(day: "2026-06-18", input: 100), // in 7d
                entry(day: "2026-06-10", input: 40),  // out of 7d, in 30d
                entry(day: "2026-04-01", input: 7),   // in 1y only
            ],
            lastActivity: now
        )

        let week = ClaudeLogParser.rollUpBreakdown([s], timeframe: .last7Days, calendar: calendar, now: now)
        #expect(week.first?.totals.input == 100)

        let month = ClaudeLogParser.rollUpBreakdown([s], timeframe: .last30Days, calendar: calendar, now: now)
        #expect(month.first?.totals.input == 140)

        let year = ClaudeLogParser.rollUpBreakdown([s], timeframe: .lastYear, calendar: calendar, now: now)
        #expect(year.first?.totals.input == 147)
    }

    @Test func dropsSessionsWithNoInFrameUsage() {
        let stale = session(key: "-p", id: "old", entries: [entry(day: "2026-01-01", input: 999)], lastActivity: now)
        let fresh = session(key: "-p", id: "new", entries: [entry(day: "2026-06-18", input: 10)], lastActivity: now)
        let projects = ClaudeLogParser.rollUpBreakdown([stale, fresh], timeframe: .last7Days, calendar: calendar, now: now)
        #expect(projects.count == 1)
        #expect(projects[0].sessionCount == 1)
        #expect(projects[0].sessions.first?.id == "new")
    }

    @Test func groupsSessionsAndCarriesTitleAndModelBreakdown() {
        let s1 = session(key: "-Users-test-alpha", id: "s1", entries: [
            entry(day: "2026-06-18", model: "claude-opus-4-8", input: 300),
            entry(day: "2026-06-18", model: "claude-haiku-4-5", input: 100),
        ], lastActivity: now)
        let s2 = session(key: "-Users-test-alpha", id: "s2", entries: [entry(day: "2026-06-18", input: 100)], lastActivity: now)
        let s3 = session(key: "-Users-test-beta", id: "s3", entries: [entry(day: "2026-06-18", input: 50)], lastActivity: now)

        let projects = ClaudeLogParser.rollUpBreakdown([s1, s2, s3], timeframe: .last7Days, calendar: calendar, now: now)
        #expect(projects.map(\.name) == ["alpha", "beta"])

        let alpha = projects[0]
        #expect(alpha.sessionCount == 2)
        #expect(alpha.totals.input == 500)
        #expect(alpha.sessions.map(\.id) == ["s1", "s2"]) // by total desc
        #expect(alpha.sessions[0].title == "Title s1")
        #expect(alpha.sessions[0].gitBranch == "main")
        // s1's per-model split: 300 opus / 100 haiku.
        #expect(alpha.sessions[0].modelBreakdown.map(\.model) == ["opus-4.8", "haiku-4.5"])
    }

    @Test func livenessFromLastActivityThreshold() {
        let live = session(key: "-p", id: "live", entries: [entry(day: "2026-06-18", input: 10)], lastActivity: now.addingTimeInterval(-60))
        let idle = session(key: "-q", id: "idle", entries: [entry(day: "2026-06-18", input: 10)], lastActivity: now.addingTimeInterval(-600))
        let projects = ClaudeLogParser.rollUpBreakdown([live, idle], timeframe: .last7Days, calendar: calendar, now: now)

        let liveProject = try? #require(projects.first { $0.id == "-p" })
        let idleProject = try? #require(projects.first { $0.id == "-q" })
        #expect(liveProject?.isActive == true)
        #expect(liveProject?.sessions.first?.isActive == true)
        #expect(idleProject?.isActive == false)
    }

    @Test func emptyInputYieldsNoProjects() {
        #expect(ClaudeLogParser.rollUpBreakdown([], timeframe: .lastYear, calendar: calendar, now: now).isEmpty)
    }
}

// MARK: - Codex breakdown

@Suite("Codex breakdown")
struct CodexBreakdownTests {
    private let calendar = gregorian()
    private var now: Date { day("2026-06-18", calendar: calendar).addingTimeInterval(12 * 3600) }

    private func writeSession(lines: [String], dateDir: String = "2026/06/18", name: String = "rollout-2026-06-18T09-00-00-019eabc4-7764-7091-a4be-8ef3ab07f760.jsonl") throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pulse-codex-bd-\(UUID().uuidString)/\(dateDir)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test func aggregateCapturesCwdSessionIDAndSpan() throws {
        let url = try writeSession(lines: [
            #"{"timestamp":"2026-06-18T09:00:00.000Z","type":"session_meta","payload":{"id":"019eabc4-7764-7091-a4be-8ef3ab07f760","cwd":"/Users/test/proj","originator":"Codex"}}"#,
            #"{"timestamp":"2026-06-18T09:01:00.000Z","type":"turn_context","payload":{"model":"gpt-5-codex","cwd":"/Users/test/proj"}}"#,
            #"{"timestamp":"2026-06-18T09:02:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"cached_input_tokens":200,"output_tokens":100,"total_tokens":1100}}}}"#,
        ])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()) }

        let aggregate = try CodexSessionParser.aggregate(file: url)
        #expect(aggregate.cwd == "/Users/test/proj")
        #expect(aggregate.sessionID == "019eabc4-7764-7091-a4be-8ef3ab07f760")
        #expect(aggregate.dayKey == "2026-06-18")
        #expect(aggregate.models["gpt-5-codex"]?.input == 1000)
        #expect(aggregate.firstActivity == CodexSessionParser.parseISO("2026-06-18T09:00:00.000Z"))
        #expect(aggregate.lastActivity == CodexSessionParser.parseISO("2026-06-18T09:02:00.000Z"))
    }

    @Test func sessionIDFallsBackToFilenameUUID() throws {
        // No session_meta → id comes from the rollout filename's UUID.
        let url = try writeSession(lines: [
            #"{"timestamp":"2026-06-18T09:01:00.000Z","type":"turn_context","payload":{"model":"gpt-5-codex","cwd":"/Users/test/p"}}"#,
            #"{"timestamp":"2026-06-18T09:02:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":10,"cached_input_tokens":0,"output_tokens":5,"total_tokens":15}}}}"#,
        ])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()) }

        let aggregate = try CodexSessionParser.aggregate(file: url)
        #expect(aggregate.sessionID == "019eabc4-7764-7091-a4be-8ef3ab07f760")
    }

    private func aggregate(cwd: String?, id: String, dayKey: String, input: Int64, lastActivity: Date?) -> CodexSessionParser.FileAggregate {
        CodexSessionParser.FileAggregate(
            dayKey: dayKey,
            models: ["gpt-5-codex": .init(input: input, cached: 0, output: 0)],
            cwd: cwd,
            sessionID: id,
            lastActivity: lastActivity
        )
    }

    @Test func rollupGroupsByCwdAndComputesCost() {
        let a1 = aggregate(cwd: "/Users/test/alpha", id: "a1", dayKey: "2026-06-18", input: 1000, lastActivity: now)
        let a2 = aggregate(cwd: "/Users/test/alpha", id: "a2", dayKey: "2026-06-17", input: 500, lastActivity: now)
        let b1 = aggregate(cwd: "/Users/test/beta", id: "b1", dayKey: "2026-06-18", input: 100, lastActivity: now)

        let projects = CodexSessionParser.rollUpBreakdown([a1, a2, b1], timeframe: .last7Days, calendar: calendar, now: now)
        #expect(projects.map(\.name) == ["alpha", "beta"])
        let alpha = projects[0]
        #expect(alpha.sessionCount == 2)
        #expect(alpha.totals.input == 1500)
        // gpt-5-codex: $1.25 / MTok input, no output/cache tokens in this fixture:
        // 1500 / 1_000_000 * 1.25 = 0.001875.
        #expect(abs((alpha.totals.costUSD ?? 0) - 0.001875) < 0.0000001)
    }

    @Test func rollupFiltersByDayKey() {
        let recent = aggregate(cwd: "/Users/test/p", id: "r", dayKey: "2026-06-18", input: 10, lastActivity: now)
        let old = aggregate(cwd: "/Users/test/p", id: "o", dayKey: "2026-05-01", input: 99, lastActivity: now)
        let week = CodexSessionParser.rollUpBreakdown([recent, old], timeframe: .last7Days, calendar: calendar, now: now)
        #expect(week.count == 1)
        #expect(week[0].sessionCount == 1)
        #expect(week[0].sessions.first?.id == "r")
    }

    @Test func emptyModelsSessionsAreDropped() {
        let empty = CodexSessionParser.FileAggregate(dayKey: "2026-06-18", models: [:], cwd: "/Users/test/p", sessionID: "e")
        #expect(CodexSessionParser.rollUpBreakdown([empty], timeframe: .lastYear, calendar: calendar, now: now).isEmpty)
    }
}

// MARK: - ProjectUsageService

@Suite("ProjectUsageService")
struct ProjectUsageServiceTests {
    @Test func exposesOnlyBreakdownCapableProvidersInCanonicalOrder() {
        let service = ProjectUsageService(providers: ProviderFactory.makeAll())
        // Only the local-log providers conform; order follows ProviderID.allCases.
        #expect(service.supportedProviderIDs == [.claude, .codex])
    }

    @Test func unsupportedProvidersYieldNil() async {
        let service = ProjectUsageService(providers: ProviderFactory.makeAll())
        #expect(await service.breakdown(for: .cursor, timeframe: .last7Days) == nil)
        #expect(await service.breakdown(for: .gemini, timeframe: .last7Days) == nil)
        #expect(await service.breakdown(for: .copilot, timeframe: .last7Days) == nil)
    }
}

// MARK: - Sorting, content-blind strip & persisted preferences

@Suite("Breakdown preferences & sorting")
struct BreakdownPreferenceTests {
    private func project(_ id: String, name: String, tokens: Int64, cost: Double?, last: TimeInterval) -> ProjectUsage {
        ProjectUsage(
            id: id, displayPath: name, name: name,
            totals: TokenTotals(input: tokens, costUSD: cost),
            sessionCount: 1, lastActivity: Date(timeIntervalSince1970: last), isActive: false
        )
    }

    @Test func sortOrders() {
        let all = [
            project("a", name: "Zeta", tokens: 100, cost: 5.0, last: 300),
            project("b", name: "alpha", tokens: 300, cost: 1.0, last: 100),
            project("c", name: "Mid", tokens: 200, cost: nil, last: 200),
        ]
        #expect(BreakdownSort.tokens.sorted(all).map(\.id) == ["b", "c", "a"]) // 300, 200, 100
        #expect(BreakdownSort.cost.sorted(all).map(\.id) == ["a", "b", "c"])   // 5, 1, nil→-1
        #expect(BreakdownSort.recent.sorted(all).map(\.id) == ["a", "c", "b"]) // 300, 200, 100
        #expect(BreakdownSort.name.sorted(all).map(\.id) == ["b", "c", "a"])   // alpha, Mid, Zeta
    }

    @Test func hidingTitlesClearsEverySessionButKeepsMetadata() {
        let session = SessionUsage(
            id: "s", title: "secret prompt summary", gitBranch: "main",
            totals: TokenTotals(input: 1), startedAt: nil, lastActivity: Date(timeIntervalSince1970: 1), isActive: false
        )
        let project = ProjectUsage(
            id: "p", displayPath: "~/p", name: "p",
            totals: TokenTotals(input: 1), sessionCount: 1,
            lastActivity: Date(timeIntervalSince1970: 1), isActive: false, sessions: [session]
        )
        let breakdown = ProjectBreakdown(
            providerID: .claude, timeframe: .last7Days, generatedAt: Date(timeIntervalSince1970: 1),
            projects: [project], grandTotal: TokenTotals(input: 1), showsCost: true
        )

        let blind = breakdown.hidingSessionTitles()
        #expect(blind.projects[0].sessions[0].title == nil)
        #expect(blind.projects[0].sessions[0].gitBranch == "main") // branch is metadata, kept
        #expect(breakdown.projects[0].sessions[0].title == "secret prompt summary") // original untouched
    }

    @MainActor
    @Test func persistsBreakdownPreferences() {
        let suite = UserDefaults(suiteName: "pulse-test-\(UUID().uuidString)")!
        let store = SettingsStore(defaults: suite)
        store.breakdownProvider = .codex
        store.breakdownTimeframe = .lastYear
        store.breakdownSort = .cost
        store.useSessionTitles = false

        let reloaded = SettingsStore(defaults: suite)
        #expect(reloaded.breakdownProvider == .codex)
        #expect(reloaded.breakdownTimeframe == .lastYear)
        #expect(reloaded.breakdownSort == .cost)
        #expect(reloaded.useSessionTitles == false)
    }

    @MainActor
    @Test func sessionTitlesDefaultOn() {
        let suite = UserDefaults(suiteName: "pulse-test-\(UUID().uuidString)")!
        #expect(SettingsStore(defaults: suite).useSessionTitles)
    }
}

// MARK: - Demo data (--demo-data screenshots/website mirror)

@Suite("Demo breakdown data")
struct DemoBreakdownDataTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func claudeDemoHasByteProjectsWithCostAndAnActiveSession() async throws {
        let breakdown = try #require(
            await DemoBreakdownProvider(id: .claude).projectBreakdown(timeframe: .last30Days, sources: .all, now: now)
        )
        #expect(breakdown.showsCost)
        #expect(Set(breakdown.projects.map(\.name)) == ["byte-pulse", "pulse-website", "byte-ui", "byte-api", "byte-cli"])
        #expect(breakdown.projects.first?.name == "byte-pulse") // highest token total
        #expect(breakdown.grandTotal.costUSD != nil)
        #expect(breakdown.projects.contains { $0.isActive })
        // Project totals equal the sum of their sessions (structurally real).
        for project in breakdown.projects {
            let summed = project.sessions.reduce(into: TokenTotals()) { $0.add($1.totals) }
            #expect(summed.total == project.totals.total)
        }
    }

    @Test func codexDemoHasTokensButNoCostOrTitles() async throws {
        let breakdown = try #require(
            await DemoBreakdownProvider(id: .codex).projectBreakdown(timeframe: .last30Days, sources: .all, now: now)
        )
        #expect(!breakdown.showsCost)
        #expect(breakdown.grandTotal.total > 0)
        #expect(breakdown.grandTotal.costUSD == nil)
        // Codex carries no CLI titles — mirrors the real source.
        #expect(breakdown.projects.allSatisfy { project in project.sessions.allSatisfy { $0.title == nil } })
    }

    @Test func unsupportedDemoProviderIsNil() async {
        #expect(await DemoBreakdownProvider(id: .cursor).projectBreakdown(timeframe: .last7Days, sources: .all, now: now) == nil)
    }

    @Test func serviceAcceptsBreakdownProvidersDirectly() async {
        let service = ProjectUsageService(breakdownProviders: DemoBreakdownProvider.all)
        #expect(service.supportedProviderIDs == [.claude, .codex])
        #expect(await service.breakdown(for: .claude, timeframe: .last30Days, now: now) != nil)
        #expect(await service.breakdown(for: .cursor, timeframe: .last30Days, now: now) == nil)
    }
}

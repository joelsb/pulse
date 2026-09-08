import Foundation

/// OpenAI Codex CLI usage: live ChatGPT-account rate limits (wham/usage) with
/// a session-log fallback, plus token history parsed from local session files.
actor CodexProvider: UsageProvider, ProjectBreakdownProviding {
    nonisolated let id: ProviderID = .codex
    nonisolated let descriptor = ProviderDescriptor(
        id: .codex,
        name: "Codex",
        shortCode: "CDX",
        appBundleID: "com.openai.chat",
        webURL: URL(string: "https://chatgpt.com/codex")!,
        setupHint: "Sign in to the Codex CLI to start tracking."
    )

    private let api: CodexUsageAPI
    private let parser: CodexSessionParser
    private let authFileURL: URL
    private let jcodeStore: JcodeOpenAICredentialsStore
    private let piAuthFileURL: URL
    /// Pulse's own Codex OAuth grant (JSB-9). Tried FIRST in `loadCandidates`,
    /// same reasoning as `ClaudeProvider.pulseOAuthStore`: it is the only
    /// source Pulse itself refreshes, so it never silently goes stale the way
    /// a harness-owned copy does the moment that harness stops running.
    private let codexOAuthStore: CodexOAuthStore

    init(
        http: HTTPClient = HTTPClient(),
        authFileURL: URL = CodexAuth.defaultFileURL,
        jcodeStore: JcodeOpenAICredentialsStore = JcodeOpenAICredentialsStore(),
        piAuthFileURL: URL = AppPaths.home.appendingPathComponent(".pi/agent/auth.json"),
        codexOAuthStore: CodexOAuthStore = CodexOAuthStore(),
        parser: CodexSessionParser = CodexSessionParser()
    ) {
        self.api = CodexUsageAPI(http: http)
        self.authFileURL = authFileURL
        self.jcodeStore = jcodeStore
        self.piAuthFileURL = piAuthFileURL
        self.codexOAuthStore = codexOAuthStore
        self.parser = parser
    }

    func probeConnection() async -> ProviderConnection {
        // A Pulse-owned grant with no harness ever having signed in — the
        // case this feature exists for — must not read as "not connected".
        if await codexOAuthStore.hasGrant() { return .available }
        do {
            _ = try CodexAuth.load(from: authFileURL)
            return .available
        } catch let error as ProviderFetchError {
            if case .notLoggedIn(let hint) = error {
                if !freshFallbackCandidates().isEmpty { return .available }
                return .notConnected(hint: hint)
            }
            return .available // parse hiccup: let fetch() surface the real error
        } catch {
            return .notConnected(hint: descriptor.setupHint)
        }
    }

    /// Where a candidate token came from, kept only for readability while
    /// building the chain — never surfaced to the UI.
    private enum CredentialSource: Sendable { case pulse, codexCLI, jcode, pi }

    private struct Candidate: Sendable {
        var source: CredentialSource
        var auth: CodexAuth
    }

    /// Every source that currently holds an unexpired Codex token, in the
    /// same freshest-non-expired-first order `ClaudeProvider.freshCandidates`
    /// uses — JSB-9's fallback chain. Reads the raw files fresh every call
    /// (cheap; these are re-read on every fetch the same way
    /// `ClaudeCredentialsStore`'s file path is).
    private func freshFallbackCandidates() -> [Candidate] {
        var result: [Candidate] = []
        if let cli = try? CodexAuth.load(from: authFileURL), !cli.isExpired() {
            result.append(Candidate(source: .codexCLI, auth: cli))
        }
        if let jcode = jcodeStore.credentials(), !jcode.isExpired() {
            result.append(Candidate(source: .jcode, auth: jcode))
        }
        if let pi = PiOpenAICodexCredentials.credentials(from: piAuthFileURL), !pi.isExpired() {
            result.append(Candidate(source: .pi, auth: pi))
        }
        return result
    }

    /// Picks a token, tries it, and retries down the freshest-first list on a
    /// 401 — mirrors `ClaudeProvider.loadLimits`/`fetchLimits`. Pulse's own
    /// grant leads regardless of the others' freshness (never rotated by a
    /// harness Pulse doesn't control); an already-expired token is never even
    /// attempted (JSB-8's rule, same reason: a dead token earns a 429 that
    /// then blocks the live one).
    private func loadCandidates() async -> [Candidate] {
        var candidates: [Candidate] = []
        if let pulse = await codexOAuthStore.credentials() {
            candidates.append(Candidate(source: .pulse, auth: CodexAuth(
                accessToken: pulse.accessToken,
                accountID: pulse.accountID,
                expiresAt: pulse.expiresAt.timeIntervalSince1970 * 1000
            )))
        }
        var harnessCandidates = freshFallbackCandidates()
        harnessCandidates.sort { ($0.auth.expiresAt ?? .infinity) > ($1.auth.expiresAt ?? .infinity) }
        candidates.append(contentsOf: harnessCandidates)
        return candidates
    }

    private func fetchUsage(candidates: [Candidate]) async -> (response: CodexUsageResponse?, winner: CodexAuth?, winnerSource: CredentialSource?, error: ProviderFetchError?) {
        guard let first = candidates.first else { return (nil, nil, nil, nil) }
        do {
            let response = try await api.fetchUsage(auth: first.auth)
            return (response, first.auth, first.source, nil)
        } catch ProviderFetchError.unauthorized {
            let remaining = Array(candidates.dropFirst())
            guard !remaining.isEmpty else { return (nil, first.auth, first.source, .unauthorized) }
            return await fetchUsage(candidates: remaining)
        } catch let error as ProviderFetchError {
            return (nil, first.auth, first.source, error)
        } catch {
            return (nil, first.auth, first.source, .network(description: "\(error)"))
        }
    }

    func fetch() async throws -> UsageSnapshot {
        let now = Date.now
        let candidates = await loadCandidates()

        async let reportTask = parser.report(now: now)
        let (response, winnerAuth, winnerSource, limitsError) = await fetchUsage(candidates: candidates)
        let auth = winnerAuth ?? (try? CodexAuth.load(from: authFileURL))
        guard let auth else {
            throw limitsError ?? ProviderFetchError.notLoggedIn(hint: descriptor.setupHint)
        }
        let report = await reportTask

        var snapshot = UsageSnapshot(providerID: .codex, fetchedAt: now)
        snapshot.plan = auth.plan ?? response?.planType.map(CodexAuth.planDisplayName)
        snapshot.accountLabel = auth.accountLabel
        // "Count the provider's own logs" gates the *usage* read from those
        // logs, never the limits: the rate-limit fallback below still comes
        // from the newest session file, because a window's reset time is a
        // property of the account and not of who spent it. The parse itself
        // still runs (it is cache-warm and the fallback needs it), so this
        // switch changes what is shown, not what is read.
        let countsLogs = UsageSourceGate.shared.current.providerLogs
        snapshot.tokens = countsLogs ? report.tokens : nil
        snapshot.dailyUsage = countsLogs ? report.dailyUsage : []
        snapshot.histograms = countsLogs ? report.histograms : [:]

        if let response {
            let windows = CodexUsageAPI.limitWindows(from: response, now: now)
            snapshot.primary = windows.primary
            snapshot.secondary = windows.secondary
            // A real answer from the live endpoint, so the age caption on a
            // LATER failed poll has something honest to measure from (see
            // ProviderGlanceCard.staleCaption — it deliberately has no
            // fallback for a provider that never sets this).
            snapshot.limitsCapturedAt = now
            if let credits = CodexUsageAPI.creditsNote(from: response) {
                snapshot.statusNotes.append(credits)
            }
        } else if let fallback = report.newestRateLimits {
            applyFallbackLimits(fallback, to: &snapshot, now: now)
        }

        if snapshot.primary == nil && snapshot.tokens == nil {
            throw limitsError ?? .dataUnavailable(description: "No Codex usage data yet — run a Codex session first.")
        }
        if snapshot.primary == nil {
            snapshot.limitsUnavailable = true
            // Same reason as Claude: the scheduler cannot back off on a failure
            // it never sees. See UsageSnapshot.limitsError.
            snapshot.limitsError = limitsError
            snapshot.statusNotes.append("No rate-limit data: \(limitsError?.userMessage ?? "unavailable")")
        }
        // A dead token must not hide behind stale session-log gauges. Review
        // B2: name the right cause — a stalled PULSE rotation needs a Pulse
        // sign-in, and telling Joel to run the Codex CLI for that is actively
        // wrong (the CLI cannot touch Pulse's own Keychain grant at all).
        switch limitsError {
        case .unauthorized, .notLoggedIn:
            if winnerSource == .pulse, await codexOAuthStore.refreshStalled() {
                snapshot.statusNotes.append("Pulse's Codex sign-in stopped refreshing — sign in again from Settings")
            } else {
                snapshot.statusNotes.append("Codex sign-in expired — run `codex` to refresh")
            }
        default:
            break
        }
        return snapshot
    }

    // MARK: - Project / session breakdown

    /// Per-project/session token usage from the local session files, reusing the
    /// same warm cache `fetch()` fills. No cost column — Codex is plan-included.
    func projectBreakdown(
        timeframe: BreakdownTimeframe,
        sources: UsageSourceSelection = UsageSourceGate.shared.current,
        now: Date = .now
    ) async -> ProjectBreakdown? {
        // Codex has exactly one writer: its own CLI. No harness bills it, so
        // the other two flags cannot change this answer.
        guard sources.providerLogs else { return nil }
        let projects = await parser.breakdown(timeframe: timeframe, now: now)
        guard !projects.isEmpty else { return nil }
        let grandTotal = projects.reduce(into: TokenTotals()) { $0.add($1.totals) }
        return ProjectBreakdown(
            providerID: id,
            timeframe: timeframe,
            generatedAt: now,
            projects: projects,
            grandTotal: grandTotal,
            // Costs are computed locally from token counts, same as Claude.
            showsCost: true
        )
    }

    /// Session-log snapshots use `window_minutes` + epoch-second `resets_at`
    /// and go stale as soon as no session is running. Windows whose reset time
    /// has already passed describe a window that no longer exists — showing
    /// their old utilization (with a perpetual "Resets in: <1m") would be a
    /// lie, so they are dropped.
    private func applyFallbackLimits(
        _ fallback: CodexSessionParser.RateLimitSnapshot,
        to snapshot: inout UsageSnapshot,
        now: Date
    ) {
        func window(
            used: Double?, resetsEpoch: Double?, minutes: Double?,
            build: (Double, Date?, TimeInterval?) -> LimitWindow
        ) -> LimitWindow? {
            guard let used else { return nil }
            let resetsAt = resetsEpoch.map { Date(timeIntervalSince1970: $0) }
            if let resetsAt, resetsAt <= now { return nil } // window already rolled over
            return build(used, resetsAt, minutes.map { $0 * 60 })
        }

        snapshot.primary = window(
            used: fallback.primaryUsedPercent,
            resetsEpoch: fallback.primaryResetsAtEpoch,
            minutes: fallback.primaryWindowMinutes,
            build: CodexLimitWindows.fiveHour
        )
        snapshot.secondary = window(
            used: fallback.secondaryUsedPercent,
            resetsEpoch: fallback.secondaryResetsAtEpoch,
            minutes: fallback.secondaryWindowMinutes,
            build: CodexLimitWindows.weekly
        )

        if snapshot.primary != nil, now.timeIntervalSince(fallback.date) > 600 {
            snapshot.statusNotes.append(
                "Limits from last session (\(Formatters.relativeAge(of: fallback.date, now: now)))"
            )
        }
    }
}

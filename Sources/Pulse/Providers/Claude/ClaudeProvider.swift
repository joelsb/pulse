import Foundation

/// Claude usage: live rate-limit windows from the OAuth usage endpoint (the
/// same one Claude Code's `/usage` calls) plus exact token/cost history from
/// the local project logs.
///
/// One instance per Claude Code **account** (`ClaudeAccount`). Each account has
/// its own config dir, log tree, parse cache and Keychain item, so two accounts
/// can never read each other's numbers.
actor ClaudeProvider: UsageProvider, ProjectBreakdownProviding {
    nonisolated let id: ProviderID
    nonisolated let descriptor: ProviderDescriptor

    private let api: ClaudeUsageAPI
    private let credentialsStore: ClaudeCredentialsStore
    private let parser: ClaudeLogParser
    /// jcode sessions billed to this account, folded in alongside the Claude
    /// Code logs. nil when the account has no jcode identity.
    private let jcodeParser: JcodeLogParser?
    /// pi sessions billed to this account, folded in the same way. pi maps its
    /// provider keys (`anthropic`, `anthropic-2`, …) onto the same `claude-N`
    /// labels, so one label drives both harnesses. nil when the account has no
    /// such identity.
    private let piParser: PiLogParser?
    /// Resolves pi's provider keys to accounts. nil when this account has no
    /// Anthropic account id to match against.
    private let piResolver: PiAccountResolver?
    private let accountUUID: String?
    private let jcodeAccountLabels: Set<String>
    /// Email this account signs in as, used to find the same account in jcode's
    /// credential store (a label can be renamed; the mailbox cannot).
    private let email: String?
    /// jcode's credential store, used only as a fallback when Claude Code's
    /// token is expired. nil when the account has no jcode identity.
    private let jcodeCredentialsStore: JcodeCredentialsStore?
    /// Pulse's own OAuth grant for this account (JSB-8). nil when the account
    /// has no Anthropic uuid to key it on. Tried FIRST in `loadLimits()`: it
    /// is the only source Pulse itself refreshes, so it is the only one that
    /// does not silently go stale the moment its owning harness stops running.
    private let pulseOAuthStore: PulseOAuthStore?

    /// Same file `PiAccountResolver` reads by default — not re-derived per
    /// call, and not a second parser: `loadLimits()` uses
    /// `PiAccountResolver.readAuth` (the resolver's own static parser) against
    /// this path, exactly as the resolver itself does internally.
    private static let piAuthFile = AppPaths.home.appendingPathComponent(".pi/agent/auth.json")

    init(
        account: ClaudeAccount,
        http: HTTPClient = HTTPClient(),
        credentialsStore: ClaudeCredentialsStore? = nil,
        parser: ClaudeLogParser? = nil,
        jcodeParser: JcodeLogParser? = nil,
        piParser: PiLogParser? = nil,
        piResolver: PiAccountResolver? = nil,
        pulseOAuthStore: PulseOAuthStore? = nil,
        captureTitles: Bool = true
    ) {
        self.id = account.id
        self.descriptor = ProviderDescriptor(
            id: account.id,
            name: account.name,
            shortCode: account.shortCode,
            appBundleID: "com.anthropic.claudefordesktop",
            webURL: URL(string: "https://claude.ai")!,
            setupHint: "Sign in to Claude Code (\(account.configDir.lastPathComponent)) to start tracking."
        )
        self.api = ClaudeUsageAPI(http: http)
        self.credentialsStore = credentialsStore ?? ClaudeCredentialsStore(
            fileURL: account.credentialsFile,
            keychainService: account.keychainService
        )
        // The primary account keeps the historical cache names, so upgrading
        // doesn't force a full re-parse of thousands of session files.
        self.parser = parser ?? ClaudeLogParser(
            projectsRoot: account.projectsRoot,
            captureTitles: captureTitles,
            cacheName: account.id == .claude
                ? nil
                : "\(account.cacheNamespace)-files-v2\(captureTitles ? "" : "-blind")"
        )
        // Every account shares one jcode cache: the parse is per file and the
        // split by account happens inside it, so parsing twice would be waste.
        self.jcodeAccountLabels = account.jcodeAccountLabels
        self.email = account.email
        self.jcodeParser = account.jcodeAccountLabels.isEmpty
            ? nil
            : (jcodeParser ?? JcodeLogParser(captureTitles: captureTitles))
        // pi attribution rides on the Anthropic account id, not on jcode's
        // labels: an account jcode never saw can still have pi usage.
        self.accountUUID = account.accountUUID
        // pi records no title anywhere, so `captureTitles` has nothing to gate
        // and one cache serves both modes.
        self.piParser = account.accountUUID == nil ? nil : (piParser ?? PiLogParser())
        self.piResolver = account.accountUUID == nil ? nil : (piResolver ?? PiAccountResolver())
        self.jcodeCredentialsStore = account.jcodeAccountLabels.isEmpty
            ? nil
            : JcodeCredentialsStore()
        self.pulseOAuthStore = account.accountUUID == nil ? nil : (pulseOAuthStore ?? PulseOAuthStore())
    }

    /// This account's credentials as jcode holds them, if any.
    private func jcodeCredentials() -> ClaudeCredentials? {
        guard let jcodeCredentialsStore else { return nil }
        // By email first: jcode renames labels, and a stale label silently
        // returns nil, which reads as "no fallback token" rather than as a
        // lookup miss.
        if let email, let byEmail = jcodeCredentialsStore.credentials(forEmail: email) { return byEmail }
        return jcodeAccountLabels.lazy.compactMap(jcodeCredentialsStore.credentials(forAccountLabel:)).first
    }

    /// Claude Code logs plus this account's jcode and pi sessions. Both are
    /// harnesses running against the same account, so their tokens belong in
    /// the same totals.
    private func allSessions(now: Date, sources: UsageSourceSelection) async -> [ClaudeLogParser.SessionFile] {
        async let claudeTask = sources.providerLogs ? parser.sessions(now: now) : []
        async let jcodeTask = sources.jcode ? jcodeSessions(now: now) : []
        async let piTask = sources.pi ? piSessions(now: now) : []
        return await claudeTask + jcodeTask + piTask
    }

    private func jcodeSessions(now: Date) async -> [ClaudeLogParser.SessionFile] {
        guard let jcodeParser, !jcodeAccountLabels.isEmpty else { return [] }
        return await jcodeParser.sessions(for: jcodeAccountLabels, now: now)
    }

    /// pi sessions billed to this account, identified through the resolver.
    /// Nothing is returned when the resolver cannot say — usage on an
    /// unidentifiable key is dropped rather than guessed onto a tab.
    private func piSessions(now: Date) async -> [ClaudeLogParser.SessionFile] {
        guard let piParser, let piResolver, let accountUUID else { return [] }
        let keys = await piResolver.providerKeys(forAccountUUID: accountUUID)
        return await piParser.sessions(for: keys, now: now)
    }

    /// Token/cost report over both harnesses' sessions.
    private func report(now: Date) async -> TokenReportBundle {
        // The panel's own switches, read once per refresh so the token card,
        // the daily chart and the histograms all see one selection.
        let sessions = await allSessions(now: now, sources: UsageSourceGate.shared.current)
        guard !sessions.isEmpty else { return TokenReportBundle(tokens: nil, dailyUsage: []) }
        // Session-aware form: the sub-agent flag lives on the session, so the
        // token card can show the sub-agent slice of Today / This Month.
        return ClaudeLogParser.rollUp(sessions: sessions, calendar: Calendar.current, now: now)
    }

    func probeConnection() async -> ProviderConnection {
        if await credentialsStore.sourceExists() { return .available }
        // An account signed in through jcode but never through Claude Code has
        // no Keychain item, and would otherwise render as "not connected"
        // despite having live credentials and parseable logs.
        if jcodeCredentials() != nil { return .available }
        // An account signed in through Pulse's own OAuth (JSB-8) and nothing
        // else — no Claude Code, no jcode — is the case this whole feature
        // exists for, and must not read as "not connected".
        if let accountUUID, let pulseOAuthStore, await pulseOAuthStore.hasGrant(forAccountUUID: accountUUID) {
            return .available
        }
        return .notConnected(hint: descriptor.setupHint)
    }

    func fetch() async throws -> UsageSnapshot {
        let now = Date.now
        async let reportTask = report(now: now)
        let limits = await loadLimits()
        let report = await reportTask

        var snapshot = UsageSnapshot(providerID: id, fetchedAt: now)
        snapshot.plan = limits.plan

        var limitsError: ProviderFetchError?
        switch limits.windows {
        case .success(let response):
            let mapped = ClaudeUsageAPI.limitWindows(from: response)
            snapshot.primary = mapped.primary
            snapshot.secondary = mapped.secondary
            snapshot.tertiary = mapped.tertiary
            snapshot.extraWindows = mapped.extras
            snapshot.limitsCapturedAt = now
        case .failure(let error):
            limitsError = error
            snapshot.limitsUnavailable = true
            snapshot.limitsError = error
            snapshot.statusNotes.append("Limits unavailable: \(error.userMessage)")
        }

        var logsError: ProviderFetchError?
        if let tokens = report.tokens {
            snapshot.tokens = tokens
            snapshot.dailyUsage = report.dailyUsage
            snapshot.histograms = report.histograms
        } else {
            logsError = .dataUnavailable(description: "No recent Claude Code session logs")
            snapshot.statusNotes.append("Token history unavailable: no recent session logs")
        }

        // One healthy source still makes a useful snapshot; both failing is a
        // fetch failure, surfaced as whichever error is more actionable.
        if let limitsError, let logsError {
            throw Self.moreInformative(limitsError, logsError)
        }
        return snapshot
    }

    // MARK: - Project / session breakdown

    /// Per-project/session usage from the local logs, reusing the same warm
    /// cache `fetch()` fills. Costs are shown (computed from the pricing table).
    func projectBreakdown(
        timeframe: BreakdownTimeframe,
        sources: UsageSourceSelection = UsageSourceGate.shared.current,
        now: Date = .now
    ) async -> ProjectBreakdown? {
        let sessions = await allSessions(now: now, sources: sources)
        let projects = ClaudeLogParser.rollUpBreakdown(
            sessions,
            timeframe: timeframe,
            calendar: Calendar.current,
            now: now
        )
        guard !projects.isEmpty else { return nil }
        let grandTotal = projects.reduce(into: TokenTotals()) { $0.add($1.totals) }
        return ProjectBreakdown(
            providerID: id,
            timeframe: timeframe,
            generatedAt: now,
            projects: projects,
            grandTotal: grandTotal,
            showsCost: true
        )
    }

    // MARK: - Live limits

    private struct Limits: Sendable {
        var plan: String?
        var windows: Result<ClaudeUsageResponse, ProviderFetchError>
    }

    /// Where a candidate token came from, kept only for the retry chain below
    /// (never surfaced to the UI — the card just says "stale" or "expired",
    /// not which store answered).
    private enum CredentialSource: Sendable { case pulse, claudeCode, jcode, pi }

    private struct Candidate: Sendable {
        var source: CredentialSource
        var credentials: ClaudeCredentials
    }

    /// Picks a token to call the usage endpoint with, tries it, and retries
    /// down the freshest-first list on a 401 — generalizing what used to be a
    /// single Claude-Code-vs-jcode fallback into N sources, in this order of
    /// preference:
    ///
    /// 1. **Pulse's own grant** (JSB-8) — the only source Pulse itself
    ///    refreshes, proactively, inside 300s of expiry. Tried first
    ///    regardless of the others' freshness: it is never going to be
    ///    hours-stale the way a harness-owned copy routinely is.
    /// 2. **The freshest NON-EXPIRED token** among Claude Code's own
    ///    Keychain/file store, jcode's `auth.json`, and pi's `auth.json`
    ///    (read through `PiAccountResolver.readAuth` — the resolver's own
    ///    parser, not a second one). "Freshest" = furthest `expiresAt`, since
    ///    none of these carry an issued-at timestamp to compare instead.
    ///
    /// An already-expired token is never even attempted: sending one wastes a
    /// request and, repeated every refresh tick, gets the endpoint to
    /// rate-limit the account (observed 2026-08-28, HTTP 429 with
    /// Retry-After 2808) — the exact failure mode this whole feature exists
    /// to end.
    private func loadLimits() async -> Limits {
        var claudeCodeError: ProviderFetchError?
        let claudeCodeCredentials: ClaudeCredentials?
        do {
            claudeCodeCredentials = try await credentialsStore.credentials()
        } catch {
            claudeCodeCredentials = nil
            claudeCodeError = Self.asFetchError(error)
        }

        var candidates = await freshCandidates(claudeCodeCredentials: claudeCodeCredentials)
        candidates.sort { ($0.credentials.expiresAt ?? 0) > ($1.credentials.expiresAt ?? 0) }
        // Pulse's own grant always leads, even over a harness token that
        // happens to expire further in the future — see the doc comment.
        if let pulseIndex = candidates.firstIndex(where: { $0.source == .pulse }), pulseIndex != 0 {
            candidates.insert(candidates.remove(at: pulseIndex), at: 0)
        }

        guard let winner = candidates.first else {
            // Nothing at all is usable anywhere. Surface Claude Code's own
            // failure when there was one — it is the most actionable message
            // an account with no live token anywhere can show; otherwise its
            // (unexpired-but-rejected-earlier is impossible here, so this
            // means genuinely expired) plan label still names the account.
            return Limits(
                plan: claudeCodeCredentials?.planLabel,
                windows: .failure(claudeCodeError ?? .unauthorized)
            )
        }
        return await fetchLimits(candidates: Array(candidates.dropFirst()), winner: winner, planFallback: claudeCodeCredentials)
    }

    /// Every source that currently holds a token this account could use,
    /// UNFILTERED by expiry — `loadLimits()` filters and orders them.
    private func freshCandidates(claudeCodeCredentials: ClaudeCredentials?) async -> [Candidate] {
        var result: [Candidate] = []

        if let accountUUID, let pulseOAuthStore,
           let pulse = await pulseOAuthStore.credentials(forAccountUUID: accountUUID) {
            // `PulseOAuthStore.credentials` already refreshes and already
            // excludes an expired result, so this candidate is never expired
            // by construction.
            result.append(Candidate(source: .pulse, credentials: ClaudeCredentials(
                accessToken: pulse.accessToken,
                expiresAt: pulse.expiresAt.timeIntervalSince1970 * 1000,
                subscriptionType: nil,
                rateLimitTier: nil
            )))
        }
        if let claudeCodeCredentials, !claudeCodeCredentials.isExpired() {
            result.append(Candidate(source: .claudeCode, credentials: claudeCodeCredentials))
        }
        if let jcode = jcodeCredentials(), !jcode.isExpired() {
            result.append(Candidate(source: .jcode, credentials: jcode))
        }
        if let accountUUID, let piResolver {
            let resolved = await piResolver.resolveAll()
            let keys = resolved.filter { $0.value.accountUUID == accountUUID }.keys
            if !keys.isEmpty {
                let piCredentials = PiAccountResolver.readAuth(Self.piAuthFile)
                if let key = keys.first(where: { piCredentials[$0]?.isExpired == false }),
                   let credential = piCredentials[key] {
                    result.append(Candidate(source: .pi, credentials: ClaudeCredentials(
                        accessToken: credential.accessToken,
                        expiresAt: credential.expiresAt,
                        subscriptionType: nil,
                        rateLimitTier: nil
                    )))
                }
            }
        }
        return result
    }

    /// Calls the usage endpoint with `winner`, falling through the remaining
    /// `candidates` (already freshest-first) on a 401 — a token that looked
    /// unexpired can still be rejected (revoked, clock skew), and the next
    /// candidate is a genuinely different token, not a re-read of the same one.
    private func fetchLimits(candidates: [Candidate], winner: Candidate, planFallback: ClaudeCredentials?) async -> Limits {
        let plan = winner.credentials.planLabel ?? planFallback?.planLabel
        do {
            let response = try await api.fetchUsage(accessToken: winner.credentials.accessToken)
            return Limits(plan: plan, windows: .success(response))
        } catch ProviderFetchError.unauthorized {
            guard let next = candidates.first else {
                return Limits(plan: plan, windows: .failure(.unauthorized))
            }
            return await fetchLimits(candidates: Array(candidates.dropFirst()), winner: next, planFallback: planFallback)
        } catch {
            return Limits(plan: plan, windows: .failure(Self.asFetchError(error)))
        }
    }

    // MARK: - Error shaping

    /// Everything leaving the provider is a `ProviderFetchError`; messages
    /// never carry token material.
    private static func asFetchError(_ error: any Error) -> ProviderFetchError {
        error as? ProviderFetchError ?? .parsing(description: "Claude: unexpected \(type(of: error))")
    }

    /// Auth problems are actionable, parse failures point at real bugs, and
    /// transport blips beat "no data yet" — pick the louder of the two.
    private static func moreInformative(
        _ lhs: ProviderFetchError,
        _ rhs: ProviderFetchError
    ) -> ProviderFetchError {
        func rank(_ error: ProviderFetchError) -> Int {
            switch error {
            case .unauthorized: 5
            case .notLoggedIn: 4
            case .parsing: 3
            // A rate limit outranks a plain HTTP error: it is the one the user
            // can act on (wait, or refresh the token that caused it).
            case .rateLimited: 3
            case .http: 2
            case .network: 1
            case .dataUnavailable: 0
            }
        }
        return rank(rhs) > rank(lhs) ? rhs : lhs
    }
}

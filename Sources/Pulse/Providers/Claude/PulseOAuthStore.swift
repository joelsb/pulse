import Foundation

/// Pulse's own Claude OAuth grants, one per Anthropic account, persisted in
/// the Keychain and refreshed by Pulse on its own schedule — no Claude Code,
/// jcode or pi session has to be running, ever.
///
/// **Storage.** One Keychain SERVICE, `de.byte.pulse.oauth`, holding one item
/// per account, distinguished by `-a <accountUUID>` — never by directory name
/// or file order (see `ClaudeAccount`'s own doc comment on why an ordinal
/// assumption is dangerous: 153.4M tokens were misattributed by exactly that
/// mistake). A second service, `de.byte.pulse.oauth-pending`, holds a rotated
/// pair that has not yet been proven to work — see
/// `docs/adr/0001-refresh-token-rotation-write-order.md` for why that split
/// exists and what it protects against.
actor PulseOAuthStore {
    struct Credentials: Sendable, Equatable {
        var accessToken: String
        var refreshToken: String
        var expiresAt: Date
        var grantedScope: String

        func isExpired(now: Date = .now) -> Bool { now >= expiresAt }

        /// Proactive refresh window: inside this many seconds of expiry, a
        /// reader should rotate before sending the token, not after it starts
        /// failing. 300s matches the plan's own margin and is comfortably
        /// inside Claude Code's 8h token lifetime.
        func needsRefresh(now: Date = .now, within: TimeInterval = 300) -> Bool {
            expiresAt.timeIntervalSince(now) < within
        }
    }

    private static let service = "de.byte.pulse.oauth"
    private static let pendingService = "de.byte.pulse.oauth-pending"

    private let keychain: KeychainReader
    private let writer: KeychainWriter
    private let oauthClient: ClaudeOAuthClient
    /// Test-only seams for `rotate()`'s two network calls. Both default to the
    /// real `oauthClient` / a real `/oauth/usage` probe; a harness overrides
    /// them to control refresh success/failure and verification success/
    /// failure without reaching the live API, while every other line of the
    /// pending→verify→promote control flow — and every Keychain read/write —
    /// still runs for real. See `scripts/verify-oauth-rotation.sh`.
    private let refreshOverride: (@Sendable (String) async throws -> ClaudeOAuthClient.TokenPair)?
    private let verifyOverride: (@Sendable (String) async -> Bool)?
    /// Accounts a rotation attempt has proven dead (`400 invalid_grant`) THIS
    /// run. In-memory only — the durable half is `clearGrant`, which deletes
    /// both Keychain items, so a relaunch reads "no grant" from `read()`
    /// itself without needing this set at all. This set exists so the SAME
    /// run stops retrying the instant it learns the grant is dead, rather
    /// than waiting for the next `credentials(forAccountUUID:)` call to
    /// rediscover it via an empty Keychain read.
    private var deadGrants: Set<String> = []
    /// Coalesces concurrent rotation attempts for the same account (S3): actor
    /// isolation does not hold across the `await`s inside `rotate`, so two
    /// overlapping calls for the same uuid would both read the same pair and
    /// both spend the single-use refresh token — one wins, one silently burns
    /// the grant. Today this is unreachable for two reasons that live
    /// elsewhere and are not otherwise documented near this code: one shared
    /// `PulseOAuthStore` instance serves every `ClaudeProvider`
    /// (`AppEnvironment.swift`, `ProviderFactory.swift`), and
    /// `RefreshScheduler`'s `isRefreshing` guard (`RefreshScheduler.swift`)
    /// keeps one provider's `fetch()` from overlapping itself. Coalescing
    /// here removes the dependency on both staying true.
    private var inFlightRotations: [String: Task<Credentials?, Never>] = [:]
    /// Bounds retrying a refresh call that fails for a reason OTHER than
    /// `invalid_grant` (R2-S1) — a retired/rotated `client_id`
    /// (`400 {"error":"invalid_client"}`, permanent but not `invalid_grant`),
    /// a persistent 5xx, or anything else this run has no way to fix by
    /// asking again. Without a cap, that POSTs to the Cloudflare-fronted
    /// token endpoint every refresh tick forever with the failure swallowed
    /// by `try?` — the same self-renewing-penalty shape B1 was about,
    /// one error class narrower. Deliberately NOT `deadGrants`/`clearGrant`:
    /// this is "stop asking THIS run", not "the grant is proven dead" — a
    /// `client_id` rotation, for instance, fixes itself on the next app
    /// update with no re-sign-in needed, so nothing here is deleted.
    private var consecutiveRefreshFailures: [String: Int] = [:]
    private static let maxConsecutiveRefreshFailures = 3
    /// Refuses to spend the same refresh token twice in one run (R2-S3).
    /// Coalescing (`inFlightRotations`) only protects callers that overlap
    /// IN TIME; a caller that read a pre-rotation `current` before a winner
    /// started, but only reaches `rotateCoalesced` after the winner's entry
    /// was already cleared, is sequential, not concurrent, and coalescing
    /// does not see it. That caller would resend an already-spent refresh
    /// token, get `invalid_grant`, and (after B1) delete the Keychain items
    /// holding the pair the winner just promoted — turning a burned-grant
    /// bug into a working-grant DELETION. Keyed on a fingerprint
    /// (`PiAccountResolver.fingerprint`, the repo's existing token-identity-
    /// without-the-token pattern), never the token itself.
    private var spentRefreshFingerprints: Set<String> = []

    init(
        keychain: KeychainReader = KeychainReader(),
        writer: KeychainWriter = KeychainWriter(),
        oauthClient: ClaudeOAuthClient = ClaudeOAuthClient(),
        refreshOverride: (@Sendable (String) async throws -> ClaudeOAuthClient.TokenPair)? = nil,
        verifyOverride: (@Sendable (String) async -> Bool)? = nil
    ) {
        self.keychain = keychain
        self.writer = writer
        self.oauthClient = oauthClient
        self.refreshOverride = refreshOverride
        self.verifyOverride = verifyOverride
    }

    // MARK: - Sign-in

    /// Runs the full PKCE round trip, resolves the account it signed into,
    /// and persists the grant for that account's uuid. Returns the resolved
    /// profile so the caller (Settings) can confirm which account it was.
    @discardableResult
    func signIn(openBrowser: @Sendable (URL) -> Void) async throws -> ClaudeOAuthClient.Profile {
        let (tokens, profile) = try await oauthClient.signIn(openBrowser: openBrowser)
        let credentials = Credentials(
            accessToken: tokens.accessToken,
            refreshToken: tokens.refreshToken,
            expiresAt: tokens.expiresAt,
            grantedScope: tokens.grantedScope
        )
        // Pending FIRST, same order `rotate` uses, even though a fresh
        // sign-in has no old pair a mis-write could strand: if the SECOND
        // write throws (a `KeychainWriter` verification failure, a timeout),
        // writing primary first would leave primary holding the new grant
        // and pending holding nothing for this uuid — harmless. Writing
        // pending first and having primary throw instead leaves pending
        // holding the new grant and primary holding nothing, which `read()`
        // (now freshest-by-`expiresAt`, see its own comment) still resolves
        // to the new grant. Either order recovers under the new `read()`; this
        // order is kept so the single rule "pending is written no later than
        // primary" holds everywhere instead of varying by call site.
        // Cleared BEFORE either persist, not after (R2-S4): a browser round
        // trip that reached this point already proves the dead mark is
        // obsolete, regardless of whether either Keychain write then
        // succeeds. The first version cleared it last, so a write that threw
        // (a `KeychainWriter` verification failure, a timeout) left a LIVE
        // grant sitting in the Keychain while `credentials`/`hasGrant` kept
        // refusing the account for the rest of the process — recoverable only
        // by a relaunch or a second successful sign-in, even though the
        // first one had already worked.
        deadGrants.remove(profile.uuid)
        try await persist(credentials, accountUUID: profile.uuid, service: Self.pendingService)
        try await persist(credentials, accountUUID: profile.uuid, service: Self.service)
        return profile
    }

    // MARK: - Reading a usable pair

    /// A pair for `accountUUID` known not to be expired, refreshing first
    /// when it is inside the proactive window. Returns nil when Pulse holds
    /// no grant for this account, or when a rotation attempt already proved
    /// this run that the grant is dead (B1) — either way the caller falls
    /// back to the harness stores, exactly as before this store existed.
    ///
    /// **R2-B1.** A pair `read()` picked from `-pending` because it was
    /// FRESHER than primary (by `expiresAt`) is not the same thing as a pair
    /// proven to work — `rotate()` writes pending before it ever calls
    /// `verifies()`, and a rotation that failed verification leaves exactly
    /// that: a fresh, unverified pair sitting in `-pending`, forever, until
    /// something re-checks it. Left unhandled, the FIRST version of this fix
    /// only protected the ONE tick that ran the failed rotation: the very
    /// next call would find pending's ~8h `expiresAt` beats primary's
    /// (already inside its 300s window), `needsRefresh()` on that fresh-
    /// looking pair would be false, `rotateCoalesced` would never run, and
    /// the unverified pair would be served — and pinned ahead of every
    /// working harness token by `ClaudeProvider` — for its ENTIRE ~8h
    /// lifetime. So an unpromoted pending pair is verified once, right here,
    /// before it is ever handed out; success promotes it into primary (so
    /// every later call skips this cost); failure refuses it outright — NOT
    /// a fall-back to primary's near-expiry pair, which the crash/failure
    /// that left pending unpromoted already proved was about to need
    /// rotating anyway.
    func credentials(forAccountUUID accountUUID: String) async -> Credentials? {
        guard !deadGrants.contains(accountUUID) else { return nil }
        guard let picked = await read(accountUUID: accountUUID) else { return nil }
        var current = picked.credentials

        if picked.isUnpromotedPending {
            guard await verifies(current) else { return nil }
            // Best-effort: even if this particular write fails, the pair is
            // still correctly served this once (it just verified), and the
            // NEXT call re-verifies and tries to promote again — the same
            // "retry, never lose the durable pending copy" shape `rotate`
            // itself uses.
            try? await persist(current, accountUUID: accountUUID, service: Self.service)
        } else if current.needsRefresh(), (consecutiveRefreshFailures[accountUUID] ?? 0) < Self.maxConsecutiveRefreshFailures {
            // R2-S1: once this run has failed to refresh this account
            // `maxConsecutiveRefreshFailures` times in a row for a reason
            // that isn't `invalid_grant` (a wrong `client_id`, a persistent
            // 5xx, ...), stop trying every tick — see
            // `consecutiveRefreshFailures`'s doc comment.
            if let rotated = await rotateCoalesced(accountUUID: accountUUID, current: current) {
                current = rotated
            }
            // A failed-but-not-dead rotation attempt is not fatal here: the
            // caller checks `isExpired()` on whatever is returned and falls
            // back on its own if even that fails. What matters is that a
            // failed attempt never discarded the pair that was still good —
            // see `rotate`'s doc comment for why it now THROWS on a failed
            // verification instead of returning the unverified pair (B2).
        }
        return current.isExpired() ? nil : current
    }

    /// Whether Pulse holds a usable grant for this account — expired is still
    /// "yes" (there is a moment before the next scheduled refresh where that
    /// is normal), but a grant proven dead this run, or a grant this store no
    /// longer has an item for (including one `clearGrant` just deleted), is
    /// "no". Read by the Settings row's connection state and by
    /// `ClaudeProvider.probeConnection()`: this is what makes a dead Pulse
    /// grant (with no harness fallback) fall through to the EXISTING
    /// "Not connected" state and "Sign in…" button, rather than needing a new
    /// UI surface for the same fact.
    func hasGrant(forAccountUUID accountUUID: String) async -> Bool {
        guard !deadGrants.contains(accountUUID) else { return false }
        return await read(accountUUID: accountUUID) != nil
    }

    /// Coalesces concurrent rotation attempts for the same uuid (S3, see the
    /// `inFlightRotations` doc comment). The dictionary check-and-insert below
    /// has no `await` between them, so it is atomic under actor isolation —
    /// a second concurrent call for the same uuid always finds the first
    /// call's task already registered and awaits ITS result instead of
    /// starting a second rotation.
    private func rotateCoalesced(accountUUID: String, current: Credentials) async -> Credentials? {
        if let inFlight = inFlightRotations[accountUUID] {
            return await inFlight.value
        }
        let task = Task<Credentials?, Never> { [self] in
            try? await self.rotate(accountUUID: accountUUID, current: current)
        }
        inFlightRotations[accountUUID] = task
        let result = await task.value
        inFlightRotations[accountUUID] = nil
        return result
    }

    // MARK: - Rotation (ADR-0001)

    /// Refreshes the current pair and persists it in write-order: `-pending`
    /// FIRST (durable the instant the endpoint answers, before the old
    /// refresh token is even discarded from memory), THEN a real request
    /// (`/oauth/usage`) to prove the new access token actually works, THEN —
    /// and only then — promote the same pair into the primary item.
    ///
    /// The refresh token this sends is one-shot: reusing it after this call,
    /// successful or not, returns `400 invalid_grant` (proven live). So a
    /// crash after the endpoint answers 200 but before ANYTHING is persisted
    /// would burn the grant with nothing left to recover it — that is
    /// exactly the window `-pending` exists to cover. See
    /// `docs/adr/0001-refresh-token-rotation-write-order.md`.
    private func rotate(accountUUID: String, current: Credentials) async throws -> Credentials {
        // R2-S3: refuses to spend the SAME refresh token twice this run,
        // closing the one gap coalescing (`inFlightRotations`) cannot: a
        // caller that read `current` before a winner started, but only
        // reaches this call after the winner's in-flight entry was already
        // cleared, is sequential rather than concurrent — invisible to
        // `rotateCoalesced`. Fingerprinted BEFORE the network call, so this
        // check fires even if the call itself never runs.
        guard spentRefreshFingerprints.insert(PiAccountResolver.fingerprint(current.refreshToken)).inserted else {
            throw ProviderFetchError.dataUnavailable(description: "refresh token already spent this run")
        }

        let tokens: ClaudeOAuthClient.TokenPair
        do {
            if let refreshOverride {
                tokens = try await refreshOverride(current.refreshToken)
            } else {
                tokens = try await oauthClient.refresh(refreshToken: current.refreshToken)
            }
        } catch {
            // B1: `invalid_grant` on the refresh call means the refresh token
            // is PERMANENTLY dead (proven live, see
            // `ClaudeOAuthClient.TokenEndpointError`'s doc comment) — not a
            // network blip a retry could fix. Left unmarked, every future
            // tick would resend the same dead token to a Cloudflare-fronted
            // endpoint forever: the exact self-renewing-penalty shape
            // `intent.md` documents for `~/.claude`'s 429, reintroduced by
            // the feature meant to end it. Marking it here, once, is what
            // stops that loop.
            //
            // Keyed on `invalid_grant` SPECIFICALLY, not on "any 400" (review
            // round 2, 2026-09-08): the first version matched
            // `ProviderFetchError.http(400)`, which is what EVERY 400 from
            // the refresh call produced (the status alone, body already
            // discarded) — deleting a still-working grant's Keychain items on
            // any 400 whatsoever, including one that has nothing to do with
            // the grant being dead.
            if Self.isDeadGrantError(error) {
                deadGrants.insert(accountUUID)
                await clearGrant(accountUUID: accountUUID)
            } else {
                // R2-S1: every OTHER refresh failure is transient in the
                // sense that it isn't proven-dead, but "transient" does not
                // mean "safe to retry forever with no backoff" — see
                // `consecutiveRefreshFailures`'s doc comment.
                consecutiveRefreshFailures[accountUUID, default: 0] += 1
            }
            throw error
        }
        // The refresh call itself succeeded, so whatever streak of failures
        // this account had is over — regardless of what verification below
        // decides.
        consecutiveRefreshFailures[accountUUID] = 0
        let rotated = Credentials(
            accessToken: tokens.accessToken,
            refreshToken: tokens.refreshToken,
            expiresAt: tokens.expiresAt,
            grantedScope: tokens.grantedScope
        )
        try await persist(rotated, accountUUID: accountUUID, service: Self.pendingService)

        guard await verifies(rotated) else {
            // B2 / R2-B1: the rotated pair is durable in `-pending` — nothing
            // is lost — but it must NOT be handed to THIS call's caller.
            // THROWING (not returning `rotated`) is what makes
            // `credentials(forAccountUUID:)` keep `current` — the old pair,
            // still valid until its own natural expiry — for this one call.
            // The pair sitting in `-pending` stays UNVERIFIED, not retried
            // automatically: `read()` will pick it again on the very next
            // call (its `expiresAt` beats primary's), and
            // `credentials(forAccountUUID:)`'s `isUnpromotedPending` branch is
            // what actually re-verifies it before serving it — not a
            // `needsRefresh()` tick, which would not fire again for ~8h. See
            // that branch's doc comment.
            throw ProviderFetchError.dataUnavailable(description: "rotated pair failed verification")
        }
        try await persist(rotated, accountUUID: accountUUID, service: Self.service)
        return rotated
    }

    /// A refresh-token rotation this dead cannot be retried into working —
    /// only a human re-sign-in fixes `invalid_grant`. Every other outcome
    /// (network, 429, 5xx, or a 400 that is NOT `invalid_grant`) is treated
    /// as transient and must NOT be marked dead — `refreshOverride` in tests
    /// throws plain `Error`s too, which fall through to `false` here exactly
    /// like any other non-`invalidGrant` case would.
    private static func isDeadGrantError(_ error: Error) -> Bool {
        (error as? ClaudeOAuthClient.TokenEndpointError)?.isPermanentlyDead ?? false
    }

    /// The durable half of B1: deletes both Keychain items for `accountUUID`
    /// so a dead grant cannot outlive this process and cannot shadow a future
    /// re-sign-in (see `signIn`'s doc comment on write order). Best-effort —
    /// a delete failure leaves `deadGrants` as the in-memory backstop for the
    /// rest of this run, and a stale item that no longer answers is already
    /// harmless: `verifies` would refuse it, and `credentials` never reads it
    /// again because `deadGrants` already blocks that account.
    private func clearGrant(accountUUID: String) async {
        try? await writer.delete(service: Self.service, account: accountUUID)
        try? await writer.delete(service: Self.pendingService, account: accountUUID)
    }

    /// Whether `credentials` actually works, proven by a real request rather
    /// than trusted from the token endpoint's 200 — a refused scope is
    /// dropped silently by that endpoint (see `ClaudeOAuthClient.scope`), so
    /// a 200 on the token call proves the pair exists, never that it can read
    /// usage.
    private func verifies(_ credentials: Credentials) async -> Bool {
        if let verifyOverride { return await verifyOverride(credentials.accessToken) }
        return (try? await ClaudeUsageAPI(http: oauthClient.http).fetchUsage(accessToken: credentials.accessToken)) != nil
    }

    // MARK: - Keychain plumbing

    /// Picks whichever item is freshest BY `expiresAt`, not by name — a crash
    /// right after the pending write in `rotate` leaves the primary item
    /// holding a burned refresh token (reuse = 400 `invalid_grant`), so the
    /// only correct pair to hand out is whichever one is actually newer.
    /// `rotate` always writes pending before primary, so unconditionally
    /// preferring pending used to give the same answer there — but `signIn`
    /// writes both directly, and on a mid-write failure could leave pending
    /// holding a STALE, already-dead grant while primary holds the live one
    /// (a real hole in the old "always prefer pending" rule). Comparing
    /// `expiresAt` is correct in both call sites instead of correct in one
    /// and silently wrong in the other.
    ///
    /// `isUnpromotedPending` (R2-B1) tells the caller whether the chosen pair
    /// came from `-pending` while DIFFERING from primary — i.e. a pair that
    /// was written by a rotation but never proven, by verification, to
    /// actually work. `true` only when pending is the pick AND its content
    /// differs from primary; a pending that already matches primary was
    /// already verified and promoted by a previous call, so re-verifying it
    /// again would be a wasted `/oauth/usage` call every time it is read.
    private func read(accountUUID: String) async -> (credentials: Credentials, isUnpromotedPending: Bool)? {
        let pending = try? await load(service: Self.pendingService, accountUUID: accountUUID)
        let primary = try? await load(service: Self.service, accountUUID: accountUUID)
        switch (pending, primary) {
        case (let pending?, let primary?):
            if pending.expiresAt >= primary.expiresAt {
                return (pending, pending.accessToken != primary.accessToken)
            }
            return (primary, false)
        case (let pending?, nil):
            return (pending, true)
        case (nil, let primary?):
            return (primary, false)
        case (nil, nil):
            return nil
        }
    }

    private func load(service: String, accountUUID: String) async throws -> Credentials {
        let secret = try await keychain.readGenericPassword(service: service, account: accountUUID)
        return try Self.decode(secret)
    }

    private func persist(_ credentials: Credentials, accountUUID: String, service: String) async throws {
        let secret = try Self.encode(credentials)
        try await writer.write(service: service, account: accountUUID, secret: secret)
    }

    // MARK: - Encoding (pure, tested)

    static func encode(_ credentials: Credentials) throws -> String {
        let payload: [String: Any] = [
            "access_token": credentials.accessToken,
            "refresh_token": credentials.refreshToken,
            "expires_at": credentials.expiresAt.timeIntervalSince1970,
            "scope": credentials.grantedScope,
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        guard let string = String(data: data, encoding: .utf8) else {
            throw ProviderFetchError.parsing(description: "PulseOAuthStore: could not encode credentials")
        }
        return string
    }

    static func decode(_ secret: String) throws -> Credentials {
        guard let data = secret.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = root["access_token"] as? String, !accessToken.isEmpty,
              let refreshToken = root["refresh_token"] as? String, !refreshToken.isEmpty,
              let expiresAtSeconds = (root["expires_at"] as? NSNumber)?.doubleValue
        else {
            throw ProviderFetchError.parsing(description: "PulseOAuthStore: stored item has an unrecognized format")
        }
        return Credentials(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: Date(timeIntervalSince1970: expiresAtSeconds),
            grantedScope: (root["scope"] as? String) ?? ""
        )
    }
}

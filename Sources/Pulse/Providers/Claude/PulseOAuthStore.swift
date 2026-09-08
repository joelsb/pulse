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
        try await persist(credentials, accountUUID: profile.uuid, service: Self.pendingService)
        try await persist(credentials, accountUUID: profile.uuid, service: Self.service)
        // A fresh sign-in proves the account was previously dead only if it
        // was marked so; clear that now so `credentials`/`hasGrant` stop
        // refusing it.
        deadGrants.remove(profile.uuid)
        return profile
    }

    // MARK: - Reading a usable pair

    /// A pair for `accountUUID` known not to be expired, refreshing first
    /// when it is inside the proactive window. Returns nil when Pulse holds
    /// no grant for this account, or when a rotation attempt already proved
    /// this run that the grant is dead (B1) — either way the caller falls
    /// back to the harness stores, exactly as before this store existed.
    func credentials(forAccountUUID accountUUID: String) async -> Credentials? {
        guard !deadGrants.contains(accountUUID) else { return nil }
        guard var current = await read(accountUUID: accountUUID) else { return nil }
        if current.needsRefresh() {
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
            }
            throw error
        }
        let rotated = Credentials(
            accessToken: tokens.accessToken,
            refreshToken: tokens.refreshToken,
            expiresAt: tokens.expiresAt,
            grantedScope: tokens.grantedScope
        )
        try await persist(rotated, accountUUID: accountUUID, service: Self.pendingService)

        guard await verifies(rotated) else {
            // B2: the rotated pair is durable in `-pending` — nothing is lost
            // — but it must NOT be handed to this call's caller. An unverified
            // pair that `ClaudeProvider` then pins ahead of a working harness
            // token would show the user a reason produced by a credential
            // this code already knows is bad. THROWING (not returning
            // `rotated`) is what makes `credentials(forAccountUUID:)` keep
            // `current` — the old pair, still valid until its own natural
            // expiry — exactly as
            // `docs/adr/0001-refresh-token-rotation-write-order.md` describes.
            // The next `needsRefresh()` tick reads `-pending` first (see
            // `read()`) and retries verification without re-spending the
            // (already-spent) refresh token.
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
    private func read(accountUUID: String) async -> Credentials? {
        let pending = try? await load(service: Self.pendingService, accountUUID: accountUUID)
        let primary = try? await load(service: Self.service, accountUUID: accountUUID)
        switch (pending, primary) {
        case (let pending?, let primary?):
            return pending.expiresAt >= primary.expiresAt ? pending : primary
        case (let pending?, nil):
            return pending
        case (nil, let primary?):
            return primary
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

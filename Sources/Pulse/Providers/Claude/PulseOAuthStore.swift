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
        // A fresh sign-in has nothing to protect against a crash mid-rotation
        // — there is no old pair a mis-write could strand — so both items are
        // written directly rather than going through `rotate`'s pending step.
        try await persist(credentials, accountUUID: profile.uuid, service: Self.service)
        try await persist(credentials, accountUUID: profile.uuid, service: Self.pendingService)
        return profile
    }

    // MARK: - Reading a usable pair

    /// A pair for `accountUUID` known not to be expired, refreshing first
    /// when it is inside the proactive window. Returns nil when Pulse holds
    /// no grant for this account — the caller falls back to the harness
    /// stores, exactly as before this store existed.
    func credentials(forAccountUUID accountUUID: String) async -> Credentials? {
        guard var current = await read(accountUUID: accountUUID) else { return nil }
        if current.needsRefresh() {
            if let rotated = try? await rotate(accountUUID: accountUUID, current: current) {
                current = rotated
            }
            // A failed rotation attempt is not fatal here: the caller checks
            // `isExpired()` on whatever is returned and falls back on its own
            // if even that fails. What matters is that a failed attempt never
            // discarded the pair that was still good.
        }
        return current.isExpired() ? nil : current
    }

    /// Whether Pulse holds ANY grant for this account, expired or not — for
    /// the Settings row's connection state, which should read "connected"
    /// even the moment before the next scheduled refresh.
    func hasGrant(forAccountUUID accountUUID: String) async -> Bool {
        await read(accountUUID: accountUUID) != nil
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
        if let refreshOverride {
            tokens = try await refreshOverride(current.refreshToken)
        } else {
            tokens = try await oauthClient.refresh(refreshToken: current.refreshToken)
        }
        let rotated = Credentials(
            accessToken: tokens.accessToken,
            refreshToken: tokens.refreshToken,
            expiresAt: tokens.expiresAt,
            grantedScope: tokens.grantedScope
        )
        try await persist(rotated, accountUUID: accountUUID, service: Self.pendingService)

        guard await verifies(rotated) else {
            // The rotated pair is durable in `-pending` even though it could
            // not be proven — the NEXT read prefers pending over the (now
            // stale-refresh-token) primary item, so nothing is lost, only
            // deferred to the next attempt.
            return rotated
        }
        try await persist(rotated, accountUUID: accountUUID, service: Self.service)
        return rotated
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

    /// Pending first: preferring it at read time is what makes `-pending`
    /// useful rather than just a backup nobody looks at — a crash right after
    /// the pending write leaves the primary item holding a burned refresh
    /// token (reuse = 400 `invalid_grant`), so the ONLY correct pair to hand
    /// out is whichever one is freshest, and pending is written strictly
    /// after primary in every code path above.
    private func read(accountUUID: String) async -> Credentials? {
        if let pending = try? await load(service: Self.pendingService, accountUUID: accountUUID) {
            return pending
        }
        return try? await load(service: Self.service, accountUUID: accountUUID)
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

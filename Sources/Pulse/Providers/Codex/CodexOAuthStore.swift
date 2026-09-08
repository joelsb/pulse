import Foundation

/// Pulse's own Codex OAuth grant, persisted in the Keychain and refreshed by
/// Pulse on its own schedule - JSB-9, the same shape as `PulseOAuthStore`
/// (JSB-8), forked rather than shared: see `impl-codex.md` for why a generic
/// store over both providers was not smaller once the differences (single
/// account vs many, `/oauth/usage` vs `wham/usage` as the verify probe, no
/// account-uuid keying) were written out.
///
/// **Storage.** One Keychain SERVICE, `de.byte.pulse.codex-oauth`, one fixed
/// item (Codex has exactly one Pulse-tracked account, unlike Claude's
/// per-uuid design) - plus `de.byte.pulse.codex-oauth-pending` for a rotated
/// pair not yet proven to work. Same pending -> verify -> promote order as
/// ADR-0001, which this store follows for the same reason: OpenAI's refresh
/// token, like Anthropic's, is a single-use credential from Pulse's
/// perspective (RFC 6749 §6's rotation grant, standard shape, not
/// separately falsified live for this provider - see `impl-codex.md`).
///
/// **The `id_token` is NEVER persisted here** - constraint 7 of the intent is
/// explicit: "an id_token is a token: parse its claims, never persist or
/// print it." `accountID` (a short string, `chatgpt_account_id`) is derived
/// from it once, at sign-in/refresh time, and only THAT is written to the
/// Keychain; the id_token itself is discarded the moment it has been read.
/// This was found the hard way while implementing: the first version stored
/// the raw id_token (1,765 characters on this machine's real token) alongside
/// the access and refresh tokens, and the combined base64 payload
/// (~5,244 characters) silently truncated. The cap is NOT on the secret
/// value alone - it is on the whole composed `security -i` stdin command
/// line (`add-generic-password -U -a <account> -s <service> -w <base64>`),
/// independent of and smaller than the 128-byte-per-value cap ADR-0001
/// already fixed. See `KeychainWriter`'s own doc comment for the two
/// measurements (a longer service/account name shrinks the same budget) and
/// the proactive `KeychainWriter.Failure.lineTooLong` guard this finding
/// produced. Dropping the id_token from the payload both obeys constraint 7
/// and keeps every write comfortably inside that budget - roughly 65% used,
/// see `KeychainWriter.maxCommandLineLength`'s own doc comment for the exact
/// figure.
actor CodexOAuthStore {
    struct Credentials: Sendable, Equatable {
        var accessToken: String
        var refreshToken: String
        var expiresAt: Date
        /// Constraint 4's `chatgpt_account_id`, derived from the id_token
        /// ONCE at sign-in/refresh time and persisted as this short string -
        /// never the id_token itself. nil is a real, storable state: a token
        /// response whose id_token carried no claim still yields a usable
        /// access/refresh pair, just without the `ChatGPT-Account-Id` header
        /// on the usage call.
        var accountID: String?

        func isExpired(now: Date = .now) -> Bool { now >= expiresAt }
        func needsRefresh(now: Date = .now, within: TimeInterval = 300) -> Bool {
            expiresAt.timeIntervalSince(now) < within
        }
    }

    private static let service = "de.byte.pulse.codex-oauth"
    private static let pendingService = "de.byte.pulse.codex-oauth-pending"

    private let keychain: KeychainReader
    private let writer: KeychainWriter
    private let oauthClient: CodexOAuthClient
    private let refreshOverride: (@Sendable (String) async throws -> CodexOAuthClient.TokenPair)?
    private let verifyOverride: (@Sendable (Credentials) async -> Bool)?
    /// Codex has exactly one Pulse-tracked account today (no
    /// `CLAUDE_CONFIG_DIR`-style multi-account discovery), so the Keychain
    /// item needs no per-account differentiator - unlike `PulseOAuthStore`,
    /// which keys on `accountUUID` because several Claude accounts can share
    /// this Mac. Overridable ONLY so `scripts/verify-codex-oauth-rotation.sh`
    /// can exercise the real Keychain under a scratch name instead of ever
    /// touching this machine's real `codex-primary` item.
    private let account: String

    private var dead = false
    private var inFlightRotation: Task<Credentials?, Never>?
    private var consecutiveRefreshFailures = 0
    private static let maxConsecutiveRefreshFailures = 3
    private var spentRefreshFingerprints: Set<String> = []

    init(
        account: String = "codex-primary",
        keychain: KeychainReader = KeychainReader(),
        writer: KeychainWriter = KeychainWriter(),
        oauthClient: CodexOAuthClient = CodexOAuthClient(),
        refreshOverride: (@Sendable (String) async throws -> CodexOAuthClient.TokenPair)? = nil,
        verifyOverride: (@Sendable (Credentials) async -> Bool)? = nil
    ) {
        self.account = account
        self.keychain = keychain
        self.writer = writer
        self.oauthClient = oauthClient
        self.refreshOverride = refreshOverride
        self.verifyOverride = verifyOverride
    }

    // MARK: - Sign-in

    @discardableResult
    func signIn(openBrowser: @Sendable (URL) -> Void) async throws -> Credentials {
        let tokens = try await oauthClient.signIn(openBrowser: openBrowser)
        let credentials = Self.credentials(from: tokens)
        // Same reasoning as `PulseOAuthStore.signIn`: cleared before either
        // write, pending no later than primary. See that type's doc comment.
        dead = false
        try await persist(credentials, service: Self.pendingService)
        try await persist(credentials, service: Self.service)
        return credentials
    }

    /// The id_token is read here, ONCE, for its `chatgpt_account_id` claim,
    /// and then dropped - this is the only place a `CodexOAuthClient.TokenPair`
    /// (which carries the raw id_token) is converted into the persisted
    /// `Credentials` shape (which never does). See the type's doc comment.
    private static func credentials(from tokens: CodexOAuthClient.TokenPair) -> Credentials {
        Credentials(
            accessToken: tokens.accessToken,
            refreshToken: tokens.refreshToken,
            expiresAt: tokens.expiresAt,
            accountID: CodexOAuthClient.accountID(fromIDToken: tokens.idToken)
        )
    }

    // MARK: - Reading a usable pair

    func credentials() async -> Credentials? {
        guard !dead else { return nil }
        guard let picked = await read() else { return nil }
        var current = picked.credentials

        if picked.isUnpromotedPending {
            guard await verifies(current) else { return nil }
            try? await persist(current, service: Self.service)
        } else if current.needsRefresh(), consecutiveRefreshFailures < Self.maxConsecutiveRefreshFailures {
            if let rotated = await rotateCoalesced(current: current) {
                current = rotated
            }
        }
        return current.isExpired() ? nil : current
    }

    func hasGrant() async -> Bool {
        guard !dead else { return false }
        return await read() != nil
    }

    private func rotateCoalesced(current: Credentials) async -> Credentials? {
        if let inFlight = inFlightRotation { return await inFlight.value }
        let task = Task<Credentials?, Never> { [self] in
            try? await self.rotate(current: current)
        }
        inFlightRotation = task
        let result = await task.value
        inFlightRotation = nil
        return result
    }

    // MARK: - Rotation (ADR-0001)

    private func rotate(current: Credentials) async throws -> Credentials {
        let fingerprint = PiAccountResolver.fingerprint(current.refreshToken)
        guard !spentRefreshFingerprints.contains(fingerprint) else {
            throw ProviderFetchError.dataUnavailable(description: "refresh token already spent this run")
        }

        let tokens: CodexOAuthClient.TokenPair
        do {
            if let refreshOverride {
                tokens = try await refreshOverride(current.refreshToken)
            } else {
                tokens = try await oauthClient.refresh(refreshToken: current.refreshToken)
            }
        } catch {
            if Self.isDeadGrantError(error) {
                dead = true
                await clearGrant()
            } else {
                consecutiveRefreshFailures += 1
            }
            throw error
        }
        spentRefreshFingerprints.insert(fingerprint)
        consecutiveRefreshFailures = 0
        let rotated = Self.credentials(from: tokens)
        try await persist(rotated, service: Self.pendingService)

        guard await verifies(rotated) else {
            throw ProviderFetchError.dataUnavailable(description: "rotated pair failed verification")
        }
        try await persist(rotated, service: Self.service)
        return rotated
    }

    private static func isDeadGrantError(_ error: Error) -> Bool {
        (error as? CodexOAuthClient.TokenEndpointError)?.isPermanentlyDead ?? false
    }

    private func clearGrant() async {
        try? await writer.delete(service: Self.service, account: account)
        try? await writer.delete(service: Self.pendingService, account: account)
    }

    /// Verification probe is `GET https://chatgpt.com/backend-api/wham/usage`
    /// (the proposed outcome's own line) - built through a throwaway
    /// `CodexAuth`, not persisted, never printed. No `idToken` to hand it
    /// either: `CodexUsageAPI.fetchUsage` only ever reads `auth.accountID`
    /// for the `ChatGPT-Account-Id` header, never the id_token itself.
    private func verifies(_ credentials: Credentials) async -> Bool {
        if let verifyOverride { return await verifyOverride(credentials) }
        let auth = CodexAuth(accessToken: credentials.accessToken, accountID: credentials.accountID)
        return (try? await CodexUsageAPI(http: oauthClient.http).fetchUsage(auth: auth)) != nil
    }

    // MARK: - Keychain plumbing

    private func read() async -> (credentials: Credentials, isUnpromotedPending: Bool)? {
        let pending = try? await load(service: Self.pendingService)
        let primary = try? await load(service: Self.service)
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

    private func load(service: String) async throws -> Credentials {
        let stored = try await keychain.readGenericPassword(service: service, account: account)
        guard let secret = KeychainWriter.decode(stored) else {
            throw ProviderFetchError.parsing(description: "CodexOAuthStore: stored item could not be decoded")
        }
        return try Self.decode(secret)
    }

    private func persist(_ credentials: Credentials, service: String) async throws {
        try await writer.write(service: service, account: account, secret: try Self.encode(credentials))
    }

    // MARK: - Encoding (pure, tested)

    static func encode(_ credentials: Credentials) throws -> String {
        var payload: [String: Any] = [
            "access_token": credentials.accessToken,
            "refresh_token": credentials.refreshToken,
            "expires_at": credentials.expiresAt.timeIntervalSince1970,
        ]
        if let accountID = credentials.accountID { payload["account_id"] = accountID }
        let data = try JSONSerialization.data(withJSONObject: payload)
        guard let string = String(data: data, encoding: .utf8) else {
            throw ProviderFetchError.parsing(description: "CodexOAuthStore: could not encode credentials")
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
            throw ProviderFetchError.parsing(description: "CodexOAuthStore: stored item has an unrecognized format")
        }
        return Credentials(
            accessToken: accessToken, refreshToken: refreshToken,
            expiresAt: Date(timeIntervalSince1970: expiresAtSeconds),
            accountID: root["account_id"] as? String
        )
    }
}

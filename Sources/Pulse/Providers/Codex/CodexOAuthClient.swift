import Foundation

/// Pulse's own PKCE sign-in for the ChatGPT/Codex account - JSB-9, the same
/// shape as `ClaudeOAuthClient` (JSB-8), with five measured differences.
/// Each is a fact, not a preference; see `docs/adr/0002-codex-oauth-differs-from-claude.md`.
///
/// 1. **`redirect_uri` is REGISTERED**, exactly `http://localhost:1455/auth/callback`,
///    path included - the opposite of Anthropic, where any loopback port
///    worked. Port 1455 is the Codex CLI's own login port.
/// 2. **The token endpoint takes `application/x-www-form-urlencoded`**, not
///    JSON - `HTTPClient.postFormRaw`, not `postRaw`.
/// 3. **No `state` in the exchange body.** `state` is still validated on the
///    CALLBACK (security-relevant, unchanged) - just not resent to the
///    token endpoint the way Anthropic requires.
/// 4. **`ChatGPT-Account-Id` comes from the `id_token`**, claim
///    `https://api.openai.com/auth` -> `chatgpt_account_id` - which is why
///    `id_token_add_organizations=true` is on the authorize URL and why the
///    exchange must ask for (and read) an `id_token`, unlike Claude's flow.
/// 5. **No separate `/oauth/profile` call** - the id_token already carries
///    everything Pulse needs to identify the account.
struct CodexOAuthClient: Sendable {
    /// The Codex CLI's own public OAuth client id (installed-app PKCE, no
    /// client secret) - read directly off this machine's real
    /// `~/.codex/auth.json` token claims (`aud` on the id_token, `client_id`
    /// on the access token), both `app_EMoamEEZ73f0CkXaXp7hrann`. Not a
    /// Pulse secret; every Codex CLI install ships the same id.
    static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    static let authorizeEndpoint = URL(string: "https://auth.openai.com/oauth/authorize")!
    static let tokenEndpoint = URL(string: "https://auth.openai.com/oauth/token")!

    /// REGISTERED redirect - constraint 1. Not derived from a variable port
    /// the way `ClaudeOAuthClient.redirectPort` is: this exact port and path
    /// are the only ones OpenAI's authorize endpoint accepts (browser-verified
    /// 2026-09-08 - `:53811` redirects straight to an `AuthApiFailure`
    /// error page before a human ever sees a consent screen).
    static let redirectPort: UInt16 = 1455
    static let redirectURI = "http://localhost:1455/auth/callback"

    /// The core OpenID Connect scopes an installed-app login needs to read
    /// its own account - deliberately narrower than the full `scp` list a
    /// real Codex CLI token carries (`openid profile email offline_access
    /// api.connectors.read api.connectors.invoke`, read off this machine's
    /// own token): the `api.connectors.*` pair grants access to connected
    /// tools, which Pulse (a read-only usage reader) has no use for and must
    /// never be able to invoke. Same principle as `ClaudeOAuthClient.scope`
    /// excluding `org:create_api_key`.
    static let scope = "openid profile email offline_access"

    var http: HTTPClient = HTTPClient()

    // MARK: - Wire types

    /// A minted or refreshed grant. Never logged, never printed.
    struct TokenPair: Sendable, Equatable {
        var accessToken: String
        var refreshToken: String
        /// Carries the `https://api.openai.com/auth` claim dict - read for
        /// `chatgpt_account_id` (constraint 4), never persisted as a raw
        /// string past `CodexOAuthStore`'s own Keychain write.
        var idToken: String
        var expiresAt: Date
    }

    typealias PKCE = ClaudeOAuthClient.PKCE

    /// Same terminal-vs-transient distinction as `ClaudeOAuthClient.TokenEndpointError`
    /// - RFC 6749 §5.2's `invalid_grant` shape is not Anthropic-specific, so
    /// the same narrow, exact-string classification applies here on the same
    /// evidence-based reasoning (a loose match on "any 400" once destroyed a
    /// working Claude grant; see that type's doc comment).
    enum TokenEndpointError: Error, Sendable, Equatable {
        case invalidGrant
        case other(status: Int)
        var isPermanentlyDead: Bool { self == .invalidGrant }
    }

    // MARK: - Authorize URL (pure, tested)

    static func authorizeURL(pkce: PKCE) -> URL {
        var components = URLComponents(url: authorizeEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: pkce.state),
            // Constraint 4: this is what makes the token endpoint's id_token
            // carry the `https://api.openai.com/auth` claim dict Pulse reads
            // `chatgpt_account_id` from.
            URLQueryItem(name: "id_token_add_organizations", value: "true"),
        ]
        return components.url!
    }

    // MARK: - Sign-in round trip

    func signIn(openBrowser: @Sendable (URL) -> Void) async throws -> TokenPair {
        let pkce = ClaudeOAuthClient.makePKCE()
        let listener = try LoopbackCallbackListener(port: Self.redirectPort)
        async let callback = listener.waitForCallback()
        openBrowser(Self.authorizeURL(pkce: pkce))
        let result = try await callback
        // Same security-relevant check as Claude's flow - `state` proves this
        // callback answers THIS listener's own authorize request. Reused
        // directly: the check itself is provider-agnostic.
        let code = try ClaudeOAuthClient.acceptCallback(result, pkce: pkce)
        return try await exchange(code: code, verifier: pkce.verifier)
    }

    // MARK: - Token endpoint

    private func exchange(code: String, verifier: String) async throws -> TokenPair {
        // Exchange is the ONE call whose response is required to carry a
        // fresh refresh_token and id_token — there is no prior grant to fall
        // back on yet. `refresh` below passes `requireIdentity: false`; see
        // that function's doc comment for why.
        try await post(form: Self.exchangeRequestBody(code: code, verifier: verifier), requireIdentity: true)
    }

    /// Pure (tested). Constraint 3: NO `state` here - do not copy Claude's
    /// fix across. OpenAI's exchange body is exactly these 5 fields.
    static func exchangeRequestBody(code: String, verifier: String) -> [String: String] {
        [
            "grant_type": "authorization_code",
            "client_id": clientID,
            "code": code,
            "code_verifier": verifier,
            "redirect_uri": redirectURI,
        ]
    }

    /// One-shot, same rotation discipline as Claude's refresh - callers MUST
    /// durably store the result before doing anything else with it; see
    /// `CodexOAuthStore` / `docs/adr/0001-refresh-token-rotation-write-order.md`.
    ///
    /// **`requireIdentity: false`** (review B1): RFC 6749 §6 says a refresh
    /// response MAY omit `refresh_token` — omitting it means "keep using the
    /// one you already have", not "the grant is broken". `id_token` is the
    /// same story one level further: `id_token_add_organizations=true` is an
    /// AUTHORIZE-time parameter (see `authorizeURL`), never sent on refresh,
    /// so there is no basis for assuming a refreshed id_token even carries
    /// the `chatgpt_account_id` claim, let alone that the endpoint returns an
    /// id_token on refresh at all. This repo's own second OAuth provider
    /// already draws this line the same way — `GeminiAuth` requires only the
    /// access token on refresh and treats `id_token` as optional. The FIRST
    /// version of this function required all three fields on every call,
    /// which meant a spec-legal refresh response missing either field
    /// silently killed Pulse's own grant every single rotation.
    func refresh(refreshToken: String) async throws -> TokenPair {
        try await post(form: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": Self.clientID,
        ], requireIdentity: false)
    }

    private func post(form: [String: String], requireIdentity: Bool) async throws -> TokenPair {
        let headers = ["Accept": "application/json"]
        let (status, responseData, response) = try await http.postFormRaw(Self.tokenEndpoint, headers: headers, form: form)
        guard (200...299).contains(status) else {
            if status == 429 {
                throw ProviderFetchError.rateLimited(retryAfter: HTTPClient.retryAfter(from: response))
            }
            throw Self.tokenEndpointError(status: status, body: responseData)
        }
        return try Self.parseTokenResponse(responseData, requireIdentity: requireIdentity)
    }

    /// Pure (tested) - same narrow, normalised match as
    /// `ClaudeOAuthClient.tokenEndpointError`; see that function's doc
    /// comment for why "any 400" is the wrong bar.
    static func tokenEndpointError(status: Int, body: Data) -> TokenEndpointError {
        guard status == 400,
              let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let errorField = root["error"] as? String,
              errorField.trimmingCharacters(in: .whitespaces).lowercased() == "invalid_grant"
        else {
            return .other(status: status)
        }
        return .invalidGrant
    }

    /// Pure (tested). `accessToken` is ALWAYS required — there is nothing
    /// usable without it. `refreshToken`/`idToken` are required only when
    /// `requireIdentity` is true (the EXCHANGE call, which mints a grant from
    /// nothing); on `refresh` (`requireIdentity: false`) either may be absent
    /// per RFC 6749 §6 and this endpoint's own authorize-vs-refresh parameter
    /// scoping (see `refresh`'s doc comment) — a missing one comes back as
    /// `""`, and `CodexOAuthStore.rotate` is the caller that knows how to
    /// fall back to what it already has.
    static func parseTokenResponse(_ data: Data, requireIdentity: Bool = true, now: Date = .now) throws -> TokenPair {
        struct Response: Decodable {
            var accessToken: String?
            var refreshToken: String?
            var idToken: String?
            var expiresIn: Double?
            enum CodingKeys: String, CodingKey {
                case accessToken = "access_token"
                case refreshToken = "refresh_token"
                case idToken = "id_token"
                case expiresIn = "expires_in"
            }
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: data),
              let accessToken = response.accessToken, !accessToken.isEmpty
        else {
            throw ProviderFetchError.parsing(description: "oauth/token: response carried no usable access token")
        }
        if requireIdentity {
            guard let refreshToken = response.refreshToken, !refreshToken.isEmpty,
                  let idToken = response.idToken, !idToken.isEmpty
            else {
                throw ProviderFetchError.parsing(description: "oauth/token: exchange response carried no refresh_token/id_token")
            }
            return TokenPair(
                accessToken: accessToken, refreshToken: refreshToken, idToken: idToken,
                // 3600s (1h) is not a guess: this machine's own real
                // `~/.codex/auth.json` id_token carries `iat` and `exp`
                // 3600 seconds apart exactly (1787856354 -> 1787859954).
                expiresAt: now.addingTimeInterval(response.expiresIn ?? 3600)
            )
        }
        return TokenPair(
            accessToken: accessToken,
            refreshToken: response.refreshToken ?? "",
            idToken: response.idToken ?? "",
            expiresAt: now.addingTimeInterval(response.expiresIn ?? 3600)
        )
    }

    /// Constraint 4: `ChatGPT-Account-Id` comes from the id_token's
    /// `https://api.openai.com/auth` claim dict, key `chatgpt_account_id` -
    /// never from a top-level field the token response might also carry.
    static func accountID(fromIDToken idToken: String) -> String? {
        JWT.claim("https://api.openai.com/auth", of: idToken, as: [String: Any].self)?["chatgpt_account_id"] as? String
    }
}

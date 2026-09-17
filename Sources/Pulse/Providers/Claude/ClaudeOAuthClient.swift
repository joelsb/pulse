import CryptoKit
import Foundation
import Network

/// Pulse's own PKCE sign-in for a Claude account: mints and refreshes a grant
/// Pulse holds itself, so the panel no longer depends on Claude Code, jcode or
/// pi having run recently enough to leave a live token behind.
///
/// **Constants below are proven, not guessed** — falsified live 2026-09-08,
/// one browser sign-in, `client_id 9d1c250a-e61b-44d9-88ed-5944d1962f5e`:
/// code exchange 200 (`expires_in=28800`, 8h), `GET /oauth/profile` 200,
/// `GET /oauth/usage` 200, self-refresh 200 (rotated), reuse of the
/// pre-rotation refresh token 400 `invalid_grant`. The token endpoint is
/// Cloudflare-fronted and 403s (Cloudflare 1010 `browser_signature_banned`)
/// under a default `Python-urllib`-style UA; `User-Agent: claude-cli/2.1.0`
/// returned 200 — a 403 here is never a credential problem, it means the UA
/// header is missing or wrong.
struct ClaudeOAuthClient: Sendable {
    /// Claude Code's own public OAuth client id for this flow (installed-app
    /// PKCE, no client secret to keep — every Claude Code install ships the
    /// same id). Not a Pulse secret.
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let authorizeEndpoint = URL(string: "https://claude.ai/oauth/authorize")!
    static let tokenEndpoint = URL(string: "https://platform.claude.com/v1/oauth/token")!
    static let profileEndpoint = URL(string: "https://api.anthropic.com/api/oauth/profile")!

    /// UA the Cloudflare-fronted token endpoint accepts (see the type's doc
    /// comment). Deliberately different from `ClaudeUsageAPI`'s
    /// `claude-code/2.1.0` — that is a different endpoint, proven separately.
    static let userAgent = "claude-cli/2.1.0"

    /// Loopback port Pulse's own listener binds. Deliberately not pi's
    /// `53692` — falsified live 2026-09-08 that an arbitrary loopback port is
    /// accepted, so there is no reason to share one and risk colliding with a
    /// pi sign-in mid-flight.
    static let redirectPort: UInt16 = 53810
    /// Derived from `redirectPort`, never a second literal — the listener
    /// binds `redirectPort` and the authorize request sends `redirectURI`;
    /// two independent constants that happened to agree would silently drift
    /// the moment either one was edited, and the failure (sign-in hangs for
    /// the full 300s timeout, reporting "Timed out waiting for the browser")
    /// points at the browser, not at the real cause.
    static var redirectURI: String { "http://localhost:\(redirectPort)/callback" }

    /// Exactly the 5 scopes the token endpoint GRANTS, not the 6 Claude
    /// Code's own CLI requests (`org:create_api_key user:profile
    /// user:inference user:sessions:claude_code user:mcp_servers
    /// user:file_upload`, read from pi's bundled `anthropic.js`). Proven end
    /// to end 2026-09-08 (see the type's doc comment): the token response's
    /// `scope` field came back with exactly these 5, alphabetised, whether or
    /// not `org:create_api_key` was requested.
    ///
    /// Two things about that number that change how a failure here should be
    /// read:
    ///
    /// 1. **A refused scope is dropped silently.** Requesting all 6 still
    ///    returns HTTP 200 with 5 in `scope` — no error, no warning. The
    ///    status code proves nothing about which scopes were granted; only
    ///    the `scope` field does. Anything that asserts on this must assert
    ///    on that field, never on the response being 200.
    /// 2. **Whether `/oauth/usage` still answers with a smaller set (e.g.
    ///    `user:profile` alone) is UNTESTED** — narrowing needs another live
    ///    sign-in, and is deliberately not done on a hunch here: a scope too
    ///    small fails at the usage call, hours after sign-in, and looks
    ///    exactly like an expired token. See `impl-pulse.md`.
    ///
    /// Excluding `org:create_api_key` is also correct on its own terms even
    /// though the server already refuses it: Pulse reads usage, and must
    /// never be ABLE to mint an API key.
    static let scope = "user:file_upload user:inference user:mcp_servers user:profile user:sessions:claude_code"

    var http: HTTPClient = HTTPClient()

    // MARK: - Wire types

    /// A minted or refreshed grant. Never logged, never printed — only ever
    /// handed to `PulseOAuthStore` for Keychain storage.
    struct TokenPair: Sendable, Equatable {
        var accessToken: String
        var refreshToken: String
        var expiresAt: Date
        /// What the endpoint actually granted, per the `scope` response field
        /// — never assumed equal to what was requested (see `scope` above).
        var grantedScope: String
    }

    struct Profile: Sendable, Equatable {
        var uuid: String
        var email: String?
    }

    struct PKCE: Sendable, Equatable {
        var verifier: String
        var challenge: String
        var state: String
    }

    /// Distinguishes the ONE non-2xx response from the token endpoint that
    /// means "this refresh token is permanently dead" from every other one.
    /// Deliberately NOT folded into `ProviderFetchError` (the shared, coarse
    /// taxonomy every provider maps into) — only `PulseOAuthStore`'s rotation
    /// path needs the distinction, and widening the shared type would give
    /// every OTHER caller a case they have no way to produce or handle.
    ///
    /// Found in review round 2 (2026-09-08): the first version keyed
    /// "permanently dead" on ANY `400` from the refresh call
    /// (`ProviderFetchError.http(400)`, which `HTTPClient.send` produces for
    /// every 400 alike, having already discarded the body). That deleted a
    /// WORKING grant's Keychain items on any 400 whatsoever — a malformed
    /// body after a future API change, a changed required parameter, a
    /// provider-side validation hiccup — none of which mean the refresh
    /// token itself is dead. The real, narrow signal, verbatim from the
    /// falsification run's response body on a genuinely reused (post-
    /// rotation) refresh token:
    /// ```
    /// HTTP 400 {"error": "invalid_grant", "error_description": "Refresh token not found or invalid"}
    /// ```
    enum TokenEndpointError: Error, Sendable, Equatable {
        /// `400` whose body's `error` field is exactly `"invalid_grant"`.
        /// Permanent: only a human re-sign-in fixes it, retrying never will.
        case invalidGrant
        /// Any other non-2xx status. Status only — the body is read just far
        /// enough to classify it and then discarded, never retained past this
        /// call, matching the "never carry provider error text further than
        /// it has to go" discipline the rest of this file follows.
        case other(status: Int)

        var isPermanentlyDead: Bool { self == .invalidGrant }
    }

    // MARK: - PKCE (pure, tested)

    static func makePKCE() -> PKCE {
        let verifier = randomURLSafeString(byteCount: 48)
        return PKCE(verifier: verifier, challenge: codeChallenge(forVerifier: verifier), state: randomURLSafeString(byteCount: 24))
    }

    /// S256 per RFC 7636 §4.2: base64url(SHA256(ascii(verifier))), no padding.
    static func codeChallenge(forVerifier verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func randomURLSafeString(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        for index in bytes.indices { bytes[index] = UInt8.random(in: 0...255) }
        return base64URL(Data(bytes))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: - Authorize URL (pure, tested)

    static func authorizeURL(pkce: PKCE) -> URL {
        var components = URLComponents(url: authorizeEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            // Sent by BOTH proven-working callers as the first query item: pi's
            // own bundle (`anthropic.js`) and the live falsification run that
            // returned 200 on 2026-09-08. Not derived from or explained by
            // RFC 6749 — kept anyway, on evidence rather than tidiness: the
            // bar for omitting a parameter two working implementations both
            // send is proof it is inert, not a hunch that it looks redundant.
            // The `state`-in-token-request fix below (`exchangeRequestBody`)
            // is the same lesson learned the hard way — a spec-correct
            // reading of this endpoint failed on the first real sign-in.
            URLQueryItem(name: "code", value: "true"),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: pkce.state),
        ]
        return components.url!
    }

    // MARK: - Sign-in round trip

    /// Starts the loopback listener, hands the authorize URL to `openBrowser`
    /// (the caller's job — Settings opens it via `NSWorkspace.open`), waits
    /// for the redirect, exchanges the code, and resolves the account.
    ///
    /// The listener is started and armed BEFORE `openBrowser` runs, so a
    /// browser that redirects immediately (a still-valid `claude.ai` session)
    /// can never race Pulse's own bind.
    func signIn(openBrowser: @Sendable (URL) -> Void) async throws -> (tokens: TokenPair, profile: Profile) {
        let pkce = Self.makePKCE()
        let listener = try LoopbackCallbackListener(port: Self.redirectPort)
        async let callback = listener.waitForCallback()
        openBrowser(Self.authorizeURL(pkce: pkce))
        let result = try await callback
        let code = try Self.acceptCallback(result, pkce: pkce)
        // `result.state`, not `pkce.state`: the value that already PASSED
        // `acceptCallback`'s check, so the parameter sent to the token
        // endpoint and the guard that validated it can never drift apart even
        // if the two are edited separately later. The two are equal at this
        // point by construction — `acceptCallback` would have thrown otherwise
        // — but using the checked value, not re-deriving it, is the point.
        let tokens = try await exchange(code: code, state: result.state, verifier: pkce.verifier)
        let profile = try await fetchProfile(accessToken: tokens.accessToken)
        return (tokens, profile)
    }

    /// The only security-relevant branch in the sign-in flow: `state` proves
    /// the callback answers THIS listener's own authorize request, not some
    /// other local process hitting `http://localhost:53810/callback` while
    /// the listener happens to be armed (loopback listeners are reachable by
    /// any process on the same Mac, not just the browser Pulse opened).
    /// Extracted to a pure function so this branch has a test independent of
    /// a real socket — the listener tests exercise `LoopbackCallbackListener`
    /// itself and would both stay green if this guard were deleted.
    static func acceptCallback(_ callback: LoopbackCallbackListener.Callback, pkce: PKCE) throws -> String {
        guard callback.state == pkce.state else {
            throw ProviderFetchError.parsing(description: "OAuth callback state did not match - discarding it")
        }
        return callback.code
    }

    // MARK: - Token endpoint

    private func exchange(code: String, state: String, verifier: String) async throws -> TokenPair {
        try await post(body: Self.exchangeRequestBody(code: code, state: state, verifier: verifier))
    }

    /// Pure (tested), because this exact shape failed silently once. RFC 6749
    /// has NO `state` in the token request — it is nominally an
    /// authorize-time parameter that comes back on the redirect, and a
    /// spec-correct implementation omits it here. This endpoint requires it
    /// anyway: the first real human sign-in (2026-09-08) sent the RFC-correct
    /// five fields and got a bare `400` with no explanation. Two INDEPENDENT
    /// working implementations both send it: pi's own bundle
    /// (`anthropic.js`), verbatim `grant_type, client_id, code, state,
    /// redirect_uri, code_verifier`; and this file's own live falsification
    /// run, which sent it and got 200. Do NOT remove `state` to "match the
    /// RFC" — that is the exact mistake that shipped.
    static func exchangeRequestBody(code: String, state: String, verifier: String) -> [String: String] {
        [
            "grant_type": "authorization_code",
            "code": code,
            "state": state,
            "client_id": clientID,
            "redirect_uri": redirectURI,
            "code_verifier": verifier,
        ]
    }

    /// Refreshes a grant. **One-shot**: the refresh token this call sends is
    /// dead the instant the endpoint answers, whether or not the caller
    /// manages to persist the result — reusing it returns `400 invalid_grant`
    /// (proven live, see the type's doc comment). Callers MUST durably store
    /// the returned pair before doing anything else with it; that ordering is
    /// `PulseOAuthStore`'s job, not this one's — see
    /// `docs/adr/0001-refresh-token-rotation-write-order.md`.
    func refresh(refreshToken: String) async throws -> TokenPair {
        try await post(body: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": Self.clientID,
        ])
    }

    private func post(body: [String: String]) async throws -> TokenPair {
        let data = try JSONSerialization.data(withJSONObject: body)
        let headers = [
            "User-Agent": Self.userAgent,
            "Accept": "application/json",
        ]
        // `postRaw`, not `post`: a non-2xx must still carry its BODY to the
        // caller so `tokenEndpointError` can read the `error` field — `post`
        // (via `HTTPClient.send`) collapses every 400 alike before the body
        // is ever looked at, which is the exact mistake `TokenEndpointError`
        // exists to undo. See that type's doc comment.
        let (status, responseData, response) = try await http.postRaw(Self.tokenEndpoint, headers: headers, jsonBody: data)
        guard (200...299).contains(status) else {
            // 429 specifically maps back to the shared `ProviderFetchError`
            // (review round 2 nit 2): `postRaw` no longer builds it the way
            // `send` did, and losing `Retry-After` here would make a sign-in
            // rate limit render as a bare "Sign-in failed (429)" instead of
            // the absolute retry time `ProviderFetchError.rateLimited`
            // already knows how to say. Every OTHER status still goes through
            // `tokenEndpointError`.
            if status == 429 {
                throw ProviderFetchError.rateLimited(retryAfter: HTTPClient.retryAfter(from: response))
            }
            throw Self.tokenEndpointError(status: status, body: responseData)
        }
        return try Self.parseTokenResponse(responseData)
    }

    /// Pure, tested by `ClaudeOAuthTokenEndpointErrorTests`
    /// (`Tests/PulseTests/ClaudeOAuthTests.swift`) and by
    /// `scripts/oauth-rotation-harness.swift` scenario 7 (`swift test` cannot
    /// run on this machine, so the same five cases run there against the
    /// real static function). This is the ONE function deciding whether a
    /// `400` deletes both of an account's Keychain items — review round 2
    /// (2026-09-08) found it had NO test anywhere: the shell harness only
    /// throws ALREADY-classified `TokenEndpointError` values from
    /// `refreshOverride`, so a defect planted directly in this function (drop
    /// the `status == 400` guard; loosen `== "invalid_grant"` to `!= nil`,
    /// which is round 2's original bug restored) passed all 7 scenarios with
    /// the classifier itself never exercised.
    ///
    /// Reads ONLY the `error` field of the body — `error_description` and
    /// anything else present is never retained. The comparison is
    /// normalised (trimmed, lowercased) because the failure mode of matching
    /// TOO STRICTLY is B1 in full: a byte-for-byte miss (a gateway adding
    /// trailing whitespace, a differently-cased variant) reads as `.other`,
    /// which retries forever with no backoff (see
    /// `PulseOAuthStore.consecutiveRefreshFailures`). Deliberately NOT
    /// widened to match on `error_description` or a nested `error` object:
    /// `error_description` is free text that could contain the phrase while
    /// describing something else, and that direction of a mistake DELETES a
    /// live grant rather than merely retrying — the two failure modes are not
    /// symmetric, so only the narrow, spec-shaped (`error`, RFC 6749 §5.2)
    /// field is read.
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

    /// Pure (tested): decodes the token endpoint's JSON body. `expires_in` is
    /// seconds from the moment of the call — there is no server timestamp in
    /// the payload, so `now` is an injectable parameter for tests.
    static func parseTokenResponse(_ data: Data, now: Date = .now) throws -> TokenPair {
        struct Response: Decodable {
            var accessToken: String?
            var refreshToken: String?
            var expiresIn: Double?
            var scope: String?
            enum CodingKeys: String, CodingKey {
                case accessToken = "access_token"
                case refreshToken = "refresh_token"
                case expiresIn = "expires_in"
                case scope
            }
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: data),
              let accessToken = response.accessToken, !accessToken.isEmpty,
              let refreshToken = response.refreshToken, !refreshToken.isEmpty
        else {
            throw ProviderFetchError.parsing(description: "oauth/token: response carried no usable token pair")
        }
        return TokenPair(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: now.addingTimeInterval(response.expiresIn ?? 28800),
            grantedScope: response.scope ?? ""
        )
    }

    // MARK: - Profile

    func fetchProfile(accessToken: String) async throws -> Profile {
        let headers = [
            "Authorization": "Bearer \(accessToken)",
            "anthropic-beta": "oauth-2025-04-20",
            "Accept": "application/json",
        ]
        let data = try await http.get(Self.profileEndpoint, headers: headers)
        guard let profile = Self.parseProfile(data) else {
            throw ProviderFetchError.parsing(description: "oauth/profile: no account uuid in response")
        }
        return profile
    }

    /// Pure (tested): the payload nests the account under `account`, but has
    /// been seen flat too (same tolerance as `PiAccountResolver`).
    static func parseProfile(_ data: Data) -> Profile? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let account = (root["account"] as? [String: Any]) ?? root
        guard let uuid = account["uuid"] as? String else { return nil }
        return Profile(uuid: uuid, email: account["email"] as? String)
    }
}

// MARK: - Loopback callback listener

/// One-shot local HTTP listener for the OAuth redirect. Binds
/// `http://localhost:<port>/callback`, accepts exactly one request, answers
/// it with a plain confirmation page, and shuts itself down — there is never
/// a second request to answer.
///
/// Not an actor: `NWConnection`'s callbacks land on an arbitrary GCD queue,
/// and bridging that into a single-resume continuation is a lock, not
/// isolation — the same shape as `KeychainReader`/`KeychainWriter`'s
/// `OnceBox`, and the same shape the repo's own `rate-limit-harness.swift`
/// already uses for a throwaway test listener.
final class LoopbackCallbackListener: @unchecked Sendable {
    struct Callback: Sendable, Equatable { var code: String; var state: String }

    enum Failure: Error, Sendable, Equatable {
        case timeout
        case deniedByProvider(description: String)
        case invalidCallback
        case listenerFailed
    }

    private let listener: NWListener
    private let box = ResolveBox()

    init(port: UInt16) throws {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else { throw Failure.listenerFailed }
        listener = try NWListener(using: .tcp, on: endpointPort)
    }

    /// Waits for the first valid `?code=&state=` callback, an `?error=`
    /// redirect (the user declined, or the provider rejected the request), or
    /// `timeout` — 5 minutes is generous for "read the consent screen and
    /// click Allow" without leaving a listener bound indefinitely if the tab
    /// is abandoned.
    func waitForCallback(timeout: TimeInterval = 300) async throws -> Callback {
        try await withCheckedThrowingContinuation { continuation in
            box.onResolve = { result in
                self.listener.cancel()
                continuation.resume(with: result)
            }
            listener.newConnectionHandler = { [box] connection in
                Self.handle(connection: connection, box: box)
            }
            listener.stateUpdateHandler = { [box] state in
                if case .failed = state { box.resolve(.failure(Failure.listenerFailed)) }
            }
            listener.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [box] in
                box.resolve(.failure(Failure.timeout))
            }
        }
    }

    private static func handle(connection: NWConnection, box: ResolveBox) {
        connection.start(queue: .global())
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, _ in
            defer { connection.cancel() }
            guard let data,
                  let text = String(data: data, encoding: .utf8),
                  let requestLine = text.split(separator: "\r\n", maxSplits: 1).first,
                  let path = requestLine.split(separator: " ", omittingEmptySubsequences: true).dropFirst().first,
                  let url = URL(string: "http://localhost\(path)"),
                  let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            else {
                respond(connection, ok: false, body: "Malformed request.")
                return
            }
            let items = components.queryItems ?? []
            func value(_ name: String) -> String? { items.first(where: { $0.name == name })?.value }

            if let error = value("error") {
                respond(connection, ok: true, body: page(title: "Sign-in didn\u{2019}t complete", detail: error))
                box.resolve(.failure(Failure.deniedByProvider(description: error)))
                return
            }
            guard let code = value("code"), let state = value("state") else {
                respond(connection, ok: false, body: "Missing code or state.")
                box.resolve(.failure(Failure.invalidCallback))
                return
            }
            respond(connection, ok: true, body: page(title: "Signed in", detail: "You can close this tab and go back to Pulse."))
            box.resolve(.success(Callback(code: code, state: state)))
        }
    }

    private static func respond(_ connection: NWConnection, ok: Bool, body: String) {
        let status = ok ? "200 OK" : "400 Bad Request"
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\n"
            + "Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
    }

    private static func page(title: String, detail: String) -> String {
        "<html><body style=\"font:15px -apple-system,sans-serif;padding:2rem;color:#1c1c1e\">"
            + "<h2>\(escapeHTML(title))</h2><p>\(escapeHTML(detail))</p></body></html>"
    }

    /// `detail` can carry the provider's own `error=` value straight from the
    /// query string (untrusted input, even though it never contains token
    /// material) — escaped before it lands in this locally-served page.
    private static func escapeHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Guarantees the continuation resumes exactly once across a racing
    /// connection callback, listener failure, and the timeout watchdog.
    private final class ResolveBox: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        var onResolve: ((Result<Callback, Error>) -> Void)?

        func resolve(_ result: Result<Callback, Error>) {
            lock.lock()
            let shouldRun = !done
            if shouldRun { done = true }
            lock.unlock()
            guard shouldRun else { return }
            onResolve?(result)
        }
    }
}

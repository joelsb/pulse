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
    static let redirectURI = "http://localhost:53810/callback"

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
        guard result.state == pkce.state else {
            throw ProviderFetchError.parsing(description: "OAuth callback state did not match — discarding it")
        }
        let tokens = try await exchange(code: result.code, verifier: pkce.verifier)
        let profile = try await fetchProfile(accessToken: tokens.accessToken)
        return (tokens, profile)
    }

    // MARK: - Token endpoint

    private func exchange(code: String, verifier: String) async throws -> TokenPair {
        try await post(body: [
            "grant_type": "authorization_code",
            "code": code,
            "client_id": Self.clientID,
            "redirect_uri": Self.redirectURI,
            "code_verifier": verifier,
        ])
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
        let responseData = try await http.post(Self.tokenEndpoint, headers: headers, jsonBody: data)
        return try Self.parseTokenResponse(responseData)
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
            + "<h2>\(title)</h2><p>\(detail)</p></body></html>"
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

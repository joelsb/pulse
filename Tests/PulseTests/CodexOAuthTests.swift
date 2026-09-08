import Foundation
import Testing
@testable import Pulse

// JSB-9: Pulse's own Codex OAuth grant, mirroring ClaudeOAuthTests.swift's
// shape and its own caveat — pure functions run under `swift test` in CI
// (macos-26); this machine has no Xcode (`error: no such module 'Testing'`).
// The live Keychain round trip and the real token exchange are exercised
// instead by `scripts/verify-codex-oauth-rotation.sh`, the same split
// `verify-oauth-rotation.sh` uses for the Claude side.

private func base64URL(_ string: String) -> String {
    Data(string.utf8).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

private func fakeJWT(payload: String) -> String {
    "\(base64URL(#"{"alg":"none"}"#)).\(base64URL(payload)).sig"
}

@Suite("CodexOAuthClient authorize URL")
struct CodexOAuthAuthorizeURLTests {
    @Test func carriesTheRegisteredRedirectAndOrgFlag() {
        let pkce = ClaudeOAuthClient.PKCE(verifier: "v", challenge: "c", state: "s")
        let url = CodexOAuthClient.authorizeURL(pkce: pkce)
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        func value(_ name: String) -> String? { components.queryItems?.first(where: { $0.name == name })?.value }

        // Constraint 1: exactly this port and path, never an arbitrary loopback.
        #expect(value("redirect_uri") == "http://localhost:1455/auth/callback")
        #expect(CodexOAuthClient.redirectURI.contains(":\(CodexOAuthClient.redirectPort)/"))
        // Constraint 4: what makes the id_token carry chatgpt_account_id.
        #expect(value("id_token_add_organizations") == "true")
        #expect(value("client_id") == CodexOAuthClient.clientID)
        #expect(value("code_challenge") == "c")
        #expect(value("code_challenge_method") == "S256")
        #expect(value("state") == "s")
        #expect(value("response_type") == "code")
        // Least privilege — never the connector-invoking scopes a real Codex
        // CLI token happens to carry.
        #expect(value("scope") == "openid profile email offline_access")
        #expect(value("scope")?.contains("connectors") == false)
    }
}

@Suite("CodexOAuthClient code-exchange request body")
struct CodexOAuthExchangeRequestBodyTests {
    // Constraint 3: NO `state` here — the opposite fix from Claude's, and
    // copying Claude's fix across would 400 every real Codex sign-in.
    @Test func containsExactlyFiveFieldsNoState() {
        let body = CodexOAuthClient.exchangeRequestBody(code: "the-code", verifier: "the-verifier")
        #expect(body == [
            "grant_type": "authorization_code",
            "client_id": CodexOAuthClient.clientID,
            "code": "the-code",
            "code_verifier": "the-verifier",
            "redirect_uri": CodexOAuthClient.redirectURI,
        ])
        #expect(body["state"] == nil)
    }
}

@Suite("CodexOAuthClient token-endpoint error classification")
struct CodexOAuthTokenEndpointErrorTests {
    @Test func exactInvalidGrantBodyClassifies() {
        let body = Data(#"{"error":"invalid_grant"}"#.utf8)
        #expect(CodexOAuthClient.tokenEndpointError(status: 400, body: body) == .invalidGrant)
    }

    @Test func differentErrorFieldIsNeverInvalidGrant() {
        let body = Data(#"{"error":"invalid_request"}"#.utf8)
        #expect(CodexOAuthClient.tokenEndpointError(status: 400, body: body) == .other(status: 400))
    }

    @Test func nonFourHundredNeverClassifiesInvalidGrant() {
        let body = Data(#"{"error":"invalid_grant"}"#.utf8)
        #expect(CodexOAuthClient.tokenEndpointError(status: 401, body: body) == .other(status: 401))
    }

    @Test func whitespaceAndCaseVariantsStillClassify() {
        #expect(CodexOAuthClient.tokenEndpointError(status: 400, body: Data(#"{"error":"Invalid_Grant "}"#.utf8)) == .invalidGrant)
    }
}

@Suite("CodexOAuthClient token response")
struct CodexOAuthTokenResponseTests {
    @Test func parsesAccessRefreshIDTokenAndExpiry() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let body = Data(#"{"access_token":"AT","refresh_token":"RT","id_token":"IDT","expires_in":3600}"#.utf8)
        let pair = try CodexOAuthClient.parseTokenResponse(body, now: now)
        #expect(pair.accessToken == "AT")
        #expect(pair.refreshToken == "RT")
        #expect(pair.idToken == "IDT")
        #expect(pair.expiresAt == now.addingTimeInterval(3600))
    }

    // Constraint 4: unlike Claude's response, id_token is REQUIRED — there is
    // no separate /oauth/profile call to fall back on for account identity.
    @Test func missingIDTokenThrows() {
        let body = Data(#"{"access_token":"AT","refresh_token":"RT","expires_in":100}"#.utf8)
        #expect(throws: (any Error).self) {
            try CodexOAuthClient.parseTokenResponse(body)
        }
    }
}

@Suite("CodexOAuthClient account id from id_token")
struct CodexOAuthAccountIDTests {
    @Test func readsTheNamespacedClaim() {
        let payload = #"{"https://api.openai.com/auth":{"chatgpt_account_id":"acct-123"}}"#
        #expect(CodexOAuthClient.accountID(fromIDToken: fakeJWT(payload: payload)) == "acct-123")
    }

    @Test func missingClaimIsNil() {
        #expect(CodexOAuthClient.accountID(fromIDToken: fakeJWT(payload: "{}")) == nil)
    }
}

@Suite("CodexOAuthStore encoding")
struct CodexOAuthStoreEncodingTests {
    @Test func roundTripsThroughJSON() throws {
        let credentials = CodexOAuthStore.Credentials(
            accessToken: "AT", refreshToken: "RT",
            expiresAt: Date(timeIntervalSince1970: 1_700_000_000), accountID: "acct-1"
        )
        let encoded = try CodexOAuthStore.encode(credentials)
        #expect(encoded.hasPrefix("{"))
        #expect(!encoded.contains("id_token")) // constraint 7: never persisted
        let decoded = try CodexOAuthStore.decode(encoded)
        #expect(decoded == credentials)
    }

    @Test func roundTripsWithoutAnAccountID() throws {
        let credentials = CodexOAuthStore.Credentials(
            accessToken: "AT", refreshToken: "RT",
            expiresAt: Date(timeIntervalSince1970: 1_700_000_000), accountID: nil
        )
        let decoded = try CodexOAuthStore.decode(try CodexOAuthStore.encode(credentials))
        #expect(decoded.accountID == nil)
    }

    @Test func decodeRejectsMalformedPayloads() {
        #expect(throws: (any Error).self) { try CodexOAuthStore.decode("not json") }
        #expect(throws: (any Error).self) { try CodexOAuthStore.decode(#"{"access_token":"a"}"#) }
    }

    @Test func expiryAndRefreshWindow() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let soon = CodexOAuthStore.Credentials(accessToken: "a", refreshToken: "r", expiresAt: now.addingTimeInterval(100), accountID: nil)
        #expect(!soon.isExpired(now: now))
        #expect(soon.needsRefresh(now: now))

        let plentyLeft = CodexOAuthStore.Credentials(accessToken: "a", refreshToken: "r", expiresAt: now.addingTimeInterval(3600), accountID: nil)
        #expect(!plentyLeft.needsRefresh(now: now))
    }
}

@Suite("CodexAuth expiry from JWT")
struct CodexAuthExpiryTests {
    @Test func expiresAtDerivesFromExpClaimInSeconds() {
        // exp is seconds since epoch (RFC 7519); CodexAuth stores milliseconds.
        let token = fakeJWT(payload: #"{"exp":1800000000}"#)
        #expect(CodexAuth.expiresAt(idToken: token, accessToken: nil) == 1_800_000_000_000)
    }

    @Test func fallsBackToAccessTokenWhenNoIDToken() {
        let token = fakeJWT(payload: #"{"exp":1800000000}"#)
        #expect(CodexAuth.expiresAt(idToken: nil, accessToken: token) == 1_800_000_000_000)
    }

    @Test func missingExpClaimIsNil() {
        let token = fakeJWT(payload: "{}")
        #expect(CodexAuth.expiresAt(idToken: token, accessToken: nil) == nil)
    }

    @Test func isExpiredHonoursDerivedExpiry() {
        var auth = CodexAuth(accessToken: "x", expiresAt: 1_000_000)
        #expect(auth.isExpired(now: Date(timeIntervalSince1970: 1_001)))
        auth.expiresAt = nil
        #expect(!auth.isExpired(now: .distantFuture))
    }
}

@Suite("Codex jcode/pi credential sources")
struct CodexFallbackSourceTests {
    @Test func jcodeParsesActiveAccountFromOpenAIAccountsArray() throws {
        let url = URL.temporaryDirectory.appendingPathComponent("pulse-jcode-openai-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let json = #"""
        {"openai_accounts":[
          {"label":"openai-1","access_token":"AT-1","refresh_token":"RT-1","id_token":"IDT-1","account_id":"acct-1","expires_at":1789639786384}
        ],"active_openai_account":"openai-1"}
        """#
        try Data(json.utf8).write(to: url)

        let store = JcodeOpenAICredentialsStore(authFile: url)
        let auth = try #require(store.credentials())
        #expect(auth.accessToken == "AT-1")
        #expect(auth.idToken == "IDT-1")
        #expect(auth.accountID == "acct-1")
        #expect(auth.expiresAt == 1_789_639_786_384)
    }

    @Test func jcodeMissingFileReturnsNil() {
        let store = JcodeOpenAICredentialsStore(authFile: URL.temporaryDirectory.appendingPathComponent("does-not-exist-\(UUID().uuidString).json"))
        #expect(store.credentials() == nil)
    }

    @Test func piReadsTheOpenAICodexKeyOfTheSameAuthFile() throws {
        let url = URL.temporaryDirectory.appendingPathComponent("pulse-pi-auth-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let json = #"""
        {"anthropic":{"access":"anthropic-at","expires":1},
         "openai-codex":{"type":"oauth","access":"AT-PI","refresh":"RT-PI","expires":1789126789904,"accountId":"acct-pi"}}
        """#
        try Data(json.utf8).write(to: url)

        let credential = try #require(PiAccountResolver.readOpenAICodexAuth(url))
        #expect(credential.accessToken == "AT-PI")
        #expect(credential.expiresAt == 1_789_126_789_904)
        #expect(credential.accountID == "acct-pi")

        let auth = try #require(PiOpenAICodexCredentials.credentials(from: url))
        #expect(auth.accessToken == "AT-PI")
        #expect(auth.accountID == "acct-pi")
    }
}

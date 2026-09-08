import Foundation
import Testing
@testable import Pulse

// JSB-8: Pulse's own Claude OAuth grant. Most of this is pure — no network,
// no Keychain, no browser — so it runs under `swift test` in CI (macos-26)
// even though it cannot run on this machine (`error: no such module
// 'Testing'`, no Xcode). The exception is `LoopbackCallbackListenerTests`
// below: those two DO bind a real loopback socket and drive a real
// `URLSession` request at it, with a fixed `Task.sleep` to win the bind race
// rather than a synchronization primitive — a CI runner that denies a
// loopback bind, or heavy load, could fail them for reasons unrelated to the
// code under test. Flagged here rather than left implicit (review round 1,
// 2026-09-08), since the rest of this file being genuinely pure made that
// exception easy to miss. The Keychain write/read round trip and the live
// token exchange were separately verified by hand against the real Keychain
// and a real socket during implementation; see impl-pulse.md.

@Suite("ClaudeOAuthClient PKCE")
struct ClaudeOAuthPKCETests {
    @Test func challengeMatchesRFC7636TestVector() {
        // The exact verifier/challenge pair from RFC 7636 §4.1's own example.
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        #expect(ClaudeOAuthClient.codeChallenge(forVerifier: verifier) == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test func pkceProducesURLSafeNonEmptyValues() {
        let pkce = ClaudeOAuthClient.makePKCE()
        #expect(!pkce.verifier.isEmpty)
        #expect(!pkce.challenge.isEmpty)
        #expect(!pkce.state.isEmpty)
        let unsafe = CharacterSet(charactersIn: "+/=")
        #expect(pkce.verifier.rangeOfCharacter(from: unsafe) == nil)
        #expect(pkce.challenge.rangeOfCharacter(from: unsafe) == nil)
    }

    @Test func twoCallsNeverRepeatTheVerifier() {
        // A repeated verifier would make the challenge predictable — PKCE's
        // entire point is that it isn't.
        let first = ClaudeOAuthClient.makePKCE()
        let second = ClaudeOAuthClient.makePKCE()
        #expect(first.verifier != second.verifier)
        #expect(first.state != second.state)
    }
}

@Suite("ClaudeOAuthClient authorize URL")
struct ClaudeOAuthAuthorizeURLTests {
    @Test func carriesExactlyTheProvenFiveScopes() {
        let pkce = ClaudeOAuthClient.PKCE(verifier: "v", challenge: "c", state: "s")
        let url = ClaudeOAuthClient.authorizeURL(pkce: pkce)
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        func value(_ name: String) -> String? {
            components.queryItems?.first(where: { $0.name == name })?.value
        }
        // Exactly the 5 granted scopes (2026-09-08 falsification), never the
        // 6 Claude Code's CLI requests — org:create_api_key must never appear.
        #expect(value("scope") == "user:file_upload user:inference user:mcp_servers user:profile user:sessions:claude_code")
        #expect(value("scope")?.contains("org:create_api_key") == false)
        #expect(value("code_challenge") == "c")
        #expect(value("code_challenge_method") == "S256")
        #expect(value("state") == "s")
        #expect(value("client_id") == ClaudeOAuthClient.clientID)
        #expect(value("redirect_uri") == ClaudeOAuthClient.redirectURI)
        // Asserts AGREEMENT between the two constants, not the literal against
        // itself (review round 1, S4): `redirectURI` is derived from
        // `redirectPort`, so a bug that lets them drift independently again
        // would still pass a test that only checked "contains 53810".
        #expect(ClaudeOAuthClient.redirectURI.contains(":\(ClaudeOAuthClient.redirectPort)/"))
        // Never pi's port — falsified live that Pulse's own arbitrary port
        // works, so there is no reason to risk colliding with a pi sign-in.
        #expect(ClaudeOAuthClient.redirectPort != 53692)
    }
}

@Suite("ClaudeOAuthClient callback acceptance (state check)")
struct ClaudeOAuthAcceptCallbackTests {
    // S5 (review round 1): `state` is the only security-relevant branch in
    // the sign-in flow — it is what stops any other local process hitting
    // the loopback listener from being accepted as the real callback. The
    // listener tests below exercise `LoopbackCallbackListener` itself, not
    // `signIn`, and would both stay green if this guard were deleted; these
    // two close that gap.
    @Test func matchingStateReturnsTheCode() throws {
        let pkce = ClaudeOAuthClient.PKCE(verifier: "v", challenge: "c", state: "expected-state")
        let callback = LoopbackCallbackListener.Callback(code: "the-code", state: "expected-state")
        let code = try ClaudeOAuthClient.acceptCallback(callback, pkce: pkce)
        #expect(code == "the-code")
    }

    @Test func mismatchedStateThrowsAndNeverReturnsTheCode() {
        let pkce = ClaudeOAuthClient.PKCE(verifier: "v", challenge: "c", state: "expected-state")
        let callback = LoopbackCallbackListener.Callback(code: "attacker-code", state: "wrong-state")
        #expect(throws: (any Error).self) {
            try ClaudeOAuthClient.acceptCallback(callback, pkce: pkce)
        }
    }
}

@Suite("ClaudeOAuthClient token-endpoint error classification")
struct ClaudeOAuthTokenEndpointErrorTests {
    // R2-B2 (review round 2): this is the ONE function deciding whether a
    // `400` deletes both of an account's Keychain items
    // (`PulseOAuthStore.isDeadGrantError` keys directly on its result), and
    // review round 2 found NOTHING exercised it directly — the shell harness
    // only threw already-classified values from `refreshOverride`. The five
    // cases below are the ones the review specified.
    @Test func exactInvalidGrantBodyClassifies() {
        let body = Data(#"{"error":"invalid_grant","error_description":"Refresh token not found or invalid"}"#.utf8)
        #expect(ClaudeOAuthClient.tokenEndpointError(status: 400, body: body) == .invalidGrant)
    }

    @Test func differentErrorFieldIsNeverInvalidGrant() {
        let body = Data(#"{"error":"invalid_request"}"#.utf8)
        #expect(ClaudeOAuthClient.tokenEndpointError(status: 400, body: body) == .other(status: 400))
    }

    @Test func nonJSONBodyIsOther() {
        let body = Data("<html>cloudflare</html>".utf8)
        #expect(ClaudeOAuthClient.tokenEndpointError(status: 400, body: body) == .other(status: 400))
    }

    @Test func emptyBodyIsOther() {
        #expect(ClaudeOAuthClient.tokenEndpointError(status: 400, body: Data()) == .other(status: 400))
    }

    @Test func invalidGrantAtANonFourHundredStatusIsNeverInvalidGrant() {
        // The RFC 6749 §5.2 shape is specifically a 400; the same body at a
        // different status is not the signal this classifies.
        let body = Data(#"{"error":"invalid_grant"}"#.utf8)
        #expect(ClaudeOAuthClient.tokenEndpointError(status: 500, body: body) == .other(status: 500))
    }

    // R2-S2: the comparison is normalised (trimmed, lowercased) because
    // matching TOO STRICTLY reopens B1 in full (a gateway-added trailing
    // space or a differently-cased variant would retry forever with no
    // backoff instead of ever being recognised as permanent).
    @Test func whitespaceAndCaseVariantsStillClassify() {
        #expect(ClaudeOAuthClient.tokenEndpointError(status: 400, body: Data(#"{"error":"invalid_grant "}"#.utf8)) == .invalidGrant)
        #expect(ClaudeOAuthClient.tokenEndpointError(status: 400, body: Data(#"{"error":"Invalid_Grant"}"#.utf8)) == .invalidGrant)
    }
}

@Suite("ClaudeOAuthClient token response")
struct ClaudeOAuthTokenResponseTests {
    @Test func parsesAccessRefreshExpiryAndScope() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let body = Data(#"{"access_token":"AT","refresh_token":"RT","expires_in":28800,"scope":"user:profile user:inference"}"#.utf8)
        let pair = try ClaudeOAuthClient.parseTokenResponse(body, now: now)
        #expect(pair.accessToken == "AT")
        #expect(pair.refreshToken == "RT")
        #expect(pair.expiresAt == now.addingTimeInterval(28800))
        #expect(pair.grantedScope == "user:profile user:inference")
    }

    @Test func missingAccessTokenThrows() {
        let body = Data(#"{"refresh_token":"RT","expires_in":100}"#.utf8)
        #expect(throws: (any Error).self) {
            try ClaudeOAuthClient.parseTokenResponse(body)
        }
    }

    @Test func missingExpiresInFallsBackToEightHours() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let body = Data(#"{"access_token":"AT","refresh_token":"RT"}"#.utf8)
        let pair = try ClaudeOAuthClient.parseTokenResponse(body, now: now)
        #expect(pair.expiresAt == now.addingTimeInterval(28800))
    }
}

@Suite("ClaudeOAuthClient profile")
struct ClaudeOAuthProfileTests {
    @Test func parsesNestedAccountShape() {
        let data = Data(#"{"account":{"uuid":"u-1","email":"joel@datainnovation.io"}}"#.utf8)
        let profile = ClaudeOAuthClient.parseProfile(data)
        #expect(profile?.uuid == "u-1")
        #expect(profile?.email == "joel@datainnovation.io")
    }

    @Test func parsesFlatShapeToo() {
        let data = Data(#"{"uuid":"u-2","email":"e@x.com"}"#.utf8)
        #expect(ClaudeOAuthClient.parseProfile(data)?.uuid == "u-2")
    }

    @Test func noUUIDIsNil() {
        #expect(ClaudeOAuthClient.parseProfile(Data("{}".utf8)) == nil)
    }
}

@Suite("PulseOAuthStore encoding")
struct PulseOAuthStoreEncodingTests {
    @Test func roundTripsThroughJSON() throws {
        let credentials = PulseOAuthStore.Credentials(
            accessToken: "AT", refreshToken: "RT",
            expiresAt: Date(timeIntervalSince1970: 1_700_000_000),
            grantedScope: "user:profile"
        )
        let encoded = try PulseOAuthStore.encode(credentials)
        // Only a shape check (encoding is plain JSON, not argv-shaped) — the
        // actual secret-discipline guarantee (never in `arguments`, a log
        // line, or an error) is `KeychainWriter`'s, verified by hand against
        // the real Keychain during implementation; see impl-pulse.md.
        #expect(encoded.hasPrefix("{"))
        let decoded = try PulseOAuthStore.decode(encoded)
        #expect(decoded == credentials)
    }

    @Test func decodeRejectsMalformedPayloads() {
        #expect(throws: (any Error).self) { try PulseOAuthStore.decode("not json") }
        #expect(throws: (any Error).self) { try PulseOAuthStore.decode(#"{"access_token":"a"}"#) }
    }

    @Test func expiryAndRefreshWindow() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let soon = PulseOAuthStore.Credentials(
            accessToken: "a", refreshToken: "r",
            expiresAt: now.addingTimeInterval(100), grantedScope: ""
        )
        #expect(soon.isExpired(now: now) == false)
        #expect(soon.needsRefresh(now: now)) // inside the 300s window

        let plentyLeft = PulseOAuthStore.Credentials(
            accessToken: "a", refreshToken: "r",
            expiresAt: now.addingTimeInterval(3600), grantedScope: ""
        )
        #expect(!plentyLeft.needsRefresh(now: now))

        let expired = PulseOAuthStore.Credentials(
            accessToken: "a", refreshToken: "r",
            expiresAt: now.addingTimeInterval(-1), grantedScope: ""
        )
        #expect(expired.isExpired(now: now))
    }
}

@Suite("LoopbackCallbackListener")
struct LoopbackCallbackListenerTests {
    @Test func parsesCodeAndStateFromARealRequest() async throws {
        let port: UInt16 = 53_811
        let listener = try LoopbackCallbackListener(port: port)
        async let callback = listener.waitForCallback(timeout: 5)
        // Give the listener a moment to bind before the request lands.
        try await Task.sleep(for: .milliseconds(200))
        let url = URL(string: "http://localhost:\(port)/callback?code=abc&state=xyz")!
        _ = try await URLSession.shared.data(from: url)
        let result = try await callback
        #expect(result.code == "abc")
        #expect(result.state == "xyz")
    }

    @Test func surfacesAProviderErrorRedirect() async throws {
        let port: UInt16 = 53_812
        let listener = try LoopbackCallbackListener(port: port)
        async let callback = listener.waitForCallback(timeout: 5)
        try await Task.sleep(for: .milliseconds(200))
        let url = URL(string: "http://localhost:\(port)/callback?error=access_denied")!
        _ = try? await URLSession.shared.data(from: url)
        do {
            _ = try await callback
            Issue.record("expected the denial to throw")
        } catch let error as LoopbackCallbackListener.Failure {
            #expect(error == .deniedByProvider(description: "access_denied"))
        }
    }
}

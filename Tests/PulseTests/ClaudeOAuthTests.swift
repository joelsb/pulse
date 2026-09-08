import Foundation
import Testing
@testable import Pulse

// JSB-8: Pulse's own Claude OAuth grant. Everything here is pure — no
// network, no Keychain, no browser — so it runs under `swift test` in CI
// (macos-26) even though it cannot run on this machine (`error: no such
// module 'Testing'`, no Xcode). The listener, the real Keychain write/read
// round trip, and the live token exchange were verified by hand against real
// sockets and the real Keychain during implementation; see impl-pulse.md.

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
        // Never pi's port — falsified live that Pulse's own arbitrary port
        // works, so there is no reason to risk colliding with a pi sign-in.
        #expect(ClaudeOAuthClient.redirectURI.contains(":53810/") )
        #expect(!ClaudeOAuthClient.redirectURI.contains("53692"))
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
        // The secret must never be argv-shaped or contain anything that would
        // look like a shell word boundary issue if it ever leaked into a log
        // — plain JSON only.
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

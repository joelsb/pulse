// Standalone verifier for `CodexOAuthStore`'s rotation write order
// (docs/adr/0001-refresh-token-rotation-write-order.md,
// docs/adr/0002-codex-oauth-differs-from-claude.md).
//
// Same shape and same reasoning as scripts/oauth-rotation-harness.swift
// (Claude/JSB-8): OpenAI's refresh token is single-use from Pulse's point of
// view, so a wrong write order is a SILENT, PERMANENT failure — the grant is
// gone and the only symptom, days later, is a forced re-sign-in.
//
// Runs against the REAL Keychain, using a scratch account name
// (`harness-scratch-codex-...`) never read by production code (which uses
// the fixed `codex-primary` account — see `CodexOAuthStore`'s own doc
// comment on why `account` is overridable at all) and deleted at the end of
// every run, pass or fail.
//
// `swift test` cannot run on this machine (no Xcode). CI runs the real
// suite; this compiles the real sources with swiftc and asserts against them.

import Foundation

nonisolated(unsafe) var failures: [String] = []

func check(_ condition: Bool, _ label: String) {
    if !condition { failures.append(label) }
}

func checkEqual<T: Equatable>(_ lhs: T, _ rhs: T, _ label: String) {
    if lhs != rhs { failures.append("\(label): got \(lhs), expected \(rhs)") }
}

func scratchAccount(_ label: String) -> String {
    let name = "harness-scratch-codex-\(label)-\(UUID().uuidString.prefix(8))"
    print("SCRATCH_ACCOUNT \(name)")
    fflush(stdout)
    return name
}

func pair(access: String, refresh: String, idToken: String = "IDT", expiresIn: TimeInterval, now: Date = .now) -> CodexOAuthClient.TokenPair {
    CodexOAuthClient.TokenPair(accessToken: access, refreshToken: refresh, idToken: idToken, expiresAt: now.addingTimeInterval(expiresIn))
}

func seed(account: String, tokens: CodexOAuthClient.TokenPair) async throws {
    let writer = KeychainWriter()
    let credentials = CodexOAuthStore.Credentials(
        accessToken: tokens.accessToken, refreshToken: tokens.refreshToken,
        expiresAt: tokens.expiresAt, accountID: CodexOAuthClient.accountID(fromIDToken: tokens.idToken)
    )
    let secret = try CodexOAuthStore.encode(credentials)
    try await writer.write(service: "de.byte.pulse.codex-oauth", account: account, secret: secret)
    try await writer.write(service: "de.byte.pulse.codex-oauth-pending", account: account, secret: secret)
}

func seedItem(service: String, account: String, tokens: CodexOAuthClient.TokenPair) async throws {
    let writer = KeychainWriter()
    let credentials = CodexOAuthStore.Credentials(
        accessToken: tokens.accessToken, refreshToken: tokens.refreshToken,
        expiresAt: tokens.expiresAt, accountID: CodexOAuthClient.accountID(fromIDToken: tokens.idToken)
    )
    try await writer.write(service: service, account: account, secret: try CodexOAuthStore.encode(credentials))
}

func readItem(service: String, account: String) async -> CodexOAuthStore.Credentials? {
    let reader = KeychainReader()
    guard let stored = try? await reader.readGenericPassword(service: service, account: account) else { return nil }
    guard let secret = KeychainWriter.decode(stored) else { return nil }
    return try? CodexOAuthStore.decode(secret)
}

// ------------------------------------------------------------ Scenario 1
// Verification fails: the rotated pair must land in -pending, primary stays
// untouched, and a fresh store (simulating a relaunch) must still hand out
// the rotated pair, never the stale one with the burned refresh token.

func runVerificationFailureScenario() async {
    let account = scratchAccount("verify-fails")
    let old = pair(access: "OLD-AT", refresh: "OLD-RT", expiresIn: 60)
    do { try await seed(account: account, tokens: old) } catch {
        failures.append("scenario 1: seeding failed: \(error)")
        return
    }

    let rotatedTokens = pair(access: "NEW-AT-1", refresh: "NEW-RT-1", expiresIn: 3600)
    let store = CodexOAuthStore(
        account: account,
        refreshOverride: { _ in rotatedTokens },
        verifyOverride: { _ in false }
    )

    let returned = await store.credentials()
    checkEqual(returned?.accessToken, "OLD-AT", "scenario 1: a failed-verification rotation must return the OLD pair, never the unverified NEW one")

    let pendingAfter = await readItem(service: "de.byte.pulse.codex-oauth-pending", account: account)
    let primaryAfter = await readItem(service: "de.byte.pulse.codex-oauth", account: account)
    check(pendingAfter?.accessToken == "NEW-AT-1", "scenario 1: rotated pair must be durable in -pending even when verification fails")
    check(primaryAfter?.accessToken == "OLD-AT", "scenario 1: primary item must NOT be promoted when verification fails")

    let freshStore = CodexOAuthStore(account: account, verifyOverride: { _ in true })
    let afterRelaunch = await freshStore.credentials()
    checkEqual(afterRelaunch?.accessToken, "NEW-AT-1", "scenario 1: a fresh store after 'relaunch' must prefer -pending over the stale primary")
}

// ------------------------------------------------------------ Scenario 2
// Verification succeeds: promoted into primary, both items converge.

func runVerificationSuccessScenario() async {
    let account = scratchAccount("verify-ok")
    let old = pair(access: "OLD-AT-2", refresh: "OLD-RT-2", expiresIn: 60)
    do { try await seed(account: account, tokens: old) } catch {
        failures.append("scenario 2: seeding failed: \(error)")
        return
    }

    let rotatedTokens = pair(access: "NEW-AT-2", refresh: "NEW-RT-2", expiresIn: 3600)
    let store = CodexOAuthStore(account: account, refreshOverride: { _ in rotatedTokens }, verifyOverride: { _ in true })

    let result = await store.credentials()
    checkEqual(result?.accessToken, "NEW-AT-2", "scenario 2: credentials() must return the rotated pair")

    let primaryAfter = await readItem(service: "de.byte.pulse.codex-oauth", account: account)
    let pendingAfter = await readItem(service: "de.byte.pulse.codex-oauth-pending", account: account)
    checkEqual(primaryAfter?.accessToken, "NEW-AT-2", "scenario 2: primary item must be promoted on successful verification")
    checkEqual(pendingAfter?.accessToken, "NEW-AT-2", "scenario 2: pending item converges to the same pair")
}

// ------------------------------------------------------------ Scenario 3
// A refresh call that throws must leave the OLD pair fully intact.

func runRefreshFailureScenario() async {
    let account = scratchAccount("refresh-fails")
    let old = pair(access: "OLD-AT-3", refresh: "OLD-RT-3", expiresIn: 60)
    do { try await seed(account: account, tokens: old) } catch {
        failures.append("scenario 3: seeding failed: \(error)")
        return
    }

    struct Boom: Error {}
    let store = CodexOAuthStore(account: account, refreshOverride: { _ in throw Boom() })
    let result = await store.credentials()
    checkEqual(result?.accessToken, "OLD-AT-3", "scenario 3: a failed refresh attempt must still hand out the still-valid old pair")

    let primaryAfter = await readItem(service: "de.byte.pulse.codex-oauth", account: account)
    checkEqual(primaryAfter?.accessToken, "OLD-AT-3", "scenario 3: primary item must be untouched by a failed refresh")
}

// ------------------------------------------------------------ Scenario 4
// A pair with plenty of time left must never be rotated at all.

func runNoRotationWhenFreshScenario() async {
    let account = scratchAccount("no-rotate")
    let fresh = pair(access: "FRESH-AT", refresh: "FRESH-RT", expiresIn: 3600)
    do { try await seed(account: account, tokens: fresh) } catch {
        failures.append("scenario 4: seeding failed: \(error)")
        return
    }

    let refreshCalledFlag = FlagBox()
    let store = CodexOAuthStore(account: account, refreshOverride: { _ in
        refreshCalledFlag.set()
        return pair(access: "SHOULD-NOT-HAPPEN", refresh: "SHOULD-NOT-HAPPEN", expiresIn: 3600)
    })
    let result = await store.credentials()
    checkEqual(result?.accessToken, "FRESH-AT", "scenario 4: a fresh pair must be returned unchanged")
    check(!refreshCalledFlag.value, "scenario 4: a pair outside the refresh window must never trigger a rotation")
}

// ------------------------------------------------------------ Scenario 5
// invalid_grant is PERMANENT: never retried, Keychain items actually deleted.

func runDeadGrantScenario() async {
    let account = scratchAccount("dead-grant")
    let old = pair(access: "OLD-AT-5", refresh: "OLD-RT-5", expiresIn: 60)
    do { try await seed(account: account, tokens: old) } catch {
        failures.append("scenario 5: seeding failed: \(error)")
        return
    }

    let refreshCallCount = CountBox()
    let store = CodexOAuthStore(account: account, refreshOverride: { _ in
        refreshCallCount.increment()
        throw CodexOAuthClient.TokenEndpointError.invalidGrant
    })

    let firstCallResult = await store.credentials()
    checkEqual(firstCallResult?.accessToken, "OLD-AT-5", "scenario 5: the FIRST call, mid-rotation, must still return the still-valid old access token")
    let deadAfterFirstCall = await !store.hasGrant()
    check(deadAfterFirstCall, "scenario 5: hasGrant must report false once invalid_grant has been seen")

    let secondResult = await store.credentials()
    check(secondResult == nil, "scenario 5: a dead account must never hand out a pair again in the same run")
    checkEqual(refreshCallCount.value, 1, "scenario 5: a dead grant must not be retried - the refresh call must happen exactly once")

    let primaryAfter = await readItem(service: "de.byte.pulse.codex-oauth", account: account)
    let pendingAfter = await readItem(service: "de.byte.pulse.codex-oauth-pending", account: account)
    check(primaryAfter == nil, "scenario 5: the primary Keychain item must be deleted for a dead grant")
    check(pendingAfter == nil, "scenario 5: the pending Keychain item must be deleted for a dead grant")

    let freshStore = CodexOAuthStore(account: account)
    let afterRelaunch = await freshStore.hasGrant()
    check(!afterRelaunch, "scenario 5: a fresh store after 'relaunch' must also read no grant for a dead account")
}

// ------------------------------------------------------------ Scenario 6
// A 400 that is NOT invalid_grant must NOT delete the grant.

func runNonInvalidGrant400Scenario() async {
    let account = scratchAccount("other-400")
    let old = pair(access: "OLD-AT-6", refresh: "OLD-RT-6", expiresIn: 60)
    do { try await seed(account: account, tokens: old) } catch {
        failures.append("scenario 6: seeding failed: \(error)")
        return
    }

    let store = CodexOAuthStore(account: account, refreshOverride: { _ in
        throw CodexOAuthClient.TokenEndpointError.other(status: 400)
    })

    let result = await store.credentials()
    checkEqual(result?.accessToken, "OLD-AT-6", "scenario 6: a non-invalid_grant 400 must still hand out the still-valid old pair")
    let stillHasGrant = await store.hasGrant()
    check(stillHasGrant, "scenario 6: a non-invalid_grant 400 must NOT mark the grant dead")

    let primaryAfter = await readItem(service: "de.byte.pulse.codex-oauth", account: account)
    let pendingAfter = await readItem(service: "de.byte.pulse.codex-oauth-pending", account: account)
    check(primaryAfter?.accessToken == "OLD-AT-6", "scenario 6: a non-invalid_grant 400 must NOT delete the primary Keychain item")
    check(pendingAfter?.accessToken == "OLD-AT-6", "scenario 6: a non-invalid_grant 400 must NOT delete the pending Keychain item")
}

// ------------------------------------------------------------ Scenario 7
// `CodexOAuthClient.tokenEndpointError` exercised directly.

func runTokenEndpointErrorScenario() {
    checkEqual(
        CodexOAuthClient.tokenEndpointError(status: 400, body: Data(#"{"error":"invalid_grant"}"#.utf8)),
        .invalidGrant,
        "scenario 7: a 400 with error=invalid_grant must classify as invalidGrant"
    )
    checkEqual(
        CodexOAuthClient.tokenEndpointError(status: 400, body: Data(#"{"error":"invalid_request"}"#.utf8)),
        .other(status: 400),
        "scenario 7: a 400 with a DIFFERENT error field must classify as other(400), never invalidGrant"
    )
    checkEqual(
        CodexOAuthClient.tokenEndpointError(status: 400, body: Data("<html>cloudflare</html>".utf8)),
        .other(status: 400),
        "scenario 7: a 400 with a non-JSON body must classify as other(400)"
    )
    checkEqual(
        CodexOAuthClient.tokenEndpointError(status: 400, body: Data()),
        .other(status: 400),
        "scenario 7: a 400 with an empty body must classify as other(400)"
    )
    checkEqual(
        CodexOAuthClient.tokenEndpointError(status: 500, body: Data(#"{"error":"invalid_grant"}"#.utf8)),
        .other(status: 500),
        "scenario 7: error=invalid_grant at a NON-400 status must classify as other(status), never invalidGrant"
    )
}

// ------------------------------------------------------------ Scenario 8
// An unpromoted -pending pair must be verified once before being served.

func runUnpromotedPendingScenario() async {
    let oldPrimary = pair(access: "OLD-AT-8", refresh: "OLD-RT-8", expiresIn: 60)
    let unpromotedPending = pair(access: "UNVERIFIED-AT-8", refresh: "UNVERIFIED-RT-8", expiresIn: 3600)

    let successAccount = scratchAccount("unpromoted-pending-ok")
    do {
        try await seedItem(service: "de.byte.pulse.codex-oauth", account: successAccount, tokens: oldPrimary)
        try await seedItem(service: "de.byte.pulse.codex-oauth-pending", account: successAccount, tokens: unpromotedPending)
    } catch {
        failures.append("scenario 8: seeding (success half) failed: \(error)")
        return
    }
    let successStore = CodexOAuthStore(account: successAccount, verifyOverride: { _ in true })
    let successResult = await successStore.credentials()
    checkEqual(successResult?.accessToken, "UNVERIFIED-AT-8", "scenario 8: a verified unpromoted pending pair must be served")
    let primaryAfterSuccess = await readItem(service: "de.byte.pulse.codex-oauth", account: successAccount)
    checkEqual(primaryAfterSuccess?.accessToken, "UNVERIFIED-AT-8", "scenario 8: a verified unpromoted pending pair must be promoted into primary")

    let failAccount = scratchAccount("unpromoted-pending-fails")
    do {
        try await seedItem(service: "de.byte.pulse.codex-oauth", account: failAccount, tokens: oldPrimary)
        try await seedItem(service: "de.byte.pulse.codex-oauth-pending", account: failAccount, tokens: unpromotedPending)
    } catch {
        failures.append("scenario 8: seeding (failure half) failed: \(error)")
        return
    }
    let failStore = CodexOAuthStore(account: failAccount, verifyOverride: { _ in false })
    let failResult = await failStore.credentials()
    check(failResult == nil, "scenario 8: an unpromoted pending pair that fails verification must be refused, not served")
    let primaryAfterFail = await readItem(service: "de.byte.pulse.codex-oauth", account: failAccount)
    checkEqual(primaryAfterFail?.accessToken, "OLD-AT-8", "scenario 8: a failed verification must NOT promote the bad pair into primary")
}

// ------------------------------------------------------------ Scenario 9
// The real exchange body: no state (constraint 3), exactly 5 fields.

func runExchangeRequestBodyScenario() {
    let body = CodexOAuthClient.exchangeRequestBody(code: "the-code", verifier: "the-verifier")
    checkEqual(body.count, 5, "scenario 9: the exchange body must carry exactly 5 fields")
    check(body["state"] == nil, "scenario 9: the exchange body must NEVER carry state (constraint 3) - copying Claude's fix across 400s every real sign-in")
    checkEqual(body["grant_type"], "authorization_code", "scenario 9: grant_type must be authorization_code")
    checkEqual(body["code"], "the-code", "scenario 9: code must be carried through unchanged")
    checkEqual(body["client_id"], CodexOAuthClient.clientID, "scenario 9: client_id must be present")
    checkEqual(body["redirect_uri"], CodexOAuthClient.redirectURI, "scenario 9: redirect_uri must be present")
    checkEqual(body["code_verifier"], "the-verifier", "scenario 9: code_verifier must be present")
}

// ------------------------------------------------------------ Scenario 10
// Bounded retries for a non-invalid_grant refresh failure.

func runBoundedRefreshFailuresScenario() async {
    let account = scratchAccount("bounded-failures")
    let stuck = pair(access: "AT-10", refresh: "RT-10", expiresIn: 60)
    do { try await seed(account: account, tokens: stuck) } catch {
        failures.append("scenario 10: seeding failed: \(error)")
        return
    }

    struct PermanentButUnclassified: Error {}
    let callCount = CountBox()
    let store = CodexOAuthStore(account: account, refreshOverride: { _ in
        callCount.increment()
        throw PermanentButUnclassified()
    })

    for _ in 0..<10 {
        _ = await store.credentials()
    }
    checkEqual(callCount.value, 3, "scenario 10: a non-invalid_grant refresh failure must stop being retried after 3 consecutive attempts")

    let stillHasGrant = await store.hasGrant()
    check(stillHasGrant, "scenario 10: a bounded-out refresh failure must NOT mark the grant dead")
}

// ------------------------------------------------------------ Scenario 11
// N concurrent callers must coalesce onto exactly ONE refresh call.

func runConcurrentRotationScenario() async {
    let account = scratchAccount("concurrent-rotation")
    let old = pair(access: "OLD-AT-11", refresh: "OLD-RT-11", expiresIn: 60)
    do { try await seed(account: account, tokens: old) } catch {
        failures.append("scenario 11: seeding failed: \(error)")
        return
    }

    let rotateCallCount = CountBox()
    let store = CodexOAuthStore(
        account: account,
        refreshOverride: { _ in
            rotateCallCount.increment()
            try? await Task.sleep(for: .milliseconds(50))
            return pair(access: "ROTATED-AT-11", refresh: "ROTATED-RT-11", expiresIn: 3600)
        },
        verifyOverride: { _ in true }
    )

    async let r1 = store.credentials()
    async let r2 = store.credentials()
    async let r3 = store.credentials()
    async let r4 = store.credentials()
    async let r5 = store.credentials()
    let results = await [r1, r2, r3, r4, r5]

    checkEqual(rotateCallCount.value, 1, "scenario 11: 5 concurrent callers for the same account must trigger exactly ONE refresh call")
    check(results.allSatisfy { $0 != nil }, "scenario 11: no concurrent caller should be starved of a usable pair")

    let primaryAfter = await readItem(service: "de.byte.pulse.codex-oauth", account: account)
    checkEqual(primaryAfter?.accessToken, "ROTATED-AT-11", "scenario 11: the account must end up on the single rotated pair, never split, burned or deleted")
}

// ------------------------------------------------------------ Scenario 12
// Realistic-length payload: Codex's real access token is ~1,698 characters -
// the exact length whose 128-byte truncation JSB-8 round 5 found and fixed.

func runRealisticLengthPayloadScenario() async {
    let account = scratchAccount("realistic-length")
    let longAccessToken = String(repeating: "T", count: 1698) // Codex's real length
    let longRefreshToken = String(repeating: "R", count: 400)
    // id_token is never persisted (constraint 7) - a realistic-length ONE is
    // still sent through TokenPair here, exactly as a real exchange/refresh
    // response would, to prove the derive-then-discard path handles it.
    let idToken = String(repeating: "I", count: 1765)
    let realistic = CodexOAuthClient.TokenPair(
        accessToken: longAccessToken, refreshToken: longRefreshToken,
        idToken: idToken, expiresAt: Date.now.addingTimeInterval(3600)
    )

    do {
        try await seed(account: account, tokens: realistic)
    } catch {
        failures.append("scenario 12: seeding a realistic-length payload failed: \(error)")
        return
    }

    let readBack = await readItem(service: "de.byte.pulse.codex-oauth", account: account)
    checkEqual(readBack?.accessToken, longAccessToken, "scenario 12: a realistic-length (1,698-byte) access token must round-trip exactly, not truncate")
    checkEqual(readBack?.refreshToken, longRefreshToken, "scenario 12: the refresh token must round-trip exactly too")

    let store = CodexOAuthStore(account: account, verifyOverride: { _ in true })
    let credentials = await store.credentials()
    checkEqual(credentials?.accessToken, longAccessToken, "scenario 12: CodexOAuthStore.credentials must return the full-length token, not a truncated or undecodable one")
}

// ------------------------------------------------------------ Scenario 13
// Constraint 7: the id_token itself must NEVER reach the Keychain, even
// though a realistic one (1,765 characters, this machine's own length) is
// what a real token response carries - this is the exact regression a
// future "just store the whole TokenPair" simplification would reintroduce,
// and the one that silently truncated at `security -i`'s undocumented
// stdin line-length limit before this fix.

func runIDTokenNeverPersistedScenario() async {
    let account = scratchAccount("id-token-not-persisted")
    let payload = #"{"https://api.openai.com/auth":{"chatgpt_account_id":"acct-scenario-13"}}"#
    let base64URL = { (string: String) -> String in
        Data(string.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
    let idToken = "\(base64URL(#"{"alg":"none"}"#)).\(base64URL(payload)).sig"
    let tokens = CodexOAuthClient.TokenPair(
        accessToken: "AT-13", refreshToken: "RT-13", idToken: idToken,
        expiresAt: Date.now.addingTimeInterval(3600)
    )
    do { try await seed(account: account, tokens: tokens) } catch {
        failures.append("scenario 13: seeding failed: \(error)")
        return
    }

    let readBack = await readItem(service: "de.byte.pulse.codex-oauth", account: account)
    checkEqual(readBack?.accountID, "acct-scenario-13", "scenario 13: the derived accountID must be persisted and readable back")

    let reader = KeychainReader()
    guard let storedRaw = try? await reader.readGenericPassword(service: "de.byte.pulse.codex-oauth", account: account),
          let decoded = KeychainWriter.decode(storedRaw)
    else {
        failures.append("scenario 13: could not read the raw stored item back to inspect it")
        return
    }
    check(!decoded.contains(idToken), "scenario 13: the raw id_token string must NEVER appear in the stored Keychain payload")
    check(!decoded.contains("id_token"), "scenario 13: the stored payload must not even carry an id_token FIELD")
}

// ------------------------------------------------------------ Scenario 14
// KeychainWriter must refuse a write whose composed `security -i` command
// line would exceed the measured stdin-line budget (KeychainWriter's own doc
// comment) BEFORE attempting it, throwing the specific `.lineTooLong` case -
// not just eventually failing the post-write read-back with the generic
// `.verificationFailed`, which sends the next person hunting the wrong cause.
// A realistic over-length payload (a ~3,000-byte fake access token, well
// past what any real Codex/Claude token needs) is used, not a synthetic
// count picked to just clear the threshold - the same "realistic length
// finds real bugs" lesson scenario 12 already applies.

func runOverLengthPayloadRejectedScenario() async {
    let account = scratchAccount("over-length")
    let oversizedAccessToken = String(repeating: "A", count: 3000)
    let credentials = CodexOAuthStore.Credentials(
        accessToken: oversizedAccessToken,
        refreshToken: String(repeating: "R", count: 200),
        expiresAt: Date.now.addingTimeInterval(3600),
        accountID: "acct-14"
    )
    guard let secret = try? CodexOAuthStore.encode(credentials) else {
        failures.append("scenario 14: could not encode the oversized credentials")
        return
    }

    let writer = KeychainWriter()
    do {
        try await writer.write(service: "de.byte.pulse.codex-oauth", account: account, secret: secret)
        failures.append("scenario 14: a write whose command line exceeds the measured budget must throw, not silently truncate or succeed")
    } catch let error as KeychainWriter.Failure {
        guard case .lineTooLong = error else {
            failures.append("scenario 14: expected .lineTooLong, got \(error) - a generic failure here means the proactive guard did not fire")
            return
        }
        // Confirmed: nothing was actually written for this scratch account -
        // the guard fired BEFORE the process ever ran.
        let stored = await readItem(service: "de.byte.pulse.codex-oauth", account: account)
        check(stored == nil, "scenario 14: a rejected over-length write must leave no item behind")
    } catch {
        failures.append("scenario 14: expected KeychainWriter.Failure.lineTooLong, got a different error type: \(error)")
    }
}

final class CountBox: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

final class FlagBox: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func set() { lock.lock(); flag = true; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
}

let semaphore = DispatchSemaphore(value: 0)
Task {
    await runVerificationFailureScenario()
    await runVerificationSuccessScenario()
    await runRefreshFailureScenario()
    await runNoRotationWhenFreshScenario()
    await runDeadGrantScenario()
    await runNonInvalidGrant400Scenario()
    runTokenEndpointErrorScenario()
    await runUnpromotedPendingScenario()
    runExchangeRequestBodyScenario()
    await runBoundedRefreshFailuresScenario()
    await runConcurrentRotationScenario()
    await runRealisticLengthPayloadScenario()
    await runIDTokenNeverPersistedScenario()
    await runOverLengthPayloadRejectedScenario()
    semaphore.signal()
}
while semaphore.wait(timeout: .now()) == .timedOut {
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
}

if failures.isEmpty {
    print("ALL PASS")
} else {
    for failure in failures { print("FAIL \(failure)") }
    exit(1)
}

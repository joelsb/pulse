// Standalone verifier for `PulseOAuthStore`'s rotation write order
// (docs/adr/0001-refresh-token-rotation-write-order.md).
//
// WHY THIS EXISTS: Anthropic's refresh token is strictly rotating — reusing
// one after it has been exchanged returns 400 invalid_grant, proven live
// 2026-09-08. That makes a wrong write order a SILENT, PERMANENT failure: the
// grant is gone and the only symptom is a forced re-sign-in, sometime later,
// that looks like nothing more than "the token expired." A bug here would not
// show up as a crash or a red test — it would show up as an account quietly
// losing its Pulse-owned grant days after the code shipped.
//
// This exercises the REAL `PulseOAuthStore`, `KeychainWriter` and
// `KeychainReader` against a real (scratch, clearly-named) Keychain item pair
// — only the network calls inside `rotate()` are swapped for controllable
// closures, via the same override seam production code has for exactly this
// purpose. Everything else, including every Keychain read/write, is the real
// shipped code path.
//
// `swift test` cannot run on a machine without Xcode (`error: no such module
// 'Testing'`). CI runs the real suite; this compiles the real sources with
// swiftc and asserts against them, same shape as
// scripts/verify-rate-limit-backoff.sh.

import Foundation

nonisolated(unsafe) var failures: [String] = []

func check(_ condition: Bool, _ label: String) {
    if !condition { failures.append(label) }
}

func checkEqual<T: Equatable>(_ lhs: T, _ rhs: T, _ label: String) {
    if lhs != rhs { failures.append("\(label): got \(lhs), expected \(rhs)") }
}

// A distinct account per test case, never a real Anthropic uuid, so a defect
// in this harness can never touch a real grant. Printed as
// `SCRATCH_ACCOUNT <name>` and FLUSHED the instant it is minted — not
// batched to the end of the run — and the .sh wrapper deletes both Keychain
// items for each one it sees on stdout. Printing early, not late, is what
// lets cleanup happen even if the process dies abnormally (a hang the
// wrapper's own timeout kills, a crash) partway through the scenarios,
// rather than only on a clean exit.
func scratchAccount(_ label: String) -> String {
    let name = "harness-scratch-\(label)-\(UUID().uuidString.prefix(8))"
    print("SCRATCH_ACCOUNT \(name)")
    fflush(stdout)
    return name
}

func pair(access: String, refresh: String, expiresIn: TimeInterval, now: Date = .now) -> ClaudeOAuthClient.TokenPair {
    ClaudeOAuthClient.TokenPair(
        accessToken: access, refreshToken: refresh,
        expiresAt: now.addingTimeInterval(expiresIn), grantedScope: "user:profile"
    )
}

func seed(account: String, tokens: ClaudeOAuthClient.TokenPair) async throws {
    let writer = KeychainWriter()
    let credentials = PulseOAuthStore.Credentials(
        accessToken: tokens.accessToken, refreshToken: tokens.refreshToken,
        expiresAt: tokens.expiresAt, grantedScope: tokens.grantedScope
    )
    let secret = try PulseOAuthStore.encode(credentials)
    // Seeds BOTH items, matching what a real prior sign-in leaves behind
    // (PulseOAuthStore.signIn writes both directly — see its own comment).
    try await writer.write(service: "de.byte.pulse.oauth", account: account, secret: secret)
    try await writer.write(service: "de.byte.pulse.oauth-pending", account: account, secret: secret)
}

func readItem(service: String, account: String) async -> PulseOAuthStore.Credentials? {
    let reader = KeychainReader()
    guard let secret = try? await reader.readGenericPassword(service: service, account: account) else { return nil }
    return try? PulseOAuthStore.decode(secret)
}

// ------------------------------------------------------------ Scenario 1
// Verification fails: the rotated pair must land in `-pending`, the primary
// item must stay untouched, and a FRESH store instance (simulating a relaunch
// after a crash right after the pending write) must still hand out the
// rotated pair, never the stale one with the burned refresh token.

func runVerificationFailureScenario() async {
    let account = scratchAccount("verify-fails")
    let old = pair(access: "OLD-AT", refresh: "OLD-RT", expiresIn: 60) // inside the 300s refresh window
    do { try await seed(account: account, tokens: old) } catch {
        failures.append("scenario 1: seeding failed: \(error)")
        return
    }

    let rotatedTokens = pair(access: "NEW-AT-1", refresh: "NEW-RT-1", expiresIn: 28800)
    let store = PulseOAuthStore(
        refreshOverride: { _ in rotatedTokens },
        verifyOverride: { _ in false } // the rotated pair does not check out
    )

    // B2: this is the assertion the original harness discarded entirely
    // (`_ = await store.credentials(...)`), which is exactly why a rotate()
    // that returned the unverified pair could pass all four planted defects
    // - none of them touch the return value, only the Keychain items. A pair
    // that failed verification must never reach the caller: `credentials()`
    // must keep handing out the OLD, still-valid pair.
    let returned = await store.credentials(forAccountUUID: account)
    checkEqual(returned?.accessToken, "OLD-AT", "scenario 1: a failed-verification rotation must return the OLD pair, never the unverified NEW one")

    let pendingAfter = await readItem(service: "de.byte.pulse.oauth-pending", account: account)
    let primaryAfter = await readItem(service: "de.byte.pulse.oauth", account: account)

    check(pendingAfter?.accessToken == "NEW-AT-1", "scenario 1: rotated pair must be durable in -pending even when verification fails")
    check(primaryAfter?.accessToken == "OLD-AT", "scenario 1: primary item must NOT be promoted when verification fails")

    // Simulate a relaunch: a brand new store instance, no in-memory state,
    // reading the same account. It must prefer the pending pair, not the
    // stale primary whose refresh token is already burned server-side.
    let freshStore = PulseOAuthStore(verifyOverride: { _ in true })
    let afterRelaunch = await freshStore.credentials(forAccountUUID: account)
    checkEqual(afterRelaunch?.accessToken, "NEW-AT-1", "scenario 1: a fresh store after 'relaunch' must prefer -pending over the stale primary")
}

// ------------------------------------------------------------ Scenario 2
// Verification succeeds: the rotated pair must be promoted into the primary
// item, and both items converge to the same content.

func runVerificationSuccessScenario() async {
    let account = scratchAccount("verify-ok")
    let old = pair(access: "OLD-AT-2", refresh: "OLD-RT-2", expiresIn: 60)
    do { try await seed(account: account, tokens: old) } catch {
        failures.append("scenario 2: seeding failed: \(error)")
        return
    }

    let rotatedTokens = pair(access: "NEW-AT-2", refresh: "NEW-RT-2", expiresIn: 28800)
    let store = PulseOAuthStore(
        refreshOverride: { _ in rotatedTokens },
        verifyOverride: { _ in true }
    )

    let result = await store.credentials(forAccountUUID: account)
    checkEqual(result?.accessToken, "NEW-AT-2", "scenario 2: credentials() must return the rotated pair")

    let primaryAfter = await readItem(service: "de.byte.pulse.oauth", account: account)
    let pendingAfter = await readItem(service: "de.byte.pulse.oauth-pending", account: account)
    checkEqual(primaryAfter?.accessToken, "NEW-AT-2", "scenario 2: primary item must be promoted on successful verification")
    checkEqual(pendingAfter?.accessToken, "NEW-AT-2", "scenario 2: pending item converges to the same pair")
}

// ------------------------------------------------------------ Scenario 3
// A refresh call that throws must leave the OLD pair fully intact and usable
// — a transient network failure must never strand the account.

func runRefreshFailureScenario() async {
    let account = scratchAccount("refresh-fails")
    let old = pair(access: "OLD-AT-3", refresh: "OLD-RT-3", expiresIn: 60)
    do { try await seed(account: account, tokens: old) } catch {
        failures.append("scenario 3: seeding failed: \(error)")
        return
    }

    struct Boom: Error {}
    let store = PulseOAuthStore(refreshOverride: { _ in throw Boom() })
    let result = await store.credentials(forAccountUUID: account)
    checkEqual(result?.accessToken, "OLD-AT-3", "scenario 3: a failed refresh attempt must still hand out the still-valid old pair")

    let primaryAfter = await readItem(service: "de.byte.pulse.oauth", account: account)
    checkEqual(primaryAfter?.accessToken, "OLD-AT-3", "scenario 3: primary item must be untouched by a failed refresh")
}

// ------------------------------------------------------------ Scenario 4
// A pair with plenty of time left must never be rotated at all — this is the
// "never send a token already known to be expired, and never rotate one that
// doesn't need it" half of the same rule.

func runNoRotationWhenFreshScenario() async {
    let account = scratchAccount("no-rotate")
    let fresh = pair(access: "FRESH-AT", refresh: "FRESH-RT", expiresIn: 3600) // outside the 300s window
    do { try await seed(account: account, tokens: fresh) } catch {
        failures.append("scenario 4: seeding failed: \(error)")
        return
    }

    let refreshCalledFlag = FlagBox()
    let store = PulseOAuthStore(refreshOverride: { _ in
        refreshCalledFlag.set()
        return pair(access: "SHOULD-NOT-HAPPEN", refresh: "SHOULD-NOT-HAPPEN", expiresIn: 28800)
    })
    let result = await store.credentials(forAccountUUID: account)
    checkEqual(result?.accessToken, "FRESH-AT", "scenario 4: a fresh pair must be returned unchanged")
    check(!refreshCalledFlag.value, "scenario 4: a pair outside the refresh window must never trigger a rotation")
}

// ------------------------------------------------------------ Scenario 5
// B1: a refresh call that returns 400 (invalid_grant) is PERMANENT, never
// retried, and its Keychain items are actually deleted, not just refused in
// memory - so the account reads as "not connected" even after a relaunch.

func runDeadGrantScenario() async {
    let account = scratchAccount("dead-grant")
    let old = pair(access: "OLD-AT-5", refresh: "OLD-RT-5", expiresIn: 60)
    do { try await seed(account: account, tokens: old) } catch {
        failures.append("scenario 5: seeding failed: \(error)")
        return
    }

    let refreshCallCount = CountBox()
    let store = PulseOAuthStore(refreshOverride: { _ in
        refreshCallCount.increment()
        throw ProviderFetchError.http(status: 400)
    })

    _ = await store.credentials(forAccountUUID: account)
    let deadAfterFirstCall = await !store.hasGrant(forAccountUUID: account)
    check(deadAfterFirstCall, "scenario 5: hasGrant must report false once a 400 has been seen for this account")

    // Second call on the SAME store: must not call the refresh override
    // again (the account is already known dead), and must not resurrect a
    // pair from the Keychain either.
    let secondResult = await store.credentials(forAccountUUID: account)
    check(secondResult == nil, "scenario 5: a dead account must never hand out a pair again in the same run")
    checkEqual(refreshCallCount.value, 1, "scenario 5: a dead grant must not be retried - the refresh call must happen exactly once")

    // Durable half: both Keychain items must actually be gone, so a relaunch
    // (a brand new store instance) also reads "no grant", not "expired grant"
    // - the two read differently to a user (silent forever-retry vs a visible
    // Sign in prompt).
    let primaryAfter = await readItem(service: "de.byte.pulse.oauth", account: account)
    let pendingAfter = await readItem(service: "de.byte.pulse.oauth-pending", account: account)
    check(primaryAfter == nil, "scenario 5: the primary Keychain item must be deleted for a dead grant")
    check(pendingAfter == nil, "scenario 5: the pending Keychain item must be deleted for a dead grant")

    let freshStore = PulseOAuthStore()
    let afterRelaunch = await freshStore.hasGrant(forAccountUUID: account)
    check(!afterRelaunch, "scenario 5: a fresh store after 'relaunch' must also read no grant for a dead account")
}

/// A locked counter, since the refresh override runs off-actor and Swift 6
/// won't let a plain closure mutate a captured `var` across that boundary.
final class CountBox: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

/// A locked bool, since the refresh override runs off-actor and Swift 6
/// won't let a plain closure mutate a captured `var` across that boundary.
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

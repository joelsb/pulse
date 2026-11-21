import Foundation
import Testing
@testable import Pulse

// JSB-112: a second Codex account beside the first. Every test runs on an
// in-memory secret store, a throwaway UserDefaults suite and stubbed usage
// responses - no Keychain, no network, no live credentials.

private func base64URL(_ string: String) -> String {
    Data(string.utf8).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

/// A fake access token carrying only the profile email claim `accountLabel` reads.
private func accessToken(email: String, nonce: String = "1") -> String {
    let payload = #"{"https://api.openai.com/profile":{"email":"\#(email)"},"n":"\#(nonce)"}"#
    return "\(base64URL(#"{"alg":"none"}"#)).\(base64URL(payload)).sig"
}

/// A fake id_token carrying only the `chatgpt_account_id` claim.
private func idToken(accountID: String) -> String {
    let payload = #"{"https://api.openai.com/auth":{"chatgpt_account_id":"\#(accountID)"}}"#
    return "\(base64URL(#"{"alg":"none"}"#)).\(base64URL(payload)).sig"
}

private func usage(session: Double, weekly: Double) -> CodexUsageResponse {
    try! JSONDecoder().decode(CodexUsageResponse.self, from: Data(#"""
    {"plan_type":"plus","rate_limit":{
      "primary_window":{"limit_window_seconds":18000,"used_percent":\#(session),"reset_after_seconds":3600},
      "secondary_window":{"limit_window_seconds":604800,"used_percent":\#(weekly),"reset_after_seconds":86400}}}
    """#.utf8))
}

/// In-memory stand-in for the Keychain, keyed exactly like it: (service, account).
actor InMemorySecretStore: CodexSecretStore {
    private(set) var items: [String: String] = [:]
    private(set) var writes = 0

    private func key(_ service: String, _ account: String) -> String { "\(service)|\(account)" }

    func read(service: String, account: String) async throws -> String {
        guard let value = items[key(service, account)] else {
            throw ProviderFetchError.notLoggedIn(hint: "missing")
        }
        return value
    }

    func write(service: String, account: String, secret: String) async throws {
        writes += 1
        items[key(service, account)] = secret
    }

    func delete(service: String, account: String) async throws {
        items[key(service, account)] = nil
    }

    func snapshot() -> [String: String] { items }
}

private struct Fixture {
    let suite = "pulse-tests-codex-accounts-\(UUID().uuidString)"
    let defaults: UserDefaults
    let secrets = InMemorySecretStore()
    let empty = URL.temporaryDirectory.appendingPathComponent("pulse-codex-none-\(UUID().uuidString)")

    init() { defaults = UserDefaults(suiteName: suite)! }

    func cleanUp() {
        defaults.removePersistentDomain(forName: suite)
    }

    /// Responses keyed by access token: the stub answers ONLY the account a
    /// token belongs to, so a row showing another account's numbers fails.
    static func fetcher(_ responses: [String: CodexUsageResponse]) -> @Sendable (CodexAuth) async throws -> CodexUsageResponse {
        { auth in
            guard let response = responses[auth.accessToken] else { throw ProviderFetchError.unauthorized }
            return response
        }
    }

    func primaryStore(fetcher: @escaping @Sendable (CodexAuth) async throws -> CodexUsageResponse) -> CodexOAuthStore {
        CodexOAuthStore(verifyOverride: { (try? await fetcher(CodexAuth(accessToken: $0.accessToken, accountID: $0.accountID))) != nil }, secrets: secrets)
    }

    func accounts(
        primary: CodexOAuthStore,
        fetcher: @escaping @Sendable (CodexAuth) async throws -> CodexUsageResponse,
        refreshOverride: (@Sendable (String) async throws -> CodexOAuthClient.TokenPair)? = nil
    ) -> CodexAccounts {
        CodexAccounts(
            index: CodexAccountIndex(defaults: defaults),
            secrets: secrets,
            primaryAccountIDs: { [primary] in
                Set([await primary.storedAccountID()].compactMap { $0 })
            },
            fetchUsage: fetcher,
            refreshOverride: refreshOverride
        )
    }

    func provider(primary: CodexOAuthStore, accounts: CodexAccounts, fetcher: @escaping @Sendable (CodexAuth) async throws -> CodexUsageResponse) -> CodexProvider {
        CodexProvider(
            authFileURL: empty.appendingPathComponent("auth.json"),
            jcodeStore: JcodeOpenAICredentialsStore(authFile: empty.appendingPathComponent("jcode.json")),
            piAuthFileURL: empty.appendingPathComponent("pi.json"),
            codexOAuthStore: primary,
            parser: CodexSessionParser(sessionsRoot: empty, cacheName: "pulse-test-\(UUID().uuidString)"),
            accounts: accounts,
            usageFetcher: fetcher
        )
    }
}

private let tokenA = accessToken(email: "alice@example.com")
private let tokenB = accessToken(email: "bob@example.com")
private let farFuture = Date(timeIntervalSinceNow: 30 * 86400)

private func pair(_ access: String, accountID: String, refresh: String = "RT") -> CodexOAuthClient.TokenPair {
    CodexOAuthClient.TokenPair(accessToken: access, refreshToken: refresh, idToken: idToken(accountID: accountID), expiresAt: farFuture)
}

@Suite("Codex multiple accounts (JSB-112)")
struct CodexMultiAccountTests {
    /// Tracer bullet: add B through the sign-in seam with A already stored,
    /// then the provider shows one labeled session+weekly row per account,
    /// each carrying ITS OWN response's numbers, and the UI renders them.
    @Test func addSecondAccountShowsOneRowPerAccount() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let fetcher = Fixture.fetcher([tokenA: usage(session: 10, weekly: 20), tokenB: usage(session: 40, weekly: 70)])
        let primary = fixture.primaryStore(fetcher: fetcher)
        try await primary.adopt(CodexOAuthStore.Credentials(accessToken: tokenA, refreshToken: "RT-A", expiresAt: farFuture, accountID: "acct-A"))
        let accounts = fixture.accounts(primary: primary, fetcher: fetcher)

        let outcome = try await accounts.add(signIn: { pair(tokenB, accountID: "acct-B", refresh: "RT-B") })
        #expect(outcome == .added(label: "bo…@example.com"))

        let snapshot = try await fixture.provider(primary: primary, accounts: accounts, fetcher: fetcher).fetch()
        #expect(snapshot.accountUsages.map(\.label) == ["al…@example.com", "bo…@example.com"])
        #expect(snapshot.accountUsages.map { $0.session?.utilization } == [10, 40])
        #expect(snapshot.accountUsages.map { $0.weekly?.utilization } == [20, 70])
        // The big cards still describe the first account.
        #expect(snapshot.primary?.utilization == 10)

        let rowB = snapshot.accountUsages[1]
        #expect(AccountUsageCard.valueText(rowB.session, direction: .used) == "40%")
        #expect(AccountUsageCard.valueText(rowB.weekly, direction: .remaining) == "30%")
        #expect(AccountUsageCard.valueText(nil, direction: .used) == "–")
    }

    private func seeded() async throws -> (Fixture, CodexOAuthStore, CodexAccounts, [String: String]) {
        let fixture = Fixture()
        let fetcher = Fixture.fetcher([tokenA: usage(session: 10, weekly: 20), tokenB: usage(session: 40, weekly: 70)])
        let primary = fixture.primaryStore(fetcher: fetcher)
        try await primary.adopt(CodexOAuthStore.Credentials(accessToken: tokenA, refreshToken: "RT-A", expiresAt: farFuture, accountID: "acct-A"))
        let before = await fixture.secrets.snapshot()
        return (fixture, primary, fixture.accounts(primary: primary, fetcher: fetcher), before)
    }

    @Test func cancelledSignInChangesNothing() async throws {
        let (fixture, _, accounts, before) = try await seeded()
        defer { fixture.cleanUp() }
        await #expect(throws: CancellationError.self) {
            try await accounts.add(signIn: { throw CancellationError() })
        }
        #expect(await fixture.secrets.snapshot() == before)
        #expect(await accounts.entries() == [])
    }

    @Test func signingInTheFirstAccountAgainIsADuplicateAndChangesNothing() async throws {
        let (fixture, _, accounts, before) = try await seeded()
        defer { fixture.cleanUp() }
        let outcome = try await accounts.add(signIn: { pair(accessToken(email: "alice@example.com", nonce: "2"), accountID: "acct-A") })
        #expect(outcome == .duplicate(label: "al…@example.com"))
        #expect(await fixture.secrets.snapshot() == before)
        #expect(await accounts.entries() == [])
    }

    @Test func addingTheSameExtraAccountTwiceIsADuplicate() async throws {
        let (fixture, _, accounts, _) = try await seeded()
        defer { fixture.cleanUp() }
        _ = try await accounts.add(signIn: { pair(tokenB, accountID: "acct-B") })
        let afterFirst = await fixture.secrets.snapshot()
        let outcome = try await accounts.add(signIn: { pair(accessToken(email: "bob@example.com", nonce: "2"), accountID: "acct-B") })
        #expect(outcome == .duplicate(label: "bo…@example.com"))
        #expect(await fixture.secrets.snapshot() == afterFirst)
        #expect(await accounts.entries().count == 1)
    }

    @Test func unidentifiedAccountIsRejectedBeforeAnyWrite() async throws {
        let (fixture, _, accounts, before) = try await seeded()
        defer { fixture.cleanUp() }
        let noClaim = CodexOAuthClient.TokenPair(accessToken: tokenB, refreshToken: "RT", idToken: "x.e30.sig", expiresAt: farFuture)
        await #expect(throws: CodexAccounts.AddFailure.unidentified) {
            try await accounts.add(signIn: { noClaim })
        }
        #expect(await fixture.secrets.snapshot() == before)
        #expect(await accounts.entries() == [])
    }

    @Test func accountWhoseUsageCannotBeReadIsNotSaved() async throws {
        let (fixture, _, accounts, before) = try await seeded()
        defer { fixture.cleanUp() }
        let unknownToken = accessToken(email: "carol@example.com")
        await #expect(throws: CodexAccounts.AddFailure.usageCheckFailed) {
            try await accounts.add(signIn: { pair(unknownToken, accountID: "acct-C") })
        }
        #expect(await fixture.secrets.snapshot() == before)
        #expect(await accounts.entries() == [])
    }

    @Test func addingKeepsTheExistingSlotByteForByte() async throws {
        let (fixture, _, accounts, before) = try await seeded()
        defer { fixture.cleanUp() }
        _ = try await accounts.add(signIn: { pair(tokenB, accountID: "acct-B") })
        let after = await fixture.secrets.snapshot()
        let primaryKeys = before.keys.filter { $0.hasSuffix("|codex-primary") }
        #expect(primaryKeys.count == 2) // pending + promoted
        for key in primaryKeys { #expect(after[key] == before[key]) }
        let slot = CodexAccounts.slot(forAccountID: "acct-B")
        #expect(slot.count == "codex-primary".count)
        #expect(after.keys.contains("de.byte.pulse.codex-oauth|\(slot)"))
    }

    @Test func bothAccountsSurviveARelaunchWithoutSigningIn() async throws {
        let (fixture, primary, accounts, _) = try await seeded()
        defer { fixture.cleanUp() }
        _ = try await accounts.add(signIn: { pair(tokenB, accountID: "acct-B") })

        // Relaunch: brand-new store, index and provider objects over the same
        // persisted defaults and secrets. No sign-in closure is ever called.
        let fetcher = Fixture.fetcher([tokenA: usage(session: 11, weekly: 21), tokenB: usage(session: 41, weekly: 71)])
        _ = primary
        let relaunchedPrimary = fixture.primaryStore(fetcher: fetcher)
        let relaunchedAccounts = fixture.accounts(primary: relaunchedPrimary, fetcher: fetcher)
        let snapshot = try await fixture.provider(primary: relaunchedPrimary, accounts: relaunchedAccounts, fetcher: fetcher).fetch()
        #expect(snapshot.accountUsages.map(\.label) == ["al…@example.com", "bo…@example.com"])
        #expect(snapshot.accountUsages.map { $0.session?.utilization } == [11, 41])
        #expect(snapshot.accountUsages.map { $0.weekly?.utilization } == [21, 71])
    }

    @Test func extraAccountRotatesInItsOwnSlotOnly() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let rotatedB = accessToken(email: "bob@example.com", nonce: "rotated")
        let fetcher = Fixture.fetcher([tokenA: usage(session: 10, weekly: 20), tokenB: usage(session: 40, weekly: 70), rotatedB: usage(session: 45, weekly: 75)])
        let primary = fixture.primaryStore(fetcher: fetcher)
        try await primary.adopt(CodexOAuthStore.Credentials(accessToken: tokenA, refreshToken: "RT-A", expiresAt: farFuture, accountID: "acct-A"))
        let refreshed = RefreshLog()
        let accounts = fixture.accounts(primary: primary, fetcher: fetcher, refreshOverride: { refreshToken in
            await refreshed.append(refreshToken)
            return CodexOAuthClient.TokenPair(accessToken: rotatedB, refreshToken: "RT-B2", idToken: "", expiresAt: farFuture)
        })
        // B's grant is two minutes from expiry, so the next read must rotate it.
        let nearlyExpired = CodexOAuthClient.TokenPair(accessToken: tokenB, refreshToken: "RT-B", idToken: idToken(accountID: "acct-B"), expiresAt: Date(timeIntervalSinceNow: 120))
        _ = try await accounts.add(signIn: { nearlyExpired })
        let primaryBefore = await fixture.secrets.snapshot().filter { $0.key.hasSuffix("|codex-primary") }

        let rows = await accounts.usages()
        #expect(rows.map { $0.session?.utilization } == [45])
        #expect(await refreshed.tokens == ["RT-B"])
        let stored = try CodexOAuthStore.decode(await fixture.secrets.read(service: "de.byte.pulse.codex-oauth", account: CodexAccounts.slot(forAccountID: "acct-B")))
        #expect(stored.refreshToken == "RT-B2")
        #expect(stored.accountID == "acct-B")
        #expect(await fixture.secrets.snapshot().filter { $0.key.hasSuffix("|codex-primary") } == primaryBefore)
    }

    @Test func extraAccountWithoutAGrantSaysSignInAgain() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        CodexAccountIndex(defaults: fixture.defaults).save([CodexAccountEntry(slot: "codex-0000000", accountID: "acct-Z", label: "zz…@example.com")])
        let accounts = fixture.accounts(primary: fixture.primaryStore(fetcher: Fixture.fetcher([:])), fetcher: Fixture.fetcher([:]))
        let rows = await accounts.usages()
        #expect(rows == [AccountUsage(id: "codex-0000000", label: "zz…@example.com", note: "Sign in again from Settings")])
    }
}

private actor RefreshLog {
    private(set) var tokens: [String] = []
    func append(_ token: String) { tokens.append(token) }
}

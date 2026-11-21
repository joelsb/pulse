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

    func exists(service: String, account: String) async throws -> Bool {
        items[key(service, account)] != nil
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

    /// A different account already owns B's derived slot (a 28-bit digest
    /// collision, planted here): B must land elsewhere and the owner's grant
    /// must stay byte for byte.
    @Test func slotCollisionWithAnotherAccountNeverOverwritesItsGrant() async throws {
        let (fixture, _, accounts, _) = try await seeded()
        defer { fixture.cleanUp() }
        let collided = CodexAccounts.slot(forAccountID: "acct-B")
        let owner = CodexOAuthStore.Credentials(accessToken: "AT-OWNER", refreshToken: "RT-OWNER", expiresAt: farFuture, accountID: "acct-OWNER")
        try await fixture.secrets.write(service: "de.byte.pulse.codex-oauth", account: collided, secret: CodexOAuthStore.encode(owner))
        CodexAccountIndex(defaults: fixture.defaults).save([CodexAccountEntry(slot: collided, accountID: "acct-OWNER", label: "ow…@example.com")])
        let ownerSecret = await fixture.secrets.snapshot()["de.byte.pulse.codex-oauth|\(collided)"]

        #expect(try await accounts.add(signIn: { pair(tokenB, accountID: "acct-B") }) == .added(label: "bo…@example.com"))

        #expect(await fixture.secrets.snapshot()["de.byte.pulse.codex-oauth|\(collided)"] == ownerSecret)
        let entries = await accounts.entries()
        #expect(entries.map(\.accountID) == ["acct-OWNER", "acct-B"])
        let bSlot = try #require(entries.last?.slot)
        #expect(bSlot != collided)
        #expect(bSlot != "codex-primary")
        #expect(bSlot.count == "codex-primary".count)
        let storedB = try CodexOAuthStore.decode(await fixture.secrets.read(service: "de.byte.pulse.codex-oauth", account: bSlot))
        #expect(storedB.accountID == "acct-B")
    }

    /// An orphaned Keychain item (no index entry) in the derived slot is not
    /// Pulse's to overwrite either.
    @Test func orphanedItemInTheDerivedSlotIsNotOverwritten() async throws {
        let (fixture, _, accounts, _) = try await seeded()
        defer { fixture.cleanUp() }
        let derived = CodexAccounts.slot(forAccountID: "acct-B")
        try await fixture.secrets.write(service: "de.byte.pulse.codex-oauth-pending", account: derived, secret: "orphan")

        _ = try await accounts.add(signIn: { pair(tokenB, accountID: "acct-B") })

        #expect(await fixture.secrets.snapshot()["de.byte.pulse.codex-oauth-pending|\(derived)"] == "orphan")
        #expect(await accounts.entries().map(\.slot) != [derived])
    }

    /// Two adds of the same account interleaving across the actor's
    /// suspension points (usage check) must save it once.
    @Test func concurrentAddsOfTheSameAccountSaveItOnce() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let fast = Fixture.fetcher([tokenA: usage(session: 10, weekly: 20), tokenB: usage(session: 40, weekly: 70)])
        let slow: @Sendable (CodexAuth) async throws -> CodexUsageResponse = { auth in
            try await Task.sleep(for: .milliseconds(100))
            return try await fast(auth)
        }
        let primary = fixture.primaryStore(fetcher: fast)
        try await primary.adopt(CodexOAuthStore.Credentials(accessToken: tokenA, refreshToken: "RT-A", expiresAt: farFuture, accountID: "acct-A"))
        let accounts = fixture.accounts(primary: primary, fetcher: slow)

        async let first = accounts.add(signIn: { pair(tokenB, accountID: "acct-B", refresh: "RT-B1") })
        async let second = accounts.add(signIn: { pair(tokenB, accountID: "acct-B", refresh: "RT-B2") })
        let outcomes = try await [first, second]

        #expect(outcomes.filter { $0 == .added(label: "bo…@example.com") }.count == 1)
        #expect(outcomes.filter { $0 == .duplicate(label: "bo…@example.com") }.count == 1)
        #expect(await accounts.entries().map(\.accountID) == ["acct-B"])
    }

    /// A dead grant clears its Keychain items but keeps its index entry; its
    /// slot still belongs to that account and must not be handed to another.
    @Test func indexedSlotWithoutKeychainItemIsStillTaken() async throws {
        let (fixture, _, accounts, _) = try await seeded()
        defer { fixture.cleanUp() }
        let collided = CodexAccounts.slot(forAccountID: "acct-B")
        CodexAccountIndex(defaults: fixture.defaults).save([CodexAccountEntry(slot: collided, accountID: "acct-OWNER", label: nil)])

        _ = try await accounts.add(signIn: { pair(tokenB, accountID: "acct-B") })

        let entries = await accounts.entries()
        #expect(entries.map(\.accountID) == ["acct-OWNER", "acct-B"])
        #expect(entries.last?.slot != collided)
    }

    /// Another writer (a second Pulse instance) indexes the same account while
    /// this add waits on the usage check: the add must back off.
    @Test func accountIndexedDuringVerificationIsADuplicate() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let otherInstance = CodexAccountIndex(defaults: fixture.defaults)
        let fetcher: @Sendable (CodexAuth) async throws -> CodexUsageResponse = { _ in
            otherInstance.save([CodexAccountEntry(slot: "codex-elsewh", accountID: "acct-B", label: nil)])
            return usage(session: 40, weekly: 70)
        }
        let accounts = CodexAccounts(index: CodexAccountIndex(defaults: fixture.defaults), secrets: fixture.secrets, primaryAccountIDs: { [] }, fetchUsage: fetcher)

        #expect(try await accounts.add(signIn: { pair(tokenB, accountID: "acct-B") }) == .duplicate(label: "bo…@example.com"))
        #expect(await fixture.secrets.snapshot().isEmpty)
        #expect(await accounts.entries().count == 1)
    }

    /// When the Keychain cannot say whether a slot is free, the add aborts.
    @Test func unanswerableSlotCheckAbortsWithoutWriting() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let blind = BlindExistsStore(inner: fixture.secrets)
        let accounts = CodexAccounts(
            index: CodexAccountIndex(defaults: fixture.defaults),
            secrets: blind,
            primaryAccountIDs: { [] },
            fetchUsage: Fixture.fetcher([tokenB: usage(session: 40, weekly: 70)])
        )
        await #expect(throws: CodexAccounts.AddFailure.slotCheckFailed) {
            try await accounts.add(signIn: { pair(tokenB, accountID: "acct-B") })
        }
        #expect(await fixture.secrets.snapshot().isEmpty)
        #expect(await accounts.entries() == [])
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

/// Answers reads and writes, but can never say whether an item exists -
/// the Keychain's "timed out / access denied" case.
private struct BlindExistsStore: CodexSecretStore {
    let inner: InMemorySecretStore
    func read(service: String, account: String) async throws -> String { try await inner.read(service: service, account: account) }
    func write(service: String, account: String, secret: String) async throws { try await inner.write(service: service, account: account, secret: secret) }
    func delete(service: String, account: String) async throws { try await inner.delete(service: service, account: account) }
    func exists(service: String, account: String) async throws -> Bool { throw KeychainReader.Failure.accessDeniedOrTimeout }
}

// MARK: - Menu bar parity with Claude accounts

@Suite("Codex extra accounts in the menu bar (JSB-112)")
@MainActor
struct CodexAccountMenuBarTests {
    /// Tracer: an indexed extra account becomes its own provider exactly like
    /// a discovered Claude account - its own id spliced after Codex, its own
    /// short code, its own figures, and a menu bar slot by default.
    @Test func extraCodexAccountIsItsOwnMenuBarProvider() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let slot = CodexAccounts.slot(forAccountID: "acct-B")
        let entry = CodexAccountEntry(slot: slot, accountID: "acct-B", label: "bo…@example.com")
        CodexAccountIndex(defaults: fixture.defaults).save([entry])
        let credentials = CodexOAuthStore.Credentials(accessToken: tokenB, refreshToken: "RT-B", expiresAt: farFuture, accountID: "acct-B")
        try await fixture.secrets.write(service: "de.byte.pulse.codex-oauth", account: slot, secret: CodexOAuthStore.encode(credentials))
        let fetcher = Fixture.fetcher([tokenA: usage(session: 10, weekly: 20), tokenB: usage(session: 40, weekly: 70)])
        let accounts = fixture.accounts(primary: fixture.primaryStore(fetcher: fetcher), fetcher: fetcher)

        let id = ProviderID.codexAccount(slot: slot)
        #expect(id.rawValue == "codexAccount.\(slot)")
        #expect(id.isCodexAccount)
        #expect(!id.isClaudeAccount)
        #expect(ProviderRegistry.ordered(claudeAccounts: [.claudeAccount(suffix: "work")], codexAccounts: [id]) == [
            .claude, .claudeAccount(suffix: "work"), .codex, id, .cursor, .copilot, .gemini,
        ])

        let providers = CodexAccountProvider.make(entries: CodexAccountIndex(defaults: fixture.defaults).load(), accounts: accounts)
        #expect(providers.map(\.id) == [id])
        let provider = try #require(providers.first)
        #expect(provider.descriptor.shortCode == "CD2")
        #expect(provider.descriptor.name == "Codex bo…@example.com")
        #expect(await provider.probeConnection() == .available)
        let snapshot = try await provider.fetch()
        #expect(snapshot.providerID == id)
        #expect(snapshot.primary?.utilization == 40)
        #expect(snapshot.secondary?.utilization == 70)
        #expect(snapshot.accountLabel == "bo…@example.com")

        // Settings: an account Joel added himself gets a menu bar slot, unlike
        // a discovered Claude directory (which starts off).
        let suite = "pulse-tests-settings-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(ProviderID.builtIns.map(\.rawValue), forKey: "knownProviders")
        let registry = ProviderRegistry()
        registry.register(claudeAccounts: [], codexAccounts: [id])
        let settings = SettingsStore(defaults: defaults, providers: registry.all)
        #expect(settings.visibleMenuBarProviders.contains(id))
        #expect(ProviderGlanceCard.windows(for: { var s = UsageSnapshot(providerID: id); s.secondary = snapshot.secondary; return s }()).ring == nil)
    }

    /// The account's own provider and the Codex tab's Accounts card read the
    /// same account in one refresh: one usage request, not two. A provider
    /// without a grant reads as not connected, never as another account.
    @Test func menuBarProviderAndAccountsCardShareOneRequest() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let slot = "codex-1111111"
        CodexAccountIndex(defaults: fixture.defaults).save([
            CodexAccountEntry(slot: slot, accountID: "acct-B", label: "bo…@example.com"),
            CodexAccountEntry(slot: "codex-2222222", accountID: "acct-C", label: "ca…@example.com"),
        ])
        try await fixture.secrets.write(service: "de.byte.pulse.codex-oauth", account: slot, secret: CodexOAuthStore.encode(
            CodexOAuthStore.Credentials(accessToken: tokenB, refreshToken: "RT-B", expiresAt: farFuture, accountID: "acct-B")))
        let calls = RefreshLog()
        let inner = Fixture.fetcher([tokenB: usage(session: 40, weekly: 70)])
        let counting: @Sendable (CodexAuth) async throws -> CodexUsageResponse = { auth in
            await calls.append(auth.accessToken)
            return try await inner(auth)
        }
        let accounts = fixture.accounts(primary: fixture.primaryStore(fetcher: inner), fetcher: counting)
        let providers = CodexAccountProvider.make(entries: CodexAccountIndex(defaults: fixture.defaults).load(), accounts: accounts)

        #expect(try await providers[0].fetch().primary?.utilization == 40)
        let rows = await accounts.usages()
        #expect(rows.map { $0.session?.utilization } == [40, nil])
        #expect(await calls.tokens == [tokenB])

        #expect(await providers[1].probeConnection() == .notConnected(hint: "Sign in again from Settings"))
        await #expect(throws: ProviderFetchError.notLoggedIn(hint: "Sign in again from Settings")) {
            try await providers[1].fetch()
        }
    }

    /// Like a Claude account, an extra Codex account has its own stable accent
    /// so its tab dot is told apart from the main Codex one.
    @Test func extraCodexAccountHasItsOwnStableAccent() {
        let id = ProviderID.codexAccount(slot: "codex-1111111")
        #expect(PulseColor.accent(id) != PulseColor.accent(.codex))
        #expect(PulseColor.accent(id) == PulseColor.accent(.codexAccount(slot: "codex-1111111")))
        // Two extra accounts never share the fallback colour.
        #expect(PulseColor.accent(id) != PulseColor.accent(.codexAccount(slot: "codex-2222222")))
    }

    /// Launch wiring: the factory builds one provider per indexed account,
    /// right after Codex, and registers their ids so tabs and menu bar see them.
    @Test func factoryBuildsAndRegistersOneProviderPerIndexedAccount() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let entries = [
            CodexAccountEntry(slot: "codex-1111111", accountID: "acct-B", label: "bo…@example.com"),
            CodexAccountEntry(slot: "codex-2222222", accountID: "acct-C", label: nil),
        ]
        let fetcher = Fixture.fetcher([:])
        let accounts = fixture.accounts(primary: fixture.primaryStore(fetcher: fetcher), fetcher: fetcher)
        let registry = ProviderRegistry()

        let providers = ProviderFactory.makeAll(codexAccounts: accounts, codexAccountEntries: entries, registry: registry)
        let ids = providers.map(\.id)
        let b = ProviderID.codexAccount(slot: "codex-1111111"), c = ProviderID.codexAccount(slot: "codex-2222222")
        let codexIndex = try #require(ids.firstIndex(of: .codex))
        #expect(Array(ids[codexIndex...].prefix(3)) == [.codex, b, c])
        #expect(providers.first { $0.id == c }?.descriptor.shortCode == "CD3")
        #expect(providers.first { $0.id == c }?.descriptor.name == "Codex 3")
        #expect(registry.all.filter(\.isCodexAccount) == [b, c])
    }
}

private actor RefreshLog {
    private(set) var tokens: [String] = []
    func append(_ token: String) { tokens.append(token) }
}

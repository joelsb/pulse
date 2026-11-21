import Foundation
import Testing
@testable import Pulse

// JSB-112 Connected Accounts: several Pulse-owned Claude grants, one per
// Anthropic account uuid, managed from Settings instead of `~/.claude-*`
// directories. In-memory secrets, a throwaway UserDefaults suite and stubbed
// usage only - no Keychain, no network, no live credentials.

private func claudeUsage(session: Double, weekly: Double) -> ClaudeUsageResponse {
    try! ClaudeUsageResponse.parse(Data(#"""
    {"five_hour":{"utilization":\#(session),"resets_at":"2030-01-01T00:00:00+00:00"},
     "seven_day":{"utilization":\#(weekly),"resets_at":"2030-01-05T00:00:00+00:00"}}
    """#.utf8))
}

private let farFuture = Date(timeIntervalSinceNow: 30 * 86400)

private func authorization(_ token: String, uuid: String, email: String?) -> PulseOAuthStore.Authorization {
    PulseOAuthStore.Authorization(
        credentials: PulseOAuthStore.Credentials(accessToken: token, refreshToken: "RT-\(token)", expiresAt: farFuture, grantedScope: "user:profile"),
        profile: ClaudeOAuthClient.Profile(uuid: uuid, email: email)
    )
}

private struct ClaudeFixture {
    let suite = "pulse-tests-claude-accounts-\(UUID().uuidString)"
    let defaults: UserDefaults
    let secrets = InMemorySecretStore()
    let store: PulseOAuthStore
    let responses: [String: ClaudeUsageResponse]

    init(responses: [String: ClaudeUsageResponse] = ["AT-A": claudeUsage(session: 10, weekly: 20), "AT-B": claudeUsage(session: 40, weekly: 70)]) {
        defaults = UserDefaults(suiteName: suite)!
        self.responses = responses
        let fetch = Self.fetcher(responses)
        store = PulseOAuthStore(verifyOverride: { (try? await fetch($0)) != nil }, secrets: secrets)
    }

    func cleanUp() { defaults.removePersistentDomain(forName: suite) }

    static func fetcher(_ responses: [String: ClaudeUsageResponse]) -> @Sendable (String) async throws -> ClaudeUsageResponse {
        { token in
            guard let response = responses[token] else { throw ProviderFetchError.unauthorized }
            return response
        }
    }

    func accounts(primary: Set<String> = ["uuid-primary"], store: PulseOAuthStore? = nil) -> ClaudeAccounts {
        ClaudeAccounts(
            index: ClaudeAccountIndex(defaults: defaults),
            store: store ?? self.store,
            primaryAccountUUIDs: { primary },
            fetchUsage: Self.fetcher(responses)
        )
    }

    func items() async -> [String: String] { await secrets.snapshot() }
}

@Suite("Claude connected accounts (JSB-112)")
struct ClaudeConnectedAccountsTests {
    /// Tracer: sign in B through the seam, then B is its own provider with
    /// its own id, short code, and its own figures read with its own grant.
    @Test func addedAccountIsItsOwnProviderWithItsOwnFigures() async throws {
        let fixture = ClaudeFixture()
        defer { fixture.cleanUp() }
        let accounts = fixture.accounts()

        let outcome = try await accounts.add(authorize: { authorization("AT-B", uuid: "uuid-b", email: "bob@example.com") })
        #expect(outcome == .added(label: "bo…@example.com"))
        #expect(await accounts.entries() == [ClaudeAccountEntry(uuid: "uuid-b", label: "bo…@example.com")])

        let providers = ClaudeConnectedProvider.make(entries: await accounts.entries(), accounts: accounts)
        let provider = try #require(providers.first)
        #expect(provider.id == ProviderID.claudeConnected(uuid: "uuid-b"))
        #expect(provider.id.isClaudeConnected)
        #expect(provider.descriptor.name == "Claude bo…@example.com")
        #expect(provider.descriptor.shortCode == "CL2")
        let snapshot = try await provider.fetch()
        #expect(snapshot.primary?.utilization == 40)
        #expect(snapshot.secondary?.utilization == 70)
        #expect(snapshot.accountLabel == "bo…@example.com")
    }

    @Test func signingInTheMacsOwnClaudeAccountIsADuplicateAndWritesNothing() async throws {
        let fixture = ClaudeFixture()
        defer { fixture.cleanUp() }
        let accounts = fixture.accounts(primary: ["uuid-a"])
        let outcome = try await accounts.add(authorize: { authorization("AT-A", uuid: "uuid-a", email: "alice@example.com") })
        #expect(outcome == .duplicate(label: "al…@example.com"))
        #expect(await fixture.items().isEmpty)
        #expect(await accounts.entries().isEmpty)
    }

    @Test func addingTheSameAccountTwiceKeepsTheFirstGrant() async throws {
        let fixture = ClaudeFixture()
        defer { fixture.cleanUp() }
        let accounts = fixture.accounts()
        _ = try await accounts.add(authorize: { authorization("AT-B", uuid: "uuid-b", email: "bob@example.com") })
        let before = await fixture.items()
        let outcome = try await accounts.add(authorize: { authorization("AT-B2", uuid: "uuid-b", email: "bob@example.com") })
        #expect(outcome == .duplicate(label: "bo…@example.com"))
        #expect(await fixture.items() == before)
    }

    @Test func cancelledOrUnverifiableSignInWritesNothing() async throws {
        let fixture = ClaudeFixture()
        defer { fixture.cleanUp() }
        let accounts = fixture.accounts()
        await #expect(throws: CancellationError.self) {
            try await accounts.add(authorize: { throw CancellationError() })
        }
        await #expect(throws: ClaudeAccounts.Failure.usageCheckFailed) {
            try await accounts.add(authorize: { authorization("AT-UNKNOWN", uuid: "uuid-c", email: nil) })
        }
        #expect(await fixture.items().isEmpty)
        #expect(await accounts.entries().isEmpty)
    }

    @Test func reconnectAsAnotherAccountChangesNothing() async throws {
        let fixture = ClaudeFixture()
        defer { fixture.cleanUp() }
        let accounts = fixture.accounts()
        _ = try await accounts.add(authorize: { authorization("AT-B", uuid: "uuid-b", email: "bob@example.com") })
        let before = await fixture.items()

        let wrong = try await accounts.reconnect(uuid: "uuid-b", authorize: { authorization("AT-A", uuid: "uuid-a", email: "alice@example.com") })
        #expect(wrong == .mismatch(label: "al…@example.com"))
        #expect(await fixture.items() == before)

        let right = try await accounts.reconnect(uuid: "uuid-b", authorize: { authorization("AT-B", uuid: "uuid-b", email: "bob@example.com") })
        #expect(right == .reconnected(label: "bo…@example.com"))
    }

    @Test func disconnectForgetsOnlyThatGrantAndRemoveNeedsDisconnectFirst() async throws {
        let fixture = ClaudeFixture()
        defer { fixture.cleanUp() }
        let accounts = fixture.accounts()
        // A grant Pulse holds for another account (the Mac's own) must survive.
        try await fixture.store.adopt(authorization("AT-A", uuid: "uuid-a", email: nil).credentials, accountUUID: "uuid-a")
        _ = try await accounts.add(authorize: { authorization("AT-B", uuid: "uuid-b", email: "bob@example.com") })

        await #expect(throws: ClaudeAccounts.Failure.stillConnected) { try await accounts.remove(uuid: "uuid-b") }

        await accounts.disconnect(uuid: "uuid-b")
        let items = await fixture.items()
        #expect(items.keys.sorted() == ["de.byte.pulse.oauth-pending|uuid-a", "de.byte.pulse.oauth|uuid-a"])
        #expect(await accounts.entries() == [ClaudeAccountEntry(uuid: "uuid-b", label: "bo…@example.com", disconnected: true)])
        let provider = try #require(ClaudeConnectedProvider.make(entries: await accounts.entries(), accounts: accounts).first)
        #expect(await provider.probeConnection() == .notConnected(hint: "Disconnected - reconnect it in Settings > Accounts"))

        try await accounts.remove(uuid: "uuid-b")
        #expect(await accounts.entries().isEmpty)
    }

    @Test func accountsSurviveARelaunchWithoutSigningIn() async throws {
        let fixture = ClaudeFixture()
        defer { fixture.cleanUp() }
        _ = try await fixture.accounts().add(authorize: { authorization("AT-B", uuid: "uuid-b", email: "bob@example.com") })

        // New store and index objects over the same persisted data.
        let relaunchedStore = PulseOAuthStore(verifyOverride: { _ in true }, secrets: fixture.secrets)
        let relaunched = fixture.accounts(store: relaunchedStore)
        let provider = try #require(ClaudeConnectedProvider.make(entries: await relaunched.entries(), accounts: relaunched).first)
        #expect(try await provider.fetch().primary?.utilization == 40)
    }
}

@Suite("Accounts panel and menu icon switches are independent (JSB-112)")
@MainActor
struct AccountVisibilityTests {
    @Test func menuIconShowsAnAccountHiddenFromThePanelAndBothKeepRefreshing() throws {
        let suite = "pulse-tests-visibility-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let b = ProviderID.claudeConnected(uuid: "uuid-b")
        let settings = SettingsStore(defaults: defaults, providers: [.claude, b, .codex])

        settings.enabledProviders = [.claude]      // Panel: only Claude has a tab
        settings.menuBarProviders = [b, .codex]    // Menu icon: B and Codex

        #expect(settings.visibleMenuBarProviders == [b, .codex])
        #expect(settings.refreshedProviders == [.claude, b, .codex])

        settings.menuBarProviders = []
        #expect(settings.visibleMenuBarProviders.isEmpty)
        #expect(settings.refreshedProviders == [.claude])
    }
}

@Suite("Accounts launch wiring (JSB-112)")
struct AccountsLaunchWiringTests {
    /// Accounts come from Settings > Accounts, never from `~/.claude-*`
    /// directories: even on a Mac that has some, only the Mac's own Claude
    /// login plus the connected accounts are registered.
    @Test func factoryRegistersConnectedClaudeAccountsAndNoDirectoryAccounts() async throws {
        let fixture = ClaudeFixture()
        defer { fixture.cleanUp() }
        let accounts = fixture.accounts()
        let entries = [ClaudeAccountEntry(uuid: "uuid-b", label: "bo…@example.com")]
        let registry = ProviderRegistry()

        let providers = ProviderFactory.makeAll(claudeAccounts: accounts, claudeAccountEntries: entries, registry: registry)

        let b = ProviderID.claudeConnected(uuid: "uuid-b")
        #expect(Array(providers.map(\.id).prefix(3)) == [.claude, b, .codex])
        #expect(registry.all.prefix(3) == [.claude, b, .codex])
        #expect(!registry.all.contains { $0.rawValue.hasPrefix(ProviderID.claudeAccountPrefix) })
        #expect(providers.first { $0.id == b }?.descriptor.shortCode == "CL2")
    }
}

@Suite("Settings > Accounts rows (JSB-112)")
struct AccountRowTests {
    @Test func eachGroupListsTheLocalLoginThenConnectedAccounts() {
        let b = ProviderID.claudeConnected(uuid: "uuid-b")
        let claude = [
            ClaudeAccountEntry(uuid: "uuid-b", label: "bo…@example.com"),
            ClaudeAccountEntry(uuid: "uuid-c", label: nil, disconnected: true),
        ]
        // uuid-c was added this session: no provider until the next launch.
        let rows = AccountRow.rows(family: .claude, registered: [.claude, b, .codex], claude: claude, codex: [])
        #expect(rows.map(\.name) == ["Claude", "Claude bo…@example.com", "Claude 3"])
        #expect(rows.map(\.code) == ["CLA", "CL2", "CL3"])
        #expect(rows.map(\.kind) == [.local, .connected(disconnected: false), .pendingRelaunch])
        #expect(rows[1].claudeUUID == "uuid-b")

        let codexSlot = ProviderID.codexAccount(slot: "codex-1111111")
        let codex = AccountRow.rows(family: .codex, registered: [.codex, codexSlot], claude: claude,
                                    codex: [CodexAccountEntry(slot: "codex-1111111", accountID: "x", label: nil, disconnected: true)])
        #expect(codex.map(\.kind) == [.local, .connected(disconnected: true)])
        #expect(codex[1].codexSlot == "codex-1111111")

        // Cursor, Copilot, Gemini: only the tool's own login, with a reason.
        #expect(AccountRow.rows(family: .cursor, registered: [.cursor], claude: claude, codex: []).map(\.kind) == [.local])
        for family in [ProviderID.cursor, .copilot, .gemini] {
            #expect(!AccountCapability.canAddAccounts(family))
            #expect(AccountCapability.unavailableReason(family)?.hasPrefix("One account only:") == true)
        }
        #expect(AccountCapability.canAddAccounts(.claude) && AccountCapability.unavailableReason(.claude) == nil)
    }

    @Test func connectedClaudeAccountsGetTheirOwnStableAccent() {
        let b = ProviderID.claudeConnected(uuid: "uuid-b")
        #expect(PulseColor.accent(b) == PulseColor.accent(.claudeConnected(uuid: "uuid-b")))
        #expect(PulseColor.accent(b) != PulseColor.accent(.claudeConnected(uuid: "uuid-zz")))
    }
}

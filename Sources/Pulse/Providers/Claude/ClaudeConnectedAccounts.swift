import Foundation

/// One Claude account connected from Settings > Accounts (JSB-112).
/// Non-secret: the Anthropic account uuid names the Keychain item that
/// `PulseOAuthStore` keeps for it; `label` is the masked email.
struct ClaudeAccountEntry: Codable, Equatable, Sendable {
    var uuid: String
    var label: String?
    /// Signed out by Disconnect: Pulse's grant is gone, the row stays until
    /// Remove or Reconnect.
    var disconnected = false
}

/// The persisted list of connected Claude accounts - what survives a relaunch.
struct ClaudeAccountIndex: @unchecked Sendable {
    static let key = "claudeConnectedAccounts"
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func load() -> [ClaudeAccountEntry] {
        guard let data = defaults.data(forKey: Self.key) else { return [] }
        return (try? JSONDecoder().decode([ClaudeAccountEntry].self, from: data)) ?? []
    }

    func save(_ entries: [ClaudeAccountEntry]) {
        defaults.set(try? JSONEncoder().encode(entries), forKey: Self.key)
    }
}

/// Claude accounts beside the Mac's own Claude Code login. Every grant lives
/// in `PulseOAuthStore` under its account uuid, so the uuid IS the identity:
/// the same account can never land in two places, and a different account
/// can never overwrite another's grant.
actor ClaudeAccounts {
    enum AddOutcome: Equatable, Sendable {
        case added(label: String?)
        /// Already tracked (the Mac's own login or a connected account): nothing written.
        case duplicate(label: String?)
    }

    enum ReconnectOutcome: Equatable, Sendable {
        case reconnected(label: String?)
        /// The browser signed in as a different account: nothing written.
        case mismatch(label: String?)
    }

    enum Failure: Error, Equatable {
        /// The new grant could not read its own usage: nothing written.
        case usageCheckFailed
        /// Remove is only offered once an account is disconnected.
        case stillConnected
    }

    static let disconnectedHint = "Disconnected - reconnect it in Settings > Accounts"

    private let index: ClaudeAccountIndex
    private let store: PulseOAuthStore
    private let primaryAccountUUIDs: @Sendable () async -> Set<String>
    private let fetchUsage: @Sendable (String) async throws -> ClaudeUsageResponse
    private var inFlight: Set<String> = []

    init(
        index: ClaudeAccountIndex = ClaudeAccountIndex(),
        store: PulseOAuthStore,
        primaryAccountUUIDs: @escaping @Sendable () async -> Set<String>,
        fetchUsage: @escaping @Sendable (String) async throws -> ClaudeUsageResponse = { try await ClaudeUsageAPI(http: HTTPClient()).fetchUsage(accessToken: $0) }
    ) {
        self.index = index
        self.store = store
        self.primaryAccountUUIDs = primaryAccountUUIDs
        self.fetchUsage = fetchUsage
    }

    func entries() -> [ClaudeAccountEntry] { index.load() }

    private static func label(_ profile: ClaudeOAuthClient.Profile) -> String? {
        profile.email.flatMap(CodexAuth.maskedEmail)
    }

    /// Browser sign-in, then duplicate and usage checks, and only then a write.
    func add(authorize: @Sendable () async throws -> PulseOAuthStore.Authorization) async throws -> AddOutcome {
        let authorization = try await authorize()
        try Task.checkCancellation()
        let uuid = authorization.profile.uuid
        let label = Self.label(authorization.profile)
        if inFlight.contains(uuid) || index.load().contains(where: { $0.uuid == uuid }) { return .duplicate(label: label) }
        inFlight.insert(uuid)
        defer { inFlight.remove(uuid) }
        if await primaryAccountUUIDs().contains(uuid) { return .duplicate(label: label) }

        guard (try? await fetchUsage(authorization.credentials.accessToken)) != nil else { throw Failure.usageCheckFailed }
        try Task.checkCancellation()
        if index.load().contains(where: { $0.uuid == uuid }) { return .duplicate(label: label) }

        try await store.adopt(authorization.credentials, accountUUID: uuid)
        index.save(index.load() + [ClaudeAccountEntry(uuid: uuid, label: label)])
        return .added(label: label)
    }

    /// Signs the same account in again; a sign-in that lands on any other
    /// account is refused without touching either grant.
    func reconnect(uuid: String, authorize: @Sendable () async throws -> PulseOAuthStore.Authorization) async throws -> ReconnectOutcome {
        let authorization = try await authorize()
        try Task.checkCancellation()
        let label = Self.label(authorization.profile)
        guard authorization.profile.uuid == uuid else { return .mismatch(label: label) }
        guard (try? await fetchUsage(authorization.credentials.accessToken)) != nil else { throw Failure.usageCheckFailed }
        try Task.checkCancellation()
        try await store.adopt(authorization.credentials, accountUUID: uuid)
        index.save(index.load().map { $0.uuid == uuid ? ClaudeAccountEntry(uuid: uuid, label: label ?? $0.label) : $0 })
        return .reconnected(label: label)
    }

    enum PrimaryOutcome: Equatable, Sendable {
        case signedIn(label: String?)
        /// The browser signed in as another account: nothing written.
        case mismatch(label: String?)
        /// No Claude Code account on this Mac to check against: refused
        /// before the browser opens (use Add account instead).
        case unknownPrimary
    }

    /// Pulse's own grant for the Mac's Claude Code account (the first row).
    /// Accepts only that account, so this button can never create a grant
    /// that no provider reads and no row manages.
    func signInPrimary(authorize: @Sendable () async throws -> PulseOAuthStore.Authorization) async throws -> PrimaryOutcome {
        let primary = await primaryAccountUUIDs()
        guard !primary.isEmpty else { return .unknownPrimary }
        let authorization = try await authorize()
        try Task.checkCancellation()
        let label = Self.label(authorization.profile)
        guard primary.contains(authorization.profile.uuid) else { return .mismatch(label: label) }
        guard (try? await fetchUsage(authorization.credentials.accessToken)) != nil else { throw Failure.usageCheckFailed }
        try Task.checkCancellation()
        try await store.adopt(authorization.credentials, accountUUID: authorization.profile.uuid)
        return .signedIn(label: label)
    }

    func primaryHasPulseGrant() async -> Bool {
        for uuid in await primaryAccountUUIDs() where await store.hasGrant(forAccountUUID: uuid) { return true }
        return false
    }

    /// Signs Pulse's own grant for the first account out; the row falls back
    /// to Claude Code's own login, which is never touched.
    func forgetPrimary() async {
        for uuid in await primaryAccountUUIDs() { await store.forget(accountUUID: uuid) }
    }

    /// Forgets Pulse's own grant for this account and keeps the row.
    func disconnect(uuid: String) async {
        await store.forget(accountUUID: uuid)
        index.save(index.load().map { var e = $0; if e.uuid == uuid { e.disconnected = true }; return e })
    }

    func remove(uuid: String) throws {
        let entries = index.load()
        guard let entry = entries.first(where: { $0.uuid == uuid }) else { return }
        guard entry.disconnected else { throw Failure.stillConnected }
        index.save(entries.filter { $0.uuid != uuid })
    }

    func isDisconnected(uuid: String) -> Bool {
        index.load().first { $0.uuid == uuid }?.disconnected ?? true
    }

    func usage(uuid: String) async throws -> ClaudeUsageResponse {
        guard !isDisconnected(uuid: uuid) else { throw ProviderFetchError.notLoggedIn(hint: Self.disconnectedHint) }
        guard let credentials = await store.credentials(forAccountUUID: uuid) else {
            throw ProviderFetchError.notLoggedIn(hint: "Sign-in expired - reconnect it in Settings > Accounts")
        }
        return try await fetchUsage(credentials.accessToken)
    }

    func hasGrant(uuid: String) async -> Bool {
        guard !isDisconnected(uuid: uuid) else { return false }
        return await store.hasGrant(forAccountUUID: uuid)
    }
}

/// One connected Claude account as its own provider: its own tab and menu
/// bar block, limits read with its own grant. No token history: local logs
/// belong to the Mac's Claude Code login, not to this account.
actor ClaudeConnectedProvider: UsageProvider {
    nonisolated let id: ProviderID
    nonisolated let descriptor: ProviderDescriptor
    private let uuid: String
    private let accounts: ClaudeAccounts

    init(entry: ClaudeAccountEntry, position: Int, accounts: ClaudeAccounts) {
        self.id = .claudeConnected(uuid: entry.uuid)
        self.uuid = entry.uuid
        self.accounts = accounts
        self.descriptor = ProviderDescriptor(
            id: .claudeConnected(uuid: entry.uuid),
            name: "Claude \(entry.label ?? String(position))",
            shortCode: "CL\(position)",
            appBundleID: "com.anthropic.claudefordesktop",
            webURL: URL(string: "https://claude.ai")!,
            setupHint: ClaudeAccounts.disconnectedHint
        )
    }

    /// Providers for the connected accounts in index order, numbered from 2
    /// (the Mac's own Claude login is the first account, `CLA`).
    static func make(entries: [ClaudeAccountEntry], accounts: ClaudeAccounts) -> [ClaudeConnectedProvider] {
        entries.enumerated().map { ClaudeConnectedProvider(entry: $1, position: $0 + 2, accounts: accounts) }
    }

    func probeConnection() async -> ProviderConnection {
        if await accounts.isDisconnected(uuid: uuid) { return .notConnected(hint: ClaudeAccounts.disconnectedHint) }
        return await accounts.hasGrant(uuid: uuid) ? .available : .notConnected(hint: "Sign-in expired - reconnect it in Settings > Accounts")
    }

    func fetch() async throws -> UsageSnapshot {
        let now = Date.now
        let response = try await accounts.usage(uuid: uuid)
        let mapped = ClaudeUsageAPI.limitWindows(from: response)
        var snapshot = UsageSnapshot(providerID: id, fetchedAt: now)
        snapshot.primary = mapped.primary
        snapshot.secondary = mapped.secondary
        snapshot.tertiary = mapped.tertiary
        snapshot.extraWindows = mapped.extras
        snapshot.limitsCapturedAt = now
        snapshot.accountLabel = await accounts.entries().first { $0.uuid == uuid }?.label
        if snapshot.primary == nil && snapshot.secondary == nil {
            throw ProviderFetchError.dataUnavailable(description: "No Claude usage data for this account yet.")
        }
        return snapshot
    }
}

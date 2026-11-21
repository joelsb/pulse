import CryptoKit
import Foundation

/// One extra Pulse-tracked Codex account (JSB-112). Non-secret: the slot names
/// the Keychain item, `accountID` is the `chatgpt_account_id`, `label` the
/// masked email. Tokens live only in the Keychain slot.
struct CodexAccountEntry: Codable, Equatable, Sendable {
    var slot: String
    var accountID: String
    var label: String?
}

/// The persisted list of extra accounts - what makes them survive a relaunch.
struct CodexAccountIndex: @unchecked Sendable {
    static let key = "codexExtraAccounts"
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func load() -> [CodexAccountEntry] {
        guard let data = defaults.data(forKey: Self.key) else { return [] }
        return (try? JSONDecoder().decode([CodexAccountEntry].self, from: data)) ?? []
    }

    func save(_ entries: [CodexAccountEntry]) {
        defaults.set(try? JSONEncoder().encode(entries), forKey: Self.key)
    }
}

/// Extra Codex accounts beside the original `codex-primary` slot, which this
/// type never writes. Each account gets its own `CodexOAuthStore` (own
/// Keychain item, own rotation state), created once and reused so per-account
/// rotation bookkeeping survives between refreshes.
actor CodexAccounts {
    enum AddOutcome: Equatable, Sendable {
        case added(label: String?)
        /// The signed-in account is already tracked: nothing was written.
        case duplicate(label: String?)
    }

    enum AddFailure: Error, Equatable {
        /// The token response named no `chatgpt_account_id`, so the account
        /// cannot be told apart from the others: nothing was written.
        case unidentified
        /// The new grant could not read its own usage: nothing was written.
        case usageCheckFailed
        /// No free Keychain slot could be confirmed: nothing was written.
        case slotCheckFailed
    }

    private let index: CodexAccountIndex
    private let secrets: any CodexSecretStore
    private let primaryAccountIDs: @Sendable () async -> Set<String>
    private let fetchUsage: @Sendable (CodexAuth) async throws -> CodexUsageResponse
    private let refreshOverride: (@Sendable (String) async throws -> CodexOAuthClient.TokenPair)?
    private var stores: [String: CodexOAuthStore] = [:]

    init(
        index: CodexAccountIndex = CodexAccountIndex(),
        secrets: any CodexSecretStore = KeychainCodexSecretStore(),
        primaryAccountIDs: @escaping @Sendable () async -> Set<String>,
        fetchUsage: @escaping @Sendable (CodexAuth) async throws -> CodexUsageResponse = { try await CodexUsageAPI(http: HTTPClient()).fetchUsage(auth: $0) },
        refreshOverride: (@Sendable (String) async throws -> CodexOAuthClient.TokenPair)? = nil
    ) {
        self.index = index
        self.secrets = secrets
        self.primaryAccountIDs = primaryAccountIDs
        self.fetchUsage = fetchUsage
        self.refreshOverride = refreshOverride
    }

    func entries() -> [CodexAccountEntry] { index.load() }

    /// Preferred Keychain account name for an extra account: as short as
    /// `codex-primary`, to stay inside `KeychainWriter`'s command-line
    /// budget. Only 28 bits, so it is a PREFERENCE, never proof the slot is
    /// free: `allocateSlot` checks that before anything is written.
    static func slot(forAccountID accountID: String, attempt: Int = 0) -> String {
        let seed = attempt == 0 ? accountID : "\(accountID)#\(attempt)"
        let digest = SHA256.hash(data: Data(seed.utf8)).map { String(format: "%02x", $0) }.joined()
        return "codex-" + digest.prefix(7)
    }

    private static let maxSlotAttempts = 16
    private static let services = ["de.byte.pulse.codex-oauth", "de.byte.pulse.codex-oauth-pending"]

    /// Account ids with an add in progress, and slots reserved by one. Both
    /// are claimed synchronously on the actor, so two adds interleaving over
    /// an `await` can never pick the same account or the same slot.
    private var addingAccountIDs: Set<String> = []
    private var reservedSlots: Set<String> = []

    /// Browser sign-in, then identity and usage checks, and only then a write.
    /// A cancelled or failed sign-in throws before any storage is touched.
    func add(signIn: @Sendable () async throws -> CodexOAuthClient.TokenPair) async throws -> AddOutcome {
        let tokens = try await signIn()
        try Task.checkCancellation()
        let credentials = CodexOAuthStore.credentialsFromSignIn(tokens)
        let label = CodexAuth(accessToken: credentials.accessToken, accountID: credentials.accountID).accountLabel
        guard let accountID = credentials.accountID, !accountID.isEmpty else { throw AddFailure.unidentified }

        // Claimed before the first suspension below.
        if addingAccountIDs.contains(accountID) || isIndexed(accountID) { return .duplicate(label: label) }
        addingAccountIDs.insert(accountID)
        defer { addingAccountIDs.remove(accountID) }

        if await primaryAccountIDs().contains(accountID) { return .duplicate(label: label) }

        let auth = CodexAuth(accessToken: credentials.accessToken, accountID: accountID)
        guard (try? await fetchUsage(auth)) != nil else { throw AddFailure.usageCheckFailed }
        try Task.checkCancellation()
        // The index may have changed while suspended (another window, a
        // relaunch writing the same defaults): check again before writing.
        if isIndexed(accountID) { return .duplicate(label: label) }

        let slot = try await allocateSlot(for: accountID)
        defer { reservedSlots.remove(slot) }
        try Task.checkCancellation()

        try await store(for: slot).adopt(credentials)
        index.save(index.load() + [CodexAccountEntry(slot: slot, accountID: accountID, label: label)])
        return .added(label: label)
    }

    private func isIndexed(_ accountID: String) -> Bool {
        index.load().contains { $0.accountID == accountID }
    }

    /// First candidate slot no other account owns: not `codex-primary`, not
    /// in the index, not reserved by a concurrent add, and holding no
    /// Keychain item under either service (an orphan is not ours to
    /// overwrite). A Keychain read that cannot answer aborts the add.
    private func allocateSlot(for accountID: String) async throws -> String {
        for attempt in 0..<Self.maxSlotAttempts {
            let candidate = Self.slot(forAccountID: accountID, attempt: attempt)
            let indexed = Set(index.load().map(\.slot))
            guard candidate != "codex-primary", !indexed.contains(candidate), !reservedSlots.contains(candidate) else { continue }
            reservedSlots.insert(candidate)
            var occupied = false
            do {
                for service in Self.services where try await secrets.exists(service: service, account: candidate) {
                    occupied = true
                }
            } catch {
                reservedSlots.remove(candidate)
                throw AddFailure.slotCheckFailed
            }
            if !occupied { return candidate }
            reservedSlots.remove(candidate)
        }
        throw AddFailure.slotCheckFailed
    }

    func store(for slot: String) -> CodexOAuthStore {
        if let existing = stores[slot] { return existing }
        let fetchUsage = fetchUsage
        let store = CodexOAuthStore(
            account: slot,
            refreshOverride: refreshOverride,
            verifyOverride: { credentials in
                (try? await fetchUsage(CodexAuth(accessToken: credentials.accessToken, accountID: credentials.accountID))) != nil
            },
            secrets: secrets
        )
        stores[slot] = store
        return store
    }

    static let signInAgainHint = "Sign in again from Settings"

    /// A response fetched within this window is reused: the Codex tab's
    /// Accounts card and the account's own menu bar provider then cost one
    /// `wham/usage` request per refresh, not two.
    private static let reuseWindow: TimeInterval = 60
    private var recent: [String: (at: Date, response: CodexUsageResponse, label: String?)] = [:]

    func hasGrant(slot: String) async -> Bool {
        await store(for: slot).hasGrant()
    }

    /// One extra account's live usage, read with that account's own grant.
    func usage(slot: String, now: Date = .now) async throws -> (response: CodexUsageResponse, label: String?) {
        if let cached = recent[slot], now.timeIntervalSince(cached.at) < Self.reuseWindow, cached.at <= now {
            return (cached.response, cached.label)
        }
        guard let credentials = await store(for: slot).credentials() else {
            throw ProviderFetchError.notLoggedIn(hint: Self.signInAgainHint)
        }
        let auth = CodexAuth(accessToken: credentials.accessToken, accountID: credentials.accountID)
        let response = try await fetchUsage(auth)
        recent[slot] = (now, response, auth.accountLabel)
        return (response, auth.accountLabel)
    }

    /// One row per extra account, each read with that account's own grant.
    func usages(now: Date = .now) async -> [AccountUsage] {
        var rows: [AccountUsage] = []
        for entry in index.load() {
            let label = entry.label ?? "Account \(rows.count + 2)"
            do {
                let windows = CodexUsageAPI.limitWindows(from: try await usage(slot: entry.slot, now: now).response, now: now)
                rows.append(AccountUsage(id: entry.slot, label: label, session: windows.primary, weekly: windows.secondary))
            } catch {
                let message = (error as? ProviderFetchError)?.userMessage ?? "Usage unavailable"
                rows.append(AccountUsage(id: entry.slot, label: label, note: message))
            }
        }
        return rows
    }
}

/// One extra Codex account as its own provider (JSB-112), so it gets a tab,
/// a menu bar block and history exactly like a discovered Claude account.
/// Limits only: local session logs cannot tell which account spent them, so
/// token history stays on the main Codex tab.
actor CodexAccountProvider: UsageProvider {
    nonisolated let id: ProviderID
    nonisolated let descriptor: ProviderDescriptor
    private let slot: String
    private let accounts: CodexAccounts

    init(entry: CodexAccountEntry, position: Int, accounts: CodexAccounts) {
        self.id = .codexAccount(slot: entry.slot)
        self.slot = entry.slot
        self.accounts = accounts
        self.descriptor = ProviderDescriptor(
            id: .codexAccount(slot: entry.slot),
            name: "Codex \(entry.label ?? String(position))",
            // The main account is CDX; extras count on from 2, as in "Codex 2".
            shortCode: "CD\(position)",
            appBundleID: "com.openai.chat",
            webURL: URL(string: "https://chatgpt.com/codex")!,
            setupHint: CodexAccounts.signInAgainHint
        )
    }

    /// Providers for the indexed accounts, in index order, numbered from 2.
    static func make(entries: [CodexAccountEntry], accounts: CodexAccounts) -> [CodexAccountProvider] {
        entries.enumerated().map { CodexAccountProvider(entry: $1, position: $0 + 2, accounts: accounts) }
    }

    func probeConnection() async -> ProviderConnection {
        await accounts.hasGrant(slot: slot) ? .available : .notConnected(hint: descriptor.setupHint)
    }

    func fetch() async throws -> UsageSnapshot {
        let now = Date.now
        let (response, label) = try await accounts.usage(slot: slot, now: now)
        var snapshot = UsageSnapshot(providerID: id, fetchedAt: now)
        let windows = CodexUsageAPI.limitWindows(from: response, now: now)
        snapshot.primary = windows.primary
        snapshot.secondary = windows.secondary
        snapshot.limitsCapturedAt = now
        snapshot.plan = response.planType.map(CodexAuth.planDisplayName)
        snapshot.accountLabel = label
        if let credits = CodexUsageAPI.creditsNote(from: response) {
            snapshot.statusNotes.append(credits)
        }
        if snapshot.primary == nil && snapshot.secondary == nil {
            throw ProviderFetchError.dataUnavailable(description: "No Codex usage data for this account yet.")
        }
        return snapshot
    }
}

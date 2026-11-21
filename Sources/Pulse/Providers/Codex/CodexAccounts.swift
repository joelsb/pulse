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

    /// One row per extra account, each read with that account's own grant.
    func usages(now: Date = .now) async -> [AccountUsage] {
        var rows: [AccountUsage] = []
        for entry in index.load() {
            let label = entry.label ?? "Account \(rows.count + 2)"
            guard let credentials = await store(for: entry.slot).credentials() else {
                rows.append(AccountUsage(id: entry.slot, label: label, note: "Sign in again from Settings"))
                continue
            }
            let auth = CodexAuth(accessToken: credentials.accessToken, accountID: credentials.accountID)
            do {
                let windows = CodexUsageAPI.limitWindows(from: try await fetchUsage(auth), now: now)
                rows.append(AccountUsage(id: entry.slot, label: label, session: windows.primary, weekly: windows.secondary))
            } catch {
                let message = (error as? ProviderFetchError)?.userMessage ?? "Usage unavailable"
                rows.append(AccountUsage(id: entry.slot, label: label, note: message))
            }
        }
        return rows
    }
}

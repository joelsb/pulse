import AppKit
import Foundation

/// Composition root: owns every long-lived object and wires them together.
@MainActor
final class AppEnvironment {
    let settings: SettingsStore
    let store: UsageStore
    let history: HistoryStore
    let providers: [any UsageProvider]
    let scheduler: RefreshScheduler
    /// Pulse's own Claude OAuth grants (JSB-8) — shared with every
    /// `ClaudeProvider`, so a sign-in from Settings is visible to the same
    /// object the next refresh reads from.
    let pulseOAuthStore: PulseOAuthStore
    /// Pulse's own Codex OAuth grant (JSB-9), same sharing reason.
    let codexOAuthStore: CodexOAuthStore
    /// Extra Codex accounts beside `codexOAuthStore`'s (JSB-112), shared with
    /// `CodexProvider` so an add from Settings shows on the next refresh.
    let codexAccounts: CodexAccounts
    /// Connected Claude accounts (JSB-112), shared with their providers.
    let claudeAccounts: ClaudeAccounts
    /// Names Joel gives his Claude and Codex accounts (JSB-112).
    let accountNames = AccountNames()
    /// The Mac's own Claude Code account uuid, read once at launch.
    private let primaryClaudeUUID: String?
    /// On-demand per-project/session analytics for the breakdown window. Shares
    /// the provider instances (and their warm caches) with the scheduler.
    let projectUsage: ProjectUsageService
    /// Local machine stats for the panel sidebar. Polls only while a view is
    /// subscribed, so it costs nothing with the panel closed.
    let system = SystemMonitor()
    /// True when launched with `--demo-data`: the breakdown shows Byte-branded
    /// mock data instead of the user's logs (for screenshots and demos).
    let isDemoData = ProcessInfo.processInfo.arguments.contains("--demo-data")

    init() {
        // Account discovery MUST run before SettingsStore is constructed.
        // SettingsStore reads ProviderID.allCases in its initialiser to decide
        // which persisted ids are still valid, so an empty registry at that
        // moment silently discards every discovered account and rewrites
        // UserDefaults without them.
        // JSB-112: accounts come from Settings > Accounts (their indexes),
        // never from `~/.claude-*` directories.
        let codexAccountEntries = CodexAccountIndex().load()
        let claudeAccountEntries = ClaudeAccountIndex().load()
        let primaryClaude = ClaudeAccount.primary()
        ProviderRegistry.shared.register(
            claudeAccounts: [primaryClaude.id] + claudeAccountEntries.map { .claudeConnected(uuid: $0.uuid) },
            codexAccounts: codexAccountEntries.map { .codexAccount(slot: $0.slot) }
        )

        let settings = SettingsStore()
        let store = UsageStore()
        let history = HistoryStore()
        let pulseOAuthStore = PulseOAuthStore()
        let codexOAuthStore = CodexOAuthStore()
        // An account already shown as the first one - Pulse's own grant or
        // the Codex CLI's login - must not be added again as an extra.
        let codexAccounts = CodexAccounts(primaryAccountIDs: { [codexOAuthStore] in
            let cliAccountID = (try? CodexAuth.load(from: CodexAuth.defaultFileURL))?.accountID
            return Set([await codexOAuthStore.storedAccountID(), cliAccountID].compactMap { $0 })
        })
        // The Mac's own Claude Code login is the first Claude account; adding
        // it again would be a duplicate.
        let primaryClaudeUUID = primaryClaude.accountUUID
        let claudeAccounts = ClaudeAccounts(store: pulseOAuthStore, primaryAccountUUIDs: {
            Set([primaryClaudeUUID].compactMap { $0 })
        })
        let providers = ProviderFactory.makeAll(
            captureTitles: settings.useSessionTitles,
            pulseOAuthStore: pulseOAuthStore,
            codexOAuthStore: codexOAuthStore,
            codexAccounts: codexAccounts,
            codexAccountEntries: codexAccountEntries,
            claudeAccounts: claudeAccounts,
            claudeAccountEntries: claudeAccountEntries
        )

        self.settings = settings
        self.store = store
        self.history = history
        self.pulseOAuthStore = pulseOAuthStore
        self.codexOAuthStore = codexOAuthStore
        self.codexAccounts = codexAccounts
        self.claudeAccounts = claudeAccounts
        self.primaryClaudeUUID = primaryClaudeUUID
        self.providers = providers
        self.scheduler = RefreshScheduler(
            providers: providers,
            store: store,
            history: history,
            settings: settings
        )
        self.projectUsage = isDemoData
            ? ProjectUsageService(breakdownProviders: DemoBreakdownProvider.all)
            : ProjectUsageService(providers: providers)
        accountNames.bind(.claude, accountID: primaryClaudeUUID)
        Task { await self.bindAccountNames() }
    }

    /// The name an account is shown by: Joel's own name for it when set,
    /// else the provider's default ("Claude", "Codex bo…@example.com").
    func displayName(for id: ProviderID) -> String {
        accountNames.name(for: id) ?? descriptor(for: id).name
    }

    func displayDescriptor(for id: ProviderID) -> ProviderDescriptor {
        let base = descriptor(for: id)
        return ProviderDescriptor(
            id: base.id, name: displayName(for: id), shortCode: base.shortCode,
            appBundleID: base.appBundleID, webURL: base.webURL, setupHint: base.setupHint
        )
    }

    /// Binds every Claude and Codex row to the account serving it now, so a
    /// name follows its account (`AccountNames`). Run at launch and after any
    /// sign-in change in Settings.
    func bindAccountNames() async {
        accountNames.bind(.claude, accountID: primaryClaudeUUID)
        for entry in await claudeAccounts.entries() {
            accountNames.bind(.claudeConnected(uuid: entry.uuid), accountID: entry.uuid)
        }
        for entry in await codexAccounts.entries() {
            accountNames.bind(.codexAccount(slot: entry.slot), accountID: entry.accountID)
        }
        // The first Codex row is served by Pulse's own grant when it has one,
        // else by the Codex CLI's login (`CodexProvider.loadCandidates`).
        let primaryCodex = await codexOAuthStore.hasGrant()
            ? await codexOAuthStore.storedAccountID()
            : (try? CodexAuth.load(from: CodexAuth.defaultFileURL))?.accountID
        accountNames.bind(.codex, accountID: primaryCodex)
    }

    func descriptor(for id: ProviderID) -> ProviderDescriptor {
        providers.first(where: { $0.id == id })!.descriptor
    }

    /// Opens the provider's desktop app when installed, else its web dashboard.
    func openProvider(_ id: ProviderID) {
        let descriptor = descriptor(for: id)
        if let bundleID = descriptor.appBundleID,
           let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            NSWorkspace.shared.openApplication(at: appURL, configuration: .init())
        } else {
            NSWorkspace.shared.open(descriptor.webURL)
        }
    }
}

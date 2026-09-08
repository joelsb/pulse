import Foundation

/// Composition point for all provider engines, in canonical display order.
enum ProviderFactory {
    /// - Parameter captureTitles: whether the Claude log parser may read
    ///   `ai-title` records (off = strictly content-blind). Set from
    ///   `SettingsStore.useSessionTitles` at launch.
    /// - Parameter pulseOAuthStore: shared across every Claude account (JSB-8)
    ///   — one Keychain service holds every account's grant already
    ///   distinguished by uuid, so one store instance is enough, and sharing
    ///   it is what lets Settings sign in through the same object every
    ///   `ClaudeProvider` reads from.
    /// - Parameter codexOAuthStore: JSB-9's Codex equivalent — shared with
    ///   Settings the same way, so a Codex sign-in updates the same object
    ///   `CodexProvider` reads from.
    static func makeAll(
        captureTitles: Bool = true,
        pulseOAuthStore: PulseOAuthStore = PulseOAuthStore(),
        codexOAuthStore: CodexOAuthStore = CodexOAuthStore()
    ) -> [any UsageProvider] {
        // Claude accounts are discovered from ~/.claude* at launch, so the
        // registry has to learn about them before anything reads allCases
        // (tab order, settings, menu bar).
        let accounts = ClaudeAccount.discover()
        ProviderRegistry.shared.register(claudeAccounts: accounts.map(\.id))

        return accounts.map { ClaudeProvider(account: $0, pulseOAuthStore: pulseOAuthStore, captureTitles: captureTitles) }
            + [
                CodexProvider(codexOAuthStore: codexOAuthStore),
                CursorProvider(),
                CopilotProvider(),
                GeminiProvider(),
            ]
    }
}

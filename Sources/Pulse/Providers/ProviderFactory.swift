import Foundation

/// Composition point for all provider engines, in canonical display order.
enum ProviderFactory {
    /// - Parameter captureTitles: whether the Claude log parser may read
    ///   `ai-title` records (off = strictly content-blind). Set from
    ///   `SettingsStore.useSessionTitles` at launch.
    static func makeAll(captureTitles: Bool = true) -> [any UsageProvider] {
        [
            ClaudeProvider(parser: ClaudeLogParser(captureTitles: captureTitles)),
            CodexProvider(),
            CursorProvider(),
            CopilotProvider(),
            GeminiProvider(),
        ]
    }
}

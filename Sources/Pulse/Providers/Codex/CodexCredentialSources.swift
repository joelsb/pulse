import Foundation

/// JSB-9: Codex OAuth credentials as jcode stores them, in
/// `~/.jcode/openai-auth.json` - a DIFFERENT file from
/// `JcodeCredentialsStore`'s `~/.jcode/auth.json` (Claude), so this is a new
/// parser, not a duplicate of an existing one.
///
/// ```
/// {"openai_accounts": [{"label": "openai-1", "access_token": "...",
///                        "refresh_token": "...", "id_token": "...",
///                        "account_id": "...", "expires_at": 1789639786384,
///                        "email": "..."}],
///  "active_openai_account": "openai-1"}
/// ```
///
/// `expires_at` is epoch MILLISECONDS - measured live 2026-09-08 against
/// this machine's own file, same convention `ClaudeCredentials.expiresAt`
/// and `PiAccountResolver.Credential.expiresAt` already use.
struct JcodeOpenAICredentialsStore: Sendable {
    let authFile: URL

    init(authFile: URL = AppPaths.home.appendingPathComponent(".jcode/openai-auth.json")) {
        self.authFile = authFile
    }

    /// The active account when the file names one, else the first account in
    /// the array - mirroring `active_openai_account`/first-entry conventions
    /// this repo already uses for jcode's Anthropic file. Returns nil rather
    /// than throwing: this is a fallback source, and its absence is the
    /// normal case for anyone not running jcode.
    func credentials() -> CodexAuth? {
        guard let data = try? Data(contentsOf: authFile),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accounts = root["openai_accounts"] as? [[String: Any]], !accounts.isEmpty
        else { return nil }

        let active = root["active_openai_account"] as? String
        let account = (active.flatMap { label in accounts.first { $0["label"] as? String == label } }) ?? accounts[0]

        guard let access = account["access_token"] as? String, !access.isEmpty else { return nil }
        return CodexAuth(
            accessToken: access,
            idToken: account["id_token"] as? String,
            accountID: account["account_id"] as? String,
            expiresAt: (account["expires_at"] as? NSNumber)?.doubleValue
        )
    }
}

/// pi's `openai-codex` entry, wrapped into the same `CodexAuth` shape the
/// other two sources use - the parsing itself lives in
/// `PiAccountResolver.readOpenAICodexAuth`, the same type that already reads
/// this file for pi's Anthropic keys (JSB-9 constraint: don't write a second
/// parser for a file another type already reads).
enum PiOpenAICodexCredentials {
    static func credentials(from url: URL) -> CodexAuth? {
        guard let credential = PiAccountResolver.readOpenAICodexAuth(url) else { return nil }
        return CodexAuth(
            accessToken: credential.accessToken,
            accountID: credential.accountID,
            expiresAt: credential.expiresAt
        )
    }
}

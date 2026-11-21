# 0005. Accounts are connected in Settings, not discovered from folders

Status: Accepted (JSB-112). Builds on [0004](0004-each-codex-account-is-its-own-provider.md).

## Decision

Settings > Accounts is the only way Pulse gains a further account. Each provider group lists the login that provider's own tool holds on this Mac first (Claude Code, Codex CLI, Cursor app, GitHub Copilot, gemini-cli), then the accounts Joel connected.
Claude accounts are connected through Pulse's existing browser sign-in and stored by Anthropic account uuid in `PulseOAuthStore`; Codex accounts as in 0003/0004. Indexes: UserDefaults `claudeConnectedAccounts` and `codexExtraAccounts`.
`~/.claude-*` directories are no longer discovered (`ClaudeAccount.primary()` replaces `discover()` at launch). Nothing in those folders, nor any tool login, is read for account management, rewritten or deleted.
Every account has two independent switches: Panel (its tab, `enabledProviders`) and Menu icon (`menuBarProviders`). Either one keeps it refreshing (`SettingsStore.refreshedProviders`).
The first row of Claude and Codex shows when Pulse holds its own grant for it ("Pulse sign-in for this Mac's Claude Code account", "Pulse sign-in (first Codex account)") and offers Sign in/Reconnect and Sign out of Pulse. Claude's first-row sign-in accepts only the Mac's Claude Code account uuid (refused before the browser when there is none); Codex's refuses an account already connected below. Neither can leave a grant no provider reads.
The panel shows exactly the accounts whose Panel switch is on: with none, an empty state leads to Settings > Accounts instead of showing every account; the menu bar icon stays (Pulse mark when no account is in it).
Disconnect deletes only Pulse's own Keychain grant for a connected account and keeps the row; Remove (after Disconnect) forgets the row. Reconnect refuses a sign-in that lands on a different account.

## What forced it

Joel approved layout A of `connected-accounts.html`: one grouped Accounts panel, add/reconnect/disconnect/remove, independent Panel and Menu icon switches, no folder dependency, and he will sign in again (no migration).

## Consequences

- Pulse grants left in `de.byte.pulse.oauth` by former `~/.claude-*` accounts are not read until that account is added again in Settings (then the add overwrites and manages it). Pulse cannot list them without enumerating the Keychain, so they are not shown.

- Accounts that came from `~/.claude-*` disappear until Joel connects them in Settings. Their folders stay untouched.
- Add, duplicate, mismatch and cancel are decided before any write; a declined sign-in leaves every grant as it was.
- A newly connected account gets its tab and menu icon at the next launch (Relaunch button), because the provider registry is fixed at launch.
- Connected accounts show limits only; local token history stays with the Mac's own login.
- Cursor, Copilot and Gemini show one account with the concrete reason: Pulse has no sign-in of its own for them, only the tool's local login. No fake sign-in is offered.

## Rejected alternatives

- Keep discovering `~/.claude-*`: ties accounts to folders, which the approved design removes.
- Reading a second Cursor, Copilot or Gemini login from another app's storage: harvesting another tool's session, not a provider-supported sign-in.
- Panel switch also gating the menu icon (the old `enabled ∩ menuBar` rule): the design requires them independent.

## Revisit when

- Pulse gets its own GitHub or Google OAuth registration, or Cursor publishes a sign-in for third-party apps.

## Evidence

- `Tests/PulseTests/ClaudeConnectedAccountsTests.swift` (add, duplicate, cancel, usage check, mismatch, disconnect scope, remove guard, relaunch, independent switches, launch wiring, rows), `CodexMultiAccountTests.swift` (`reconnectDisconnectAndRemoveKeepEveryOtherGrant`).

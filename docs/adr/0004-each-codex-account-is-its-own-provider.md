# 0004. Each extra Codex account is its own provider, like a Claude account

Status: Accepted (JSB-112). Supersedes the "ride one provider" part of [0003](0003-codex-extra-accounts-ride-one-provider.md).

## Decision

Every account in `codexExtraAccounts` becomes a `CodexAccountProvider` with id `codexAccount.<slot>`, spliced right after `.codex` in `ProviderRegistry`, exactly as discovered Claude accounts follow `.claude`.
It therefore gets everything a Claude account gets, from the same generic code: a panel tab, a Settings enable and menu bar toggle, a menu bar block (short code `CD2`, `CD3`... in index order; the main account stays `CDX`), history, trends and a hashed accent colour.
Its snapshot carries only limits (session and weekly from its own `wham/usage`), plan and masked email.
The Codex tab's Accounts card stays, and reads the same per-account response (reused for 60 s), so the two cost one request per account per refresh.

## What forced it

Joel: "I should be able to view both codex accounts in the menu icon just like claude accounts." The menu bar renders one block per registered provider id, so a row inside the Codex snapshot could never reach it.

## Consequences

- Registration happens at launch, before `SettingsStore` reads the registry (same constraint as Claude accounts). An account added mid-session appears after a relaunch; Settings says so and offers a Relaunch button.
- Unlike a discovered Claude account, a new Codex account is enabled and shown in the menu bar by default: Joel added it on purpose (`SettingsStore`'s existing rule for any introduced non-Claude id).
- Local token history (`~/.codex/sessions`) cannot be attributed to an account, so it stays on the main Codex tab only.
- `SettingsStore(providers:)` and `ProviderFactory.makeAll(registry:)` take an injectable list or registry so tests never mutate `ProviderRegistry.shared`.

## Rejected alternatives

- Keeping extras as rows only (0003): does not reach the menu bar.
- Registering new ids live, without relaunch: the registry, refresh loops, tab selection and persisted settings all assume a launch-fixed set (see `ProviderRegistry`'s doc comment); Claude accounts make the same trade.

## Revisit when

- Adding accounts becomes frequent enough that a relaunch annoys.

## Evidence

- `Tests/PulseTests/CodexMultiAccountTests.swift`, suite "Codex extra accounts in the menu bar (JSB-112)".

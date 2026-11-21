# 0003. Extra Codex accounts ride the one Codex provider, one Keychain slot each

Status: Accepted (JSB-112)

## Decision

A second (third, ...) Codex account is added from Settings with "Add account…" beside the existing "Sign in…".
It is stored as its own Keychain item under the same services as the first (`de.byte.pulse.codex-oauth` and `-pending`), account name `codex-` plus 7 hex characters of SHA-256 of its `chatgpt_account_id` (then of `<id>#1`, `#2`, ... up to 16 tries).
That digest is only 28 bits, so it is a preference, never proof the slot is free: a candidate is skipped when it is `codex-primary`, owned by any index entry (even one whose Keychain items a dead grant already cleared), reserved by an add in progress, or holding a Keychain item under either service. A Keychain read that cannot answer aborts the add with nothing written.
The non-secret list of extra accounts (slot, account id, masked email) lives in UserDefaults key `codexExtraAccounts`.
`CodexProvider` stays one provider: when extra accounts exist, its snapshot carries `accountUsages`, one labeled session + weekly row per account (first account first), rendered by `AccountUsageCard`.
The first account's fixed `codex-primary` slot is never written by the add flow.

## What forced it

- The intent: add B without replacing A, and see both after relaunch without signing in again.
- The approved UI: one labeled usage row per account inside the Codex tab, not one tab per account.
- Keychain budget: `KeychainWriter` caps the whole `security -i` command line, and a longer account name shrinks it. The derived slot is exactly as long as `codex-primary` (13 characters), so it uses no more budget than the slot already proven live.

## Consequences

- Duplicates are refused three times: before the first suspension (index plus an in-flight account-id claim, so two interleaving adds on the actor cannot both pass), against the first account, and again against the index after the usage check, since another Pulse instance may have written it meanwhile.

- The add flow checks identity (`chatgpt_account_id` present) and usage (`wham/usage` answers with the new token) before any write. Cancel, a duplicate of the first account (Pulse grant or Codex CLI login) or of an extra, and either failed check write nothing.
- Each extra account has its own `CodexOAuthStore` instance, cached by slot, so ADR-0001 rotation and its spent-token bookkeeping run per account.
- The big session and weekly cards, the menu bar number and history still describe the first account only. Extra accounts are visible in the Accounts card only.
- No remove-account button yet. Removing one means deleting its Keychain item and its UserDefaults entry by hand.

## Rejected alternatives

- One `ProviderID` per Codex account, as Claude accounts do: a tab per account, not the approved row-per-account layout, and it rewires menu bar, history and enabled-provider settings for a feature that only needs two numbers per account.
- Trusting the digest alone: 28 bits collide, and an add that writes without checking would overwrite another account's grant.
- Random slot names: equally safe once slots are checked, but the derived slot keeps the same account in the same item across re-adds and is easier to find by hand.
- Storing the account list in the Keychain: it holds no secret, and UserDefaults needs no `security` subprocess or ACL prompt to read at launch.

## Revisit when

- Joel wants an extra account in the menu bar or as its own tab.
- OpenAI stops returning `chatgpt_account_id` in the id_token (identity check would reject every add).

## Evidence

- `Tests/PulseTests/CodexMultiAccountTests.swift`: 10 tests on an in-memory secret store, each watched failing under a targeted mutation of `CodexAccounts.swift`.

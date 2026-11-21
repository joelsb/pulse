# Architecture Decision Records

One file per decision that constrains future work, is counter-intuitive
enough that someone will try to "simplify" it, or rests on evidence not
visible in the code (a live measurement, a provider limit, a real observation)
rather than something a reader could re-derive by inspection.

| # | Title | Status |
|---|-------|--------|
| [0001](0001-refresh-token-rotation-write-order.md) | Refresh-token rotation write order (pending → verify → promote) | Accepted |
| [0002](0002-codex-oauth-differs-from-claude.md) | Codex's OAuth grant differs from Claude's in five measured ways | Accepted |
| [0003](0003-codex-extra-accounts-ride-one-provider.md) | Extra Codex accounts ride the one Codex provider, one Keychain slot each | Partly superseded by 0004 |
| [0004](0004-each-codex-account-is-its-own-provider.md) | Each extra Codex account is its own provider, like a Claude account | Accepted |
| [0005](0005-accounts-are-connected-in-settings.md) | Accounts are connected in Settings, not discovered from folders | Accepted |

Not every decision gets one — routine implementation, renames, dependency
bumps and a fix with one obvious answer go in the commit message instead.

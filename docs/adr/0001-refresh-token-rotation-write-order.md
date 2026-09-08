# 0001. Refresh-token rotation write order (pending → verify → promote)

Status: Accepted — 2026-09-08 (JSB-8)

## Decision

`PulseOAuthStore` never overwrites its primary Keychain item (`de.byte.pulse.oauth`)
with a rotated token pair directly. Every rotation goes through three steps,
in this exact order, and step 2 is a real network call, not a status check:

1. **Persist** the rotated `{access_token, refresh_token, expires_at, scope}`
   to a second Keychain item, `de.byte.pulse.oauth-pending`, keyed on the same
   account uuid. This happens the instant the token endpoint answers — before
   the old refresh token is discarded from memory, before anything else runs.
2. **Verify** the rotated access token with a real request
   (`GET /oauth/usage`). A 200 response is required; the token endpoint's own
   200 on the refresh call is not accepted as proof (see "Why a 200 there
   proves nothing" below).
3. **Promote**: only after step 2 succeeds, write the same pair to the primary
   item. If step 2 fails, the pair stays in `-pending` and the primary item is
   left untouched.

On every read, whichever item has the LATER `expires_at` wins — not "pending
 unconditionally," which review round 1 (2026-09-08) found a real hole in:
`signIn` writes both items directly (no old pair to protect, so no pending
step), and if its second write throws, an unconditional "prefer pending"
rule could leave a stale, already-dead pending item shadowing a live primary
one forever. Comparing `expires_at` gives the right answer in both call
sites — `rotate` always makes pending strictly newer when it writes it, so
for that path this is equivalent to "prefer pending," but it is also correct
when `signIn` fails halfway. This is not an optimization — it is required
for the write order above to be safe at all (see "Why preferring the
fresher item is required," not optional, below).

A rotation whose refresh call itself fails with `400 invalid_grant` is not a
transient error to retry — it is proof the grant is permanently dead, and is
treated as a distinct, terminal outcome (see "Dead grants are terminal, not
retried" below), not folded into the pending/verify/promote flow above.

Concurrent rotation attempts for the same account are coalesced inside the
actor (one `Task` per in-flight uuid) rather than relying on nothing calling
`credentials(forAccountUUID:)` twice at once for the same account — see
"Why rotation is coalesced, not just hoped to be single-caller" below.

## What forced it

Anthropic's OAuth refresh is **strictly rotating**: exchanging a refresh token
for a new pair invalidates the refresh token that was sent, immediately and
permanently. Falsified live 2026-09-08, one browser sign-in
(`client_id 9d1c250a-e61b-44d9-88ed-5944d1962f5e`):

```
self-refresh          200   rotated=True; refreshed token reads /oauth/usage 200
reuse old refresh      400   invalid_grant "Refresh token not found or invalid"
```

A refresh token is therefore a **single-use** credential from Pulse's point of
view. Combined with "Pulse mints and refreshes its own grant end to end"
(JSB-8's whole point), this creates a window with no safe fallback if it goes
wrong: the moment the token endpoint answers 200 to a refresh call, the
*previous* refresh token is dead. If Pulse crashes, is force-quit, or the
Mac loses power between that 200 and the new pair becoming durable, there is
nothing left to recover the grant with — not the old pair (its refresh token
is burned) and not the new one (it was never written down). The account would
need a full re-sign-in, silently, the next time Pulse launches and finds a
primary item whose refresh token 400s.

A single unconditional write (`security add-generic-password -U` straight to
the primary item) does not close this window — it just narrows it to "between
the endpoint's response arriving in memory and the write syscall returning,"
which is still nonzero and still a real crash target (a Mac can lose power at
any instruction boundary; a force-quit can land the process between any two
statements). The fix has to be about *what exists on disk after any possible
crash point*, not about making the window smaller.

## Why a 200 on the refresh call proves nothing

This project's other proven rule (`ClaudeOAuthClient.scope`) is that
Anthropic's OAuth endpoints answer 200 while silently doing less than asked:
requesting 6 scopes returns 200 with 5 granted, no error field, nothing to
distinguish it from a clean 6-for-6 grant except the `scope` field itself. The
same posture applies here on principle, not just as a stylistic match: a 200
from `/oauth/token` proves the HTTP round trip succeeded and a token-shaped
JSON body came back. It does not prove that access token can do anything —
Anthropic could return a pair scoped to nothing usable, or a transient
downstream failure could leave a technically-valid-shaped but functionally
dead token. `/oauth/usage` — the actual endpoint every gauge on the panel
depends on — is what gets asked, not `/oauth/token`'s status code.

## Why preferring the fresher item is required, not optional

Once a rotation reaches step 1 (pending written) the primary item's refresh
token is already burned server-side, regardless of whether steps 2–3 ever run.
If a crash happens between step 1 and step 3, the next launch faces:

- primary item: old access token (may still have minutes left, or may not),
  old refresh token (dead — any future rotation attempt using it gets `400
  invalid_grant`)
- pending item: the actual live pair, always further from expiry than the
  primary item in this scenario, because it was just minted with a fresh
  ~8h lifetime

A reader that ignores `-pending` and trusts the primary item will keep working
by coincidence until the old access token's natural ~8h expiry, then rotate,
get `400 invalid_grant` because it's using the burned refresh token, and force
a re-sign-in it had no need to force — the exact silent-failure shape this
whole feature exists to end. Reading by freshest `expires_at` is what makes
step 1 actually protective instead of just an unread backup file, in the
`rotate` path where it matters most, while also handling `signIn`'s directly-
written pair correctly (see "Decision" above).

## Dead grants are terminal, not retried

`400 invalid_grant` on the REFRESH call (not the verification step — a
different failure, see "Why a 200 proves nothing") means the refresh token
itself was rejected: permanently dead, and no amount of retrying fixes it,
only a human re-sign-in does. Found in review round 1 (2026-09-08): the first
version of this store used `try?` around the whole rotation and treated a
dead grant exactly like a network blip — retried on every refresh tick,
forever, POSTing an already-burned refresh token to a Cloudflare-fronted
endpoint. That is the same self-renewing-penalty shape `intent.md` documents
for `~/.claude`'s HTTP 429 (a live credential problem earning a rate limit
that then blocks the live credential), reintroduced on the token endpoint by
the very feature meant to end it.

`PulseOAuthStore` now marks the account in an in-memory `deadGrants` set on a
`400` from the refresh call specifically, and deletes both Keychain items for
that uuid (`KeychainWriter.delete`) so the dead state is durable across a
relaunch too — not just refused in memory. `credentials(forAccountUUID:)` and
`hasGrant(forAccountUUID:)` both refuse a dead account outright. A fresh
`signIn` for the same uuid clears the mark.

## Why rotation is coalesced, not just hoped to be single-caller

Actor isolation does not hold across `await` points, and `rotate` awaits a
Keychain read, a network refresh, two Keychain writes, and a usage probe.
Two concurrent `credentials(forAccountUUID:)` calls for the same uuid would
both see `needsRefresh() == true`, both read the same pair, and both spend
the same single-use refresh token — one call's rotation wins, the other's
response is for a token the server has already invalidated.

Review round 1 found this was unreachable in practice, but only because of
two facts that live elsewhere and were not documented near this code: one
shared `PulseOAuthStore` instance serves every `ClaudeProvider`
(`AppEnvironment.swift`, `ProviderFactory.swift`), and
`RefreshScheduler`'s `isRefreshing` guard keeps one provider's `fetch()` from
overlapping itself. Depending on both of those staying true forever, in a
different file, for a single-use credential, was judged fragile enough to fix
directly: `PulseOAuthStore` now coalesces concurrent rotation attempts for
the same uuid onto one in-flight `Task`, so the invariant holds even if
either of those two external facts changes later.

## Consequences

- Every successful rotation leaves `-pending` holding the same content as the
  (now updated) primary item. This is deliberate redundancy, not drift: the
  two are expected to converge after every clean rotation and the reader
  logic does not need to reconcile or delete anything for that to stay true.
- One extra Keychain write and one extra network call (the `/oauth/usage`
  verification) per rotation. Rotations happen at most once per token
  lifetime (~8h) per account, so this is negligible against the 30s–5min
  refresh-loop cadence the rest of the app runs at.
- A rotation whose verification fails (network blip, endpoint hiccup, or any
  transient error other than `400` on the refresh call itself) makes `rotate`
  THROW rather than return the unverified pair — review round 1 (2026-09-08)
  found the first version returned it, which let `ClaudeProvider` pin an
  unverified, possibly-broken credential ahead of a working harness token.
  `credentials(forAccountUUID:)` swallows that throw (`try?`) and keeps
  serving the OLD pair for that call; the next caller that needs a fresh
  token tries the rotation again, and finds the ALREADY-rotated pair waiting
  in `-pending` rather than re-spending the (already-spent) refresh token.
  The old access token remains usable until its own natural expiry regardless
  of what happened to the refresh token, so this costs nothing except
  deferring the rotation, never a dropped grant.
- A rotation whose refresh call itself returns `400` is the one outcome that
  is NOT retried at all — see "Dead grants are terminal, not retried" above.

## Rejected alternatives

- **Write straight to the primary item.** Rejected: see "What forced it" — it
  narrows the crash window instead of closing it, and Anthropic's rotation is
  strict enough that even a narrow window is a real, permanent failure mode
  once hit.
- **Keep the old pair until the new one is written, then write, then delete
  the old one (no separate `-pending` item, no verification step).** Rejected:
  still trusts the token endpoint's 200 as proof of a working token, which
  "Why a 200 proves nothing" above shows is not warranted on this API.
- **Verify before persisting anything (call `/oauth/usage` first, write to
  primary only after it answers 200).** Rejected: this holds the rotated pair
  in memory only, unprotected, for the entire round trip to `/oauth/usage` —
  a strictly *larger* crash window than persisting to `-pending` first, for no
  benefit.

## Evidence

- Live falsification, 2026-09-08 (see `intent.md`): code exchange 200, profile
  200, usage 200, self-refresh 200 (rotated), reuse of the pre-rotation
  refresh token → 400 `invalid_grant`.
- `ClaudeOAuthClient.scope`'s doc comment: the same "a 200 here proves less
  than you think" finding, independently confirmed on a different endpoint of
  the same API the same day (6 scopes requested, 5 granted, still 200).
- `scripts/verify-oauth-rotation.sh`: plants defects in the write order
  (primary-first, no verification, pending not preferred at read time, no
  Keychain persistence at all) and requires each to be caught by a harness
  that kills the process between the pending write and the promotion. Also
  asserts the RETURN VALUE of a failed-verification rotation is the old
  pair, not the unverified new one (review round 1's B2 finding: the
  original harness discarded that return value, so all four defects could
  pass while this property was untested).

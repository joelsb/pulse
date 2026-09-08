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

## Pending is provisional until proven, not just until promoted (R2-B1)

Picking the freshest item by `expires_at` (previous section) is necessary but
NOT sufficient: `rotate` writes `-pending` BEFORE it calls `verifies()`, so a
rotation whose verification fails leaves a pair in `-pending` that is fresh
(a full ~8h `expires_at`) and completely UNPROVEN. Review round 2 (2026-09-08)
found that the round-1 fix for this (throw instead of returning the unverified
pair — see the "Consequences" bullet below) only protected the ONE call that
ran the failed rotation. The very next `credentials(forAccountUUID:)` call
would pick that same pending pair (fresher than primary by `expires_at`), see
`needsRefresh() == false` on it (nothing about an ~8h-out pair looks like it
needs refreshing), never call `rotate`/`verifies` again, and serve the
unverified pair — pinned by `ClaudeProvider` ahead of every working harness
token — for its entire ~8h life. Two docs and the shell harness's own
relaunch assertion stated the opposite of this as settled behaviour; all
three were wrong until this fix.

The fix: `read()` reports not just which pair it picked but whether that pair
came from `-pending` while DIFFERING from primary (`isUnpromotedPending`) —
that is the signature of "written by a rotation, never proven". On that path,
`credentials(forAccountUUID:)` calls `verifies()` once before handing the pair
out: success promotes it into primary (so every later call skips the extra
`/oauth/usage` call — pending now equals primary, no longer "unpromoted");
failure refuses the pair outright (`nil`) rather than falling back to
primary's near-expiry old pair, which is what was already about to need
rotating in the first place. Bounded per call: at most one extra verification
request, and only until the pair is either promoted or the account signs in
again.

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

`PulseOAuthStore` now marks the account in an in-memory `deadGrants` set on
`invalid_grant` from the refresh call SPECIFICALLY — not on "any `400`", which
was review round 2's own finding about the round-1 version of this exact fix
(see "Only `invalid_grant` is terminal" below) — and deletes both Keychain
items for that uuid (`KeychainWriter.delete`) so the dead state is durable
across a relaunch too, not just refused in memory. `credentials(forAccountUUID:)`
and `hasGrant(forAccountUUID:)` both refuse a dead account outright. A fresh
`signIn` for the same uuid clears the mark — BEFORE either Keychain write, not
after (R2-S4), so a browser round trip that succeeded is not left shadowed by
a stale mark if either write then fails.

## Only `invalid_grant` is terminal — every other failure is bounded, not deleted

Review round 2 (2026-09-08) found the round-1 version of the section above too
BROAD: it matched `ProviderFetchError.http(400)`, which is what `HTTPClient.send`
produced for EVERY `400` alike (status only, body already discarded before the
throw) — so any 400 unrelated to the refresh token being dead (a malformed
body after a future API change, a changed required parameter, a provider-side
validation hiccup) permanently destroyed a working grant.

The fix reads the response BODY (`ClaudeOAuthClient.TokenEndpointError`, via
`HTTPClient.postRaw`/`sendRaw`, additive — `send` and every other caller are
unchanged) and marks dead ONLY when the body's `error` field is, normalised,
exactly `invalid_grant` — the RFC 6749 §5.2 shape, and the exact string proven
live (see "What forced it"). Every other outcome of the refresh call — a 401,
a network failure, a 429, a 5xx, or a 400 that is NOT `invalid_grant` (a
retired/rotated `client_id` returns `400 {"error":"invalid_client"}` per the
same RFC section, which is also permanent but is not a dead REFRESH TOKEN) —
is treated as transient in the sense that it is not proven-dead. But
"transient" must not mean "retried every tick forever with no backoff", which
is the SAME failure shape one error class narrower. `PulseOAuthStore` bounds
this separately: `consecutiveRefreshFailures` counts non-`invalid_grant`
refresh failures per account, resets on any successful refresh call, and once
it passes `maxConsecutiveRefreshFailures` (3), `credentials(forAccountUUID:)`
stops attempting a rotation for that account for the rest of the run — no
Keychain deletion, no `deadGrants` entry, because the failure was never proven
permanent, only proven not worth asking about again this run.

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

**Coalescing alone is not sufficient (R2-S3, review round 2).** The in-flight
entry is removed as soon as its `Task` completes. A caller that read a
pre-rotation `current` BEFORE a winner started, but only reaches `rotate`
AFTER the winner's entry is already cleared, is SEQUENTIAL, not concurrent —
invisible to the in-flight dictionary. That caller would resend the
already-spent refresh token, get `invalid_grant`, and — after the dead-grant
fix above — delete the Keychain items holding the pair the winner had just
promoted: a burned-grant bug turned into a working-grant DELETION. Closed with
the repo's own fingerprint-not-token pattern (`PiAccountResolver.fingerprint`,
reused rather than re-implemented): `spentRefreshFingerprints` records every
refresh token `rotate` has attempted to spend THIS run, checked and inserted
before the network call, so a second attempt with the same token — concurrent
or sequential — is refused before it ever reaches the endpoint.

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
  transient error other than `invalid_grant` on the refresh call itself)
  makes `rotate` THROW rather than return the unverified pair — review round 1
  (2026-09-08) found the first version returned it, which let `ClaudeProvider`
  pin an unverified, possibly-broken credential ahead of a working harness
  token. `credentials(forAccountUUID:)` swallows that throw (`try?`) and keeps
  serving the OLD pair for THAT call. The pair that failed verification stays
  in `-pending`, UNVERIFIED — the next call does NOT trigger a fresh rotation
  (review round 2 found and fixed this: an ~8h-out pending pair never looks
  like it "needs refreshing"). Instead it re-verifies that SAME pending pair
  once before serving it, without spending another refresh token — see
  "Pending is provisional until proven, not just until promoted (R2-B1)"
  above. The old access token remains usable until its own natural expiry
  regardless of what happened to the refresh token, so none of this costs a
  dropped grant, only a deferred promotion.
- A rotation whose refresh call itself fails with `invalid_grant` is the one
  outcome that is NOT retried at all — see "Dead grants are terminal, not
  retried" above. Every OTHER refresh failure (including a `400` that is NOT
  `invalid_grant`) IS retried, up to `maxConsecutiveRefreshFailures` times per
  run — see "Only `invalid_grant` is terminal" above.

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
- Same file, review round 2 additions: a non-`invalid_grant` `400` must NOT
  delete a working grant (`dead-grant-too-broad` defect); an unpromoted
  pending pair must be verified before being served, never served on the
  strength of `expires_at` alone (`serve-unpromoted-pending-unverified`
  defect, scenario 8); and `ClaudeOAuthClient.tokenEndpointError` — the ONE
  function deciding whether a `400` deletes a grant — is exercised DIRECTLY
  (scenario 7, plus a real `swift test` suite in `ClaudeOAuthTests.swift`),
  after review round 2 found the shell harness only ever threw
  already-classified values and so never ran the classifier itself
  (`invalid-grant-match-too-loose` defect).

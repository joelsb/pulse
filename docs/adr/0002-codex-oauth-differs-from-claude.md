# 0002. Codex's OAuth grant differs from Claude's in five ways (one measured, four inferred)

Status: Accepted — 2026-09-08 (JSB-9)

## Decision

`CodexOAuthClient`/`CodexOAuthStore` follow the exact same pending → verify →
promote write order as ADR-0001. What this ADR records is the five places the
wire protocol itself is NOT the same as Anthropic's, none a design preference
— **but review round 1 (2026-09-08) found only claim 1 below is an actual
live MEASUREMENT; claims 2–5 are evidence-based INFERENCES** (a real
token's own claims, the Codex CLI's on-disk shape, and RFC 6749/OIDC's
general rules) that have never themselves been exercised against
`auth.openai.com`. Marked individually below. The first live sign-in must
capture, and this ADR must then be updated with: the granted `scope` (the
token endpoint's response field, if it returns one under that name at all),
the real `refresh_token`'s length, and the body of one real token-endpoint
error (to confirm or correct claim 4's RFC-shaped `invalid_grant` classifier
below, which is currently untested against this provider specifically).

1. **MEASURED. `redirect_uri` is REGISTERED**, exactly `http://localhost:1455/auth/callback`,
   path included — the OPPOSITE of Anthropic, where any loopback port
   worked. Browser-verified: `1455` stays on `/oauth/authorize`; `:53811`
   redirects immediately to `https://auth.openai.com/error?payload=…`,
   which decodes to `{"kind":"AuthApiFailure","errorCode":"unknown_error"}`.
   Port 1455 is also the Codex CLI's own login port, which is why a bind
   failure there gets its own message ("a Codex CLI login is in progress")
   instead of a generic "port busy."
2. **INFERRED, not yet measured.** The token endpoint takes
   `application/x-www-form-urlencoded`, not JSON — `ClaudeOAuthClient.post`
   sends `jsonBody` and cannot be reused unchanged; `HTTPClient.postFormRaw`
   was added alongside `postRaw`, not in place of it, so `postRaw` and every
   existing caller (including `scripts/verify-rate-limit-backoff.sh`, which
   exercises it through `ClaudeOAuthClient`) are unaffected. Inferred from
   OAuth2's RFC 6749 default content type for the token endpoint (§3.2);
   never confirmed against `auth.openai.com` specifically.
3. **INFERRED, not yet measured.** No `state` in the exchange body —
   Anthropic requires it (JSB-8 round 4 cost a live 400 without it);
   OpenAI's exchange body is assumed to be `grant_type, client_id, code,
   code_verifier, redirect_uri` — five fields, no `state` — on the strict
   reading of RFC 6749 §4.1.3, which lists no `state` parameter for the
   token request. Copying Claude's fix across on a hunch would risk 400ing
   every real Codex sign-in the same way omitting it broke Claude's; this is
   the untested, opposite risk. `state` is still validated on the CALLBACK
   — that guard is security-relevant (proves the redirect answers THIS
   listener's own request) and is unchanged, reusing
   `ClaudeOAuthClient.acceptCallback` directly since the check itself is
   provider-agnostic.
4. **PARTLY MEASURED.** `ChatGPT-Account-Id` comes from the `id_token`,
   claim `https://api.openai.com/auth` → `chatgpt_account_id` — never from a
   top-level field. MEASURED on the AUTHORIZE side: this machine's real
   `~/.codex/auth.json` id_token carries exactly that namespaced claim, and
   `id_token_add_organizations=true` on the authorize URL is documented
   OpenAI behaviour for adding it. INFERRED, and materially different, on
   the REFRESH side: `id_token_add_organizations` is an AUTHORIZE-time
   parameter and is never sent on `refresh` (§6's body is `grant_type,
   refresh_token, client_id` only), so whether a refreshed id_token even
   exists, let alone carries the claim, is unmeasured — `CodexOAuthClient`
   and `CodexOAuthStore` now treat both as optional on refresh specifically
   because of this gap (review B1; see `CodexOAuthStore.rotate`'s own doc
   comment).
5. **INFERRED, not yet measured.** No separate `/oauth/profile` call —
   Claude's token response carries no account identity, so
   `ClaudeOAuthClient` makes a second request to learn it. Codex's
   `id_token` is assumed to carry everything Pulse needs (see 4) whenever an
   exchange succeeds, so `CodexOAuthClient` has no profile step at all; this
   has not been confirmed by an exchange response that was actually missing
   the claim.

The same over-claim reached the terminal-failure classifier this ADR's
rotation logic depends on: `CodexOAuthClient.TokenEndpointError` assumes
OpenAI's dead-refresh-token error is the RFC 6749 §5.2 shape
(`400 {"error":"invalid_grant"}`), by analogy with Anthropic's MEASURED
wording (ADR-0001) — the only OpenAI auth failure actually observed on this
machine is `401 token_expired` from `chatgpt.com/backend-api`, a different
service from `auth.openai.com/oauth/token`, so it says nothing about the
token endpoint's error shape. Being wrong here is safe in one direction
(too strict just means a real dead grant gets retried, bounded, instead of
cleared — see review B2) and unverified in the other.

## What forced it

Two independent live falsifications, both 2026-09-08, run before any code
was written for this ticket (see `intent.md`'s `## Constraints`, which this
ADR expands on rather than restates verbatim):

- A real browser round trip against `auth.openai.com/oauth/authorize` with
  `redirect_uri` set to Pulse's OWN candidate port (`:53811`, the same
  "any loopback port works" pattern that held for Anthropic) redirected
  immediately to an error page, before a human ever saw a consent screen.
  Only `:1455` — Codex CLI's own registered port — stayed on the authorize
  flow. `curl` could not be used to settle this (see the next paragraph),
  so it was checked in a real, headed browser.
- The SAME two ports, hit with `curl` instead of a browser, returned
  near-identical 403 Cloudflare challenge pages (7,288 vs 7,312 bytes) —
  proving nothing about which `redirect_uri` OpenAI's authorize endpoint
  actually accepts. `curl` cannot answer a redirect_uri question on this
  provider; only a real browser session can.

## Correction (2026-09-08): the Keychain-write limit id_token hit is on the whole command line, not the secret

Building this ticket, an earlier draft persisted the id_token itself (see
"Consequences" below for why that was wrong on its own terms) and hit a
write failure. The first write-up of that failure, in `CodexOAuthStore`'s
own doc comment and in an earlier version of this ADR, mis-stated the cause
as "a ~4,096-byte cap on the secret value." Re-measured and corrected: the
cap is on the WHOLE composed `security -i` stdin command line
(`add-generic-password -U -a <account> -s <service> -w <base64 secret>`),
not on the base64 payload alone. Two measurements, same short-vs-long
comparison ADR-0001 already uses for the 128-byte cap:

```
short service name:  sent 4000 -> stored 4000   sent 4090 -> stored 4032
                      sent 4095 -> stored 4032   sent 5000 -> stored 4032
service name +105 chars:  sent 3900 -> stored 3900   sent 3950 -> stored 3924
                           sent 4000 -> stored 3924
```

The ceiling moved from 4032 to 3924 - down by 108, matching the longer
name almost exactly. **The secret's usable budget is
`~4096 - len("add-generic-password -U -a <account> -s <service> -w ")`,
so lengthening a Keychain service or account name shrinks the budget a
payload that used to fit needs, silently.** Renaming
`de.byte.pulse.codex-oauth` to something longer, for instance, could
re-truncate a payload that was safely under the wall before the rename -
with no code change to the payload itself.

Fixed at the source, not just documented: `KeychainWriter.write` now
computes the composed line and refuses (`Failure.lineTooLong`) to even
attempt a write that doesn't leave headroom, rather than relying only on
the post-write read-back to notice. **`maxCommandLineLength` (4,000) is a
LINE limit, checked against the whole composed command
(`command.utf8.count`), not a payload limit** (review S5 caught an earlier
draft of this constant's comment stating it the other way, which invites
raising it to 4032 and putting a long-name write back inside the truncation
zone) - see `KeychainWriter`'s own doc comment for the measurements. The
longest line the current code can build, with the real production strings
(`de.byte.pulse.codex-oauth-pending`, the longer of the two services, plus
`codex-primary`, a 1,698-byte access token, a 400-byte refresh token and a
36-byte account id): ~3,074 bytes, 77% of the 4,000 budget - real headroom,
not an illusory one. Guarded by `scripts/verify-codex-oauth-rotation.sh`'s
over-length scenario.

## Why the client id and scope are what they are, not requested fresh

`CodexOAuthClient.clientID` (`app_EMoamEEZ73f0CkXaXp7hrann`) was not
requested from a developer console — Codex CLI logins are installed-app
PKCE with no client secret, so every install shares one public id, and this
one is read directly off this machine's own `~/.codex/auth.json` token
claims (`aud` on the id_token, `client_id` on the access token — both agree).
Same posture as `ClaudeOAuthClient.clientID`'s own doc comment: evidence
from a real, working token, not a value copied from documentation that may
not describe what the endpoint actually enforces.

`CodexOAuthClient.scope` (`openid profile email offline_access`) is
deliberately NARROWER than the full `scp` claim a real Codex CLI token
carries on this machine (`openid profile email offline_access
api.connectors.read api.connectors.invoke`) — the connector-invoking pair
grants access to connected tools, which Pulse (a read-only usage reader) has
no use for and must never be able to invoke. Same principle as
`ClaudeOAuthClient.scope` excluding `org:create_api_key`: least privilege,
not "request everything a working token happens to have." **Whether the
token endpoint silently grants a smaller set than requested here (the same
"a 200 proves less than you think" pattern Anthropic showed,
`ClaudeOAuthClient.scope`'s own doc comment) is UNTESTED** — narrowing this
further needs a real sign-in and reading the response's actual granted
scope, not this file's own assumption. A scope too small fails at the
`wham/usage` verification call, hours after sign-in, and looks exactly like
an expired token.

## Consequences

- `CodexOAuthStore` is a FORK of `PulseOAuthStore`, not a shared generic
  store over both providers — see `impl-codex.md` for the "would a generic
  store actually be smaller" check this decision rests on. The two stores
  duplicate the pending → verify → promote control flow (~120 lines);
  changing that flow (a future ADR-0001 amendment) means editing both files,
  which is the accepted cost of not building a two-provider abstraction on
  a sample size of two.
- `CodexOAuthStore` keys its Keychain items on a FIXED account string
  (`codex-primary`), not a per-account uuid like `PulseOAuthStore` — Codex
  has exactly one Pulse-tracked account today (no `CLAUDE_CONFIG_DIR`-style
  multi-account discovery). Adding real multi-account support later means
  adding a keying dimension here, the same shape `PulseOAuthStore` already
  has for Claude.

## Evidence

- Live browser test, 2026-09-08: `redirect_uri=http://localhost:1455/auth/callback`
  stays on `/oauth/authorize`; `:53811` redirects to
  `https://auth.openai.com/error?payload=…` decoding to
  `{"kind":"AuthApiFailure","errorCode":"unknown_error"}`.
- Same date, `curl` against both ports: near-identical Cloudflare 403
  challenge pages (7,288 vs 7,312 bytes) — proves nothing, hence "browser
  only" above.
- This machine's own `~/.codex/auth.json`, `~/.jcode/openai-auth.json` and
  `~/.pi/agent/auth.json`'s `openai-codex` entry, all for the same account
  (`b6ecc3be-…` / `joelsb2001@gmail.com` / plan `plus`): `client_id`/`aud`
  agree at `app_EMoamEEZ73f0CkXaXp7hrann`; `exp`/`expires`/`expires_at` are
  all epoch values (seconds on the JWT `exp` claim, milliseconds on jcode's
  and pi's own file fields) confirmed by direct inspection.
- `scripts/verify-codex-oauth-rotation.sh`: the same planted-defect shape as
  `scripts/verify-oauth-rotation.sh`, adapted for `CodexOAuthStore`'s
  single-account keying and `CodexOAuthClient`'s form-encoded, no-`state`
  exchange body.

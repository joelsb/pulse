# 0002. Codex's OAuth grant differs from Claude's in five measured ways

Status: Accepted — 2026-09-08 (JSB-9)

## Decision

`CodexOAuthClient`/`CodexOAuthStore` follow the exact same pending → verify →
promote write order as ADR-0001 (unchanged rationale: OpenAI's refresh token
is single-use from Pulse's point of view, same RFC 6749 §5.2 shape). What
this ADR records is the five places the wire protocol itself is NOT the same
as Anthropic's, each measured live on this machine 2026-09-08, none a design
preference:

1. **`redirect_uri` is REGISTERED**, exactly `http://localhost:1455/auth/callback`,
   path included — the OPPOSITE of Anthropic, where any loopback port
   worked. Browser-verified: `1455` stays on `/oauth/authorize`; `:53811`
   redirects immediately to `https://auth.openai.com/error?payload=…`,
   which decodes to `{"kind":"AuthApiFailure","errorCode":"unknown_error"}`.
   Port 1455 is also the Codex CLI's own login port, which is why a bind
   failure there gets its own message ("a Codex CLI login is in progress")
   instead of a generic "port busy."
2. **The token endpoint takes `application/x-www-form-urlencoded`**, not
   JSON — `ClaudeOAuthClient.post` sends `jsonBody` and cannot be reused
   unchanged; `HTTPClient.postFormRaw` was added alongside `postRaw`, not in
   place of it, so `postRaw` and every existing caller (including
   `scripts/verify-rate-limit-backoff.sh`, which exercises it through
   `ClaudeOAuthClient`) are unaffected.
3. **No `state` in the exchange body.** Anthropic requires it (JSB-8 round 4
   cost a live 400 without it); OpenAI's exchange body is `grant_type,
   client_id, code, code_verifier, redirect_uri` — five fields, no `state`.
   Copying Claude's fix across would 400 every real Codex sign-in. `state`
   is still validated on the CALLBACK — that guard is security-relevant
   (proves the redirect answers THIS listener's own request) and is
   unchanged, reusing `ClaudeOAuthClient.acceptCallback` directly since the
   check itself is provider-agnostic.
4. **`ChatGPT-Account-Id` comes from the `id_token`**, claim
   `https://api.openai.com/auth` → `chatgpt_account_id` — never from a
   top-level field. This is what `id_token_add_organizations=true` on the
   authorize URL is for, and it is why `CodexOAuthClient.TokenPair` carries
   an `idToken` (Claude's does not) and `CodexOAuthClient.parseTokenResponse`
   treats a missing `id_token` as a hard parse failure, not an optional
   field.
5. **No separate `/oauth/profile` call.** Claude's token response carries no
   account identity, so `ClaudeOAuthClient` makes a second request to learn
   it. Codex's `id_token` already carries everything Pulse needs (see 4),
   so `CodexOAuthClient` has no profile step at all.

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
the post-write read-back to notice - see that type's own doc comment for
the measurements and the constant (`maxCommandLineLength`, 4,000, with the
headroom Codex's real payload leaves against it). Guarded by
`scripts/verify-codex-oauth-rotation.sh`'s over-length scenario.

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

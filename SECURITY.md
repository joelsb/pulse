# Security Policy

## Reporting a vulnerability

Please report security issues **privately** via GitHub's private vulnerability
reporting: go to the repository's **Security** tab and click **"Report a
vulnerability"**. This opens a private advisory visible only to the maintainers.

Please do **not** open a public issue for security reports.

When you can, include: affected version, the provider(s) involved, reproduction steps,
and impact. Never include real tokens, credentials, or other secrets in a report.

## Supported versions

Pulse is a small, single-maintainer project. Only the **latest release** is supported;
fixes land there and on `main`.

## Response time

Best-effort. We aim to acknowledge a valid report reasonably quickly and to work with
you on a fix, but cannot commit to a fixed SLA.

## Security posture

Pulse is designed to minimize attack surface:

- **Read-only, local credential access.** It reads the credentials each tool already
  stores on your machine and never writes back or rotates them. (Gemini refreshes its
  short-lived access token in memory only.)
- **No servers, no telemetry, no backend.** The app talks **only** to each provider's
  own API — nothing else leaves your machine.
- **No third-party dependencies.**
- **Build from source, ad-hoc signed.** There is no notarized distribution; you build
  the `.app` yourself with `./scripts/build-app.sh`.

### Known caveat: Keychain "Always Allow"

As documented in the README, Pulse reads Claude's `Claude Code-credentials` Keychain
item through Apple's `security` tool so a single approval survives rebuilds. Choosing
**"Always Allow"** grants standing access to that item via the `security` tool; click
**"Allow"** instead for the stricter per-session posture (Pulse asks at most every
5 minutes). This is expected behavior, not a vulnerability.

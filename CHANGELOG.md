# Changelog

## 2026-06-22 v1.2.0

### Signed & notarized
- Byte Pulse is now **code-signed with Apple Developer ID and notarized by
  Apple**, then stapled — so the downloaded `Byte-Pulse.dmg` and the app inside
  launch with **no Gatekeeper warning** (no more right-click → Open). Behavior is
  unchanged; this is purely about trusted distribution.
- `scripts/build-app.sh` gains a `--notarize` flow (Hardened Runtime + secure
  timestamp, inner→outer signing, `notarytool submit` + staple for both the
  `.app` and the `.dmg`); plain dev builds stay ad-hoc and instant. A new
  `.github/workflows/release.yml` signs, notarizes, and publishes the DMG on
  every `v*` tag.

## 2026-06-19 v1.1.0

### Usage Breakdown by project & session (new)
- **Per-project / per-session ("thread") breakdown** for **Claude** and **Codex**
  — a dedicated resizable window grouping your local CLI usage by working
  directory, with drill-down to individual sessions ("which instance used how
  many tokens, and what did it cost"). Open it with **⌘B**, the chart button in
  the panel's bottom bar, or right-click the menu-bar item → *Usage Breakdown…*.
- Tokens for both providers; **$ cost for Claude** (computed from the pricing
  table — Codex is plan-included, so it shows tokens only). Timeframe **7 days /
  30 days / 1 year**, sortable by tokens / cost / recent / name.
- **"Active now"** badge for sessions touched in the last few minutes; the window
  auto-refreshes while it's focused (and pauses when hidden).
- Friendly session names from the CLI's own generated title (Claude's `ai-title`),
  falling back to project + git branch + start time. A Settings toggle
  (**Show session titles**) keeps the breakdown strictly content-blind when off.
- Only Claude & Codex expose a project dimension locally; Cursor, Copilot, and
  Gemini have no per-project data to attribute and are intentionally absent here.
- Architecture: a capability-shaped `ProjectBreakdownProviding` on the local-log
  providers plus an on-demand `ProjectUsageService`, reusing the live refresh's
  warm aggregation cache so the breakdown adds no work to the hot path.

### Also

- Settings → About now reads the version from the bundle, so it can't drift from
  the shipped build.
- Test suite grows to **186 unit tests** (breakdown parsing, project/session
  rollups, the analytics service, persisted preferences, and the demo dataset).

## 2026-06-10 v1.0.1

- New app icon: the Byte "B" mark on the brand acid-orange plate, matching the
  pulse.byte.de site icon (replaces the bar-chart motif). Rendered by
  `scripts/make-icon.swift` onto the standard macOS squircle plate with the
  baked drop shadow; no other changes.

## 2026-06-10 v1.0.0

Initial release of **Byte Pulse** — AI usage for your menu bar.

### Providers (real data only, read-only on your credentials)
- **Claude** — live 5-hour-session & weekly rate-limit gauges (the same endpoint
  Claude Code's `/usage` calls, via the Keychain credentials), per-model weekly
  caps (Opus/Sonnet) when active, plus exact token counts & cost computed from
  the local `~/.claude/projects` logs (streamed-duplicate dedup, 5m/1h cache-write
  pricing split, plan detection "Max 5×" etc.)
- **Codex** — live ChatGPT-account 5h/weekly limits (`wham/usage`) with an
  automatic fallback to the freshest session-log snapshot (expired windows
  dropped, staleness labeled), token history aggregated from `~/.codex/sessions`
  cumulative counters with per-model attribution, plan & credits surfaced
- **Cursor** — plan-usage gauge (modern summary with legacy request-count
  fallback), on-demand spend vs. hard limit, per-model month tokens & cost, and
  paginated 30-day event history; session token read from Cursor's local store
  in immutable mode (a running Cursor is never touched)
- **Copilot** — premium-requests quota, plan, and reset date via the GitHub
  Copilot token from `~/.config/github-copilot`
- **Gemini** — per-model daily quotas + tier via the Code Assist API (Google
  sign-in), token refresh kept strictly in memory

### Menu bar
- Per-provider compact stat blocks (2+1 letter code, threshold-colored dot,
  session % with live numeric ticks, 1-hour trend arrow)
- Only providers active in the last 7 days occupy the bar; dormant/unconnected
  ones keep their tab
- Icon-only mode with the Byte "B" mark (Settings toggle)

### Panel
- Native Tahoe popover chrome (vibrancy material, continuous 20pt corners,
  adaptive hairline), opening on whichever display you click
- Provider tabs with matched-geometry pill; arrow keys / ⌘1–5 switch (reduced
  motion for keyboard, per the motion system)
- Cards: limit gauges with reset countdown ("2h 41m at 15:20") and pace
  (safe/elevated/critical), usage-rate chart (±30%, red = consuming, green =
  rolling off), usage histogram with a clickable timeframe badge
  (1d hourly / 7d / 30d / 1y monthly — per data-source support), token table
  (Today / This Month × Input / Output / Cache / Cost) with model breakdown
- Footer with live "Updated Xs ago", staleness tinting, manual refresh
  (spinner → checkmark); bottom bar: Open <Provider> · Settings · minimize · quit
- Empty/error states per provider; failures degrade to stale data, never a
  blank panel; ESC / click-outside / focus-loss dismissal

### App
- Settings: launch at login, refresh cadence (30s–5m), menu bar style &
  per-provider visibility, provider enable/disable with connection status
- Motion & design system per Emil Kowalski / Jakub Krehel principles
  (docs/DESIGN.md): ≤300ms, exits faster than enters, zero bounce on data,
  Reduce Motion respected throughout
- Swift 6 strict concurrency, zero third-party dependencies, 157 unit tests
- `scripts/build-app.sh --install` builds, signs, and installs `/Applications/Pulse.app`

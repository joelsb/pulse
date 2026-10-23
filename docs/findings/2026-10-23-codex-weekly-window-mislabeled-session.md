# Codex weekly-only limit mislabeled as session

## Symptom

Sanitized live evidence supplied from main checkout: `plan_type: "prolite"`, `primary_window.limit_window_seconds: 604800`, `used_percent: 55`, `reset_after_seconds: 530114`, `secondary_window: null`.
Pulse labeled this seven-day limit `5-Hour Session` instead of `Weekly Limit`.
After correcting mapping, provider also needed to accept a valid secondary-only snapshot rather than throwing `No Codex usage data yet — run a Codex session first.` without token history or adding `No rate-limit data: unavailable` with token history.

## Wrong diagnosis it invites

Expired authentication, missing Codex sessions, stale polling, or a prolite-specific title override.
Payload contains valid usage and duration. Neither authentication changes nor new session activity fixes positional classification.

## Mechanism

`CodexUsageAPI.limitWindows(from:now:)` in CodexUsageAPI.swift (`/Users/joelsbastos/MYNE/Projects/pulse/Sources/Pulse/Providers/Codex/CodexUsageAPI.swift`) unconditionally classified API primary as five-hour and secondary as weekly.
API position is not window identity: prolite can return its only weekly window in primary.
`CodexProvider.fetch()` in CodexProvider.swift (`/Users/joelsbastos/MYNE/Projects/pulse/Sources/Pulse/Providers/Codex/CodexProvider.swift`) is mapper's only production caller. It copied both windows correctly, but availability checks required primary even when secondary was valid.
Without tokens this threw; with tokens it marked limits unavailable, allowing store carry-forward behavior despite valid weekly data.

Caller inspection also covered detail cards, glance-card fallback, menu-bar weekly utilization, snapshot window semantics and store activity. Existing views already render secondary-only gauges. No view changes needed.

## Fix

Fix commit: `1976ac9d660509db80ecfdad3e95bad18b01e6ee`.
Classify known reported durations: `18000` seconds as five-hour, `604800` seconds as weekly, regardless of payload position.
Preserve positional fallback for absent or unrecognized durations, existing reset precedence, utilization and duration.
Both provider availability guards now require primary AND secondary to be absent before rejecting limits.
No plan-name special case, network abstraction change, session parser change or generated changelog edit.

## Proof

Tests in ProviderTests.swift (`/Users/joelsbastos/MYNE/Projects/pulse/Tests/PulseTests/ProviderTests.swift`) use two seams: supplied prolite JSON through decoder and mapper, then secondary-only session-log fallback through `CodexProvider.fetch()` with and without token history.
Fallback fixture has an expired five-hour window and valid weekly window. Expired fake JWT prevents network requests. Temporary files and unique parser cache are deleted in `defer`, with absence assertions.

### Mapper RED, before production edits

```sh
swift test --disable-xctest -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib --filter CodexParsingTests/whamProliteWeekOnlyWindowMapsToWeeklyLimit
```

```text
✘ Test whamProliteWeekOnlyWindowMapsToWeeklyLimit() recorded an issue at ProviderTests.swift:217:9: Expectation failed: (windows.primary → LimitWindow(id: "five_hour", title: "5-Hour Session", systemImage: "clock", utilization: 55.0, resetsAt: Optional(2025-12-12 09:01:54 +0000), windowDuration: Optional(604800.0), periodStart: nil, detail: nil)) == nil
✘ Test whamProliteWeekOnlyWindowMapsToWeeklyLimit() recorded an issue at ProviderTests.swift:218:9: Expectation failed: (windows.secondary?.title → nil) == "Weekly Limit"
```

### Tracer bullet GREEN, before expanding to provider guard

```sh
swift test --disable-xctest -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib --filter CodexParsingTests
```

```text
✔ Test whamProliteWeekOnlyWindowMapsToWeeklyLimit() passed after 0.001 seconds.
✔ Test whamResponseDecodes() passed after 0.001 seconds.
✔ Test run with 6 tests in 1 suite passed after 0.005 seconds.
```

### Provider RED, before guard edits

```sh
swift test --disable-xctest -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib --filter CodexParsingTests/weekOnlyFetchIsAvailable
```

```text
✘ Test weekOnlyFetchIsAvailable(hasTokenHistory:) recorded an issue with 1 argument hasTokenHistory → false at ProviderTests.swift:225:6: Caught error: .dataUnavailable(description: "No Codex usage data yet — run a Codex session first.")
✘ Test weekOnlyFetchIsAvailable(hasTokenHistory:) recorded an issue with 1 argument hasTokenHistory → true at ProviderTests.swift:269:9: Expectation failed: (snapshot.statusNotes → ["No rate-limit data: unavailable"]).isEmpty → false
```

### Targeted GREEN, both fixes

```sh
swift test --disable-xctest -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib --filter CodexParsingTests
```

```text
✔ Test whamProliteWeekOnlyWindowMapsToWeeklyLimit() passed after 0.001 seconds.
✔ Test whamResponseDecodes() passed after 0.001 seconds.
✔ Test weekOnlyFetchIsAvailable(hasTokenHistory:) with 2 test cases passed after 0.034 seconds.
✔ Test run with 7 tests in 1 suite passed after 0.034 seconds.
```

Mapper test asserts literal `primary == nil`, `secondary.title == "Weekly Limit"`, id `weekly`, utilization `55`, duration `604800` and reset epoch `1765530114`.
Traditional plus primary-five-hour/secondary-weekly fixture remains green.

### Full suite GREEN

Machine has CommandLineTools, not Xcode. Bare `swift test` failed with `error: no such module 'Testing'`.
Flags supply installed Testing framework and its runtime. Default-home full run reached all tests but failed two pre-existing canonical-provider-list assertions because local Claude profiles are discovered.
Fresh Foundation home avoids host-account-dependent discovery without editing unrelated tests or real profiles.

Exact command, including temporary-home cleanup:

```sh
set -o pipefail; testHome=$(mktemp -d /tmp/pulse-codex-test-home.XXXXXX); CFFIXED_USER_HOME="$testHome" swift test --disable-xctest -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib > /tmp/pulse-codex-full-test-isolated.log 2>&1; result=$?; tail -n 16 /tmp/pulse-codex-full-test-isolated.log; python3 -c 'import shutil,sys; shutil.rmtree(sys.argv[1])' "$testHome"; exit "$result"
```

```text
✔ Test run with 296 tests in 69 suites passed after 0.247 seconds.
```

Other observed commands and deciding output:

```text
swift build
Build complete! (3.26s)
python3 scripts/check-gauge-direction.py
PASS: all 4 percentage surfaces honour the direction setting
python3 scripts/check-panel-height.py
OK: no measured panel column carries a stretching Spacer (2 files checked)
python3 scripts/check-timeline-animation.py
PASS: 26 view file(s), no animation restarts on every timeline tick
bash scripts/verify-rate-limit-backoff.sh
PASS: clean sources pass and every planted defect is caught
```

No separate lint target configured. CI's three source guards passed. Existing test/linker warnings left untouched.

### Live account and on-screen proof

On 2026-10-23, orchestrator launched branch binary against Joel's real account and observed Codex `Weekly Limit`, `43%` left, `Resets in: 6 days 3h 0m`, and no Codex `5-Hour Session`.
Orchestrator reconciled live endpoint with this UI result. This does not claim OpenAI supplied a five-hour window for this account.
Screenshot evidence: screen-2026-10-23T14-32-53-380Z.png (`/var/folders/rj/56j7gm4d11nghvvwyhl_1ydh0000gn/T/screen-2026-10-23T14-32-53-380Z.png`).
Solo agent also inspected supplied screenshot during finding amendment and confirmed displayed Codex title, value, reset and absence of a Codex session card.

## Status

proven working - solo agent observed RED then GREEN on 2026-10-23, targeted legacy plus new regressions, full 296-test suite with isolated Foundation home, build and CI guards.
Orchestrator observed real-account UI on 2026-10-23 and reconciled live endpoint with `Weekly Limit`, `43%` left, `Resets in: 6 days 3h 0m`, and no Codex `5-Hour Session`.

## Do-not-undo

Do not infer duration from primary/secondary position or special-case `prolite`.
Do not restore primary-only provider availability checks: weekly-only data is valid even without token history.
Keep both regression seams and literal payload values. Keep HTTPClient unchanged and do not expand this fix into session-log format redesign or unrelated environment-dependent test repairs.

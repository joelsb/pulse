## Symptom

Codex, a connected provider with real usage, disappeared from the menu bar
label. `defaults read de.byte.pulse` showed it present in both
`enabledProviders` and `menuBarProviders` - settings correct. Live probe on
2026-09-17: `GET https://chatgpt.com/backend-api/wham/usage` returned
`primary_window.used_percent = 0`, `secondary_window.used_percent = 8`.

## Wrong diagnosis it invites

"Settings dropped the provider" or "the fetch failed and the snapshot is
stale" - both wrong, since settings read back correct and the snapshot had a
live, non-nil `secondary` window with real spend.

## Mechanism

`ProviderRecord.isActiveRecently` (Sources/Pulse/Core/Services/UsageStore.swift)
is the third and only-uninspected gate: `StatusBarLabelView.activeProviders`
filters `settings.visibleMenuBarProviders` through it. The gate checked
`snapshot.primary.utilization > 0` and `snapshot.dailyUsage`, never
`snapshot.secondary`. Codex's 5-hour (primary) window idles to 0% between
sessions while its weekly (secondary) window still holds real spend, so a
connected, spending provider read as dormant and was filtered out of the bar.

## Fix

Commit 5ba98b2: added `if let secondary = snapshot.secondary,
secondary.utilization > 0 { return true }` alongside the existing primary
and dailyUsage checks in `isActiveRecently`. One extra condition, no refactor,
`StatusBarLabelView.swift` untouched.

## Proof

RED (before the fix, production code at parent of 5ba98b2, tests already
added): `swiftpm-testing-helper --filter ProviderRecordActivity` ->
`✘ Test activityCountsSecondaryUtilizationWhenPrimaryIsIdle() recorded an
issue at CoreModelTests.swift:380:9: Expectation failed: ...isActiveRecently
→ false`.

GREEN (after the fix, commit 5ba98b2): same command -> `✔ Test
activityCountsSecondaryUtilizationWhenPrimaryIsIdle() passed after 0.001
seconds`, plus the dormant-provider regression case
(`activityStaysFalseWhenPrimaryAndSecondaryAreBothIdle`) stayed green.

## Status

proven working - observed by this session (solo agent) on 2026-09-17, both
red and green swift-testing runs captured verbatim above, and
`./scripts/build-app.sh --install` rebuilt and reinstalled
`/Applications/Pulse.app` with the fix.

## Do-not-undo

Do not remove the `secondary` check or fold it back into the `primary`
condition (they gate genuinely different windows - 5h vs weekly - and Codex
is proof they go to zero independently). Do not touch the `dailyUsage`
branch or `StatusBarLabelView.swift` for this fix; they were confirmed
in scope but not the cause.

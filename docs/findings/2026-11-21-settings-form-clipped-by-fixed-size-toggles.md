# Settings window cut off on both sides by fixed-size toggles

## Symptom

Pulse Settings (500pt window) showed every section cut off at both the left and right edge, not only the long Accounts rows: "Show" label truncated to "how", "Remaining" radio cut, help text cut mid-word.
Measured on the real window through System Events: window `645, 140, 500, 652`, its scroll area `523, 172, 744, 620`, so the Form was 744pt wide, starting 122pt left of the window.

## Wrong diagnosis it invites

"One row is too long, make the window wider" or "the window is 420 and the view 500". The window really is 500pt (NSHostingController sizes it from the view). Widening only moves the threshold: the Form takes the widest row's ideal width, whatever the window.

## Mechanism

`Sources/Pulse/UI/Settings/AccountsSection.swift`, `AccountRowView`: `Toggle("Panel", ...).fixedSize()` and `Toggle("Menu icon", ...).fixedSize()`, added so "Menu icon" would not wrap.
In a macOS grouped `Form`, a switch toggle lays out as a full-width row (label leading, switch trailing). `.fixedSize()` pins it to that ideal width, the row can no longer shrink, and the Form's scroll view becomes wider than the window and is centered, which clips every section.
Bisected in a test host at 500pt: plain Form 500; one row with the two fixed toggles 744; the same toggles without `.fixedSize()` 500; label-hidden toggles with their own text 500.

## Fix

Commit `4e95e3f`: switches are `Toggle(title, isOn:).labelsHidden()` plus a `Text(title)` in a fixed-size HStack; the switch and button line uses `ViewThatFits` to wrap onto two lines; account names are one line, truncated.

## Proof

- Test `SettingsGeometryTests.accountRowsFitTheSettingsWindow` (NSHostingController in an NSWindow at `SettingsView.width`), failing case: `Expectation failed: (frame.minX → -122.0) >= -0.5` and `(frame.width → 744.0) <= (SettingsView.width + 0.5 → 500.5)`. Passing case: `✔ Test run with 1 test in 1 suite passed`.
- Real window, isolated (`HOME` and `CFFIXED_USER_HOME` in a temp folder, so no login keychain and no live defaults; process renamed `PulseE2E` beside the installed Pulse), launched with `--show-settings`, seeded with three connected accounts including a 54-character email and a long custom name: before `645, 140, 500, 652, 523, 172, 744, 620`; after `645, 140, 500, 652, 645, 172, 500, 620`. Screens at scroll 0, 0.15, 0.30, 0.62 and 1.0 show every section, switch and button inside the window, down to About.

## Status

Fixed and observed in the real window by the implementing agent on 2026-11-21. Not yet seen by Joel in his installed build.

## Do not undo

Never put `.fixedSize()` on a `Toggle` inside a grouped `Form`, and never fix a clipped Settings window by widening it. Keep `SettingsGeometryTests` passing.

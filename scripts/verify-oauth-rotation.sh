#!/usr/bin/env bash
# Standalone verifier for PulseOAuthStore's refresh-token rotation write order
# (docs/adr/0001-refresh-token-rotation-write-order.md).
#
# WHY THIS EXISTS: Anthropic's refresh token is strictly rotating — reusing
# one after it has been exchanged returns 400 invalid_grant, proven live
# 2026-09-08. A wrong write order here is silent and permanent: nothing
# crashes, nothing errors at the time, the account just quietly loses its
# Pulse-owned grant the next time a crash lands between two writes, and the
# only symptom days later is a forced re-sign-in. That is exactly the shape
# scripts/verify-rate-limit-backoff.sh exists for on the 429 side of this
# codebase, so this gets the same treatment: plant the defect, require it
# caught.
#
# Review round 1 (2026-09-08) found that the FIRST version of this verifier
# discarded the one return value (`_ = await store.credentials(...)`) that
# would have caught B2 - a rotation that fails verification handing out the
# unverified pair anyway - so all four original planted defects passed while
# that property was completely unguarded. This version asserts the return
# value, and adds two more defects (a regressed B2 fix, a regressed B1 dead-
# grant fix) that only that assertion and the new dead-grant scenario can see.
#
# Review round 2 (2026-09-08) found the round-1 B1 fix itself too broad: it
# marked a grant dead on ANY 400 from the refresh call, when the only real
# "permanently dead" signal is a 400 whose body's `error` field is exactly
# `invalid_grant`. Fixed in `ClaudeOAuthClient.TokenEndpointError`; this file
# adds scenario 6 (a non-invalid_grant 400 must NOT delete a working grant)
# and the `dead-grant-too-broad` defect to guard the distinction going
# forward.
#
# The SAME round found two more gaps: (1) the round-1 B2 fix only protected
# the one tick that ran a failed rotation - the very next call would find the
# unverified pair sitting in `-pending` looking FRESHER than primary and
# serve it, unverified, for its whole ~8h life. Fixed by treating an
# "unpromoted pending" pair (fresher than primary, different content) as
# provisional: verified once before being served, promoted on success,
# refused on failure. Scenario 8 and the `serve-unpromoted-pending-unverified`
# defect guard it. (2) `ClaudeOAuthClient.tokenEndpointError` - the ONE
# function deciding whether a 400 deletes a grant - had NO test anywhere;
# scenarios 5/6 only exercised its CALLERS with already-classified values.
# Scenario 7 calls the real static function directly, and the
# `invalid-grant-match-too-loose` defect guards the string comparison itself.
#
# Round 4 (2026-09-08): the human's FIRST real sign-in 400'd. Every scenario
# above exercises `refresh` (rotation); NONE ever built an `authorization_code`
# exchange body - the exact path a real sign-in takes. That body was missing
# `state`, which this endpoint requires despite RFC 6749 not listing it there
# (proven twice: pi's own bundle, and this file's own live falsification run,
# both send it and both 200). Scenario 9 calls the real, pure
# `exchangeRequestBody` function directly; `missing-state-in-exchange` guards
# it. Also added: scenario 10 (R2-S1's bounded-retry cap, previously
# time-boxed) and scenario 11 (R2-S3's concurrent-rotation invariant,
# likewise) - writing scenario 10 surfaced a real interaction bug between
# R2-S1 and R2-S3 (the fingerprint guard was blocking R2-S1's own legitimate
# retries), fixed in the same commit; see `PulseOAuthStore.rotate`'s comment
# on `spentRefreshFingerprints.insert`.
#
# Round 5 (2026-09-08): the OAuth round trip now SUCCEEDS (round 4's fix
# held), but sign-in still failed - this time at the Keychain write.
# `security add-generic-password -w` (no trailing value, two-copy stdin
# prompt) - the write path EVERY scenario above used since scenario 1 -
# silently caps the stored value at exactly 128 bytes, exit 0 regardless.
# Every prior scenario used short fake tokens ("NEW-AT-1") that never came
# near the cap, so all 11 passed while the real ~350-byte JSON payload (or a
# 1,698-byte Codex access token) truncated silently. Fixed by moving the
# write to `security -i` (interactive mode, no length cap) with the payload
# base64-encoded (that mode's own parser word-splits on whitespace
# otherwise, and every real scope string contains a space). Scenario 12 uses
# a realistic-length payload (1,698-byte access token, the real production
# scope string) through the real write/read/decode path; the
# `no-base64-encoding-on-write` defect guards the encoding step itself.
#
# This runs against the REAL Keychain, using scratch account names
# (`harness-scratch-...`) that are never read by production code and are
# deleted at the end of every run, pass or fail.
#
# `swift test` cannot run on this machine (no Xcode: `error: no such module
# 'Testing'`). CI runs the real suite; this compiles the real sources with
# swiftc and asserts against them.
#
# Usage: bash scripts/verify-oauth-rotation.sh
set -euo pipefail

cd "$(dirname "$0")/.."
REPO="$PWD"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/pulse-oauth-rotation-verify.XXXXXX")"

SCRATCH_ACCOUNTS_FILE="$WORK/scratch-accounts.txt"
: > "$SCRATCH_ACCOUNTS_FILE"

cleanup() {
  # Delete every Keychain item any run (clean or defect) created, regardless
  # of pass/fail. `security delete-generic-password` on a name that was never
  # created (a defect that never got as far as writing it) exits non-zero,
  # which is expected and silenced — there is nothing to clean up in that case.
  if [ -s "$SCRATCH_ACCOUNTS_FILE" ]; then
    while IFS= read -r account; do
      [ -n "$account" ] || continue
      security delete-generic-password -s de.byte.pulse.oauth -a "$account" >/dev/null 2>&1 || true
      security delete-generic-password -s de.byte.pulse.oauth-pending -a "$account" >/dev/null 2>&1 || true
    done < "$SCRATCH_ACCOUNTS_FILE"
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

SOURCES=(
  "Sources/Pulse/Core/Models/ProviderFetchError.swift"
  "Sources/Pulse/Core/Models/LimitWindow.swift"
  "Sources/Pulse/Core/Services/HTTPClient.swift"
  "Sources/Pulse/Core/Services/Formatters.swift"
  "Sources/Pulse/Core/Services/KeychainReader.swift"
  "Sources/Pulse/Core/Services/KeychainWriter.swift"
  "Sources/Pulse/Core/Services/AppPaths.swift"
  "Sources/Pulse/Providers/Claude/ClaudeOAuthClient.swift"
  "Sources/Pulse/Providers/Claude/ClaudeUsageAPI.swift"
  "Sources/Pulse/Providers/Claude/PulseOAuthStore.swift"
  "Sources/Pulse/Providers/Pi/PiAccountResolver.swift"
)
HARNESS="scripts/oauth-rotation-harness.swift"

MISSING=0
for source in "${SOURCES[@]}" "$HARNESS"; do
  if [ ! -f "$REPO/$source" ]; then
    echo "MISSING SOURCE: $source"
    MISSING=1
  fi
done
[ "$MISSING" -eq 0 ] || { echo "FAIL: source list is stale"; exit 1; }

# Exact-string replacement that FAILS LOUDLY when the anchor is gone. A
# planted defect that silently no-ops would leave the clean code running and
# report a false "caught".
swap() {
  local file="$1" from="$2" to="$3"
  FROM="$from" TO="$to" /usr/bin/python3 -c '
import os, sys
path = sys.argv[1]
text = open(path).read()
frm, to = os.environ["FROM"], os.environ["TO"]
if frm not in text:
    sys.exit("defect anchor not found in %s: %r" % (path, frm))
open(path, "w").write(text.replace(frm, to, 1))
' "$file"
}

run_case() {
  # $1 = label, $2 = defect name ("" for the clean run)
  local label="$1" defect="${2:-}"
  local dir="$WORK/${defect:-clean}"
  rm -rf "$dir"; mkdir -p "$dir"

  local files=()
  for source in "${SOURCES[@]}"; do
    local dest="$dir/$(basename "$source")"
    cp "$REPO/$source" "$dest"
    files+=("$dest")
  done
  # The harness is top-level code, which swiftc only accepts in `main.swift`.
  cp "$REPO/$HARNESS" "$dir/main.swift"
  files+=("$dir/main.swift")

  case "$defect" in
    "")
      ;;
    primary-first)
      # Writes the primary item unconditionally, ignoring verification, and
      # writes -pending only after - the exact inversion the ADR forbids.
      swap "$dir/PulseOAuthStore.swift" \
'        try await persist(rotated, accountUUID: accountUUID, service: Self.pendingService)

        guard await verifies(rotated) else {' \
'        try await persist(rotated, accountUUID: accountUUID, service: Self.service)
        _ = await verifies(rotated)
        try await persist(rotated, accountUUID: accountUUID, service: Self.pendingService)
        if false {'
      ;;
    skip-verification)
      # Verification result is computed but never gates the promotion.
      swap "$dir/PulseOAuthStore.swift" \
        'guard await verifies(rotated) else {' \
        'guard true else {'
      ;;
    no-pending-persist)
      # The pending write is dropped entirely - a crash right after the
      # refresh call has nothing durable to recover from.
      swap "$dir/PulseOAuthStore.swift" \
'        try await persist(rotated, accountUUID: accountUUID, service: Self.pendingService)

        guard await verifies(rotated) else {' \
'        guard await verifies(rotated) else {'
      ;;
    pending-not-preferred)
      # Reads pick the STALER item instead of the freshest one - the exact
      # inversion of what read() must do.
      swap "$dir/PulseOAuthStore.swift" \
'            if pending.expiresAt >= primary.expiresAt {
                return (pending, pending.accessToken != primary.accessToken)
            }
            return (primary, false)' \
'            if pending.expiresAt >= primary.expiresAt {
                return (primary, false)
            }
            return (pending, pending.accessToken != primary.accessToken)'
      ;;
    serve-unpromoted-pending-unverified)
      # R2-B1 regression: an unpromoted pending pair (fresher than primary,
      # never proven to work) is served without verifying it first - the
      # exact bug scenario 8 exists to catch.
      swap "$dir/PulseOAuthStore.swift" \
'        if picked.isUnpromotedPending {
            guard await verifies(current) else { return nil }' \
'        if picked.isUnpromotedPending {
            _ = await verifies(current)'
      ;;
    invalid-grant-match-too-loose)
      # R2-B2 regression: any non-empty error field classifies as
      # invalid_grant, not just the exact spec string - round 2's original
      # bug restored (any 400 with any error field deletes the grant).
      swap "$dir/ClaudeOAuthClient.swift" \
        'errorField.trimmingCharacters(in: .whitespaces).lowercased() == "invalid_grant"' \
        '!errorField.isEmpty'
      ;;
    missing-state-in-exchange)
      # Round 4 regression: the human's FIRST real sign-in 400'd because
      # `state` was missing from the code-exchange body - RFC 6749 doesn't
      # require it here, but this endpoint does, proven live twice (pi's
      # bundle, this file's own falsification run). Removing it silently
      # breaks every real sign-in with no explanation in the response.
      swap "$dir/ClaudeOAuthClient.swift" \
'            "code": code,
            "state": state,
            "client_id": clientID,' \
'            "code": code,
            "client_id": clientID,'
      ;;
    no-base64-encoding-on-write)
      # Round 5 regression: sends the raw secret straight into `security -i`'s
      # command line instead of base64-encoding it first. Breaks two ways at
      # once, both measured live: `-i`'s own parser word-splits on
      # whitespace, so any payload with a space (every real scope string has
      # one) truncates at the first one; and this is also the shape of "someone
      # simplifies away the encoding layer thinking it's unneeded overhead".
      swap "$dir/KeychainWriter.swift" \
        'let command = "add-generic-password -U -a \(account) -s \(service) -w \(Self.encode(secret))\n"' \
        'let command = "add-generic-password -U -a \(account) -s \(service) -w \(secret)\n"'
      ;;
    return-unverified-pair)
      # B2 regression: hands the caller a pair that failed verification,
      # instead of keeping it durable in -pending and throwing so the caller
      # keeps the old, still-valid one.
      swap "$dir/PulseOAuthStore.swift" \
        'throw ProviderFetchError.dataUnavailable(description: "rotated pair failed verification")' \
        'return rotated'
      ;;
    no-dead-grant-detection)
      # B1 regression: a 400 invalid_grant is never marked or cleared, so a
      # dead grant is retried forever - the exact self-renewing-penalty shape
      # this whole feature exists to end.
      swap "$dir/PulseOAuthStore.swift" \
        'if Self.isDeadGrantError(error) {' \
        'if false {'
      ;;
    dead-grant-too-broad)
      # Review round 2 regression: marks ANY TokenEndpointError dead, not just
      # invalid_grant specifically - the exact bug the round-2 fix corrected
      # (a working grant destroyed by an unrelated 400).
      swap "$dir/PulseOAuthStore.swift" \
        '(error as? ClaudeOAuthClient.TokenEndpointError)?.isPermanentlyDead ?? false' \
        '(error as? ClaudeOAuthClient.TokenEndpointError) != nil'
      ;;
    *)
      echo "unknown defect: $defect"; exit 1
      ;;
  esac

  local binary="$dir/harness"
  if ! swiftc -swift-version 6 -o "$binary" "${files[@]}" > "$dir/compile.log" 2>&1; then
    if [ -z "$defect" ]; then
      echo "FAIL: clean build did not compile"
      tail -30 "$dir/compile.log"
      exit 1
    fi
    echo "  caught (did not compile): $label"
    return 0
  fi

  set +e
  local output
  output="$("$binary" 2>&1)"
  local status=$?
  set -e

  # Every SCRATCH_ACCOUNT line this run printed goes into the cleanup list,
  # regardless of pass/fail.
  echo "$output" | grep '^SCRATCH_ACCOUNT ' | awk '{print $2}' >> "$SCRATCH_ACCOUNTS_FILE"
  local result
  result="$(echo "$output" | grep -v '^SCRATCH_ACCOUNT ')"

  if [ -z "$defect" ]; then
    if [ "$status" -ne 0 ] || [ "$result" != "ALL PASS" ]; then
      echo "FAIL: clean run did not pass"
      echo "$result"
      exit 1
    fi
    echo "  clean run: ALL PASS"
    return 0
  fi

  if [ "$status" -eq 0 ]; then
    echo "NOT CAUGHT: $label"
    echo "    the harness passed with this defect planted - it does not test what it claims"
    return 1
  fi
  echo "  caught: $label"
  echo "$result" | sed 's/^/      /' | head -4
  return 0
}

echo "Byte Pulse - OAuth rotation write-order verifier"
echo
echo "clean sources:"
run_case "clean" ""
echo
echo "planted defects (each MUST be caught):"

UNCAUGHT=0
run_case "primary written before verification, pending after"   primary-first            || UNCAUGHT=$((UNCAUGHT + 1))
run_case "verification computed but not enforced"               skip-verification        || UNCAUGHT=$((UNCAUGHT + 1))
run_case "pending write dropped entirely"                        no-pending-persist       || UNCAUGHT=$((UNCAUGHT + 1))
run_case "read prefers the staler item over the fresher one"     pending-not-preferred    || UNCAUGHT=$((UNCAUGHT + 1))
run_case "B2 regressed: unverified pair returned to the caller"  return-unverified-pair   || UNCAUGHT=$((UNCAUGHT + 1))
run_case "B1 regressed: a dead grant is never marked or cleared" no-dead-grant-detection  || UNCAUGHT=$((UNCAUGHT + 1))
run_case "B1 too broad: any 400 marked dead, not just invalid_grant" dead-grant-too-broad  || UNCAUGHT=$((UNCAUGHT + 1))
run_case "R2-B1 regressed: unpromoted pending served without verifying" serve-unpromoted-pending-unverified || UNCAUGHT=$((UNCAUGHT + 1))
run_case "R2-B2 regressed: invalid_grant match loosened to any error"   invalid-grant-match-too-loose      || UNCAUGHT=$((UNCAUGHT + 1))
run_case "round 4 regressed: state missing from the exchange body"      missing-state-in-exchange          || UNCAUGHT=$((UNCAUGHT + 1))
run_case "round 5 regressed: raw (unencoded) secret sent to security -i" no-base64-encoding-on-write        || UNCAUGHT=$((UNCAUGHT + 1))

echo
if [ "$UNCAUGHT" -ne 0 ]; then
  echo "FAIL: $UNCAUGHT planted defect(s) went undetected"
  exit 1
fi
echo "PASS: clean sources pass and every planted defect is caught"

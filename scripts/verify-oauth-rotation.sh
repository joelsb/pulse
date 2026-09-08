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
  "Sources/Pulse/Providers/Claude/ClaudeOAuthClient.swift"
  "Sources/Pulse/Providers/Claude/ClaudeUsageAPI.swift"
  "Sources/Pulse/Providers/Claude/PulseOAuthStore.swift"
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
        'return pending.expiresAt >= primary.expiresAt ? pending : primary' \
        'return pending.expiresAt >= primary.expiresAt ? primary : pending'
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

echo
if [ "$UNCAUGHT" -ne 0 ]; then
  echo "FAIL: $UNCAUGHT planted defect(s) went undetected"
  exit 1
fi
echo "PASS: clean sources pass and every planted defect is caught"

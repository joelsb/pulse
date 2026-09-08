#!/usr/bin/env bash
# Standalone verifier for CodexOAuthStore's refresh-token rotation write order
# (docs/adr/0001-refresh-token-rotation-write-order.md,
# docs/adr/0002-codex-oauth-differs-from-claude.md). Same shape and same
# reasoning as scripts/verify-oauth-rotation.sh (Claude/JSB-8) - see that
# file's own header for why this class of bug is silent and permanent.
#
# JSB-9. Runs against the REAL Keychain using scratch account names
# (`harness-scratch-codex-...`) that are never read by production code
# (which uses the fixed `codex-primary` account) and are deleted at the end
# of every run, pass or fail.
#
# `swift test` cannot run on this machine (no Xcode). CI runs the real
# suite; this compiles the real sources with swiftc and asserts against them.
#
# Usage: bash scripts/verify-codex-oauth-rotation.sh
set -euo pipefail

cd "$(dirname "$0")/.."
REPO="$PWD"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/pulse-codex-oauth-rotation-verify.XXXXXX")"

SCRATCH_ACCOUNTS_FILE="$WORK/scratch-accounts.txt"
: > "$SCRATCH_ACCOUNTS_FILE"

cleanup() {
  if [ -s "$SCRATCH_ACCOUNTS_FILE" ]; then
    while IFS= read -r account; do
      [ -n "$account" ] || continue
      security delete-generic-password -s de.byte.pulse.codex-oauth -a "$account" >/dev/null 2>&1 || true
      security delete-generic-password -s de.byte.pulse.codex-oauth-pending -a "$account" >/dev/null 2>&1 || true
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
  "Sources/Pulse/Core/Services/JWT.swift"
  "Sources/Pulse/Core/Services/AppPaths.swift"
  "Sources/Pulse/Providers/Claude/ClaudeOAuthClient.swift"
  "Sources/Pulse/Providers/Codex/CodexOAuthClient.swift"
  "Sources/Pulse/Providers/Codex/CodexOAuthStore.swift"
  "Sources/Pulse/Providers/Codex/CodexUsageAPI.swift"
  "Sources/Pulse/Providers/Codex/CodexAuth.swift"
  "Sources/Pulse/Providers/Pi/PiAccountResolver.swift"
)
HARNESS="scripts/codex-oauth-rotation-harness.swift"

MISSING=0
for source in "${SOURCES[@]}" "$HARNESS"; do
  if [ ! -f "$REPO/$source" ]; then
    echo "MISSING SOURCE: $source"
    MISSING=1
  fi
done
[ "$MISSING" -eq 0 ] || { echo "FAIL: source list is stale"; exit 1; }

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
  local label="$1" defect="${2:-}"
  local dir="$WORK/${defect:-clean}"
  rm -rf "$dir"; mkdir -p "$dir"

  local files=()
  for source in "${SOURCES[@]}"; do
    local dest="$dir/$(basename "$source")"
    cp "$REPO/$source" "$dest"
    files+=("$dest")
  done
  cp "$REPO/$HARNESS" "$dir/main.swift"
  files+=("$dir/main.swift")

  case "$defect" in
    "")
      ;;
    primary-first)
      swap "$dir/CodexOAuthStore.swift" \
'        try await persist(rotated, service: Self.pendingService)

        guard await verifies(rotated) else {' \
'        try await persist(rotated, service: Self.service)
        _ = await verifies(rotated)
        try await persist(rotated, service: Self.pendingService)
        if false {'
      ;;
    skip-verification)
      swap "$dir/CodexOAuthStore.swift" \
        'guard await verifies(rotated) else {' \
        'guard true else {'
      ;;
    no-pending-persist)
      swap "$dir/CodexOAuthStore.swift" \
'        try await persist(rotated, service: Self.pendingService)

        guard await verifies(rotated) else {' \
'        guard await verifies(rotated) else {'
      ;;
    pending-not-preferred)
      swap "$dir/CodexOAuthStore.swift" \
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
      swap "$dir/CodexOAuthStore.swift" \
'        if picked.isUnpromotedPending {
            guard await verifies(current) else { return nil }' \
'        if picked.isUnpromotedPending {
            _ = await verifies(current)'
      ;;
    invalid-grant-match-too-loose)
      swap "$dir/CodexOAuthClient.swift" \
        'errorField.trimmingCharacters(in: .whitespaces).lowercased() == "invalid_grant"' \
        '!errorField.isEmpty'
      ;;
    state-added-to-exchange)
      # Codex's own regression risk, the OPPOSITE of Claude's round-4 bug:
      # copying Claude's "add state" fix across breaks every real Codex
      # sign-in (constraint 3 - OpenAI's exchange body has no state field).
      swap "$dir/CodexOAuthClient.swift" \
'        [
            "grant_type": "authorization_code",
            "client_id": clientID,
            "code": code,
            "code_verifier": verifier,
            "redirect_uri": redirectURI,
        ]' \
'        [
            "grant_type": "authorization_code",
            "client_id": clientID,
            "code": code,
            "state": "should-not-be-here",
            "code_verifier": verifier,
            "redirect_uri": redirectURI,
        ]'
      ;;
    no-base64-encoding-on-write)
      swap "$dir/KeychainWriter.swift" \
        'let command = "add-generic-password -U -a \(account) -s \(service) -w \(Self.encode(secret))\n"' \
        'let command = "add-generic-password -U -a \(account) -s \(service) -w \(secret)\n"'
      ;;
    no-line-length-guard)
      # The proactive guard is removed - a write whose composed command line
      # exceeds the measured budget is attempted anyway instead of refused
      # up front. Scenario 14 specifically checks for `.lineTooLong`, so this
      # is caught even though the write itself would likely still fail the
      # existing read-back verification eventually (a slower, less specific
      # failure this guard exists to shortcut).
      swap "$dir/KeychainWriter.swift" \
'        guard command.utf8.count <= Self.maxCommandLineLength else {
            throw Failure.lineTooLong(length: command.utf8.count, limit: Self.maxCommandLineLength)
        }' \
'        if false {
            throw Failure.lineTooLong(length: command.utf8.count, limit: Self.maxCommandLineLength)
        }'
      ;;
    return-unverified-pair)
      swap "$dir/CodexOAuthStore.swift" \
        'throw ProviderFetchError.dataUnavailable(description: "rotated pair failed verification")' \
        'return rotated'
      ;;
    no-dead-grant-detection)
      swap "$dir/CodexOAuthStore.swift" \
        'if Self.isDeadGrantError(error) {' \
        'if false {'
      ;;
    dead-grant-too-broad)
      swap "$dir/CodexOAuthStore.swift" \
        '(error as? CodexOAuthClient.TokenEndpointError)?.isPermanentlyDead ?? false' \
        '(error as? CodexOAuthClient.TokenEndpointError) != nil'
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

echo "Byte Pulse - Codex OAuth rotation write-order verifier"
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
run_case "unverified pair returned to the caller"                return-unverified-pair   || UNCAUGHT=$((UNCAUGHT + 1))
run_case "a dead grant is never marked or cleared"                no-dead-grant-detection  || UNCAUGHT=$((UNCAUGHT + 1))
run_case "any 400 marked dead, not just invalid_grant"            dead-grant-too-broad     || UNCAUGHT=$((UNCAUGHT + 1))
run_case "unpromoted pending served without verifying"            serve-unpromoted-pending-unverified || UNCAUGHT=$((UNCAUGHT + 1))
run_case "invalid_grant match loosened to any error"              invalid-grant-match-too-loose       || UNCAUGHT=$((UNCAUGHT + 1))
run_case "constraint 3 regressed: state added to the exchange body" state-added-to-exchange            || UNCAUGHT=$((UNCAUGHT + 1))
run_case "raw (unencoded) secret sent to security -i"              no-base64-encoding-on-write         || UNCAUGHT=$((UNCAUGHT + 1))
run_case "proactive line-length guard removed"                     no-line-length-guard                || UNCAUGHT=$((UNCAUGHT + 1))

echo
if [ "$UNCAUGHT" -ne 0 ]; then
  echo "FAIL: $UNCAUGHT planted defect(s) went undetected"
  exit 1
fi
echo "PASS: clean sources pass and every planted defect is caught"

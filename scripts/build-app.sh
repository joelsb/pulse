#!/usr/bin/env bash
#
# build-app.sh — builds the distributable Byte Pulse app bundle (dist/Pulse.app).
#
# Usage:
#   ./scripts/build-app.sh            build dist/Pulse.app (ad-hoc signed)
#   ./scripts/build-app.sh --install  build + install to /Applications/Pulse.app
#   ./scripts/build-app.sh --run      build + open dist/Pulse.app
#   ./scripts/build-app.sh --package  build + create dist/Byte-Pulse.dmg (release asset)
#   ./scripts/build-app.sh --notarize build + notarize + staple the .app and .dmg
#                                      (implies --package; needs a Developer ID)
#
# Environment overrides:
#   SIGN_IDENTITY   codesign identity. Default "-" (ad-hoc, for local dev). For a
#                   release set a Developer ID, e.g.
#                     SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID1234)"
#                   With a real identity the code is signed with Hardened Runtime
#                   (--options runtime) and a secure timestamp — required to notarize.
#                   Find yours with: security find-identity -v -p codesigning
#   NOTARY_PROFILE  notarytool keychain profile used by --notarize (default BYTE_NOTARY).
#                   Create it once with an App Store Connect API key:
#                     xcrun notarytool store-credentials BYTE_NOTARY \
#                       --key AuthKey_KEYID.p8 --key-id KEYID --issuer ISSUER-UUID
#   SWIFT_BUILD_FLAGS   extra flags appended to `swift build` (e.g. "--arch arm64")
#   BINARY_OVERRIDE     path to a prebuilt executable; skips `swift build`
#                       entirely (for CI / packaging tests only)
#
# Pipeline: swift build → assemble bundle → Info.plist + PkgInfo → icon
# (cached render via scripts/make-icon.swift) → codesign LAST, inner→outer
# (adding files after signing breaks the seal — docs/RESEARCH/swiftui-macos26.md §6)
# → [--notarize] notarytool submit + staple the .app, then the .dmg.

set -euo pipefail

APP_NAME="Pulse"
BUNDLE_ID="de.byte.pulse"
VERSION="1.3.0"
BUILD="6"
MIN_OS="26.0"

# ---------------------------------------------------------------- pretty output

if [ -t 1 ]; then
    GREEN=$'\033[32m'; RED=$'\033[31m'; DIM=$'\033[2m'; BOLD=$'\033[1m'; RESET=$'\033[0m'
else
    GREEN=""; RED=""; DIM=""; BOLD=""; RESET=""
fi
step() { printf '%s→ %s%s\n' "$DIM" "$*" "$RESET"; }
ok()   { printf '%s✓%s %s\n' "$GREEN" "$RESET" "$*"; }
die()  { printf '%s✗ error:%s %s\n' "$RED" "$RESET" "$*" >&2; exit 1; }

on_exit() {
    rc=$?
    if [ "$rc" -ne 0 ]; then
        printf '%s✗ build failed (exit %d)%s\n' "$RED" "$rc" "$RESET" >&2
    fi
    exit "$rc"
}
trap on_exit EXIT

# ---------------------------------------------------------------- signing config

# "-" means ad-hoc (default). A Developer ID switches on Hardened Runtime + a
# secure timestamp so the result is notarization-eligible. SWIFT_BUILD_FLAGS-style
# word-splitting on CODESIGN_OPTS is intentional (flags carry no spaces).
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
NOTARY_PROFILE="${NOTARY_PROFILE:-BYTE_NOTARY}"
if [ "$SIGN_IDENTITY" = "-" ]; then
    SIGN_LABEL="ad-hoc"
    CODESIGN_OPTS=""
else
    SIGN_LABEL="$SIGN_IDENTITY"
    CODESIGN_OPTS="--options runtime --timestamp"
fi

# Sign one path with the configured identity/options.
sign_path() {
    # shellcheck disable=SC2086
    codesign --force $CODESIGN_OPTS --sign "$SIGN_IDENTITY" "$1"
}

# Submit a container (.zip/.dmg) to the notary service, wait, then staple the
# ticket onto a target (the .app or the .dmg — you cannot staple a .zip).
notarize_container() {  # notarize_container <submit-target> <staple-target>
    step "notarytool submit ${1#"$REPO_ROOT"/}  (profile: ${NOTARY_PROFILE})"
    if ! xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait; then
        die "notarization failed — inspect with: xcrun notarytool log <submission-id> --keychain-profile ${NOTARY_PROFILE}"
    fi
    step "stapler staple ${2#"$REPO_ROOT"/}"
    xcrun stapler staple "$2"
    xcrun stapler validate "$2" || die "stapler validate failed for ${2#"$REPO_ROOT"/}"
    ok "notarized + stapled: ${2#"$REPO_ROOT"/}"
}

# ---------------------------------------------------------------- locations

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "$REPO_ROOT"   # works no matter where it is invoked from

DIST_DIR="${REPO_ROOT}/dist"
APP_BUNDLE="${DIST_DIR}/${APP_NAME}.app"
CONTENTS="${APP_BUNDLE}/Contents"
ICON_CACHE_DIR="${REPO_ROOT}/.build-icon"
ICON_SRC="${SCRIPT_DIR}/make-icon.swift"

# ---------------------------------------------------------------- arguments

DO_INSTALL=0
DO_RUN=0
DO_PACKAGE=0
NOTARIZE=0
for arg in "$@"; do
    case "$arg" in
        --install)  DO_INSTALL=1 ;;
        --run)      DO_RUN=1 ;;
        --package)  DO_PACKAGE=1 ;;
        --notarize) NOTARIZE=1; DO_PACKAGE=1 ;;
        -h|--help)
            sed -n '2,/^$/p' "${SCRIPT_DIR}/build-app.sh" | sed 's/^# \{0,1\}//'
            trap - EXIT; exit 0 ;;
        *) die "unknown argument: ${arg} (use --install, --run, --package, or --notarize)" ;;
    esac
done

if [ "$NOTARIZE" -eq 1 ] && [ "$SIGN_IDENTITY" = "-" ]; then
    die "--notarize needs a Developer ID — set SIGN_IDENTITY=\"Developer ID Application: … (TEAMID)\" (see --help)"
fi

printf '%sByte Pulse — packaging %s %s (build %s)%s\n' "$BOLD" "$APP_NAME" "$VERSION" "$BUILD" "$RESET"
printf '%s  signing identity: %s%s\n' "$DIM" "$SIGN_LABEL" "$RESET"

# ---------------------------------------------------------------- 1. binary

if [ -n "${BINARY_OVERRIDE:-}" ]; then
    [ -f "$BINARY_OVERRIDE" ] && [ -x "$BINARY_OVERRIDE" ] \
        || die "BINARY_OVERRIDE is not an executable file: ${BINARY_OVERRIDE}"
    BINARY_PATH="$BINARY_OVERRIDE"
    ok "using BINARY_OVERRIDE (swift build skipped): ${BINARY_OVERRIDE}"
else
    step "swift build -c release --product ${APP_NAME} ${SWIFT_BUILD_FLAGS:-}"
    # SWIFT_BUILD_FLAGS is intentionally word-split:
    # shellcheck disable=SC2086
    swift build -c release --product "$APP_NAME" ${SWIFT_BUILD_FLAGS:-}
    # shellcheck disable=SC2086
    BIN_DIR="$(swift build -c release --product "$APP_NAME" ${SWIFT_BUILD_FLAGS:-} --show-bin-path)"
    BINARY_PATH="${BIN_DIR}/${APP_NAME}"
    [ -x "$BINARY_PATH" ] || die "built binary not found at ${BINARY_PATH}"
    ok "release binary: ${BINARY_PATH}"
fi

# ---------------------------------------------------------------- 2. icon (cached)

ICON_SUM_FILE="${ICON_CACHE_DIR}/make-icon.swift.sha256"
ICON_ICNS="${ICON_CACHE_DIR}/AppIcon.icns"
ICON_SUM="$(shasum -a 256 "$ICON_SRC" | awk '{print $1}')"

if [ -f "$ICON_ICNS" ] && [ -f "$ICON_SUM_FILE" ] && [ "$(cat "$ICON_SUM_FILE")" = "$ICON_SUM" ]; then
    ok "icon cache hit (.build-icon/AppIcon.icns)"
else
    step "rendering app icon (scripts/make-icon.swift)"
    mkdir -p "$ICON_CACHE_DIR"
    rm -f "$ICON_SUM_FILE"
    swift "$ICON_SRC" "$ICON_CACHE_DIR"
    printf '%s' "$ICON_SUM" > "$ICON_SUM_FILE"   # written only after success
    ok "AppIcon.icns rendered"
fi
[ -s "$ICON_ICNS" ] || die "icon missing: ${ICON_ICNS}"

# ---------------------------------------------------------------- 3. assemble bundle

step "assembling ${APP_BUNDLE#"$REPO_ROOT"/}"
rm -rf "$APP_BUNDLE"
mkdir -p "${CONTENTS}/MacOS" "${CONTENTS}/Resources"

cp "$BINARY_PATH" "${CONTENTS}/MacOS/${APP_NAME}"
chmod 755 "${CONTENTS}/MacOS/${APP_NAME}"

# SPM resource bundle (Bundle.module assets, e.g. the Byte mark). It lives next
# to the built binary and must ship in Contents/Resources for Bundle.module to
# resolve inside the .app.
RESOURCE_BUNDLE="$(dirname "$BINARY_PATH")/${APP_NAME}_${APP_NAME}.bundle"
if [ -d "$RESOURCE_BUNDLE" ]; then
  cp -R "$RESOURCE_BUNDLE" "${CONTENTS}/Resources/"
fi

cat > "${CONTENTS}/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleExecutable</key>
	<string>${APP_NAME}</string>
	<key>CFBundleIdentifier</key>
	<string>${BUNDLE_ID}</string>
	<key>CFBundleName</key>
	<string>${APP_NAME}</string>
	<key>CFBundleDisplayName</key>
	<string>${APP_NAME}</string>
	<key>CFBundleShortVersionString</key>
	<string>${VERSION}</string>
	<key>CFBundleVersion</key>
	<string>${BUILD}</string>
	<key>LSMinimumSystemVersion</key>
	<string>${MIN_OS}</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSHumanReadableCopyright</key>
	<string>© 2026 Byte</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>CFBundleIconName</key>
	<string>AppIcon</string>
	<key>LSApplicationCategoryType</key>
	<string>public.app-category.developer-tools</string>
	<key>NSPrincipalClass</key>
	<string>NSApplication</string>
</dict>
</plist>
PLIST
plutil -lint "${CONTENTS}/Info.plist" > /dev/null || die "Info.plist failed plutil -lint"

printf 'APPL????' > "${CONTENTS}/PkgInfo"
cp "$ICON_ICNS" "${CONTENTS}/Resources/AppIcon.icns"
ok "bundle assembled (Info.plist lint OK, icon + PkgInfo in place)"

# ---------------------------------------------------------------- 4. codesign (LAST)

# Sign the .app bundle — that seals both the main executable and every resource
# under Contents/, including the flat SPM resource bundle (SVG-only, no Mach-O,
# so it must NOT be signed on its own — codesign rejects that bundle format and
# it needs no signature). There is no nested *code* to sign first, so a single
# bundle sign is complete; Apple deprecates --deep, which we avoid.
step "codesign — ${SIGN_LABEL}"
sign_path "$APP_BUNDLE"
codesign --verify --strict --verbose=2 "$APP_BUNDLE" || die "codesign verification failed"
ok "signed + verified (${SIGN_LABEL})"

# Notarize + staple the .app. notarytool needs a container, so zip the bundle to
# submit, then staple the ticket onto the .app itself (a .zip can't be stapled).
if [ "$NOTARIZE" -eq 1 ]; then
    NOTARIZE_ZIP="${DIST_DIR}/${APP_NAME}-notarize.zip"
    rm -f "$NOTARIZE_ZIP"
    ditto -c -k --keepParent "$APP_BUNDLE" "$NOTARIZE_ZIP"
    notarize_container "$NOTARIZE_ZIP" "$APP_BUNDLE"
    rm -f "$NOTARIZE_ZIP"
fi

ok "${APP_BUNDLE#"$REPO_ROOT"/} ready"

# ---------------------------------------------------------------- 5. --package (.dmg)

if [ "$DO_PACKAGE" -eq 1 ]; then
    # Asset name is kept stable across versions: the website's download CTA links
    # to releases/latest/download/Byte-Pulse.dmg (see usage-tracker-website).
    DMG_PATH="${DIST_DIR}/Byte-Pulse.dmg"
    step "packaging ${DMG_PATH#"$REPO_ROOT"/}"
    STAGE="$(mktemp -d)"
    ditto "$APP_BUNDLE" "${STAGE}/${APP_NAME}.app"
    ln -s /Applications "${STAGE}/Applications"   # drag-to-install affordance
    rm -f "$DMG_PATH"
    hdiutil create -volname "Byte Pulse" -srcfolder "$STAGE" -ov -format UDZO "$DMG_PATH" > /dev/null
    rm -rf "$STAGE"
    ok "${DMG_PATH#"$REPO_ROOT"/} created ($(du -h "$DMG_PATH" | awk '{print $1}'))"

    # The .dmg is signed and notarized separately from the .app it carries
    # (a disk image gets no Hardened Runtime — that's a property of executables).
    if [ "$SIGN_IDENTITY" != "-" ]; then
        step "codesign dmg — ${SIGN_LABEL}"
        codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG_PATH"
        ok "dmg signed"
    fi
    if [ "$NOTARIZE" -eq 1 ]; then
        notarize_container "$DMG_PATH" "$DMG_PATH"
    fi

    # SHA computed LAST: signing + stapling rewrite the disk image's bytes.
    printf '  SHA-256: %s\n' "$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')"

    if [ "$SIGN_IDENTITY" = "-" ]; then
        printf '  %sNote:%s ad-hoc signed (no Developer ID) — Gatekeeper warns on first launch;\n' "$DIM" "$RESET"
        printf '        users must right-click → Open. For a clean release set SIGN_IDENTITY and pass --notarize.\n'
    fi
fi

# ---------------------------------------------------------------- 6. --install

if [ "$DO_INSTALL" -eq 1 ]; then
    TARGET="/Applications/${APP_NAME}.app"
    step "installing to ${TARGET}"
    pkill -x "$APP_NAME" 2> /dev/null || true
    if [ -e "$TARGET" ]; then
        EXISTING_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
            "${TARGET}/Contents/Info.plist" 2> /dev/null || true)"
        if [ "$EXISTING_ID" != "$BUNDLE_ID" ]; then
            die "refusing to remove ${TARGET}: its CFBundleIdentifier ('${EXISTING_ID:-<unreadable>}') is not ${BUNDLE_ID}"
        fi
        rm -rf "$TARGET"
    fi
    ditto "$APP_BUNDLE" "$TARGET"
    ok "installed: ${TARGET}"
    printf '\n  Launch it with:  %sopen %s%s\n\n' "$BOLD" "$TARGET" "$RESET"
fi

# ---------------------------------------------------------------- 7. --run

if [ "$DO_RUN" -eq 1 ]; then
    step "launching ${APP_BUNDLE#"$REPO_ROOT"/}"
    open "$APP_BUNDLE"
    ok "launched"
fi

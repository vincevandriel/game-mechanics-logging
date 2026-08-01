#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
XCODE_PROJECT="$PROJECT_DIR/AdventureBarEncounterLogger/AdventureBarEncounterLogger.xcodeproj"
SCHEME="AdventureBarEncounterLogger"
APP_NAME="AdventureBarEncounterLogger.app"
DIST_DIR="$PROJECT_DIR/dist"
IPA_PATH="$DIST_DIR/AdventureBarEncounterLogger.ipa"

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

command -v xcodebuild >/dev/null 2>&1 || fail "xcodebuild was not found. Run this script on macOS with full Xcode selected."
command -v ditto >/dev/null 2>&1 || fail "macOS ditto was not found."
command -v unzip >/dev/null 2>&1 || fail "unzip was not found."
[[ -d "$XCODE_PROJECT" ]] || fail "Xcode project not found at $XCODE_PROJECT"

# Fail closed: a failed run must not leave an older IPA at the documented
# output path where it could be mistaken for this build.
mkdir -p "$DIST_DIR"
rm -f "$IPA_PATH"

TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/AdventureBarEncounterLogger.XXXXXX")"
trap 'rm -rf "$TEMP_ROOT"' EXIT
DERIVED_DATA="$TEMP_ROOT/DerivedData"
STAGING_DIR="$TEMP_ROOT/Package"
PAYLOAD_DIR="$STAGING_DIR/Payload"
TEMP_IPA_PATH="$TEMP_ROOT/AdventureBarEncounterLogger.ipa"

printf 'Building %s (Release, generic iOS device, unsigned)...\n' "$SCHEME"
xcodebuild \
  -project "$XCODE_PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY='' \
  build || fail "Release device build failed. Review the xcodebuild diagnostics above."

APP_PATH="$DERIVED_DATA/Build/Products/Release-iphoneos/$APP_NAME"
if [[ ! -d "$APP_PATH" ]]; then
  APP_PATH="$(find "$DERIVED_DATA/Build/Products" -type d -name "$APP_NAME" -print -quit)"
fi
[[ -n "${APP_PATH:-}" && -d "$APP_PATH" ]] || fail "Built app bundle could not be located under DerivedData."
[[ -f "$APP_PATH/Info.plist" ]] || fail "Built app bundle is missing Info.plist."

rm -rf "$STAGING_DIR"
mkdir -p "$PAYLOAD_DIR"
ditto "$APP_PATH" "$PAYLOAD_DIR/$APP_NAME" || fail "Could not copy the app into the Payload directory."

(
  cd "$STAGING_DIR"
  ditto -c -k --sequesterRsrc --keepParent Payload "$TEMP_IPA_PATH"
) || fail "Could not create the IPA archive."

[[ -s "$TEMP_IPA_PATH" ]] || fail "IPA was not created or is empty."
ARCHIVE_LIST="$TEMP_ROOT/ipa-contents.txt"
unzip -Z1 "$TEMP_IPA_PATH" > "$ARCHIVE_LIST" || fail "Could not inspect the completed IPA archive."
if ! grep -Eq '^Payload/AdventureBarEncounterLogger\.app(/|$)' "$ARCHIVE_LIST"; then
  fail "IPA verification failed: Payload/AdventureBarEncounterLogger.app is absent."
fi
if ! grep -Fxq 'Payload/AdventureBarEncounterLogger.app/Info.plist' "$ARCHIVE_LIST"; then
  fail "IPA verification failed: app Info.plist is absent."
fi

mv "$TEMP_IPA_PATH" "$IPA_PATH" || fail "Verified IPA could not be moved into the dist directory."

printf 'Verified archive member: Payload/AdventureBarEncounterLogger.app\n'
printf 'Created: %s\n' "$IPA_PATH"

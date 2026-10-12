#!/usr/bin/env bash
# Smoke test: build -> install -> launch on a fresh simulator.
# Purpose: prove the rehearsal harness works for a given repo BEFORE you have
# a real task. It asserts nothing about features, so expect BOTH matrix runs
# to pass. The rehearsal workflow will flag "Unexpected outcome — base
# verdict=pass" — that is OK for this smoke test only. Replace with your real
# check when authoring the task.
#
# On the platform you will paste only the check logic into tests/test.sh —
# the locked frame provides pass/fail, siri_* helpers and appium_wda.sh.
# Here, the stubs stand in for them.

source "$(dirname "$0")/lib/platform-stubs.sh"

# ---- Defaults ----------------------------------------------------------------
# Scheme: run `xcodebuild -list` in the repo, or read the qualifier summary.
SCHEME="${SCHEME:-FreeOTP}"
# APP_ID: left empty on purpose — after the build we read the real bundle id
# from the built .app's Info.plist, so a stale default can never mislead us.
# (On the platform the same trick works; or hardcode after the survey.)
APP_ID=""
# ------------------------------------------------------------------------------

# Auto-detect project vs workspace (the platform check may hardcode its own).
PROJECT_FLAGS=()
found_ws="$(ls -d "$WORKSPACE"/*.xcworkspace 2>/dev/null | head -1 || true)"
found_proj="$(ls -d "$WORKSPACE"/*.xcodeproj 2>/dev/null | head -1 || true)"
if [ -n "$found_ws" ]; then
  PROJECT_FLAGS=(-workspace "$found_ws")
elif [ -n "$found_proj" ]; then
  PROJECT_FLAGS=(-project "$found_proj")
else
  fail "No .xcodeproj or .xcworkspace found in $WORKSPACE"
fi

BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/rehearsal-build.XXXXXX")"
remove_build() {
  xcrun simctl uninstall "$UDID" "$APP_ID" >/dev/null 2>&1 || :
  rm -rf "$BUILD_DIR"
}
siri_on_cleanup remove_build

# Build the app for the simulator (mirrors the platform's required flags).
xcodebuild -disableAutomaticPackageResolution -skipMacroValidation -skipPackagePluginValidation \
  "${PROJECT_FLAGS[@]}" -scheme "$SCHEME" -configuration Debug \
  -destination "platform=iOS Simulator,id=$UDID" \
  -derivedDataPath "$BUILD_DIR" CODE_SIGNING_ALLOWED=NO build \
  > "$ARTIFACTS/build.log" 2>&1 || fail "The app does not build. See build.log."

APP_PATH="$(ls -d "$BUILD_DIR"/Build/Products/Debug-iphonesimulator/*.app 2>/dev/null | head -1)"
[ -d "$APP_PATH" ] || fail "The build produced no .app bundle."

# Resolve the real bundle id from the built product (single source of truth).
if [ -z "$APP_ID" ]; then
  APP_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_PATH/Info.plist" 2>/dev/null || true)"
  [ -n "$APP_ID" ] || fail "Could not read CFBundleIdentifier from the built app."
  echo "Detected bundle id: $APP_ID"
fi

# Uninstall old app, install candidate, launch on $UDID.
if xcrun simctl get_app_container "$UDID" "$APP_ID" app >/dev/null 2>&1; then
  xcrun simctl uninstall "$UDID" "$APP_ID" || fail "The old app cannot be uninstalled."
fi
xcrun simctl install "$UDID" "$APP_PATH" || fail "The app does not install."
xcrun simctl launch "$UDID" "$APP_ID" > "$ARTIFACTS/launch.log" 2>&1 || fail "The app does not launch."

sleep 3
xcrun simctl io "$UDID" screenshot "$ARTIFACTS/launch-screenshot.png" >/dev/null 2>&1 || :

pass

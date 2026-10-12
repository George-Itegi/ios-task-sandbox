# ============================================================================
# Check block — single source of truth.
# PLATFORM: this exact text is the editable middle of tests/test.sh; the locked
# frame lines above it provide pass/fail/siri_error/siri_on_cleanup and
# WORKSPACE/UDID/ARTIFACTS.
# BITRISE REHEARSAL: checks/task2-check.sh defines the same helper names and
# environment, then sources this file, so both contexts run identical logic.
# ============================================================================

PROJECT="$WORKSPACE/ExcalidrawZ.xcodeproj"

# --- Preserved checks 1-3: invariants that hold before and after the change -
RESOLVED="$WORKSPACE/ExcalidrawZ.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
grep -q '39a8bf5f9a813ca3981e437b6ae61902d461e4f2' "$RESOLVED" \
  || fail "preserved 1: the ChocofordKit dependency pin in Package.resolved changed."
grep -q 'IPHONEOS_DEPLOYMENT_TARGET = 16.0' "$PROJECT/project.pbxproj" \
  || fail "preserved 2: the iOS deployment target is no longer 16.0."
grep -q 'NSOpenPanel' "$WORKSPACE/ExcalidrawZ/ExclidrawView/WebView/Coordinator/ExcalidrawStore+UI.swift" \
  || fail "preserved 3: the macOS open-panel implementation was removed instead of platform-guarded."

# --- Build, install, launch (the requested change) ---------------------------
BUILD_DIR="$(mktemp -d)"
cleanup_check() {
  if [ -n "${APP_ID:-}" ]; then
    xcrun simctl uninstall "$UDID" "$APP_ID" >/dev/null 2>&1 || :
  fi
  rm -rf "$BUILD_DIR"
}
siri_on_cleanup cleanup_check

# Best effort: warm the package cache when the environment allows it. A
# failure here is not a wrong answer — the offline build below decides.
xcodebuild -resolvePackageDependencies -project "$PROJECT" -scheme ExcalidrawZ \
  -derivedDataPath "$BUILD_DIR" > "$ARTIFACTS/resolve.log" 2>&1 || :

xcodebuild -project "$PROJECT" -scheme ExcalidrawZ -configuration Debug \
  -destination "platform=iOS Simulator,id=$UDID" \
  -disableAutomaticPackageResolution -skipMacroValidation -skipPackagePluginValidation \
  -derivedDataPath "$BUILD_DIR" CODE_SIGNING_ALLOWED=NO build \
  > "$ARTIFACTS/build.log" 2>&1 \
  || fail "target 1: the app does not build for the Simulator profile of the task."

APP_PATH="$BUILD_DIR/Build/Products/Debug-iphonesimulator/ExcalidrawZ.app"
[ -d "$APP_PATH" ] || fail "target 2: the built app bundle is missing."
APP_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_PATH/Info.plist" 2>/dev/null || true)"
[ -n "$APP_ID" ] || fail "target 2: the app bundle identifier cannot be read."

if xcrun simctl get_app_container "$UDID" "$APP_ID" app >/dev/null 2>&1; then
  xcrun simctl uninstall "$UDID" "$APP_ID" || fail "target 2: an old installation cannot be removed."
fi
xcrun simctl install "$UDID" "$APP_PATH" || fail "target 2: the app does not install."
xcrun simctl launch "$UDID" "$APP_ID" > "$ARTIFACTS/launch.log" 2>&1 || fail "target 3: the app does not launch."
sleep 6
xcrun simctl spawn "$UDID" launchctl list 2>/dev/null | grep -F "UIKitApplication:$APP_ID" >/dev/null 2>&1 \
  || fail "target 4: the app quits or crashes right after launch."

# --- Observable UI ------------------------------------------------------------
. "$(dirname "$0")/appium_wda.sh"
appium_session "$APP_ID"

appium_exists create_file_button \
  || fail "target 5: the create-drawing control is missing from the accessibility tree (create_file_button)."
appium_exists sidebar_toggle_button \
  || fail "target 6: the sidebar toggle is missing from the accessibility tree (sidebar_toggle_button)."

ROW_TEXT="$(appium_text file_row)" \
  || fail "target 7: the drawing list shows no entry (file_row not found)."
[ -n "$ROW_TEXT" ] || fail "target 7: the drawing-list entry has no name."

# --- Preserved check 4: creating a drawing still adds a list entry ------------
# Behavioral preserved check; it needs the launched app, so it runs after the
# target build steps. On the unchanged project the run already failed at
# target 1, so this check cannot mask that failure.
appium_page_source rows-before.xml || fail "preserved 4: the page source cannot be captured."
appium_tap create_file_button || fail "preserved 4: the create-drawing control cannot be tapped."
sleep 2
appium_page_source rows-after.xml || fail "preserved 4: the page source cannot be captured after creating a drawing."
count_rows() {
  local f=""
  if [ -f "$ARTIFACTS/$1" ]; then f="$ARTIFACTS/$1"; elif [ -f "$1" ]; then f="$1"; fi
  if [ -n "$f" ]; then
    grep -c 'file_row' "$f" 2>/dev/null || true
  else
    echo 0
  fi
}
BEFORE="$(count_rows rows-before.xml)"
AFTER="$(count_rows rows-after.xml)"
[ "$AFTER" -ge $((BEFORE + 1)) ] \
  || fail "preserved 4: creating a drawing no longer adds an entry to the drawing list (before=$BEFORE after=$AFTER)."

appium_screenshot launch-screenshot.png || :
pass

#!/usr/bin/env bash
# Full smoke rehearsal on CI: build -> install -> launch a target repo on a
# REAL iOS simulator, using the platform check contract (via stubs).
# Usage: bash scripts/smoke-rehearsal.sh <repo-url> [ref]
#
# This proves the full $90-task mechanics minus UI assertions:
#   clone -> boot simulator -> xcodebuild (parity flags) -> simctl install ->
#   simctl launch -> screenshot.
set -euo pipefail

REPO_URL="${1:?usage: smoke-rehearsal.sh <repo-url> [ref]}"
REF="${2:-}"
ROOT="$PWD"

echo "== Toolchain =="
XCODE_26="$(ls -d /Applications/Xcode*26*.app 2>/dev/null | sort -V | tail -1 || true)"
if [ -z "$XCODE_26" ]; then
  echo "ERROR: no Xcode 26.x found. Available:"; ls /Applications | grep -i xcode || true
  exit 1
fi
# DEVELOPER_DIR takes precedence over xcode-select (no sudo dependency);
# sudo xcode-select kept as fallback for bare xcodebuild invocations.
export DEVELOPER_DIR="$XCODE_26/Contents/Developer"
sudo xcode-select -s "$XCODE_26" 2>/dev/null || true
xcodebuild -version
swift --version 2>/dev/null | head -1 || true

echo "== Clone target =="
rm -rf target
git clone "$REPO_URL" target
cd target
if [ -n "$REF" ]; then git checkout "$REF"; fi
git log -1 --format='Base commit: %H %ci'
export WORKSPACE="$(pwd)"

# Optional pre-build repo patch — simulates the repo edits a task agent would
# make (e.g. dependency-pin fixes) BEFORE package resolution. PATCH_SCRIPT is
# resolved relative to CWD first, then to the sandbox repo root ($ROOT).
if [ -n "${PATCH_SCRIPT:-}" ]; then
  PATCH_RESOLVED="$PATCH_SCRIPT"
  if [ ! -f "$PATCH_RESOLVED" ] && [ -f "$ROOT/$PATCH_SCRIPT" ]; then
    PATCH_RESOLVED="$ROOT/$PATCH_SCRIPT"
  fi
  [ -f "$PATCH_RESOLVED" ] || { echo "ERROR: PATCH_SCRIPT not found: $PATCH_SCRIPT"; exit 1; }
  echo "== Apply PATCH_SCRIPT: $PATCH_RESOLVED =="
  bash "$PATCH_RESOLVED" "$PWD"
fi

echo "== Provision simulator =="
# Prefer an existing available device; otherwise create one from the newest
# iPhone devicetype + newest iOS runtime on this image.
UDID="$(xcrun simctl list devices available | grep -m1 -o '[0-9A-F-]\{36\}' || true)"
if [ -z "$UDID" ]; then
  DEVTYPE="$(xcrun simctl list devicetypes | grep -o 'com.apple.CoreSimulator.SimDeviceType.iPhone[^(]*' | tail -1 | sed 's/[[:space:]]*$//')"
  RUNTIME="$(xcrun simctl list runtimes | grep -o 'com.apple.CoreSimulator.SimRuntime.iOS-[0-9-]*' | tail -1)"
  echo "Creating simulator: devicetype=$DEVTYPE runtime=$RUNTIME"
  UDID="$(xcrun simctl create smoke-dev "$DEVTYPE" "$RUNTIME")"
fi
echo "UDID=$UDID"
# EXPORT REQUIRED: checks/smoke-build-launch.sh runs as a child script and
# reads $UDID for -destination and simctl. Unexported => empty id => xcodebuild
# "missing value for key 'id' of option 'Destination'" (Build #10 failure).
export UDID
xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b

echo "== Run smoke check (platform contract, stubs) =="
export ARTIFACTS="$ROOT/artifacts"
mkdir -p "$ARTIFACTS"
export SCHEME="${SCHEME:-FreeOTP}"
# APP_ID intentionally NOT preset: smoke-build-launch.sh derives it from the
# built .app's Info.plist, so we never hardcode a wrong bundle id.
bash "$ROOT/checks/smoke-build-launch.sh"

echo "RESULT: SMOKE OK — build/install/launch verified on simulator"

#!/usr/bin/env bash
# Qualifier: prove a target repo builds for iOS on Xcode 26.3 (platform parity).
# Usage: bash scripts/qualify.sh <repo-url> [ref]
# Designed for Cirrus CI macOS instances; also works on any macOS machine.
set -euo pipefail

REPO_URL="${1:?usage: qualify.sh <repo-url> [ref]}"
REF="${2:-}"

echo "== Toolchain =="
XCODE_26="$(ls -d /Applications/Xcode*26*.app 2>/dev/null | sort -V | tail -1 || true)"
if [ -z "$XCODE_26" ]; then
  echo "ERROR: no Xcode 26.x found. Available:"; ls /Applications | grep -i xcode || true
  exit 1
fi
# DEVELOPER_DIR takes precedence over xcode-select (no sudo dependency).
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

echo "== Survey =="
ls -d *.xcodeproj *.xcworkspace Package.swift Podfile Podfile.lock project.yml 2>/dev/null || true
if [ -f Podfile.lock ] && [ ! -d Pods ]; then
  echo "WARNING: Podfile.lock present but Pods/ not committed (platform requires committed Pods)"
fi

xcodebuild -list -json > /tmp/schemes.json 2>/dev/null || true
SCHEME="$(python3 -c 'import json;d=json.load(open("/tmp/schemes.json"));s=d.get("project",{}).get("schemes",[]);print(s[0] if s else "")' 2>/dev/null || true)"
if [ -z "$SCHEME" ]; then
  found="$(ls -d *.xcodeproj 2>/dev/null | head -1 || true)"
  [ -n "$found" ] && SCHEME="${found%.xcodeproj}"
fi
echo "Using scheme: $SCHEME"
[ -n "$SCHEME" ] || { echo "ERROR: no scheme detected"; exit 1; }

FLAGS=()
ws="$(ls -d *.xcworkspace 2>/dev/null | head -1 || true)"
proj="$(ls -d *.xcodeproj 2>/dev/null | head -1 || true)"
[ -n "$ws" ] && FLAGS+=(-workspace "$ws")
[ -n "$proj" ] && FLAGS+=(-project "$proj")

echo "== Build (iOS Simulator destination) =="
if xcodebuild build "${FLAGS[@]}" -scheme "$SCHEME" \
    -destination 'generic/platform=iOS Simulator' \
    -skipMacroValidation -skipPackagePluginValidation \
    -derivedDataPath /tmp/qualifier-dd \
    COMPILER_INDEX_STORE_ENABLE=NO CODE_SIGNING_ALLOWED=NO \
    > /tmp/build.log 2>&1; then
  echo "RESULT: BUILD OK — repo qualified for task authoring"
else
  echo "RESULT: BUILD FAILED — last 60 lines:"
  tail -60 /tmp/build.log
  exit 1
fi

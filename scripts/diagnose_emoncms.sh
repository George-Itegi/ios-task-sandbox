#!/usr/bin/env bash
# Diagnostic: can emoncms-ios build if its Charts pin is unlocked to v4.1.0?
#
# WHY: committed Package.resolved pins Charts 4.0.2 (Mar 2022). On Xcode 26.6 /
# Swift 6.3.3 the Charts target dies in SwiftEmitModule. Charts' compile fixes
# ("makeIterator()" protocol fix, Swift 5.7 protocol conformance fix) landed
# ONLY in v4.1.0 (Sep 2022) — the final tagged release of the project.
# v4.0.3 (the only newer version inside the project's
# `upToNextMinorVersion from 4.0.0` range) contains zero compiler fixes.
#
# WHAT THIS DOES (simulates the exact repo edits a task agent would make):
#   1. Package.resolved: charts pin 4.0.2 -> 4.1.0 (commit revision resolved live)
#   2. project.pbxproj: Charts requirement upToNextMinorVersion -> upToNextMajorVersion
#      (from 4.0.0, so 4.1.0 satisfies it; still <5.0.0 which does not exist)
#   3. xcodebuild build for generic iOS Simulator, full error capture on failure.
#
# Everything else (Realm 10.24.2, Former, KeychainAccess, XCGLogger) stays
# pinned as committed — one variable at a time.
set -euo pipefail

REPO_URL="https://github.com/emoncms/emoncms-ios"

XCODE_26="$(ls -d /Applications/Xcode*26*.app 2>/dev/null | sort -V | tail -1 || true)"
if [ -z "$XCODE_26" ]; then
  echo "ERROR: no Xcode 26.x found. Available:"; ls /Applications | grep -i xcode || true
  exit 1
fi
export DEVELOPER_DIR="$XCODE_26/Contents/Developer"
sudo xcode-select -s "$XCODE_26" 2>/dev/null || true
echo "== Toolchain =="
xcodebuild -version
swift --version 2>/dev/null | head -1 || true

echo "== Clone target =="
rm -rf target
git clone --quiet "$REPO_URL" target
cd target
git log -1 --format='Base commit: %H %ci'

RESOLVED="EmonCMSiOS.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
PBXPROJ="EmonCMSiOS.xcodeproj/project.pbxproj"
[ -f "$RESOLVED" ] || { echo "ERROR: Package.resolved not found at $RESOLVED"; exit 1; }
[ -f "$PBXPROJ" ]  || { echo "ERROR: pbxproj not found at $PBXPROJ"; exit 1; }

# v4.1.0 is a LIGHTWEIGHT tag (verified): only refs/tags/v4.1.0 exists, no peeled
# ^{} variant. Try peeled first (annotated-tag case), fall back to the tag ref.
CHARTS_REV="$(git ls-remote https://github.com/danielgindi/Charts 'refs/tags/v4.1.0^{}' | cut -f1)"
if [ -z "$CHARTS_REV" ]; then
  CHARTS_REV="$(git ls-remote https://github.com/danielgindi/Charts 'refs/tags/v4.1.0' | cut -f1)"
fi
case "$CHARTS_REV" in
  ????????????????????????????????????????) ;;  # 40 hex chars -> ok
  *) echo "ERROR: could not resolve v4.1.0 commit revision (got '$CHARTS_REV')"; exit 1 ;;
esac

echo "== Patch 1/2: Package.resolved charts pin -> 4.1.0 ($CHARTS_REV) =="
python3 - "$RESOLVED" "$CHARTS_REV" <<'PYEOF'
import json, sys
path, rev = sys.argv[1], sys.argv[2]
with open(path) as f:
    d = json.load(f)
hit = False
for pin in d.get("pins", []):
    if pin.get("identity") == "charts":
        pin["state"] = {"revision": rev, "version": "4.1.0"}
        hit = True
if not hit:
    sys.exit("ERROR: no 'charts' pin found in Package.resolved")
with open(path, "w") as f:
    json.dump(d, f, indent=2)
    f.write("\n")
print("Package.resolved patched: charts -> 4.1.0")
PYEOF

echo "== Patch 2/2: pbxproj Charts requirement upToNextMinorVersion -> upToNextMajorVersion =="
python3 - "$PBXPROJ" <<'PYEOF'
import re, sys
path = sys.argv[1]
with open(path) as f:
    src = f.read()
pattern = re.compile(
    r'(XCRemoteSwiftPackageReference "Charts" \*/ = \{\s*'
    r'isa = XCRemoteSwiftPackageReference;\s*'
    r'repositoryURL = "[^"]+";\s*'
    r'requirement = \{\s*kind = )upToNextMinorVersion(;\s*minimumVersion = )4\.0\.0(;\s*\};)'
)
new, n = pattern.subn(r'\1upToNextMajorVersion\g<2>4.0.0\3', src)
print(f"requirement replacements: {n}")
if n != 1:
    sys.exit("ERROR: expected exactly 1 Charts requirement replacement, got %d" % n)
with open(path, "w") as f:
    f.write(new)
print("pbxproj patched")
PYEOF

echo "== Build (Charts 4.1.0 unlocked, everything else as committed) =="
if xcodebuild build -project EmonCMSiOS.xcodeproj -scheme EmonCMSiOS \
    -destination 'generic/platform=iOS Simulator' \
    -skipMacroValidation -skipPackagePluginValidation \
    -derivedDataPath /tmp/diag-dd \
    COMPILER_INDEX_STORE_ENABLE=NO CODE_SIGNING_ALLOWED=NO \
    > /tmp/diag-build.log 2>&1; then
  echo "VERDICT: PASS — Charts 4.1.0 compiles under this toolchain."
  echo "emoncms-ios is salvageable as a task: agent's fix = bump Charts pin to 4.1.0"
  echo "+ patch requirement rule (exactly the edits this script made)."
else
  echo "VERDICT: FAIL — still broken with Charts 4.1.0. Evidence:"
  echo "== Compiler errors (first 40, deduped) =="
  grep 'error: ' /tmp/diag-build.log | sed 's/^[[:space:]]*//' | awk '!seen[$0]++' | head -40 || true
  echo "== Failed build commands =="
  grep -A8 "The following build commands failed" /tmp/diag-build.log | head -14 || true
  echo "== Last 25 lines =="
  tail -25 /tmp/diag-build.log
  exit 1
fi

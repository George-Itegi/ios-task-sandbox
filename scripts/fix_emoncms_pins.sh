#!/usr/bin/env bash
# Apply the emoncms-ios dependency-pin fix that a task agent would make:
#   1. Package.resolved: charts pin 4.0.2 -> 4.1.0 (final tagged release;
#      contains commit 3af939e which adds the replaceSubrange<C> witness that
#      Swift 6.3.3 demands for RangeReplaceableCollection).
#   2. project.pbxproj: Charts requirement upToNextMinorVersion ->
#      upToNextMajorVersion (from 4.0.0, so 4.1.0 satisfies it).
# Idempotent: safe to run multiple times.
# Usage: bash fix_emoncms_pins.sh <target-repo-dir>
set -euo pipefail

TARGET="${1:?usage: fix_emoncms_pins.sh <target-repo-dir>}"
RESOLVED="$TARGET/EmonCMSiOS.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
PBXPROJ="$TARGET/EmonCMSiOS.xcodeproj/project.pbxproj"
[ -f "$RESOLVED" ] || { echo "ERROR: Package.resolved not found at $RESOLVED"; exit 1; }
[ -f "$PBXPROJ" ]  || { echo "ERROR: pbxproj not found at $PBXPROJ"; exit 1; }

echo "== Patch 1/2: Package.resolved charts pin -> 4.1.0 =="
python3 - "$RESOLVED" <<'PYEOF'
import json, sys
path = sys.argv[1]
with open(path) as f:
    d = json.load(f)
hit = False
for pin in d.get("pins", []):
    if pin.get("identity") == "charts":
        if pin.get("state", {}).get("version") == "4.1.0":
            print("already patched (charts == 4.1.0), skipping")
        else:
            pin["state"] = {"revision": "07b23476ad52b926be772f317d8f1d4511ee8d02", "version": "4.1.0"}
            with open(path, "w") as f2:
                json.dump(d, f2, indent=2)
                f2.write("\n")
            print("Package.resolved patched: charts -> 4.1.0")
        hit = True
if not hit:
    sys.exit("ERROR: no 'charts' pin found in Package.resolved")
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
if n == 1:
    with open(path, "w") as f:
        f.write(new)
    print("pbxproj patched (1 replacement)")
elif n == 0:
    if 'XCRemoteSwiftPackageReference "Charts"' in src and "upToNextMajorVersion" in src:
        print("already patched (requirement is upToNextMajorVersion), skipping")
    else:
        sys.exit("ERROR: Charts requirement block not found for patching")
else:
    sys.exit("ERROR: expected at most 1 Charts requirement replacement, got %d" % n)
PYEOF

echo "PINS OK — Charts unlocked to 4.1.0"

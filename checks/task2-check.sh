#!/usr/bin/env bash
# ============================================================================
# task2-check.sh — standalone Bitrise rehearsal of the platform check block.
# Defines the same helper names the locked platform frame provides, exports the
# same environment variables, then sources checks/task2-check-block.sh so the
# rehearsal exercises byte-identical check logic.
# Usage: bash checks/task2-check.sh <repo-dir>
# Requires: macOS with Xcode + a booted simulator (export UDID), except that
# the appium_* helpers come from the rehearsal stub checks/appium_wda.sh
# (no WDA on the rehearsal runner).
# ============================================================================
set -euo pipefail
REPO_DIR="${1:?usage: task2-check.sh <repo-dir>}"

export WORKSPACE="$REPO_DIR"
export ARTIFACTS="${ARTIFACTS:-$(mktemp -d /tmp/task2-check-artifacts.XXXXXX)}"
export UDID="${UDID:?ERROR: export UDID of a booted simulator first}"
mkdir -p "$ARTIFACTS"

pass() { echo "CHECK RESULT: PASS"; exit 0; }
fail() { echo "CHECK RESULT: FAIL — $*"; exit 1; }
siri_error() { echo "CHECK RESULT: SIRI_ERROR — $*"; exit 2; }
siri_on_cleanup() { :; }  # rehearsal: no post-run hook machinery

# $0 here is checks/task2-check.sh -> sources the rehearsal stub appium_wda.sh
source "$(dirname "$0")/task2-check-block.sh"

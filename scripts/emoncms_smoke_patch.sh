#!/usr/bin/env bash
# emoncms_smoke_patch.sh — combined PATCH_SCRIPT for the emoncms SOLVED-app smoke.
# Applies, in order:
#   1. fix_emoncms_pins.sh        Charts 4.0.2 -> 4.1.0 (dev-stack-only rehearsal fix:
#                                  Charts 4.0.2 cannot compile on Swift 6.3.3/Xcode 26.6.
#                                  The platform's check block is static source analysis and
#                                  never builds the app, so this pin fix is rehearsal-only.)
#   2. emoncms_apply_solution.sh  the task's reference solution (trim credentials).
# Idempotent: safe to run multiple times.
# Usage (called by smoke-rehearsal.sh): bash emoncms_smoke_patch.sh <repo-dir>
set -euo pipefail
TARGET="${1:?usage: emoncms_smoke_patch.sh <repo-dir>}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bash "$HERE/fix_emoncms_pins.sh" "$TARGET"
bash "$HERE/emoncms_apply_solution.sh" "$TARGET"
echo "SMOKE PATCH OK — pins fixed + solution applied"

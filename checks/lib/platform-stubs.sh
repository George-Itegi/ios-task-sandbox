#!/usr/bin/env bash
# Platform helper stubs — FOR REHEARSAL ONLY.
#
# On the real platform, the locked frame of tests/test.sh provides pass/fail
# and the siri_* helpers, and Simulator tasks source the real appium_wda.sh.
# Here we mimic their contracts so the SAME check logic can run in rehearsal.
#
# Never ship this file. Never source it from the bundle you submit.

pass() {
  echo "VERDICT: pass"
  exit 0
}

fail() {
  echo "VERDICT: fail — $*" >&2
  exit 1
}

siri_on_cleanup() {
  # Real platform runs the given function when the script ends.
  # Rehearsal: no-op (short-lived CI machine, nothing to clean).
  :
}

siri_error() {
  # Real platform: stop with an error when the check cannot grade.
  echo "VERDICT: error — $*" >&2
  exit 2
}

siri_require_file() {
  [ -f "$1" ] || fail "siri_require_file: missing file: $1"
}

siri_require_tool() {
  command -v "$1" >/dev/null 2>&1 || fail "siri_require_tool: missing tool: $1"
}

# --- Appium / WDA stubs -------------------------------------------------------
# v1 rehearsal CANNOT validate UI assertions. These stubs fail loudly so you
# notice immediately. Keep UI assertions out of rehearsal checks, or upgrade
# the harness (v2) with a real Appium + WebDriverAgent setup.

appium_session() {
  echo "REHEARSAL-v1: appium_session is not available. UI assertions cannot be validated here." >&2
  return 2
}

appium_exists() {
  echo "REHEARSAL-v1: appium_exists is not available." >&2
  return 2
}

appium_tap() {
  echo "REHEARSAL-v1: appium_tap is not available." >&2
  return 2
}

appium_text() {
  echo "REHEARSAL-v1: appium_text is not available." >&2
  return 2
}

appium_scroll_to() {
  echo "REHEARSAL-v1: appium_scroll_to is not available." >&2
  return 2
}

appium_page_source() {
  echo "REHEARSAL-v1: appium_page_source is not available." >&2
  return 2
}

appium_screenshot() {
  echo "REHEARSAL-v1: appium_screenshot is not available." >&2
  return 2
}

#!/usr/bin/env bash
# ============================================================================
# appium_wda.sh — REHEARSAL STUB ONLY.
# The platform generates a read-only tests/appium_wda.sh with real WDA helpers
# for the grading run. This stand-in lives next to checks/task2-check.sh so the
# rehearsal's sourced check block finds "$(dirname "$0")/appium_wda.sh" and the
# full block logic (including the rows-before/rows-after counting) executes on
# a runner that has no WebDriverAgent.
# State model: appium_tap leaves a marker; page sources written AFTER the tap
# contain one extra file_row element, mirroring a successful create.
# ============================================================================
appium_session() { [ -n "${1:-}" ] && return 0 || return 1; }
appium_exists()  { return 0; }
appium_text()    { echo "Untitled"; return 0; }
appium_tap() {
  mkdir -p "${ARTIFACTS:-/tmp}"
  touch "${ARTIFACTS:-/tmp}/.task2-tapped"
  return 0
}
appium_page_source() {
  local name="${1:?usage: appium_page_source <name>.xml}"
  local dir="${ARTIFACTS:-$PWD}"
  local n=1
  if [ "$name" = "rows-after.xml" ] && [ -f "$dir/.task2-tapped" ]; then
    n=2
  fi
  {
    echo '<?xml version="1.0" encoding="UTF-8"?>'
    echo '<AppiumAUT>'
    local i
    for i in $(seq 1 "$n"); do
      echo '  <element type="Other" name="file_row" label="Untitled" />'
    done
    echo '</AppiumAUT>'
  } > "$dir/$name"
  return 0
}
appium_screenshot() { :; }

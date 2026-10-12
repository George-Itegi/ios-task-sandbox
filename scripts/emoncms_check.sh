#!/usr/bin/env bash
# emoncms_check.sh — rehearsal stand-in for the platform check block.
# Same logic as test_check_block.sh, self-contained, takes the repo dir as $1.
# Exit 0 = VERDICT pass, exit 1 = VERDICT fail.
set -uo pipefail
REPO="${1:?usage: emoncms_check.sh <repo-dir>}"

fail() { echo "VERDICT: fail — $*" >&2; exit 1; }
pass() { echo "VERDICT: pass"; exit 0; }

cd "$REPO" || fail "cannot cd to $REPO"

SRC="EmonCMSiOS/ViewModel/AddAccountViewModel.swift"

[ -f "$SRC" ] || fail "missing file: $SRC"

BODY="$(awk '/func saveAccount\(\)/{found=1} found{print} found && /^}/{exit}' "$SRC")"
[ -n "$BODY" ] || fail "could not locate saveAccount() in $SRC"

COUNT="$(printf '%s\n' "$BODY" | grep -c 'trimmingCharacters(in: .whitespacesAndNewlines)' || true)"
if [ "${COUNT:-0}" -lt 6 ]; then
  fail "saveAccount() trims only ${COUNT:-0}/6 values (guard URL + name, url, username, password, apiKey)"
fi

case "$BODY" in
  *"URL(string: self.url.trimmingCharacters(in: .whitespacesAndNewlines))"*) : ;;
  *) fail "URL validity guard must validate the trimmed URL" ;;
esac

pass

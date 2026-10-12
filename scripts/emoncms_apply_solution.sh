#!/usr/bin/env bash
# emoncms_apply_solution.sh — Trim whitespace/newlines from credentials in AddAccountViewModel.saveAccount()
# Reference solution for the emoncms-ios "trim credentials" task.
# Idempotent; exits non-zero if the expected anchor code is missing.
set -euo pipefail
REPO_DIR="${1:-.}"

python3 - "$REPO_DIR" <<'PYEOF'
import pathlib, sys

p = pathlib.Path(sys.argv[1]) / "EmonCMSiOS/ViewModel/AddAccountViewModel.swift"
if not p.exists():
    print(f"ERROR: {p} not found")
    sys.exit(1)
src = p.read_text()

OLD = """    guard let _ = URL(string: self.url) else { return Fail(error: AddAccountError.urlNotValid).eraseToAnyPublisher() }

    let name = self.name
    let url = self.url
    let username = self.username
    let password = self.password
    let apiKey = self.apiKey
"""

NEW = """    guard let _ = URL(string: self.url.trimmingCharacters(in: .whitespacesAndNewlines)) else { return Fail(error: AddAccountError.urlNotValid).eraseToAnyPublisher() }

    let name = self.name.trimmingCharacters(in: .whitespacesAndNewlines)
    let url = self.url.trimmingCharacters(in: .whitespacesAndNewlines)
    let username = self.username.trimmingCharacters(in: .whitespacesAndNewlines)
    let password = self.password.trimmingCharacters(in: .whitespacesAndNewlines)
    let apiKey = self.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
"""

if NEW in src:
    print("already solved — nothing to do")
    sys.exit(0)
if OLD not in src:
    print("ERROR: expected anchor code not found in saveAccount()")
    sys.exit(1)

p.write_text(src.replace(OLD, NEW, 1))
print(f"patched: {p}")
PYEOF

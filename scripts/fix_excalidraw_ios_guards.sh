#!/usr/bin/env bash
# fix_excalidraw_ios_guards.sh
# PATCH_SCRIPT for smoke-rehearsal.sh — makes ExcalidrawZ @ a7631da compile
# for the iOS Simulator by adding the same platform guards upstream adopted
# later (os(macOS) conditions). Idempotent: safe to run twice.
#
# What it does:
#   1. SettingsView.swift        : #if !APP_STORE              -> #if os(macOS) && !APP_STORE   (Sparkle import)
#   2. GeneralSettingsView.swift : #if !APP_STORE (x3)         -> #if os(macOS) && !APP_STORE   (Sparkle import + usages)
#   3. ExcalidrawZApp.swift      : #if !APP_STORE (x1)         -> #if os(macOS) && !APP_STORE   (updateChecker env object)
#   4. ExcaliDrawOpenPanel.swift : wraps NSOpenPanel impl in #if os(macOS) and adds a
#      compile-only iOS stub so unguarded callers (Utils.swift, ShareView.swift,
#      MigrateToNewVersion.swift) keep compiling; runModal() returns .canceled on iOS.
#
# Usage: bash fix_excalidraw_ios_guards.sh <target-repo-dir>
set -euo pipefail
REPO_DIR="${1:?usage: fix_excalidraw_ios_guards.sh <repo-dir>}"
cd "$REPO_DIR"

python3 - <<'PYEOF'
import pathlib

def edit(path, fn):
    p = pathlib.Path(path)
    if not p.exists():
        print(f"SKIP (missing): {path}")
        return
    src = p.read_text()
    out, note = fn(src)
    if out is None:
        print(f"KEEP   ({note}): {path}")
        return
    p.write_text(out)
    print(f"PATCHED ({note}): {path}")

def qualify_bare_guards(src):
    """Replace every bare '#if !APP_STORE' line with '#if os(macOS) && !APP_STORE'."""
    lines = src.splitlines(keepends=True)
    n = 0
    for i, l in enumerate(lines):
        if l.strip() == "#if !APP_STORE":
            indent = l[: len(l) - len(l.lstrip())]
            eol = "\n" if l.endswith("\n") else ""
            lines[i] = indent + "#if os(macOS) && !APP_STORE" + eol
            n += 1
    if n == 0:
        if "#if os(macOS) && !APP_STORE" in src:
            return None, "already guarded"
        return None, "no bare #if !APP_STORE found (inspect manually)"
    return "".join(lines), f"upgraded {n} guard(s)"

def open_panel(src):
    """Wrap the WHOLE original file in #if os(macOS); put an iOS stub in #else."""
    if "#if os(macOS)" in src:
        return None, "already guarded"
    stub_body = """import Foundation

/// iOS compile-only stub: NSOpenPanel does not exist on iOS. The import /
/// export panel flows are macOS-only; on iOS they resolve to safe no-ops
/// (runModal() returns .canceled so callers compile unchanged).
class ExcalidrawOpenPanel {
    static var importPanel: ExcalidrawOpenPanel { ExcalidrawOpenPanel() }
    static var exportPanel: ExcalidrawOpenPanel { ExcalidrawOpenPanel() }
    var urls: [URL] { [] }
    var url: URL? { nil }
    enum ModalResult { case OK, canceled }
    func runModal() -> ModalResult { .canceled }
}"""
    return ("#if os(macOS)\n" + src.rstrip("\n")
            + "\n#else\n" + stub_body + "\n#endif\n",
            "wrapped whole file in #if os(macOS) with iOS stub")

edit("ExcalidrawZ/Settings/SettingsView.swift", qualify_bare_guards)
edit("ExcalidrawZ/Settings/GeneralSettingsView.swift", qualify_bare_guards)
edit("ExcalidrawZ/ExcalidrawZApp.swift", qualify_bare_guards)
edit("ExcalidrawZ/Utils/ExcaliDrawOpenPanel.swift", open_panel)
PYEOF

echo "== diff summary =="
git --no-pager diff --stat || true

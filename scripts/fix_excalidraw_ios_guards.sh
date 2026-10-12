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
#   5. File+Extension.swift      : adds 'import CoreData'. It uses NSManagedObjectContext
#      with only Foundation/SwiftUI imported. On macOS SwiftUI->AppKit exposes CoreData
#      transitively, on iOS (UIKit) it does not -> "cannot find type 'NSManagedObjectContext'".
#   6. AppStore.swift            : adds 'import CoreData' (same root cause; uses
#      NSManagedObjectContext / NSManagedObjectID; was in an interrupted batch in build #23
#      so the error had not surfaced yet).
#   7. GeneralSettingsView.swift : the DEBUG #Preview block calls
#      .environmentObject(UpdateChecker()) but UpdateChecker is macOS-only (its own file is
#      '#if os(macOS)') -> guard the preview with '#if DEBUG && os(macOS)'.
#
# Usage: bash fix_excalidraw_ios_guards.sh <target-repo-dir>
set -euo pipefail
REPO_DIR="${1:?usage: fix_excalidraw_ios_guards.sh <repo-dir>}"
cd "$REPO_DIR"

python3 - <<'PYEOF'
import pathlib
import re

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

def make_add_import(import_line, anchors):
    """Return a transform that inserts import_line after the LAST matching anchor import."""
    def fn(src):
        if import_line in src.splitlines():
            return None, f"{import_line} already present"
        lines = src.splitlines(keepends=True)
        idx = None
        for i, l in enumerate(lines):
            if l.strip() in anchors:
                idx = i
        if idx is None:
            return None, "no anchor import found (inspect manually)"
        anchor = lines[idx].strip()
        lines.insert(idx + 1, import_line + "\n")
        return "".join(lines), f"added {import_line} after {anchor}"
    return fn

def preview_guard(src):
    """Guard the '#if DEBUG / #Preview {' block with os(macOS) (UpdateChecker is macOS-only)."""
    if "#if DEBUG && os(macOS)" in src:
        return None, "preview already guarded"
    new, n = re.subn(r"(?m)^#if DEBUG[ \t]*\n(#Preview\s*\{)",
                     "#if DEBUG && os(macOS)\n\\1", src, count=1)
    if n == 0:
        return None, "no '#if DEBUG + #Preview {' pattern found (inspect manually)"
    return new, "guarded #Preview with os(macOS)"

def compose(*fns):
    """Apply several transforms to one file; report each sub-result."""
    def fn(src):
        cur = src
        notes = []
        changed = False
        for f in fns:
            out, note = f(cur)
            if out is None:
                notes.append(f"[keep: {note}]")
            else:
                cur = out
                changed = True
                notes.append(f"[ok: {note}]")
        if not changed:
            return None, " ".join(notes)
        return cur, " ".join(notes)
    return fn

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
edit("ExcalidrawZ/Settings/GeneralSettingsView.swift",
     compose(qualify_bare_guards, preview_guard))
edit("ExcalidrawZ/ExcalidrawZApp.swift", qualify_bare_guards)
edit("ExcalidrawZ/Utils/ExcaliDrawOpenPanel.swift", open_panel)
edit("ExcalidrawZ/Persistence/File+Extension.swift",
     make_add_import("import CoreData", {"import Foundation", "import SwiftUI"}))
edit("ExcalidrawZ/AppStore.swift",
     make_add_import("import CoreData", {"import SwiftUI", "import Combine", "import UniformTypeIdentifiers"}))
PYEOF

echo "== diff summary =="
git --no-pager diff --stat || true

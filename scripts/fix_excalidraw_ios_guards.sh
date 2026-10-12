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
# --- Wave 2 (build #24: whole-module type-check exposed unguarded AppKit types) ---
#   8. ContentView.swift / ExcalidrawToolbar.swift / MigrateToNewVersion.swift :
#      dual '@State window' decl (NSWindow? on macOS / UIWindow? on iOS) — same split
#      upstream uses; ChocofordKit's bindWindow has a UIWindow overload on iOS
#      (verified at pinned rev 39a8bf5).
#   9. ExcalidrawStore.swift      : exportElementsToPNG/SVG return PlatformImage;
#      NSImage(data:) -> PlatformImage(data:).
#  10. LibraryItemView.swift      : NSCache<NSString, PlatformImage>; Image(platformImage:).
#  11. Utils.swift                : PlatformImage typealias + Image(platformImage:) init +
#      iOS UIImage.resizeWhileMaintainingAspectRatioToSize (mirror of the macOS-only
#      NSImage+Extension.swift helper).
#  12. ExportImageView.swift      : PlatformImage state/thumbnail; UIImage decode on iOS;
#      UIPasteboard copy on iOS; DragableImageView is macOS-only in pinned ChocofordKit
#      (whole file is #if os(macOS)) -> plain Image on iOS.
#  13. ExportFileView.swift       : copy-to-clipboard via UIPasteboard on iOS.
#  14. ExcalidrawStore+ScriptMessage.swift : handleCopy via UIPasteboard on iOS.
#  15. ExcalidrawStore+UI.swift   : runOpenPanel delegate wrapped in os(macOS)
#      (WKOpenPanelParameters is iOS 18.4+; NSOpenPanel is macOS-only).
#  16. ExcalidrawView.swift       : keyDown(with: NSEvent) override wrapped in os(macOS).
#  17. AboutView.swift            : app icon via Image("AppIcon") on iOS.
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

def replace_once(old, new, note):
    """Exact-string replace (first occurrence only)."""
    def fn(src):
        if new in src:
            return None, f"already applied ({note})"
        if old not in src:
            return None, f"PATTERN NOT FOUND ({note}) - inspect manually"
        return src.replace(old, new, 1), note
    return fn

def replace_all(old, new, note):
    def fn(src):
        if old not in src:
            if new in src:
                return None, f"already applied ({note})"
            return None, f"PATTERN NOT FOUND ({note}) - inspect manually"
        n = src.count(old)
        return src.replace(old, new), f"replaced {n} occurrence(s) ({note})"
    return fn

def wrap_block(start_pat, note):
    """Wrap the whole construct starting at start_pat through its closing
    '^    }' line (4-space indent) in '#if os(macOS) ... #endif'."""
    def fn(src):
        if re.search(r"#if os\(macOS\)[ \t]*\n" + start_pat, src, re.M):
            return None, f"already wrapped ({note})"
        m = re.search(start_pat, src, re.M)
        if not m:
            return None, f"START NOT FOUND ({note}) - inspect manually"
        endm = re.compile(r"^    \}$", re.M).search(src, m.end())
        if not endm:
            return None, f"END NOT FOUND ({note}) - inspect manually"
        block = src[m.start():endm.end()]
        return (src[:m.start()] + "#if os(macOS)\n" + block + "\n#endif\n"
                + src[endm.end():]), note
    return fn

def dual_body(start_pat, ios_body, marker, note):
    """Keep the function signature; wrap its body in
    '#if os(macOS) <original body> #else <ios_body> #endif'."""
    def fn(src):
        if marker in src:
            return None, f"already applied ({note})"
        m = re.search(start_pat, src, re.M)
        if not m:
            return None, f"START NOT FOUND ({note}) - inspect manually"
        endm = re.compile(r"^    \}$", re.M).search(src, m.end())
        if not endm:
            return None, f"END NOT FOUND ({note}) - inspect manually"
        sig_end = src.index("\n", m.start()) + 1
        sig = src[m.start():sig_end]
        body = src[sig_end:endm.start()]
        new = (src[:m.start()] + sig + "#if os(macOS)\n" + body + "#else\n" + ios_body
               + "\n#endif\n" + src[endm.start():])
        return new, note
    return fn

def dual_window_decl():
    return replace_once(
        "    @State private var window: NSWindow?",
        "#if os(macOS)\n    @State private var window: NSWindow?\n"
        "#else\n    @State private var window: UIWindow?\n#endif",
        "dual NSWindow/UIWindow @State decl")

INFRA = """
// ==== Cross-platform shims (added by fix_excalidraw_ios_guards.sh) ====
#if os(macOS)
import AppKit
typealias PlatformImage = NSImage
#else
import UIKit
typealias PlatformImage = UIImage

/// iOS counterpart of the macOS-only helper in Extensions/NSImage+Extension.swift
extension UIImage {
    func resizeWhileMaintainingAspectRatioToSize(size: CGSize) -> UIImage {
        let widthRatio = size.width / self.size.width
        let heightRatio = size.height / self.size.height
        let ratio = min(widthRatio, heightRatio)
        let newSize = CGSize(width: self.size.width * ratio, height: self.size.height * ratio)
        return UIGraphicsImageRenderer(size: newSize).image { _ in
            self.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
}
#endif

extension Image {
    init(platformImage: PlatformImage) {
#if os(macOS)
        self.init(nsImage: platformImage)
#else
        self.init(uiImage: platformImage)
#endif
    }
}
"""

def append_infra(src):
    """Utils.swift: import SwiftUI + PlatformImage typealias + Image(platformImage:) + iOS resize helper."""
    notes, cur, changed = [], src, False
    # 1) The appended extension Image { init(platformImage:) } needs SwiftUI in
    #    scope; Utils.swift only imports Foundation + conditional AppKit/UIKit
    #    (build #27: "cannot find type 'Image' in scope" at the extension).
    if "\nimport SwiftUI" in cur or cur.startswith("import SwiftUI"):
        notes.append("[keep: import SwiftUI present]")
    elif "\nimport Foundation\n" in cur:
        cur = cur.replace("\nimport Foundation\n",
                          "\nimport Foundation\nimport SwiftUI\n", 1)
        notes.append("[ok: added import SwiftUI]")
        changed = True
    else:
        cur = "import SwiftUI\n" + cur
        notes.append("[ok: added import SwiftUI (prepended)]")
        changed = True
    # 2) infra block (typealias + resize helper + Image init)
    if "typealias PlatformImage" in cur:
        notes.append("[keep: infra already present]")
    else:
        cur = cur.rstrip("\n") + "\n" + INFRA
        notes.append("[ok: appended cross-platform shims (PlatformImage / Image init / iOS resize)]")
        changed = True
    if not changed:
        return None, " ".join(notes)
    return cur, " ".join(notes)

HANDLECOPY_IOS = """        for item in data {
            let string = item.data
            // iOS: UIPasteboard has a simpler model; text types go as strings,
            // binary image payloads as raw data (best effort).
            switch item.type {
                case "image/png", "image/jpeg", "image/gif", "image/webp",
                     "image/bmp", "image/x-icon", "image/avif", "image/jfif":
                    if let data = Data(base64Encoded: string, options: [.ignoreUnknownCharacters]) {
                        UIPasteboard.general.setData(data, forPasteboardType: "public.png")
                    } else {
                        UIPasteboard.general.string = string
                    }
                default:
                    UIPasteboard.general.string = string
            }
        }"""

# NOTE: old text must swallow the WHOLE guard statement (incl. else body),
# otherwise the original 'else { ... }' survives after #endif and corrupts the file.
EXPORTIMAGE_GUARD_OLD = """            guard let image = NSImage(contentsOf: url)?.resizeWhileMaintainingAspectRatioToSize(size: .init(width: 200, height: 120)) else {
                hasError = true
                return
            }"""

EXPORTIMAGE_GUARD_NEW = """#if os(macOS)
            guard let image = NSImage(contentsOf: url)?.resizeWhileMaintainingAspectRatioToSize(size: .init(width: 200, height: 120)) else {
                hasError = true
                return
            }
#else
            guard let image = UIImage(contentsOfFile: url.path)?.resizeWhileMaintainingAspectRatioToSize(size: .init(width: 200, height: 120)) else {
                hasError = true
                return
            }
#endif"""

THUMBNAIL_OLD = """    @ViewBuilder private func thumbnailView(_ image: NSImage, url: URL) -> some View {
        DragableImageView(
            image: image,
            sourceURL: url
        )
        .frame(width: 200, height: 120, alignment: .center)
    }"""

THUMBNAIL_NEW = """    @ViewBuilder private func thumbnailView(_ image: PlatformImage, url: URL) -> some View {
#if os(macOS)
        DragableImageView(
            image: image,
            sourceURL: url
        )
        .frame(width: 200, height: 120, alignment: .center)
#else
        Image(platformImage: image)
            .resizable()
            .scaledToFit()
            .frame(width: 200, height: 120, alignment: .center)
#endif
    }"""

# NOTE: each #if branch must be brace-balanced on its own — Swift forbids
# splitting one statement's braces across #if/#else. Duplicate the shared tail.
COPYIMAGE_OLD = """                if let image = NSImage(contentsOf: url) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.writeObjects([image])
                    withAnimation {
                        copied = true
                    }
                    Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { _ in
                        withAnimation {
                            copied = false
                        }
                    }
                }"""

COPYIMAGE_NEW = """#if os(macOS)
                if let image = NSImage(contentsOf: url) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.writeObjects([image])
                    withAnimation {
                        copied = true
                    }
                    Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { _ in
                        withAnimation {
                            copied = false
                        }
                    }
                }
#else
                if let image = UIImage(contentsOfFile: url.path) {
                    UIPasteboard.general.image = image
                    withAnimation {
                        copied = true
                    }
                    Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { _ in
                        withAnimation {
                            copied = false
                        }
                    }
                }
#endif"""

COPYFILE_OLD = """                NSPasteboard.general.clearContents()
                if let url = fileURL,
                   let url = (url as NSURL).fileReferenceURL() as NSURL? {
                    NSPasteboard.general.writeObjects([url])
                    NSPasteboard.general.setString(url.relativeString, forType: .fileURL)
                    NSPasteboard.general.setData(file.content, forType: .fileContents)
                    withAnimation {
                        copied = true
                    }
                    Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { _ in
                        withAnimation {
                            copied = false
                        }
                    }
                }"""

COPYFILE_NEW = """#if os(macOS)
                NSPasteboard.general.clearContents()
                if let url = fileURL,
                   let url = (url as NSURL).fileReferenceURL() as NSURL? {
                    NSPasteboard.general.writeObjects([url])
                    NSPasteboard.general.setString(url.relativeString, forType: .fileURL)
                    NSPasteboard.general.setData(file.content, forType: .fileContents)
                    withAnimation {
                        copied = true
                    }
                    Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { _ in
                        withAnimation {
                            copied = false
                        }
                    }
                }
#else
                UIPasteboard.general.setValue(file.content, forPasteboardType: UTType.data.identifier)
                withAnimation {
                    copied = true
                }
                Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { _ in
                    withAnimation {
                        copied = false
                    }
                }
#endif"""

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

# --- Wave 2: unguarded AppKit types (build #24) ---
edit("ExcalidrawZ/Utils/Utils.swift", append_infra)
edit("ExcalidrawZ/ContentView.swift", dual_window_decl())
edit("ExcalidrawZ/ExclidrawView/ExcalidrawToolbar.swift", dual_window_decl())
edit("ExcalidrawZ/Utils/Migration/MigrateToNewVersion.swift", dual_window_decl())
edit("ExcalidrawZ/ExclidrawView/WebView/Coordinator/ExcalidrawStore.swift",
     compose(
         replace_all("throws -> NSImage {", "throws -> PlatformImage {",
                     "PNG/SVG export returns PlatformImage"),
         replace_all("let image = NSImage(data: data) else {",
                     "let image = PlatformImage(data: data) else {",
                     "decode via PlatformImage(data:)"),
     ))
edit("ExcalidrawZ/Sidebar/Library/LibraryItemView.swift",
     compose(
         replace_once("let excalidrawLibItemsCache: NSCache = NSCache<NSString, NSImage>()",
                      "let excalidrawLibItemsCache: NSCache = NSCache<NSString, PlatformImage>()",
                      "library item image cache via PlatformImage"),
         replace_all("Image(nsImage: nsImage)", "Image(platformImage: nsImage)",
                     "Image(platformImage:) init"),
     ))
edit("ExcalidrawZ/Share/ExportImageView.swift",
     compose(
         replace_once("    @State private var image: NSImage? = nil",
                      "    @State private var image: PlatformImage? = nil",
                      "image state via PlatformImage"),
         replace_once(EXPORTIMAGE_GUARD_OLD, EXPORTIMAGE_GUARD_NEW,
                      "thumbnail decode: NSImage (macOS) / UIImage (iOS)"),
         replace_once(THUMBNAIL_OLD, THUMBNAIL_NEW,
                      "thumbnailView: DragableImageView (macOS) / Image (iOS)"),
         replace_once(COPYIMAGE_OLD, COPYIMAGE_NEW,
                      "copy action: NSPasteboard (macOS) / UIPasteboard (iOS)"),
     ))
edit("ExcalidrawZ/Share/ExportFileView.swift",
     replace_once(COPYFILE_OLD, COPYFILE_NEW,
                  "copy file: NSPasteboard (macOS) / UIPasteboard (iOS)"))
edit("ExcalidrawZ/ExclidrawView/WebView/Coordinator/ExcalidrawStore+ScriptMessage.swift",
     dual_body(r"^    func handleCopy\(_ data: \[WebClipboardItem\]\) throws \{",
               HANDLECOPY_IOS, "UIPasteboard.general.setData",
               "handleCopy: NSPasteboard (macOS) / UIPasteboard (iOS)"))
edit("ExcalidrawZ/ExclidrawView/WebView/Coordinator/ExcalidrawStore+UI.swift",
     wrap_block(r"^    func webView\(\n        _ webView: WKWebView,\n        runOpenPanelWith parameters: WKOpenPanelParameters,",
                "wrap runOpenPanel (WKOpenPanelParameters/NSOpenPanel) in os(macOS)"))
edit("ExcalidrawZ/ExclidrawView/WebView/ExcalidrawView.swift",
     wrap_block(r"^    override func keyDown\(with event: NSEvent\) \{",
                "wrap keyDown(with: NSEvent) in os(macOS)"))
edit("ExcalidrawZ/Settings/AboutView.swift",
     replace_once(
         "                    Image(nsImage: NSApp.applicationIconImage)",
         "#if os(macOS)\n                    Image(nsImage: NSApp.applicationIconImage)\n#else\n                    Image(\"AppIcon\")\n#endif",
         "About icon: NSApp.applicationIconImage (macOS) / asset (iOS)"))
PYEOF

echo "== diff summary =="
git --no-pager diff --stat || true

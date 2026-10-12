#!/usr/bin/env bash
# fix_excalidraw_ios_guards.sh
# PATCH_SCRIPT for smoke-rehearsal.sh — makes ExcalidrawZ @ 8355c75 compile
# (platform-accepted anchor; swift tree identical to parent a7631da, so the
# same patch serves both — wave 7, 26 files +286/-43, validated at both refs)
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
# --- Wave 5 (build #30: last whole-module error) ---
#  18. Utils.swift                : iOS stand-in for ChocofordUI's macOS-only
#      `SharingsPicker` (pinned ChocofordKit 39a8bf5 defines it entirely inside
#      `#if os(macOS)`; call site ExportImageView.swift:188 passes
#      `isPresented:sharingItems:`). Stub is a UIViewControllerRepresentable
#      with the same call surface, presenting UIActivityViewController -> call
#      site compiles unchanged on iOS and works at runtime.
#
# --- Wave 6 (build #31: next compile batch) ---
#  19. ContentView.swift          : inspector clause macOS 14.0 -> macOS 14.0+iOS 17.0
#      (.inspector/.inspectorColumnWidth are iOS 17+; branch was type-checked on
#      iOS because the macOS clause is vacuously true there).
#  20. LibraryView.swift (#Preview): same clause fix for .inspector.
#  21. LibraryImportSheetView.swift: .toggleStyle(.checkbox) os(macOS)-wrapped.
#  22. ContentView.swift          : toolbarContent_iOS() body was left EMPTY by
#      upstream (never compiled upstream — macOS-only project); an empty
#      @ToolbarContentBuilder cannot infer Content at iOS 16 deployment ->
#      filled with a visually no-op ToolbarItemGroup(.bottomBar) { EmptyView() }.
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

SHARINGS_PICKER_IOS = """
// ==== iOS SharingsPicker stand-in (added by fix_excalidraw_ios_guards.sh) ====
// ChocofordKit 39a8bf5 defines SharingsPicker only for macOS
// (NSViewRepresentable around NSSharingServicePicker). Mirror the same
// call surface for iOS so ExportImageView.swift compiles unchanged;
// presents UIActivityViewController when isPresented flips to true.
#if !os(macOS)
import SwiftUI
import UIKit

struct SharingsPicker: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    var sharingItems: [Any] = []

    final class Coordinator { var presented = false }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> UIViewController {
        let vc = UIViewController()
        vc.view.backgroundColor = .clear
        return vc
    }

    func updateUIViewController(_ vc: UIViewController, context: Context) {
        guard isPresented, !context.coordinator.presented else { return }
        context.coordinator.presented = true
        let activityVC = UIActivityViewController(activityItems: sharingItems,
                                                  applicationActivities: nil)
        activityVC.completionWithItemsHandler = { _, _, _, _ in
            context.coordinator.presented = false
            isPresented = false
        }
        if UIDevice.current.userInterfaceIdiom == .pad {
            activityVC.popoverPresentationController?.sourceView = vc.view
            activityVC.popoverPresentationController?.sourceRect =
                CGRect(x: vc.view.bounds.midX, y: vc.view.bounds.midY, width: 1, height: 1)
        }
        vc.present(activityVC, animated: true)
    }
}
#endif
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
    # 3) wave 5 (build #30): iOS stand-in for the macOS-only ChocofordUI
    #    `SharingsPicker` (call site: ExportImageView.swift `.background(...)`).
    #    Separate sub-step so trees already carrying the old INFRA still get it.
    if "struct SharingsPicker: UIViewControllerRepresentable" in cur:
        notes.append("[keep: iOS SharingsPicker stub present]")
    else:
        cur = cur.rstrip("\n") + "\n" + SHARINGS_PICKER_IOS
        notes.append("[ok: appended iOS SharingsPicker stub (UIActivityViewController)]")
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
         "                    Image(nsImage: NSApp.applicationIconImage)\n"
         "                        .resizable()\n"
         "                        .frame(width: 128, height: 128)\n",
         "#if os(macOS)\n"
         "                    Image(nsImage: NSApp.applicationIconImage)\n"
         "                        .resizable()\n"
         "                        .frame(width: 128, height: 128)\n"
         "#else\n"
         "                    Image(\"AppIcon\")\n"
         "                        .resizable()\n"
         "                        .frame(width: 128, height: 128)\n"
         "#endif\n",
         "About icon: NSApp.applicationIconImage (macOS) / asset (iOS) — modifiers INSIDE branches (an #if element in a ViewBuilder list types as View, .resizable cannot chain after #endif)"))

# ---- wave 3 (build #28 errors): iOS-17-only SwiftUI APIs + macOS-only scene APIs ----
# Facts from #28: branches of `if #available(macOS X, *)` are type-checked on iOS
# (macOS clause is vacuously true there), but their `else` branches are skipped.
# Shape.fill(_:style:) is iOS 17+ in this SDK; replacements use iOS 13/15-era APIs:
# foregroundStyle (15+), stroke(Color) (13+), background(_:in:) (15+).
edit("ExcalidrawZ/ExcalidrawZApp.swift",
     compose(
         replace_once(
             "        Settings {\n"
             "            SettingsView()\n"
             "                .environmentObject(appPrefernece)\n"
             "#if os(macOS) && !APP_STORE\n"
             "                .environmentObject(updateChecker)\n"
             "#endif\n"
             "                .preferredColorScheme(appPrefernece.appearance.colorScheme)\n"
             "        }",
             "#if os(macOS)\n"
             "        Settings {\n"
             "            SettingsView()\n"
             "                .environmentObject(appPrefernece)\n"
             "#if os(macOS) && !APP_STORE\n"
             "                .environmentObject(updateChecker)\n"
             "#endif\n"
             "                .preferredColorScheme(appPrefernece.appearance.colorScheme)\n"
             "        }\n"
             "#endif",
             "wrap Settings scene in os(macOS)"),
         replace_once(
             "        if #available(macOS 13.0, *) {\n"
             "            return self.defaultSize(size)",
             "        if #available(macOS 13.0, iOS 17.0, *) {\n"
             "            return self.defaultSize(size)",
             "defaultSize clause + iOS 17.0"),
     ))
edit("ExcalidrawZ/Settings/SettingsView.swift",
     compose(
         replace_once(
             "                sidebar\n"
             "                    .toolbar(removing: .sidebarToggle)",
             "                sidebar\n"
             "#if os(macOS)\n"
             "                    .toolbar(removing: .sidebarToggle)\n"
             "#endif",
             "toolbar(removing:) os(macOS)-only (iOS 17+)"),
         replace_once(
             "            .removeSettingsSidebarToggle()\n"
             "            .navigationTitle(.localizable(.settingsNavigationTitle))",
             "#if os(macOS)\n"
             "            .removeSettingsSidebarToggle()\n"
             "#endif\n"
             "            .navigationTitle(.localizable(.settingsNavigationTitle))",
             "removeSettingsSidebarToggle os(macOS)-only"),
     ))
edit("ExcalidrawZ/ContentView.swift",
     compose(
         replace_once(
             "                    .toolbar(content: sidebarToolbar)\n"
             "                    .toolbar(removing: .sidebarToggle)",
             "                    .toolbar(content: sidebarToolbar)\n"
             "#if os(macOS)\n"
             "                    .toolbar(removing: .sidebarToggle)\n"
             "#endif",
             "toolbar(removing:) os(macOS)-only (iOS 17+)"),
         replace_once(
             "        .removeSettingsSidebarToggle()\n"
             "        .onChange(of: columnVisibility) { newValue in",
             "#if os(macOS)\n"
             "        .removeSettingsSidebarToggle()\n"
             "#endif\n"
             "        .onChange(of: columnVisibility) { newValue in",
             "removeSettingsSidebarToggle os(macOS)-only"),
         replace_once(
             "                                    RoundedRectangle(cornerRadius: 12)\n"
             "                                        .fill(.regularMaterial)\n"
             "                                        .shadow(radius: 4)",
             "                                    RoundedRectangle(cornerRadius: 12)\n"
             "                                        .foregroundStyle(.regularMaterial)\n"
             "                                        .shadow(radius: 4)",
             "fill->foregroundStyle (Shape.fill is iOS 17+)"),
         replace_once(
             "                            RoundedRectangle(cornerRadius: 12)\n"
             "                                .fill(.regularMaterial)\n"
             "                                .shadow(radius: 4)",
             "                            RoundedRectangle(cornerRadius: 12)\n"
             "                                .foregroundStyle(.regularMaterial)\n"
             "                                .shadow(radius: 4)",
             "fill->foregroundStyle (2nd site)"),
     ))
edit("ExcalidrawZ/Sidebar/SidebarView.swift",
     replace_once(
         "                    if #available(macOS 14.0, *) {\n"
         "                        Text(.localizable(.sidebarFilesPlaceholder))\n"
         "                            .foregroundStyle(.placeholder)",
         "                    if #available(macOS 14.0, iOS 17.0, *) {\n"
         "                        Text(.localizable(.sidebarFilesPlaceholder))\n"
         "                            .foregroundStyle(.placeholder)",
         "placeholder clause + iOS 17.0"))
edit("ExcalidrawZ/Share/ShareView.swift",
     compose(
         replace_once(
             "        .frame(width: 400, height: 300)\n"
             "        .visualEffect(material: .sidebar)",
             "        .frame(width: 400, height: 300)\n"
             "#if os(macOS)\n"
             "        .visualEffect(material: .sidebar)\n"
             "#endif",
             "visualEffect(material:) os(macOS)-only (ChocofordUI NSVisualEffect)"),
         replace_once(
             "                    if #available(macOS 14.0, *) {\n"
             "                        RoundedRectangle(cornerRadius: 12)\n"
             "                            .fill(\n"
             "                                isPressed ? AnyShapeStyle(Color.gray.opacity(0.4)) : AnyShapeStyle(isHovered ? .ultraThickMaterial : .regularMaterial)\n"
             "                            )\n"
             "                            .stroke(.separator, lineWidth: 0.5)\n"
             "                            .animation(.default, value: isHovered)",
             "                    if #available(macOS 14.0, *) {\n"
             "                        RoundedRectangle(cornerRadius: 12)\n"
             "                            .stroke(Color.gray.opacity(0.25), lineWidth: 0.5)\n"
             "                            .background(\n"
             "                                isPressed ? AnyShapeStyle(Color.gray.opacity(0.4)) : AnyShapeStyle(isHovered ? .ultraThickMaterial : .regularMaterial),\n"
             "                                in: RoundedRectangle(cornerRadius: 12)\n"
             "                            )\n"
             "                            .animation(.default, value: isHovered)",
             "share button bg: stroke+background(in:) (fill/separator iOS 17+)"),
     ))
edit("ExcalidrawZ/ExclidrawView/ExcalidrawToolbar.swift",
     replace_once(
         "                if #available(macOS 14.0, *) {\n"
         "                    RoundedRectangle(cornerRadius: 12)\n"
         "                        .fill(.regularMaterial)\n"
         "                        .stroke(.separator, lineWidth: 0.5)",
         "                if #available(macOS 14.0, *) {\n"
         "                    RoundedRectangle(cornerRadius: 12)\n"
         "                        .stroke(Color.gray.opacity(0.25), lineWidth: 0.5)\n"
         "                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))",
         "toolbar bg: stroke+background(in:) (fill/separator iOS 17+)"))
edit("ExcalidrawZ/Utils/SegmentedPicker/SegmentedPicker.swift",
     compose(
         replace_once(
             "                    RoundedRectangle(cornerRadius: 6)\n"
             "                        .fill(.background)\n"
             "                        .shadow(radius: 1, y: 2)",
             "                    RoundedRectangle(cornerRadius: 6)\n"
             "                        .foregroundStyle(.background)\n"
             "                        .shadow(radius: 1, y: 2)",
             "selection pill: fill->foregroundStyle"),
         replace_once(
             "            if #available(macOS 14.0, *) {\n"
             "                RoundedRectangle(cornerRadius: 12)\n"
             "                    .fill(.regularMaterial)\n"
             "                    .stroke(.separator, lineWidth: 0.5)",
             "            if #available(macOS 14.0, *) {\n"
             "                RoundedRectangle(cornerRadius: 12)\n"
             "                    .stroke(Color.gray.opacity(0.25), lineWidth: 0.5)\n"
             "                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))",
             "picker bg: stroke+background(in:) (fill/separator iOS 17+)"),
     ))
edit("ExcalidrawZ/Utils/Migration/MigrateToNewVersion.swift",
     compose(
         replace_once(
             "                RoundedRectangle(cornerRadius: 8)\n"
             "                    .fill(Color(hexString: \"#f57c00\"))",
             "                RoundedRectangle(cornerRadius: 8)\n"
             "                    .foregroundStyle(Color(hexString: \"#f57c00\"))",
             "migration badge: fill->foregroundStyle"),
         replace_once(
             "                        if #available(macOS 14.0, *) {\n"
             "                            RoundedRectangle(cornerRadius: 12)\n"
             "                                .fill(.thinMaterial)\n"
             "                                .stroke(.separator, lineWidth: 0.5)",
             "                        if #available(macOS 14.0, *) {\n"
             "                            RoundedRectangle(cornerRadius: 12)\n"
             "                                .stroke(Color.gray.opacity(0.25), lineWidth: 0.5)\n"
             "                                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))",
             "migrate card 1: stroke+background(in:)"),
         replace_once(
             "                            if #available(macOS 14.0, *) {\n"
             "                                RoundedRectangle(cornerRadius: 12)\n"
             "                                    .fill(.thinMaterial)\n"
             "                                    .stroke(.separator, lineWidth: 0.5)",
             "                            if #available(macOS 14.0, *) {\n"
             "                                RoundedRectangle(cornerRadius: 12)\n"
             "                                    .stroke(Color.gray.opacity(0.25), lineWidth: 0.5)\n"
             "                                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))",
             "migrate card 2: stroke+background(in:)"),
     ))
edit("ExcalidrawZ/Sidebar/Library/LibraryImportSheetView.swift",
     compose(
         replace_once(
             "                                                Circle().fill(.green)",
             "                                                Circle().foregroundStyle(.green)",
             "selection dot: fill->foregroundStyle"),
         replace_once(
             "                let roundedRectangle = RoundedRectangle(cornerRadius: 12)\n"
             "                roundedRectangle.stroke(.separator, lineWidth: 0.5)\n"
             "                roundedRectangle.fill(.regularMaterial)",
             "                let roundedRectangle = RoundedRectangle(cornerRadius: 12)\n"
             "                roundedRectangle.stroke(Color.gray.opacity(0.25), lineWidth: 0.5)\n"
             "                roundedRectangle.foregroundStyle(.regularMaterial)",
             "import sheet bg: separator->gray, fill->foregroundStyle"),
     ))
edit("ExcalidrawZ/Sidebar/Library/LibrarySection.swift",
     replace_once(
         "                                        Circle().fill(.green)",
         "                                        Circle().foregroundStyle(.green)",
         "selection dot: fill->foregroundStyle"))
edit("ExcalidrawZ/Settings/AboutChocofordView.swift",
     replace_once(
         "                    Capsule()\n"
         "                        .fill(.background)",
         "                    Capsule()\n"
         "                        .foregroundStyle(.background)",
         "badge bg: fill->foregroundStyle"))

# ---- wave 4 (build #29 errors): last 2 macOS-only modifier sites ----
# Build #29 (validator PASS, 12 -> 4 errors) proved the wave-3 wrap pattern
# compiles on iOS (SE-0308 postfix #if in member chains). Remaining sites:
#   a) ShareView.swift:81  .toolbar(.hidden, for: .windowToolbar)
#      (ToolbarPlacement.windowToolbar is macOS 13+ only; 'unavailable in iOS')
#   b) SettingsView.swift:45 (else branch of `#available(macOS 13.0, *)`)
#      .visualEffect(material: .sidebar) — ChocofordUI NSVisualEffect extension
#      does not exist on iOS -> same wrap wave 3 applied to ShareView:84.
#      (Note: else branches ARE type-checked on iOS — this site proves it.)
edit("ExcalidrawZ/Share/ShareView.swift",
     replace_once(
         "            .padding(.horizontal, 40)\n"
         "            .toolbar(.hidden, for: .windowToolbar)\n",
         "            .padding(.horizontal, 40)\n"
         "#if os(macOS)\n"
         "            .toolbar(.hidden, for: .windowToolbar)\n"
         "#endif\n",
         "windowToolbar placement os(macOS)-only"))
edit("ExcalidrawZ/Settings/SettingsView.swift",
     replace_once(
         "                sidebar\n"
         "                    .visualEffect(material: .sidebar)\n"
         "                    .frame(width: 200)\n",
         "                sidebar\n"
         "#if os(macOS)\n"
         "                    .visualEffect(material: .sidebar)\n"
         "#endif\n"
         "                    .frame(width: 200)\n",
         "else-branch visualEffect(material:) os(macOS)-only"))

# ---- wave 6 (build #31 errors): inspector/checkbox/empty iOS toolbar ----
#  a) ContentView: `if #available(macOS 14.0, *)` branch is type-checked on iOS
#     (vacuously true) but .inspector/.inspectorColumnWidth are iOS 17+ ->
#     extend the clause with iOS 17.0 (same pattern as wave 3's defaultSize/
#     placeholder fixes). On iOS 16 runtime the floating-bar else branch runs.
#  b) LibraryView DEBUG preview: same clause fix.
#  c) LibraryImportSheetView: ToggleStyle.checkbox is macOS-only -> os(macOS)
#     wrap (iOS default switch style applies).
#  d) ContentView.toolbarContent_iOS(): upstream left the body EMPTY and it
#     never compiled upstream (macOS-only project). An empty
#     @ToolbarContentBuilder body has no zero-arg buildBlock at iOS 16
#     deployment -> 'expected expression of type Content'. Supply a no-op item.
edit("ExcalidrawZ/ContentView.swift",
     compose(
         replace_once(
             "            if #available(macOS 14.0, *), appPreference.inspectorLayout == .sidebar {\n",
             "            if #available(macOS 14.0, iOS 17.0, *), appPreference.inspectorLayout == .sidebar {\n",
             "inspector clause + iOS 17.0"),
         replace_once(
             "    private func toolbarContent_iOS() -> some ToolbarContent {\n"
             "        \n"
             "    }\n",
             "    private func toolbarContent_iOS() -> some ToolbarContent {\n"
             "        // upstream left this body empty (never compiled upstream);\n"
             "        // an empty @ToolbarContentBuilder body cannot infer Content\n"
             "        // at iOS 16 deployment -> provide a visually no-op item.\n"
             "        ToolbarItemGroup(placement: .bottomBar) { EmptyView() }\n"
             "    }\n",
             "empty iOS toolbar builder -> no-op item"),
     ))
edit("ExcalidrawZ/Sidebar/Library/LibraryView.swift",
     replace_once(
         "        if #available(macOS 14.0, *) {\n"
         "            NavigationSplitView {\n",
         "        if #available(macOS 14.0, iOS 17.0, *) {\n"
         "            NavigationSplitView {\n",
         "preview inspector clause + iOS 17.0"))
edit("ExcalidrawZ/Sidebar/Library/LibraryImportSheetView.swift",
     replace_once(
         "                                    )\n"
         "                                    .toggleStyle(.checkbox)\n",
         "                                    )\n"
         "#if os(macOS)\n"
         "                                    .toggleStyle(.checkbox)\n"
         "#endif\n",
         "ToggleStyle.checkbox os(macOS)-only"))

# ---- wave 7 (build #32 errors): webview inspectable, iOS representable twin ----
#  a) ExcalidrawStore.swift: WKWebView.isInspectable is iOS 16.4+; the existing
#     `if #available(macOS 13.3, *)` clause is vacuously true on iOS -> extend
#     with iOS 16.4 (empty else branch already present upstream).
#  b) ExcalidrawView.swift: upstream left `#elseif os(iOS)` EMPTY — ExcalidrawView
#     is only NSViewRepresentable on macOS, so on iOS it is not a View and
#     ExcalidrawContainerView's `.preferredColorScheme` fails. Fill the hook with
#     a UIViewRepresentable twin (makeUIView/updateUIView/makeCoordinator);
#     updateUIView mirrors updateNSView verbatim (all coordinator methods are
#     cross-platform — verified they compile on iOS after the isInspectable fix).
#  c) FileListView.swift: two-param onChange(of:) { _, newValue in } is iOS 17+;
#     both closures ignore the old value -> convert to one-param (iOS 14+),
#     exactly what upstream's own else-branch already does.
edit("ExcalidrawZ/ExclidrawView/WebView/Coordinator/ExcalidrawStore.swift",
     replace_once(
         "            if #available(macOS 13.3, *) {\n"
         "                self.webView.isInspectable = true\n",
         "            if #available(macOS 13.3, iOS 16.4, *) {\n"
         "                self.webView.isInspectable = true\n",
         "isInspectable clause + iOS 16.4"))
edit("ExcalidrawZ/ExclidrawView/WebView/ExcalidrawView.swift",
     replace_once(
         "#elseif os(iOS)\n\n#endif",
         "#elseif os(iOS)\n"
         "// Upstream left this branch empty (macOS-only project at a7631da).\n"
         "// Provide the UIKit twin so ExcalidrawView is a View on iOS.\n"
         "extension ExcalidrawView: UIViewRepresentable {\n"
         "\n"
         "    func makeUIView(context: Context) -> ExcalidrawWebView {\n"
         "        context.coordinator.webView\n"
         "    }\n"
         "\n"
         "    func updateUIView(_ uiView: ExcalidrawWebView, context: Context) {\n"
         "        let webView = context.coordinator.webView\n"
         "        context.coordinator.parent = self\n"
         "        exportState.excalidrawWebCoordinator = context.coordinator\n"
         "        fileState.excalidrawWebCoordinator = context.coordinator\n"
         "        guard !webView.isLoading, !isLoading else { return }\n"
         "        Task {\n"
         "            do {\n"
         "                if appPreference.excalidrawAppearance == .auto {\n"
         "                    try await context.coordinator.changeColorMode(dark: colorScheme == .dark)\n"
         "                } else {\n"
         "                    try await context.coordinator.changeColorMode(dark: appPreference.excalidrawAppearance.colorScheme ?? colorScheme == .dark)\n"
         "                }\n"
         "            } catch {\n"
         "                self.onError(error)\n"
         "            }\n"
         "        }\n"
         "        context.coordinator.loadFile(from: fileState.currentFile)\n"
         "        if context.coordinator.lastTool != toolState.activatedTool {\n"
         "            Task {\n"
         "                do {\n"
         "                    if let rawValue = toolState.activatedTool?.rawValue {\n"
         "                        if rawValue < 10 {\n"
         "                            try await context.coordinator.toggleToolbarAction(key: rawValue)\n"
         "                        } else if let keyEquivalent = toolState.activatedTool?.keyEquivalent {\n"
         "                            try await context.coordinator.toggleToolbarAction(key: keyEquivalent)\n"
         "                        }\n"
         "                    }\n"
         "                } catch {\n"
         "                    self.onError(error)\n"
         "                }\n"
         "            }\n"
         "        }\n"
         "    }\n"
         "\n"
         "    func makeCoordinator() -> Coordinator {\n"
         "        Coordinator(self)\n"
         "    }\n"
         "}\n"
         "#endif",
         "fill empty os(iOS) hook: UIViewRepresentable twin"))
# NOTE: do NOT use replace_once here — its "already applied" check (`new in src`)
# false-positives because upstream's own else-branch already contains the
# one-param form. Count-based transform instead.
def drop_two_param_closures(src):
    """FileListView: two-param onChange closures are iOS 17+; both ignore the
    old value -> one-param (iOS 14+), mirroring upstream's own else-branch."""
    n = src.count("{ _, newValue in")
    if n == 0:
        return None, "already applied (onChange two-param -> one-param)"
    return src.replace("{ _, newValue in", "{ newValue in"), f"converted {n} onChange closure(s)"
edit("ExcalidrawZ/Sidebar/FileListView.swift", drop_two_param_closures)
PYEOF

echo "== diff summary =="
git --no-pager diff --stat || true

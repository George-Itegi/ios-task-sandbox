#!/usr/bin/env python3
"""Structural validator for Swift sources that use conditional compilation.

For every *.swift file under the given roots it renders TWO platform views
(macOS-active and iOS-active) by evaluating #if/#elseif/#else/#endif blocks,
then checks brace/paren/bracket balance of each view with comments and string
literals masked.

Catches the build-#25 class of bug locally, before spending a Bitrise build:
  - leftover statements after a replaced guard's #endif
  - one statement's braces split across #if/#else branches (Swift forbids)

Usage: python3 validate_swift_conditional.py <dir-or-file> [more...]
Exit 0 = all balanced; exit 1 = listing of failures.
"""
import re
import sys
from pathlib import Path

SKIP_DIRS = {".git", ".build", "DerivedData", "Pods", "target", "artifacts", ".swiftpm"}

FLAVORS = {
    "macos": {
        "os_macos": True, "os_ios": False, "os_tvos": False, "os_watchos": False,
        "can_AppKit": True, "can_UIKit": False, "can_Sparkle": True,
        "tenv_simulator": False, "tenv_macCatalyst": False,
        "arch_arm64": True, "arch_x86_64": True, "DEBUG": True, "APP_STORE": False,
    },
    "ios": {
        "os_macos": False, "os_ios": True, "os_tvos": False, "os_watchos": False,
        "can_AppKit": False, "can_UIKit": True, "can_Sparkle": False,
        "tenv_simulator": True, "tenv_macCatalyst": False,
        "arch_arm64": True, "arch_x86_64": True, "DEBUG": True, "APP_STORE": False,
    },
}


def eval_cond(cond, flavor):
    env = FLAVORS[flavor]
    expr = cond.strip()
    # func-like atoms -> identifiers
    expr = re.sub(r"\bos\((\w+)\)", lambda m: "os_" + m.group(1).lower(), expr)
    expr = re.sub(r"\bcanImport\((\w+)\)", lambda m: "can_" + m.group(1), expr)
    expr = re.sub(r"\barch\((\w+)\)", lambda m: "arch_" + m.group(1).lower(), expr)
    expr = re.sub(r"\btargetEnvironment\((\w+)\)", lambda m: "tenv_" + m.group(1), expr)
    expr = re.sub(r"\bswift\([^)]*\)", "swiftver", expr)
    expr = re.sub(r"\bcompiler\([^)]*\)", "swiftver", expr)
    expr = expr.replace("&&", " and ").replace("||", " or ")
    expr = re.sub(r"!(?!=)", " not ", expr)
    # every remaining identifier must resolve; unknown conditions count as True
    for tok in re.findall(r"[A-Za-z_]\w*", expr):
        if tok in ("and", "or", "not", "True", "False"):
            continue
        if tok not in env:
            env[tok] = True
    try:
        return bool(eval(expr, {"__builtins__": {}}, env))  # noqa: S307 - controlled input
    except Exception:
        return True  # unparseable condition -> treat as active, let compiler judge


def render(src, flavor):
    """Return (active_lines, problems) for one flavor."""
    out, problems = [], []
    stack = []  # frames: [taken_any, current_active]
    for lineno, raw in enumerate(src.splitlines(), 1):
        s = raw.strip()
        m_if = re.match(r'#if\s+(.*)$', s)
        m_eif = re.match(r'#(?:elseif|elif)\s+(.*)$', s)
        if m_if:
            active = eval_cond(m_if.group(1), flavor)
            stack.append([active, active])
            continue
        if m_eif:
            if not stack:
                problems.append(f"line {lineno}: #elseif without #if")
                continue
            fr = stack[-1]
            active = (not fr[0]) and eval_cond(m_eif.group(1), flavor)
            fr[0] = fr[0] or active
            fr[1] = active
            continue
        if re.match(r'#else\b', s):
            if not stack:
                problems.append(f"line {lineno}: #else without #if")
                continue
            fr = stack[-1]
            fr[1] = not fr[0]
            fr[0] = True
            continue
        if re.match(r'#endif\b', s):
            if not stack:
                problems.append(f"line {lineno}: #endif without #if")
                continue
            stack.pop()
            continue
        if all(fr[1] for fr in stack):
            out.append(raw)
    if stack:
        problems.append("unterminated #if at end of file")
    return "\n".join(out) + "\n", problems


OPEN = {"{": "}", "(": ")", "[": "]"}
CLOSE = {"}": "{", ")": "(", "]": "["}


def scan(text, flavor, path):
    """Brace/paren/bracket balance with comments + strings masked."""
    depth = {"{": 0, "(": 0, "[" : 0}
    state = "code"
    delim = ""
    i, n, line = 0, len(text), 1
    while i < n:
        c = text[i]
        if c == "\n":
            line += 1
            i += 1
            if state == "linecomment":
                state = "code"
            elif state == "str" and delim == '"':
                problems = f"unterminated \" string at line {line - 1}"
                return depth, problems
            continue
        if state == "blockcomment":
            if text.startswith("*/", i):
                state, i = "code", i + 2
            else:
                i += 1
            continue
        if state == "linecomment":
            i += 1
            continue
        if state == "str":
            if c == "\\":
                i += 2
                continue
            if text.startswith(delim, i):
                state, i = "code", i + len(delim)
            else:
                i += 1
            continue
        # --- code state ---
        if text.startswith("/*", i):
            state, i = "blockcomment", i + 2
            continue
        if text.startswith("//", i):
            state, i = "linecomment", i + 2
            continue
        m = re.match(r'(#+)"""', text[i:])
        if m:
            hashes = m.group(1)
            state, delim, i = "str", '"""' + hashes, i + len(hashes) + 3
            continue
        m = re.match(r'(#+)"', text[i:])
        if m:
            hashes = m.group(1)
            state, delim, i = "str", '"' + hashes, i + len(hashes) + 1
            continue
        if text.startswith('"""', i):
            state, delim, i = "str", '"""', i + 3
            continue
        if c == '"':
            state, delim, i = "str", '"', i + 1
            continue
        if c in OPEN:
            depth[c] += 1
        elif c in CLOSE:
            depth[CLOSE[c]] -= 1
            if depth[CLOSE[c]] < 0:
                return depth, f"extra '{c}' at line {line}"
        i += 1
    if state == "blockcomment":
        return depth, "unterminated /* comment"
    if state == "str":
        return depth, f"unterminated string (delim {delim!r})"
    return depth, None


def validate(path):
    src = path.read_text(encoding="utf-8", errors="replace")
    fails = []
    for flavor in FLAVORS:
        view, problems = render(src, flavor)
        if problems:
            fails.append(f"{flavor}: {problems[0]}")
            continue
        depth, problem = scan(view, flavor, path)
        if problem:
            fails.append(f"{flavor}: {problem}")
        else:
            bad = {k: v for k, v in depth.items() if v != 0}
            if bad:
                fails.append(f"{flavor}: unbalanced {bad}")
    return fails


def main():
    roots = [Path(a) for a in sys.argv[1:]]
    files = []
    for r in roots:
        if r.is_file():
            files.append(r)
        else:
            files += [p for p in sorted(r.rglob("*.swift")) if not (SKIP_DIRS & set(p.parts))]
    if not files:
        print("ERROR: no swift files found under", *map(str, roots))
        return 1
    failures = {}
    for p in files:
        fails = validate(p)
        if fails:
            failures[p] = fails
    for p, fails in failures.items():
        print(f"FAIL {p}")
        for f in fails:
            print(f"     - {f}")
    if failures:
        print(f"SWIFT STRUCTURE VALIDATION: FAIL ({len(failures)}/{len(files)} files)")
        return 1
    print(f"SWIFT STRUCTURE VALIDATION: PASS ({len(files)} files x {len(FLAVORS)} flavors)")
    return 0


if __name__ == "__main__":
    sys.exit(main())

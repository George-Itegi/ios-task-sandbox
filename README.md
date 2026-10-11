# iOS Task Sandbox (private)

Reusable GitHub Actions harness for authoring iOS tasks for the expert platform
from a Windows/WSL machine. The macOS work happens here, on GitHub's runners.

**Keep this repository PRIVATE.** It will hold your reference solutions, and a
public solution can trip the platform's originality check.

## Layout

```
.github/workflows/qualifier.yml    Proves a repo builds on Xcode 26.x for iOS (~10-15 mac-min)
.github/workflows/rehearsal.yml    Runs your check twice: solved (must pass) + base (must fail)
checks/smoke-build-launch.sh       Example/harness smoke test (build + install + launch)
checks/lib/platform-stubs.sh       Stand-ins for the platform's pass/fail + siri_* + appium_* helpers
solutions/                         Your solve.sh scripts live here (one per task)
```

## Setup (once)

1. Create a **private** GitHub repo (e.g. `ios-task-sandbox`).
2. Copy this folder's contents into it (keep the `.github/workflows` path).
3. Ensure every text file uses **LF line endings** (`.gitattributes` or editor setting).
4. Push. Actions are enabled by default for private repos.

## Workflow 1 — Qualify a repository (run before authoring anything)

Actions → **Repo Qualifier** → Run workflow → paste the repo URL (and ref, if
the platform's base commit differs from the branch head).

Green + "Build succeeded" = safe to author tasks on this repo.
Red = read the summary; likely Swift 6.2 incompatibilities or missing committed Pods.

Budget: ~10–15 macOS minutes per run. Free private tier gives ~200 macOS
min/month (10× multiplier) — qualify several repos in one sitting, but rehearse
selectively.

## Workflow 2 — Rehearse a task bundle (before every submission)

1. Write `solutions/<task>.sh` (assumes `$WORKSPACE` = repo clone; edits files
   only, no builds, no network).
2. Write `checks/<task>-check.sh`: same logic as your platform check block,
   but `source "$(dirname "$0")/lib/platform-stubs.sh"` at the top, and keep
   Appium UI assertions out (v1 stubs fail loudly).
3. Actions → **Task Rehearsal** → paste repo URL, ref, solve path, check path.
4. Read the matrix result:
   - `solved` ✅ + `base` ❌ → task is wired correctly. Submit.
   - `solved` ❌ → your solution or check is wrong.
   - `base` ✅ → your check passes the unchanged repo — the task is not a real
     behavior change; tighten the check.
   - Smoke-test exception: `smoke-build-launch.sh` asserts no features, so
     "base verdict=pass" is expected and fine — it only proves the harness.

## Environment parity with the platform

- The platform mac runs a **clean shell** with only: Xcode toolchain, python3,
  node, xcodegen. Do not make checks depend on brew-installed tools.
- Simulator flags to always mirror:
  `-disableAutomaticPackageResolution -skipMacroValidation -skipPackagePluginValidation`,
  `CODE_SIGNING_ALLOWED=NO`, `-destination "platform=iOS Simulator,id=$UDID"`.
- Rehearsal creates its own simulator (fine — it is your machine). The SHIPPED
  check must only use the platform-provided `$UDID`, never create/boot one.
- Reference solutions run **offline** and must not add dependencies.

## Windows authoring reminders

- `git config --global core.autocrlf input` before committing any `.sh` file.
- CRLF shell scripts are refused by the platform's format checks.
- Author and explore repos in WSL; only builds need this sandbox.

---
name: upstream-rebase
description: Sync this fork (origin=Whoaa512/supacode) against upstream/main (supabitapp/supacode) by cherry-picking fork features onto a fresh cut of upstream, dropping commits upstream has obsoleted, fixing conflicts iteratively (asking when ambiguous), building/validating, then waiting for user validation before tagging and promoting cj-main. Use when asked to "rebase on upstream", "sync the fork", "check upstream changes", or "fetch upstream".
---

# Upstream Sync + cj-main Promotion (supacode)

Keep this fork current against upstream. `origin` = `Whoaa512/supacode` (CJ's fork), `upstream` = `supabitapp/supacode`. CJ's only line in `AGENTS.local.md`: always commit to `cj-main`, no feature branches — but the sync itself happens on a throwaway `cj-main-rebase-*` branch and is promoted into `cj-main` only at the end.

Hard rules:
- Never touch `cj-main` directly until the very end, and only with the user's explicit go-ahead.
- Never open PRs to upstream. Everything stays on local branches/tags.
- Always set `GIT_EDITOR=true` so git never opens an editor (and use `--no-edit` on cherry-pick continues).
- **Cherry-pick onto a fresh cut, do NOT rebase or merge.** Fork patches touch the same files repeatedly (RepositoriesFeature, AppFeature, WorktreeTerminalManager, Info.plist), so a rebase/merge replays the same conflict many times. A fresh branch from `upstream/main` + clustered cherry-picks is the proven approach.

## 1. Survey the gap

```bash
git status && git branch --show-current
git fetch upstream
git merge-base cj-main upstream/main                 # the base; call it $BASE
git log --oneline cj-main..upstream/main | head -60  # incoming
git log --oneline cj-main..upstream/main | wc -l
git log --oneline --reverse --no-merges $BASE..cj-main   # our patches, in apply order
```

Dry-run the conflict surface (then abort — we won't actually merge):

```bash
git merge --no-commit --no-ff upstream/main 2>&1 | head -60
git status --short | rg '^UU' | wc -l
git merge --abort
```

Summarize for the user: incoming commit count, fork-patch count, conflict-file count.

## 2. Feature-overlap analysis (decide what to DROP)

The biggest win is dropping fork commits upstream has since implemented (often with a different/better architecture) plus stale build-fixup commits. For each fork feature cluster, check whether upstream now has it:

```bash
git show upstream/main:<path/to/file.swift> 2>/dev/null | rg -i "<symbol>"
git ls-tree -r upstream/main | rg -i "<FeatureName>"
```

Recurring verdicts from past syncs:
- **AgentBusyState enum / `waitingForInput` / waiting-for-input indicator** → upstream replaced with a centralized `AgentPresenceManager` (`.awaitingInput`). **Drop** the fork's socket-server-level enum commits.
- **Equalize splits on split/close** → upstream has `.equalizeSplits` / `.equalize` *manual* actions (`SplitTree.equalize()`/`.equalized()`), but NOT the fork's auto-on-split/close *setting toggle* (`equalizeSplitsOnSplit`). **Keep** the fork's setting commits; expect conflicts in `WorktreeTerminalState.swift` (context drift around `createSurface`/notifications) — take HEAD, the equalize `if` usually applies clean.
- **In-app project browser (⌘⇧O / `CommandPaletteBrowseView`), fork-worktree-from-branch** → still **unique to fork**, keep.
- **Scrollback persistence (fork's `.vt`-file approach)** → **DROP** (2026-06): upstream landed zmx-based live session persistence (#334/#369/#361, `ThirdParty/zmx`, `ZmxClient`, `LayoutsPersistenceKey`). zmx keeps the real shell alive across quit; the fork's text-replay is strictly inferior and has no migration path (dead `.vt` dumps can't become live zmx daemons). Dropping it reverts the custom ghostty submodule to upstream's.
- **Searchable base-ref picker, auto-select first worktree** → **DROP** (2026-06): upstream subsumed both (#350 `BaseRefBranchMenu`; `shouldSelectFirstAfterReload`). Re-implement searchable picker later only if wanted.
- **Sidebar folders (`SidebarFolder` repo-grouping)** → **DROP rendering, can't cherry-pick** (2026-06): upstream rebuilt the sidebar around `SidebarStructure` + `SidebarSectionDispatcher` (#323/#324/#328) and *reuses the word `.folder`* in `SidebarStructure.Section.folder(repositoryID:, rowID:)` for a **non-git directory opened as a repo** — a different concept. The fork's 245-line `SidebarFolderSectionView` targets the deleted `SidebarRootView`/`displayItems` path. This is a feature-port, not a cherry-pick. Drop `b54322c9`/`c5785b60`/`9cef9dff` and the folder-reorder fix `f66c1c08`; note re-impl in `plans/sidebar-folders-reimpl.md`.
- **Build-fixup / rebase-repair commits** that only made sense against the old base → drop; they won't apply and you'll re-fix forward.

Produce a table (fork feature | upstream status | keep/drop) and a cherry-pick plan grouped into clusters. Present to the user before executing if the drop set is non-obvious.

## 3. Fresh branch + safety tag

```bash
git tag cj-main-pre-rebase-$(date +%F) cj-main           # safety
git checkout -b cj-main-rebase-$(date +%F) upstream/main  # fresh cut of upstream
```

(Branch naming convention from history: `cj-main-rebase-YYYY-MM-DD`.)

## 4. Cherry-pick feature clusters

Cherry-pick the keep-set in `--reverse --no-merges` order, cluster by cluster:

```bash
GIT_EDITOR=true git cherry-pick <sha> [<sha> ...]
```

On conflict:
1. `rg -n "<<<<<<<|=======$|>>>>>>>" <file>` to locate markers.
2. Resolve. Guidance from past conflicts:
   - Conflicts in code tied to a **dropped** feature (e.g. `onBusy` handler) → take HEAD (upstream), drop the fork hunk.
   - **`Info.plist`** → upstream sets static `CFBundleDisplayName=Supacode`; fork wants build-var display name for dev builds. Keep fork's build-var version but **remove the duplicate key**.
   - Heavily-refactored upstream areas (AppFeature using `appLifecycleClient`, `allScripts`, `surfaceMainWindow()`, `pruneScriptRecencyEffect`) → take upstream's structure, graft only the fork's net-new additions on top. If the fork commit fights too much upstream refactor, **skip it and re-implement the feature later** on the building branch (note it for the user).
3. Re-grep to confirm zero markers, then `git add <files>` and `GIT_EDITOR=true git cherry-pick --continue --no-edit`.

When a conflict is **ambiguous** — doesn't match a documented pattern, both sides carry real semantic changes, or you can't tell the intended behavior — STOP and `intme` (one question at a time, with your recommended answer). Don't guess on semantic conflicts.

## 5. Build + validate

```bash
make check          # swift-format + swiftlint (strict)
make build-app      # Debug build via xcodebuild
make test           # all tests; add tests for any reducer logic touched
```

Known pre-existing quirks (NOT introduced by the sync — verify against `cj-main` before chasing):
- TCA + current Xcode strict concurrency can surface a single error in TCA itself; `SWIFT_VERSION=5` on the app target is the existing mitigation (Makefile auto-injects `LOCAL_XCODEBUILD_FLAGS=SWIFT_VERSION=5` on Xcode 26.4/26.5).
- `make build-app` can report failure due to `xcbeautify` + `pipefail` exit-code handling even when raw `xcodebuild` prints **BUILD SUCCEEDED / EXIT: 0**. Re-run raw `xcodebuild` to confirm true status before treating it as a real failure.
- **Xcode version REQUIREMENT (zig#31272): you MUST build with an Xcode whose macOS SDK is ≤ 26.3.** zig 0.15.2's self-hosted linker can't link the macOS 26.4+ SDK, so ghostty AND zmx foreign builds fail with `undefined symbol: _fork` (libSystem) under Xcode 26.4/26.5. Upstream's CI (`.github/actions/setup-macos`) selects the newest Xcode ≤ 26.3 for exactly this reason. Check `plutil -extract Version raw "$(xcrun --show-sdk-path)/SDKSettings.plist"`; if > 26.3, `sudo xcode-select -s /Applications/Xcode_26.3.app/Contents/Developer`.
  - The CommandLineTools SDK is often ≤ 26.3 (linkable) but has **no iOS SDK**. `DEVELOPER_DIR=CommandLineTools` + a ghostty patch (native-only xcframework) can build *ghostty*, but **zmx still fails**: its ghostty *package dependency* eagerly runs `GhosttyXCFramework.init`, which builds the iOS slice (`emit_xcframework` defaults on) and calls `findNative` → `DarwinSdkNotFound`. The cached zig package can't be durably patched. Conclusion: don't fight it with CLT — just install/select Xcode ≤ 26.3.
- **Do NOT run `make check` (or `make format`) under a mismatched Xcode.** Xcode 26.5's `swift-format` adds trailing commas everywhere and rewrites ~260 files (formatter-version drift vs upstream's ≤26.3). To validate without the churn, run `mise exec -- swiftlint lint --quiet --config .swiftlint.yml <files>` directly (swiftlint enforces the mandatory trailing commas anyway). If you accidentally reformat the tree, `git checkout -- .` to discard — but re-apply any real cherry-pick fixups first, since that command nukes uncommitted work too.

Fix syntax fallout from cherry-picks (stray/duplicate braces from conflict resolution are common — e.g. an extra `}` closing a SwiftUI `switch`/`VStack` early, or a doubled `}` ending a test func). Also watch swiftlint **cyclomatic_complexity** (limit 15): cherry-picked features that add a branch/case to an already-near-limit function (e.g. `performSplitAction`, `delegateAction`) tip it over — extract the case body into a helper (matches the repo's line-of-sight style). Commit cleanup on the throwaway branch (commit the specific files, never `git add -A` after a stray `make check`).

## 6. Install dev build for dogfooding

```bash
make install-dev-build   # builds + copies to /Applications
```

Tell the user exactly which features to validate: the kept fork features (scrollback persistence, project browser, sidebar folders, fork-worktree, base-ref picker, etc.) plus anything you **skipped/re-implemented** in step 4. Call out anything still missing.

## 7. WAIT for user validation

Do not promote. Report: clusters cherry-picked, commits dropped (and why), conflicts resolved, build/test status, dev build installed, features needing manual validation. If the user wants missing items fixed, offer a `tdd loop fix` prompt. Only continue when the user explicitly says it's good / to promote.

## 8. Tag + promote cj-main

Only after the user confirms. Tag the OLD cj-main head for rollback, then fast-forward cj-main onto the rebase branch:

```bash
git tag cj-main-v<version>-$(date +%F) cj-main          # e.g. cj-main-v0.8.0-2026-05-15
git branch -f cj-main cj-main-rebase-$(date +%F)
git checkout cj-main && git log --oneline -1
```

(History uses `git branch -f cj-main <rebase-branch>` — `--ff-only` merge works too when cj-main is a strict ancestor.)

Push only when the user explicitly asks (never `git push` blindly):

```bash
git push origin cj-main
git push origin cj-main-pre-rebase-$(date +%F) cj-main-v<version>-$(date +%F)
```

## 9. Update this skill / AGENTS.local.md

If you learned a new keep/drop verdict, conflict pattern, or build quirk, append it here so the next sync is cheaper.

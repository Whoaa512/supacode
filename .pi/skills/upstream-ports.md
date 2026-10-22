---
name: upstream-ports
description: Port selected upstream (supabitapp/supacode) commits onto this fork's cj-main (origin=Whoaa512/supacode) by classifying each new upstream commit port/skip, cherry-picking with -x, running targeted tests, and writing a dated ports note under plans/. Never rebases the whole fork. Use when asked to "check upstream", "sync the fork", "fetch upstream", "port upstream changes", or "rebase on upstream" (answer: we port, we don't rebase).
---

# Upstream ports (supacode fork)

`origin` = `Whoaa512/supacode`, `upstream` = `supabitapp/supacode`. Work happens
directly on `cj-main`. Since 2026-10 the fork is its own thing: tasks own
layouts (`TaskRecord`, `LayoutID`), the terminal data model differs, so a
rebase or fresh-cut cherry-pick of the fork onto upstream is off the table
(decision in `plans/task-as-unit-sizing.md`; the retired flow lived in
`.pi/skills/upstream-rebase.md`, see git history). Upstream changes come in one
commit at a time or not at all.

Hard rules:
- **Never rebase, merge, or re-cut the fork onto upstream.** Only `cherry-pick -x`.
- Never open PRs to upstream. Never `git push` unless asked.
- `GIT_EDITOR=true` on every git command that could open an editor.
- Never `git stash` mid-port (a pop once resurrected an unrelated old stash
  into ~150 conflicted files). Compare with `git show <ref>:<path>` instead.
- Keep upstream authorship: `git cherry-pick -x <sha>`, no `--author` games.

## 1. Survey

```bash
git status --short && git branch --show-current     # must be cj-main, clean
git fetch upstream --tags
LAST=$(git tag -l 'upstream-reviewed/*' | sort | tail -1)
git log --oneline --no-merges $LAST..upstream/main | cat   # candidates, newest first
git log --oneline --no-merges $LAST..upstream/main | wc -l
```

`upstream-reviewed/YYYY-MM-DD` tags mark the upstream commit the last review
stopped at; everything before it is already decided (see the ports notes), do
not re-classify. `cj-main..upstream/main` is useless here: the merge-base is
frozen at the 2026-09 fork point and cherry-picks never move it.

## 2. Classify each commit: port / skip

For each candidate, `git show --stat <sha>` and decide. Standing verdicts:

| Upstream area | Verdict |
|---|---|
| Build tooling, Makefile, scripts, ghostty/zmx patches | port (check the fork's SDK-overlay fallthrough in `scripts/select-developer-dir.sh` survives) |
| Git client, watcher, fsmonitor, PR/status polling | port; the fork often has its own fix for the same symptom, keep both when they compose |
| Agent presence, hook extensions, OSC protocol | port, then re-check installed extensions (Settings → agent integrations must read "Installed") |
| Licensing, Team leases, creation limits, checkout prompts | skip: no licensing in the fork |
| OpenCode plugin and other agents the fork does not use | skip |
| Version bumps (`bump vX.Y.Z`, `build: prepare version`) | skip: the fork versions itself |
| Anything touching `WorktreeContentHost`, `LayoutFeature`, `TerminalsFeature`, `LayoutPersistence`, layouts keyed by worktree | usually skip; if the behaviour matters, it is a re-implementation against tasks, not a port. Note it in the ports file under "Re-implement later" |
| Sidebar rendering | port only if it fits `sidebarItems` / `sidebarStructure` (AGENTS.md invalidation rule) |

When a verdict is ambiguous (both sides carry real semantics, or you cannot
tell what the fork wants), stop and ask with your recommended answer. Do not
guess on semantic conflicts.

## 3. Cherry-pick, oldest first

```bash
GIT_EDITOR=true git cherry-pick -x <sha>
```

On conflict: `rg -n "<<<<<<<|=======$|>>>>>>>" <files>`, resolve preserving
fork behaviour, re-grep for zero markers, `git add <files>`,
`GIT_EDITOR=true git cherry-pick --continue`. If the pick fights the task
model, `git cherry-pick --abort` and reclassify as skip / re-implement.

Conflict shapes that recur: a union of two `case a, b:` lists, two
`private` → non-`private` visibility edits on the same declaration (the fork
exposes types for tests), the shared closing brace at the end of a conflict
region (`awk` brace delta must be 0), the HEAD side's last initializer line
missing a trailing comma after a union.

## 4. Validate each pick

```bash
make generate-project       # if the pick adds a test file
make check                  # swift-format + swiftlint
make test LOCAL_XCODEBUILD_FLAGS='SWIFT_VERSION=5 -only-testing:<bundle>/<Suite>'
xcrun xcresulttool get test-results summary --path build/supacode-tests.xcresult   # totalTestCount > 0
make build-app
```

`SWIFT_VERSION=5` is mandatory whenever `LOCAL_XCODEBUILD_FLAGS` is set (TCA
strict-concurrency workaround). Test bundle routing is in AGENTS.md; the wrong
bundle runs zero tests and reports success. If `make build-app` fails with
CodeSign "bundle format unrecognized": `rm -rf .build/**/supacode.app/Contents/PlugIns`
and retry. If `make check` reformats hundreds of files, your Xcode's
swift-format drifted; lint the touched files only and do not commit the churn.

Known isolated-pass flakes: `settingsChangedPropagatesRepositorySettings`,
`deleteSocketDeeplinkFailsOnScriptCancellation`. `GhosttyRuntimeBundledOverridesTests`
color tests read the real `~/.config/ghostty/config`.

One commit per ported upstream commit (the cherry-pick itself). Conflict
fix-ups go into that commit, not a follow-up.

## 5. Write the ports note

`plans/upstream-sync-YYYY-MM-DD-ports.md`, shape of
`plans/upstream-sync-2026-10-20-ports.md`: upstream HEAD sha, gap size, a
"Ported" list (sha, title, what conflicted and how it was resolved, tests run
with counts), a "Skipped" list (sha, one line why), optionally "Re-implement
later" for task-model ports. Commit it on its own, then move the pointer:

```bash
git tag upstream-reviewed/YYYY-MM-DD upstream/main
```

(Tags push with `git push origin --tags` only when asked.)

## 6. Report

Ported shas, skipped shas with reasons, tests run, build status, anything
that needs dogfooding (agent badges after protocol changes, scrollback,
browse mode ⌘⇧O, fork-worktree-from-branch). Do not push.

## 7. Keep this skill current

New standing verdicts or conflict shapes go into the tables above, not into a
dated learnings section.

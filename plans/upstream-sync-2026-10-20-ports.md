# Upstream sync 2026-10-20 — selective ports

Upstream HEAD: `upstream/main` @ 2ec32a6dd (bump v0.11.5). Gap since the last
sync: 16 commits (`git log cj-main..upstream/main`).

First sync under the new process (`.pi/skills/upstream-ports.md`): the fork
is no longer rebased onto upstream. Tasks own layouts here (`TaskRecord`,
`LayoutID`), so upstream's worktree-owned terminal layer and ours have
diverged for good. Each upstream commit is classified port / skip and ported
with `git cherry-pick -x` on `cj-main`.

## Ported

- `2fa4e79cd` Select supported Xcode before generating the workspace (#891).
  Clean pick.
- `2b33f4c05` watcher: stop idle refresh loops from fsmonitor (#907). One
  conflict in `WorktreeInfoWatcherManager.swift`: the fork already had a
  path-only pre-filter (`WorktreeFileEventMonitor.isRelevant`, drops
  `fsmonitor--daemon` and `objects` under `.git`/`.bare`). Kept it and layered
  upstream's `WorktreeFileEventFilter` (flag-aware, resolves the real git
  dir, handles submodules) behind it. Also brings `--no-optional-locks` on
  the shortstat diff. Tests: `WorktreeFileEventFilterTests`,
  `WorktreeInfoWatcherManagerTests` (supacodeTests),
  `GitClientLineChangesTests` (supacodeGitTests): 39/39.

## Skipped

- `9d0687fe1` licensing: require a license after five local worktree
  creations (#892): the fork has no license checkout; a creation cap is
  hostile to the parallel-worktree workflow this fork exists for.
- `68cb53ace` `1832ebf71` `0d96942bc` `1c2b06e2e` `194708319` (+ merges
  `c308b56f6` `ecb96c56e` `aa0b3d1f8`) licensing/Team leases, entitlements,
  purchase prompt: all build on the creation limit; no licensing in the fork.
- `b5fd9d9fe` opencode: presence through a TUI plugin (#909): we do not use
  OpenCode; the plugin ships a bundled JS asset we would have to maintain.
- `af5b4e32e` `7fd94fc11` `2ec32a6dd` `0e5dd3e8a` version bumps: the fork
  versions itself.

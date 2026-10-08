# Task as the unit — sizing notes

Status: **exploring** (not scoped). Idea: the sidebar row becomes a task that
owns its own layout (agent sessions + plain shells), instead of a derived row
pointing into a worktree-owned layout.

Read `ideas-graveyard.md` (Task Inbox) first. This only differs if a task is
never created by hand: it is minted from the first agent session, and every
indexed session without a task is its own task.

## Blast radius (measured on cj-main at 86ec3ec5)

- `LayoutFeature.State.id` is `Worktree.ID`; layouts live in
  `terminals.layouts[id: worktreeID]`: 29 source call sites, 46 in tests.
- `WorktreeTerminalManager.swift` (2574 lines): 232 worktree references, 7
  dictionaries/sets keyed by `Worktree.ID`.
- `PaneWindowManager.swift` 58, `TerminalsFeature.swift` 43,
  `TerminalClient.swift` 36 worktree references.
- 43 places in the terminal layer use the full `Worktree` (cwd, host), not
  just its id.
- `selectedWorktreeID` drives the detail view: 168 uses in 15 files.
- Persistence: `LayoutsFile.worktrees: [String: LayoutRecord]`.

## TODO (after the departure lands)

- [ ] Decide whether this fork is still supacode. The task-owned layout
  rewrites the terminal layer upstream keeps changing, so the
  `upstream-rebase` skill's cherry-pick-onto-fresh-upstream flow may stop
  working. Work out the replacement process (selective ports, as in
  `upstream-sync-2026-09-16-ports.md`?) and whether to rename.

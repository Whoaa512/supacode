# Task as the unit — sizing notes

Status: **landed on `cj-main`, 2026-10-12.** Every decision below shipped
through `task-as-unit-plan.md` (phases R, F, T, S, K, M, P, Z; see its
Progress section). Open: the TODO at the bottom on the upstream process. Idea: the sidebar row becomes a task that
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

## Spike: can cwd be split from the layout key?

Yes. The terminal layer uses `Worktree.ID` only as an opaque key (layouts,
hosts, persistence, zmx, CLI commands). All 43 full-`Worktree` sites read
directory facts off the value: cwd, remote host, repo root (repo settings,
setup scripts) and name (tab title prefix). Read-only spike; nothing compiled.

Known id-is-a-path sites: deeplink and CLI id parsing
(`DeeplinkClient.swift:152,223`, `supacodeApp.swift:630,688`),
`AppFeature.resolveWorktreeID`, the name fallback at
`WorktreeTerminalManager.swift:1862`, `Repository.swift:143`.

Not read yet: git watchers, `prune(keeping:)`, archive/delete, and the
worktree sidebar rows, all of which assume one layout per directory.

## Decisions

1. **True rekey**, not the container-id seam. Land it on `cj-main` in slices:
   `LayoutID` typealias for `Worktree.ID`, migrate call sites, then flip the
   alias to a real type. Behaviour unchanged until the flip.
2. **Tasks are never managed by hand.** Starting an agent or shell mints one.
   Every indexed session without a task is its own task, so history shows on
   day one. A history row has no layout until clicked; resume mints it.
3. **Creation.** Cmd-N is instant: current task's directory, default agent.
   Cmd-Shift-N opens a picker: directory and agent-or-shell only. Remote is
   covered by picking a remote directory. No model or machine field yet.
4. **Shell-only tasks** are allowed from the picker, titled by directory, and
   become agent tasks when the first agent starts in them.
5. **Multiple agent sessions per task.** An agent started in a task's tab
   belongs to that task. First session is the primary and gives the title.
   Membership is persisted; a closed tangent stays a dimmed sub-row, click to
   resume. Sub-rows show only while the task is selected.
6. **Settle is task-level only** and closes every tab. Reopening resumes the
   primary; tangents resume on click.
7. **Keyboard.** Task chord cycles tasks, tab chord cycles surfaces inside
   the task, jump-to-attention goes to the exact sub-surface across tasks.
   The task row shows its most urgent child: needs you > working > done
   unseen > idle.
8. **Merge and detach, one level deep.** Merge A into B: A's agents become
   tangents of B, all of A's tabs flatten into B, A is removed. Detach: one
   tangent and its tab become a new top-level task. A task is always a flat
   list of surfaces; no nesting.
9. **Directory is a default, not a rule.** Tabs may run elsewhere. Two tasks
   may share a directory. No auto-worktrees, no checkouts; the per-session
   branch-mismatch alert stays.
10. **Tasks are the only layout owner.** Worktree-owned layouts go away;
    directories become a filter and the picker's source.
11. **Migration.** Each live agent tab becomes its own task; leftover shell
    tabs become one shell-only task per directory.
12. **Order.** Rekey, then task ownership and migration, then sub-rows,
    tangents, merge/detach, picker.

## Open

- Per-directory features (repo settings, setup and run scripts, PR and git
  status, file explorer) need a rule for a task whose tabs span directories.
  Assumed: they follow the task's directory.
- Detach of a plain shell tab: assumed allowed, yielding a shell-only task.
- Merge when A has splits: assumed flattened to tabs in B's focused pane.
- Bar from `done/sessions-sidebar-scope.md` still applies: task cycling must be at
  least as fast as today's session cycling.

## TODO (after the departure lands)

- [x] Decided 2026-10-20: the fork is its own thing. Full upstream rebases
  stop; upstream commits are classified port / skip and cherry-picked one
  at a time (`.pi/skills/upstream-ports.md`, first run in
  `upstream-sync-2026-10-20-ports.md`). Renaming is deferred until the
  divergence has settled.

## Landed (2026-10-12)

The departure from upstream's worktree-owned layout is complete: tasks own
layouts (`TaskRecord`, `LayoutID` a real UUID type), v2 → v3 migration, sub-rows,
tangent keyboard, merge and detach, the picker, task-scoped CLI and deeplinks
(`SUPACODE_TASK_ID`, `--task`, `/task/<id>/`). Decisions 1–12 hold as written;
the assumptions cj confirmed on 2026-10-09 are in `task-as-unit-followups.md`.
The TODO above is resolved: the terminal layer no longer matches upstream, so
upstream changes arrive as selective ports, never a rebase of the fork.

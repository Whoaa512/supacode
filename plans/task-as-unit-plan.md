# Task as the unit — implementation plan

Status: **plan, not started**. Scope and decisions are in
`task-as-unit-sizing.md` (authoritative; "D3" below means decision 3 there).
Read `ideas-graveyard.md` (Task Inbox) first: this lands on `cj-main` in thin
slices, tasks are never made by hand, and history shows on day one.

Measured on cj-main at 47b3b515. Line numbers drift; re-`rg` before editing.

## Ground rules for every slice

- Commit straight to `cj-main`. No branches, no PRs, no `git add .`, no AI
  co-author lines. One slice = one or a few atomic commits, why-focused.
- Slice gate, run in this order, all must pass before committing:
  1. `make check` (format + lint)
  2. the slice's focused tests (listed per slice)
  3. `make build-app`
  4. full `make test` on: the last slice of each phase, F1, and the
     destructive slices R8, T2, T6. Other slices run focused tests only.
- Full `make test` is red on cj-main before this work (5 failures, seen at
  R0 with 3979 tests). "Passes" for a full run means: no failure outside
  this list, and `totalTestCount` not lower than the previous full run.
  - `AppFeatureCommandAckTests/deleteSocketDeeplinkFailsOnScriptCancellation()`
    (parallel-run flake, see PAPERCUTS.md)
  - `AppFeatureSettingsChangedTests/settingsChangedPropagatesRepositorySettings()`
  - `GhosttyRuntimeBundledOverridesTests/backgroundColorTracksColorScheme()`
  - `GhosttyRuntimeBundledOverridesTests/initSeedsResolvedColorSchemeBeforeFirstRead()`
  - `PaneWindowShortcutTests/relativeTabCyclingShortcutsUseBracketChords()`
- Focused test form (keep `SWIFT_VERSION=5`):
  `make test LOCAL_XCODEBUILD_FLAGS='SWIFT_VERSION=5 -only-testing:<bundle>/<Suite>'`
  then
  `xcrun xcresulttool get test-results summary --path build/supacode-tests.xcresult`
  and confirm `totalTestCount > 0` (wrong bundle passes with 0 tests).
- Bundle routing by filename: `AppFeature*`/`RepositoriesFeature*` →
  `supacodeFeatureTests`; `Ghostty*`/`LayoutFeature*`/`Layouts*`/`SplitTree*`/
  `WorktreeTerminalManager*`/`Zmx*` → `supacodeTerminalTests`; `AgentHook*`/
  `Git*`/`ShellClient*` → `supacodeGitTests`; everything else →
  `supacodeTests`. New test file → `make generate-project` first.
- Reducer logic changes get reducer tests. No `Task.sleep` in tests.
- "Mechanical" = retype/rename, compiler-driven, no behaviour change.
  "Complex" = new behaviour or destructive paths; needs new tests.

## Vocabulary and fixed design choices

- **`LayoutID`**: the layout key and the task id. One type, no separate
  `TaskID`. Alias of `Worktree.ID` (`WorktreeID` struct,
  `RepositoryIdentity.swift:27`) through phase R, a real struct after F1.
- **`TaskRecord`** (not `Task`: collides with Swift concurrency; and
  `WorktreeTaskStatus` already uses "task" for something else, renamed in
  R3). Fields: `id: LayoutID`, `directory` (worktree id + remote host),
  `layout` (may be empty), `sessions: [SessionKey]` (primary first),
  `createdAt`.
- **`DirectoryContext`**: `{ worktreeID, repositoryID, name, workingDirectory,
  repositoryRootURL, host }`, built from a `Worktree`. The terminal layer holds
  this instead of a `Worktree`.
- **Settle state stays in the session sidecar**, on the task's current
  primary session. No sidecar migration. A task is settled iff its current
  primary's entry is settled. Session-level settle (sidecar mark only) and
  task settle (closes tabs) are separate actions; see T9. Shell-only tasks have no settle state: closing the last tab
  deletes the task.
- **Implicit tasks**: an indexed session in no `TaskRecord` renders as a
  one-member task with no layout and nothing persisted. Resume mints the
  record (D2).
- **Resolver seam**: every app-layer "worktree → which layout" lookup goes
  through one function (`layoutID(forDirectory:)`). Under the alias it is the
  identity; in T3 it becomes "that directory's most recently selected task".
- **External contracts unchanged**: `SUPACODE_WORKTREE_ID`, `-w`, and
  worktree deeplinks stay path-based. `SUPACODE_TASK_ID` is added.

## Validation contract

Pass/fail. "Auto" = an agent can prove it with a test or command. "UI" = only
cj can confirm in the running app (see the live-UI section).

Rekey (behaviour unchanged):

- A1 (auto) After every R slice and F1, `make build-app` and the slice's
  focused tests pass with no test deleted or weakened; the full `make test`
  passes at R8, R10 and F1 (same policy as ground rule 4).
- A2 (auto) No file in `supacode/Features/Terminal` or
  `supacode/Clients/Terminal` names `Worktree.ID` as a layout key after R
  phase: `rg -n 'Worktree\.ID' supacode/Features/Terminal supacode/Clients/Terminal`
  returns only `DirectoryContext` construction and worktree-facing event
  payloads listed in R3.
- A3 (auto) The terminal layer stores no `Worktree` value: `rg -n ': Worktree\b|\(Worktree[,)]' supacode/Features/Terminal supacode/Clients/Terminal`
  returns only the `DirectoryContext(worktree:)` initialiser.
- A4 (auto) After F1, `LayoutID` is a distinct struct; passing a
  `Worktree.ID` where a `LayoutID` is expected does not compile (proved by
  the build needing the explicit conversions added in F1).
- A5 (auto) A persisted v2 layouts blob written before the rekey hydrates to
  the same layouts, tabs and content ids after F1 (golden-file test).
- A6 (auto) `prune` and worktree-delete teardown decide by the host's
  directory, not by the dictionary key: a host keyed `X` with directory `Y`
  survives `prune(keeping: [Y])` and is torn down by removing `Y`.

Ownership and migration:

- A7 (auto) v2 → v3 migration: each tab with a non-empty agent record becomes
  its own task; remaining tabs of a directory become one shell-only task; a
  directory with no leftover tabs gets no shell task (D11).
- A8 (auto) Migration loses nothing: the multiset of content ids, tab ids and
  surface ids across all v3 tasks equals the v2 input; splits inside one tab
  stay together; every v2 `origin` survives in the directory-keyed `origins`
  field, including for a directory whose tabs all became agent tasks.
- A9 (auto) Migration is safe: v2 is backed up before the first v3 write; any
  decode loss defers migration and leaves v2 untouched; rerunning is a no-op.
- A10 (auto) After migration, the complete `allKnownSurfaceIDs` set
  (origin-only ids included) equals the v2 set, and agent presence restore
  covers every surface that v2 covered (no zmx session is orphaned or
  reaped).
- A11 (auto) Two tasks may share a directory: both layouts survive a
  `repositoriesChanged` prune, and the info watcher is still fed one entry
  per worktree (D9).
- A12 (auto) Deleting or archiving a worktree tears down every task whose
  directory is that worktree, and no other task. A `.deletingScript`
  directory keeps all its tasks.
- A13 (auto) A task whose directory is not a known worktree (orphan) is kept
  by prune, and is listed in the sidebar.
- A14 (auto) Setup script runs at most once per directory, not once per task.
- A15 (auto) Cmd-N mints a task in the current task's directory with the
  default agent, with no prompt; resuming a history row mints a task for it;
  no code path lets the user create an empty task (D2, D3).
- A16 (auto) Every indexed session with no `TaskRecord` appears as its own
  task row; row count on first launch ≥ today's session row count (D2).
- A17 (auto) Selecting a different task in the same directory changes the
  shown layout and leaves the selected directory unchanged. (Revised
  2026-10-08 with R7: the handler is not gated, so the directory-side
  sends repeat for the same directory, as they already do today on same-id
  re-sends. Skipping them is an optimisation, not part of done.)
- A18 (auto) `selectedWorktreeID` equals the selected task's directory, so
  directory features (scripts, PR, explorer, open-in) follow the task.
- A19 (auto) Task settle closes every tab of the task and settles the
  current primary's sidecar entry; unsettle/reopen resumes only the primary
  (D6).
- A36 (auto) Every task is reachable: for any set of tasks (several per
  directory, orphans, shell-only, freshly migrated), each layout id is the
  target of a sidebar row, activating the row shows that layout and focuses
  its surface, and the next/previous chord visits every live task without
  minting or resuming. Holds before the split migration is wired (T6 gate).
- A37 (auto) Replacement is not quit: `/new` or `/fork` on a member's
  surface keeps the task active, closes no surface, puts the new session in
  the replaced one's slot (new primary if it replaced the primary) and keeps
  the replaced session as a session-level-settled member. Primary quit
  settles the task only when no other member is live; tangent quit never
  does.
- A38 (auto) Branch capture uses the session surface's cwd: a tangent
  running in directory B inside a task on directory A records B's branch,
  and its resume warning compares against B (D9).
- A20 (auto) `SUPACODE_WORKTREE_ID` in a new surface is still the
  percent-encoded directory path; `SUPACODE_TASK_ID` is the task id; existing
  CLI `-w <path>` and worktree deeplinks resolve to that directory's active
  task; tab- and surface-addressed commands reach the right task when two
  tasks share a directory.

Sub-rows, tangents, keyboard:

- A21 (auto) An agent that starts in a task's tab is appended to that task's
  `sessions`; the first is primary and supplies the title; membership
  survives relaunch; two agents in one task are both visible before grouping
  lands (D5).
- A22 (auto) A provisional (no session ref yet) member upgrades in place when
  the ref arrives, without a second row or a membership loss.
- A23 (auto) The sidebar structure exposes sub-rows only for the selected
  task; a closed tangent is a dimmed sub-row whose activation resumes it in
  the same task (D5).
- A24 (auto) A task row's status is its most urgent member: needs you >
  working > done unseen > idle (D7).
- A25 (auto) Task chord walks live tasks only and never spawns a process; tab
  chord walks surfaces inside the selected task; jump-to-attention returns
  the exact surface across tasks (D7).
- A26 (auto) Reconcile with tasks stays O(n) and write-free when nothing
  changed. Deterministic: a 3,000-row reconcile with an unchanged input
  performs zero state writes. Scaling, same process and build config: median
  of 5 runs at 6,000 rows ≤ 3× the median at 3,000 rows. The test is added
  in T4's first commit against pre-task code and must pass unmodified after
  S1; the T4 numbers in Progress are informational, not a gate.
- A27 (auto) A shell-only task is titled by its directory and becomes an
  agent task (primary set, title switches) when the first agent starts in it
  (D4).

Merge, detach, picker:

- A28 (auto) Merge A into B: all of A's tabs end up as tabs in B's focused
  pane, A's sessions are appended to B's as tangents, A's record is removed,
  and no surface id changes or is killed (D8).
- A29 (auto) Detach: one tab (agent or plain shell) and its session become a
  new top-level task; the source task keeps the rest; detaching the primary
  is refused (D8).
- A30 (auto) No operation yields a task inside a task: `TaskRecord` has no
  parent/child field and merge of a merged task still yields a flat list.
- A31 (auto) Cmd-Shift-N picker takes only a directory and agent-or-shell and
  mints a task there; a remote directory mints a remote task (D3).
- A32 (auto) No worktree-owned layout path remains: the resolver seam is the
  only worktree→layout mapping and nothing constructs a `LayoutID` from a
  worktree id outside the v2 migrator (D10).

Live use:

- A33 (UI) Task cycling feels at least as fast as today's session cycling;
  no visible lag or flicker on chord repeat.
- A34 (UI) After the migration launch, every previously open agent and shell
  is reachable, attached to its original zmx session, with scrollback.
- A35 (UI) Sub-rows, dimming, status rollup, merge/detach menus and the
  picker look and behave right; tooltips name action and hotkey.

## Slices

Order: R (rekey behind alias) → F (flip) → T (ownership, reachability, then
migration) → S (sub-rows) → K (tangent keyboard) → M (merge/detach) → P
(picker) → Z (cleanup). Each slice depends on the one before it unless stated.

### Phase R — rekey behind a typealias (no behaviour change)

Every R slice covers **A1** and moves **A2/A3** forward. Verification for all
R slices unless a slice says more:

```
make check
make test LOCAL_XCODEBUILD_FLAGS='SWIFT_VERSION=5 -only-testing:supacodeTerminalTests'
make test LOCAL_XCODEBUILD_FLAGS='SWIFT_VERSION=5 -only-testing:supacodeTests/TerminalsFeatureTests'
xcrun xcresulttool get test-results summary --path build/supacode-tests.xcresult
make build-app
```

**R1 — Add `LayoutID` alias; retype the reducer core.** Mechanical.
- Goal: the name exists and the layout reducer uses it.
- Files: new `Features/Terminal/Models/LayoutID.swift`; `LayoutFeature.swift`
  (`:77`, `:113`, `:1100`); `TabContent.swift` (`:64,73`).
- Steps: add `typealias LayoutID = Worktree.ID`; retype the three
  `LayoutFeature` sites and `TabContent`; rename `worktree:` labels to
  `layout:` in those signatures only.
- Tests: none new; existing compile unchanged.
- Assertions: A1, A2.

**R2 — Retype `TerminalsFeature` and manager storage.** Mechanical.
- Files: `TerminalsFeature.swift`; `WorktreeTerminalManager.swift` (the 7
  dictionaries/sets at `:18,34,43,53,82,86,98`, observation keys,
  `layoutState`/`sendLayout`/`hostIfExists`); `PaneWindowManager.swift` keys.
- Steps: retype storage and private helper params to `LayoutID`. Do not
  rename `selectedWorktreeID` yet (R7). Do not touch `prune`/
  `removeWorktreeLayout` semantics (R8).
- Tests: none new.
- Assertions: A1, A2.

**R3 — Retype `TerminalClient` closures and events; free the word "task".**
Mechanical.
- Files: `TerminalClient.swift` (`:9-47` closures, `:147-187` events),
  manager emit sites, `AppFeature.swift` event handlers, tests that build
  events.
- Steps: closures `(Worktree.ID, …)` → `LayoutID`. Event payload labels
  `worktreeID:` → `layoutID:` where the value is a layout key
  (`tabCreated`, `tabClosed`, `focusChanged`, `surfaceCreated`, `tabRemoved`,
  `tabRenamed`, `userClosedSurfaces`, `surfacesClosed`,
  `surfaceCreationFailed`, `initialTabCreationFailed`,
  `commandPaletteToggleRequested`, `setupScriptConsumed`). Keep these
  worktree-facing and document them as the A2 allow-list:
  `worktreeProjectionChanged`, `taskStatusChanged`, `worktreeStateTornDown`
  (retargeted in T3). Rename `WorktreeTaskStatus`/`taskStatusChanged` to
  `WorktreeRunStatus`/`runStatusChanged` in a separate commit.
- Tests: update constructors in `WorktreeTerminalManagerAckTests`,
  `AppFeature*Tests`.
- Verify: add
  `…-only-testing:supacodeFeatureTests` to the R block.
- Assertions: A1, A2.

**R4 — Introduce `DirectoryContext`; host and recipe hold it.** Mechanical
with care.
- Files: new `Features/Terminal/Models/DirectoryContext.swift`;
  `WorktreeContentHost.swift` (`:17`, `:979`, `:997`);
  `TerminalSurfaceRecipe.swift` (`:47,54,102,218-221,294,324-337`); manager
  directory-fact sites (`:749,938,1050,1175,1233-1238`).
- Steps: add the struct with `init(worktree:)`. Host stores
  `context: DirectoryContext` instead of `worktree`. Recipe lookup closure
  becomes `(LayoutID) -> DirectoryContext?`. Replace
  `hosts[id]?.worktree.x` with `hosts[id]?.context.x`. Host gains
  `worktreeID` via the context (R8 uses it).
- Tests: `TerminalSurfaceRecipeTests` constructors; add
  `DirectoryContextTests` (built from local and remote worktree, fields
  match). New file → `make generate-project`.
- Verify: add `…-only-testing:supacodeTests/TerminalSurfaceRecipeTests` and
  `…/DirectoryContextTests`.
- Assertions: A1, A3.

**R5a — `Command` payloads that only read `.id` → `LayoutID`.** Mechanical,
largest diff (≈35 of the 50 cases; 40 `terminalClient.send` sites, 39 in
`AppFeature.swift`).
- Files: `TerminalClient.swift` (`:87-130`), manager command switch,
  `AppFeature.swift`, `AppFeature+Sessions.swift`, command tests.
- Steps: first audit each case in the manager: does the handler read
  anything but `.id` or possibly create a host? If neither, payload becomes
  `LayoutID`. Split into two commits by family (tab/pane/search focus cases;
  destroy/rename/select cases). Callers pass `worktree.id` for now.
- Tests: update command constructors.
- Verify: R block + `supacodeFeatureTests`.
- Assertions: A1, A3.

**R5b — `Command` payloads that need directory facts → `(LayoutID,
DirectoryContext)`.** Mechanical.
- Files: same as R5a.
- Steps: the remainder (`createTab*`, `ensureInitialTab`, script cases
  `openFileWithScript`/`stopRunScript`/`stopScript`/`runBlockingScript`, and
  any case that may create a host). Payload carries the context explicitly.
  After this, `rg '\(Worktree[,)]' TerminalClient.swift` is empty.
- Tests: update constructors.
- Assertions: A1, A3.

**R6 — One resolver seam for worktree → layout in the app layer.** Mechanical.
- Goal: every non-terminal caller asks one function which layout a worktree
  means.
- Files: new small helper on `AppFeature.State` (or `TerminalsFeature.State`);
  the 18 `layouts[id:]` sites (`AppFeature.swift` e.g. `:2302,2408`,
  `AppFeature+Sessions.swift:37,569,589,616`, `WorktreeDetailView.swift:339`,
  `WorktreeLayoutView`, `PaneWindowManager`); the `terminalClient.send`
  callers from R5; `SessionSidebarItemFeature.swift` (`SessionLocation`).
- Steps: add `layoutID(forDirectory: Worktree.ID) -> LayoutID` (identity
  today). Route every `layouts[id: worktree.id]` and every command caller
  through it. `SessionLocation.worktreeID` → `layoutID`; add `directoryID`
  where a caller truly needs the worktree.
- Tests: `AppFeatureSessionsTests` constructors (18 sites).
- Verify: R block + `supacodeFeatureTests/AppFeatureSessionsTests`.
- Assertions: A1, A32 (seam exists).

**R7 — Split "selected layout" from "selected directory".** Mechanical, one
judgement call per site.
- Files: `TerminalClient.swift:137`; `TerminalsFeature.swift`
  (`:49,53,81,158,223-251`); manager (`:147,614,767,770`);
  `RepositoriesFeature.swift` (`:765` delegate, sends at `:1157,1654,1984`,
  `hasSelectionChanged :1146`); `AppFeature.swift:614-657,1136,1920,2026`;
  `WorktreeDetailView.swift:339,354`; `supacodeApp.swift:503,732`.
- Steps: `setSelectedWorktreeID` → `setSelectedLayoutID`;
  `TerminalsFeature.selectedWorktreeID`/`recentWorktreeIDs` →
  `selectedLayoutID`/`recentLayoutIDs`. The delegate payload carries both the
  worktree and the layout id (resolved through R6). The `AppFeature.swift:614`
  handler splits into a layout half and a directory half, each gated on its
  own id changing. Switch only the ~8 layout sites to `selectedLayoutID`;
  leave the ~75 directory sites on `selectedWorktreeID`.
- **Revised 2026-10-08**: only the rename half lands in R7. The payload
  change and the handler split are dropped from R7 and the gating is dropped
  altogether: it needed new "previous id" state in `AppFeature`, and id-only
  gating would skip work the handler does today on same-id re-sends
  (`hasSelectionChanged` re-sends on path changes; `ensureInitialTab` is not
  idempotent in its `focusing:`/`runSetupScriptIfNew:` intent). T5 instead
  adds an optional `layoutID:` to `selectedWorktreeChanged` (nil = resolve
  through the seam) and the single handler keeps running both halves on
  every send, as it does today. A17 is covered by T5 alone.
- Tests: `TerminalsFeatureTests` renames; add an `AppFeature` test that the
  handler does the layout half only when just the layout id changes (using
  the alias, feed same worktree with a different layout id).
- Verify: R block + `supacodeFeatureTests`.
- Assertions: A1.

**R8 — Prune and teardown decide by the host's directory.** Complex
(destructive path).
- Files: `WorktreeTerminalManager.swift` (`prune :1583`,
  `removeWorktreeLayout :1547`, `invalidateCaches(forPrunedWorktree:)`,
  `handleSurfacesClosed`), `TerminalClient.swift:131,134`,
  `AppFeature.swift:691-698,1745-1759`.
- Steps: `prune(keepingDirectories: Set<Worktree.ID>, protecting…)` keeps a
  host when `host.context.worktreeID` is in the set (was: the key).
  `removeWorktreeLayout` → `removeLayouts(forDirectory:)`, a loop over every
  host with that directory, running the existing per-layout teardown
  (pane windows, snapshot delete, detach, presence retraction, torn-down
  event) per layout id. Identical behaviour while one layout per directory.
- Tests: new cases in `WorktreeTerminalManagerAckTests` (or a new
  `WorktreeTerminalManagerPruneTests`): host keyed `X` with directory `Y`
  survives `prune(keeping:[Y])`; two hosts on `Y` are both torn down by
  `removeLayouts(forDirectory: Y)` and each emits its own events; a host on
  `Z` is untouched.
- Verify: R block (`supacodeTerminalTests`).
- Assertions: A6, A12 (mechanism), A1.

**R9 — Persistence key seam and the id-is-a-path fallback.** Mechanical.
- Files: `TerminalsFeature.swift:189`; writer call sites
  `WorktreeTerminalManager.swift:1684,1706,2303`;
  `LayoutsIncrementalWriter.swift`; manager `:1862`.
- Steps: add `LayoutID.init(legacyWorktreeKey:)` and `persistenceKey` (both
  trivial under the alias); route hydration and the three writer sites
  through them. Replace the `URL(fileURLWithPath: worktreeID.rawValue)` name
  fallback with `context.name`.
- Tests: add golden-file test `LayoutsLegacyKeyTests` (a checked-in v2 blob
  hydrates to expected layout ids, tab ids, content ids). This is the A5
  fixture; it must pass unchanged after F1.
- Verify: `…-only-testing:supacodeTerminalTests/LayoutsLegacyKeyTests`.
- Assertions: A5, A1.

**R10 — Audit sweep and A2/A3 gate.** Mechanical.
- Steps: run the A2 and A3 `rg` commands; fix stragglers among the 26
  `hosts[` sites and manager lines 1324–2574 (not read line by line during
  inventory). Record the final allow-list in a comment-free note at the top
  of this plan's "Progress" section.
- Verify: A2/A3 commands return only the allow-list; full `make test`.
- Assertions: A1, A2, A3.

### Phase F — flip

**F1 — `LayoutID` becomes a real struct.** Complex only in breadth; no
behaviour change.
- Files: `LayoutID.swift`, then whatever the compiler reports.
- Steps: `struct LayoutID: Hashable, Sendable, Codable,
  CustomStringConvertible` wrapping a string. The only constructors used in
  production are `init(legacyWorktreeKey:)` and the R6 resolver (which still
  returns the legacy id for a worktree). Fix compile errors by going through
  the seam, never by adding a second conversion.
- Tests: all existing tests compile-fixed (46 sites); `LayoutsLegacyKeyTests`
  passes unchanged.
- Verify: `rg -n 'LayoutID\(' supacode --type swift` shows constructions only
  in `LayoutID.swift`, the resolver, hydration and tests; full `make test`;
  `make build-app`.
- Assertions: A1, A4, A5.
- **UI checkpoint**: cj runs the build for a day before T starts (A34-lite:
  nothing changed).

### Phase T — task ownership and migration

Row rule through phase T: a sidebar row is still one session (as today), now
located in a task, plus one row per task with no sessions (shell-only).
Collapsing members into one task row with sub-rows is phase S. This keeps
every agent visible when a task holds several (unsplit store, or a second
agent started in a tab).

**T1 — `TaskRecord` model and pure v2 → v3 split.** Complex, pure code.
- Files: new `Domain/TaskRecord.swift`; new
  `Features/Terminal/BusinessLogic/LayoutsTaskSplitter.swift`.
- Steps: define `TaskRecord` and a **separately named** v3 DTO
  `TaskLayoutsFile` (`tasks: [String: TaskRecord]`, key =
  `LayoutID.persistenceKey`; `origins: [String: Origin]` top-level, keyed by
  directory, so an all-agent directory keeps its origin). Production
  `LayoutsFile` and its consumers are untouched. Write the pure split: per v2
  record, each tab whose terminal state has a non-empty agent record (dead
  flagged ones included) becomes a single-pane task with a fresh UUID id and
  `sessions` seeded from the record's `sessionRef` when present; the rest go
  through `TerminalRestorePruner.prunedLayout` with the inverse predicate
  into one shell-only task that keeps the legacy id. Origin moves to
  `origins[directory]` whether or not a shell task exists. Rebuild
  focus/selection per task. Nothing wired.
- Tests: new `LayoutsTaskSplitterTests` (Terminal bundle): A7 cases, A8
  multiset equality, splits kept together, empty-leftover case, tab without
  `sessionRef`, remote directory, all-agent directory with an origin
  (origin-only surface ids still in the known-surface set).
- Verify: `make generate-project`; `…-only-testing:supacodeTerminalTests/LayoutsTaskSplitterTests`.
- Assertions: A7, A8, A10 (pure half).

**T2 — Switch production codec and consumers to v3 atomically (still one
task per directory).** Complex.
- Files: `LayoutsMigrator.swift`, `LayoutsIncrementalWriter.swift`,
  `LayoutsPersistenceKey.swift:52`, `TerminalsFeature.swift:172-196`,
  `AgentPresenceFeature.swift:628`, `AppFeature.swift:476-477`,
  `AppFeature+Sessions.swift` (`persistedLayouts.worktrees` readers), manager
  writer sites.
- Steps: one commit swaps the production type to the T1 DTO and converts
  every `.worktrees` consumer (hydration, presence restore, reaper, session
  lookups). Readers decode v3, or v2 mapped 1:1 in memory (each worktree
  record → one `TaskRecord` with the legacy id and explicit directory, origin
  → `origins`; **no split yet**). Writer upserts/deletes `TaskRecord`s.
  `allKnownSurfaceIDs` = all task content ids ∪ all `origins` surface ids.
  `stageRestore(from:)` iterates tasks. Hydration hands each host its
  `DirectoryContext` from the record's directory instead of from the key.
  Bump `currentSchemaVersion` to 3; back up v2 before the first v3 write,
  same pattern as v1→v2 (`:399-456`).
- Tests: extend `LayoutsMigrator` tests: v2 in → v3 out round trip, backup
  written once, decode loss defers (A9), newer schema stays read-only;
  `LayoutsLegacyKeyTests` still green; reaper/presence coverage test: full
  `allKnownSurfaceIDs` before == after, including origin-only ids (A10).
- Verify: `…-only-testing:supacodeTerminalTests`, `supacodeTests/TerminalsFeatureTests`,
  `supacodeFeatureTests`.
- Assertions: A9, A10, A5.
- Note: from here an older build reads the store as `.unreadable` (safe, no
  reaping, but shows no layouts).

**T3 — Runtime allows many layouts per directory.** Complex.
- Files: resolver (R6), `AppFeature.swift:680-698` (`ensureInitialTab`,
  `allowed`), manager setup-script consumption, the three worktree-facing
  events from R3, `RepositoriesFeature` projection consumers.
- Steps: resolver returns the directory's most recently selected task (small
  `[Worktree.ID: LayoutID]` map in `TerminalsFeature.State`, persisted with
  the layouts file), falling back to the legacy id. `allowed` becomes a
  directory set and adds an orphan rule: a task whose directory matches no
  known worktree is always kept. Setup-script state keyed by directory.
  `worktreeProjectionChanged`/`runStatusChanged` aggregate over all hosts of
  the directory. `.deletingScript` exemption applies per directory.
- Tests: reducer + manager tests for A11, A12 (delete and archive with two
  tasks), A13, A14; watcher input unchanged with two tasks on one worktree.
- Verify: `supacodeTerminalTests`, `supacodeFeatureTests`.
- Assertions: A11, A12, A13, A14.

**T4 — Surface discovery walks tasks.** Complex.
- Files: `AppFeature+Sessions.swift` (`sessionSnapshots :611-642`,
  `focusedSurfaceID :35`, `worktreeIDForSurface :565`,
  `hasUnresolvedLivePresence :584`), `SessionSidebarItemFeature.swift`,
  `SessionsSidebarStructure.swift`.
- Steps: first commit (before any change): add the reconcile benchmark and
  zero-write test against the current pre-task code (see A26) and note the
  measured numbers in Progress. Then: one `surfaceIndex` helper walks every
  task (live layout, else persisted record), not repositories→worktrees
  through the resolver, and returns `surface → (LayoutID, tabID, directory,
  cwd)`; cwd is the tab snapshot `workingDirectory`, falling back to the task
  directory (D9). The four functions above use it. `SessionLocation` carries
  the owning `layoutID`. Orphan tasks are included.
- Tests: `AppFeatureSessionsTests`: two tasks on one directory, each with an
  agent → both snapshots, each with its own layout id; orphan task's agent
  listed; `hasUnresolvedLivePresence` false for a surface in a non-active
  task.
- Verify: `supacodeFeatureTests/AppFeatureSessionsTests`, `supacodeTests`.
- Assertions: A36 (discovery half), A26 (baseline), A13.

**T5 — Task selection, shell-only rows, focus routing, minimum keyboard.**
Complex.
- Files: `SessionSidebarItemFeature.swift`, `SessionsSidebarStructure.swift`
  (`reconcileSessionItems :97-180`, cycling `:18-65`),
  `RepositoriesFeature.swift` (`selectedWorktreeID :5914`, removal paths
  `:1122,1455,1520,1584`, history `~:244`), `SidebarSelection.swift`,
  `SessionsSidebarListView.swift`, `TerminalCommands.swift`.
- Steps: add `selectedTaskID`; `selectedWorktreeID` becomes
  `tasks[selectedTaskID]?.directory ?? selection?.worktreeID`. Activating a
  session row selects its task (`location.layoutID`) and focuses its surface.
  Add a `.task(LayoutID)` row for every task with no sessions (titled by
  directory). Indexed sessions in no task stay as implicit rows. Removing a
  directory clears or retargets `selectedTaskID`. Keyboard: the existing
  next/previous and ⌘1–9 walk live rows including shell-only task rows, and
  never mint or resume. Selecting a task sends
  `selectedWorktreeChanged(worktree, layoutID: taskID)`; the `AppFeature`
  handler uses that id when present and the R6 seam when nil, and runs both
  its layout and directory work on every send (no gating, no new state).
- Tests: `SessionsSidebarStructure`/`AppFeatureSessionsTests`: A16, A17,
  A18; A36: for N tasks across shared directories, every layout id is the
  target of some row, and next/previous from any row visits every live task;
  selection cleared when the directory is deleted.
- Verify: `supacodeFeatureTests`, `supacodeTests`.
- Assertions: A16, A17, A18, A36.

**T6 — Wire the split migration.** Complex, destructive if wrong. Depends on
T4 and T5 (migrated tasks must already be reachable).
- Files: `LayoutsMigrator.swift`, `SettingsRelocationMigrator.swift:121`.
- Steps: one-time on-disk v2/"v3-unsplit" → split using T1's function, gated
  by a `tasksSplit` marker in the file so it runs once; backup first; any
  integrity failure (A8 check and full known-surface-set equality, run at
  migration time) aborts and leaves the unsplit store in use.
- Tests: migrator tests end to end from a realistic v2 fixture (several
  directories, mixed agent/shell tabs, splits, a dead-flagged agent, a
  remote, an all-agent directory with an origin); idempotence; abort path.
  Reducer test: hydrate the split fixture and assert A36 over it (every
  migrated layout has a row and is in the keyboard cycle).
- Verify: `…-only-testing:supacodeTerminalTests`; full `make test`.
- Assertions: A7, A8, A9, A10, A36.
- **UI checkpoint (A34)**: cj copies his real `layoutsFile` default aside,
  launches, and confirms every agent and shell reattached and is reachable
  by click **and** by the cycling chord. Do not start T7 before this is
  confirmed.

**T7 — Minting and membership.** Complex.
- Files: `AppFeature+Sessions.swift` (`handleNewSession :284-312`,
  resume `:314-495`, `launchSessionTab`, `worktreeForCwd :505`,
  `createTabWithInput :513`, `surfacesChanged :77`, swap at `:162`),
  `TerminalsFeature`, `TaskRecord`, writer.
- Steps: Cmd-N mints a `TaskRecord` (fresh id, directory = current task's
  directory, default agent) and creates its first tab. Resume of a session
  with no task mints one with that session as primary. When presence reports
  an agent on a surface, its `SessionKey` is appended to the owning task's
  `sessions` if absent (first = primary). Provisional members (no ref yet)
  are recorded by surface and upgraded in place when the ref arrives. A task
  whose last tab closes and that has no sessions is deleted; one with
  sessions keeps its record with an empty layout. No grouping or sub-row UI:
  each member is still its own row (row rule above).
- Tests: `AppFeatureSessionsTests`: A15 cases; no action creates an empty
  task; task with sessions survives last-tab close; A21, A22; two agents in
  one task → two rows, both members, survives a v3 codec round trip.
- Verify: `supacodeFeatureTests/AppFeatureSessionsTests`,
  `supacodeTerminalTests`.
- Assertions: A15, A21, A22.
- **Revised (T7 r1 review)**: "deleted" means at runtime too, not only in
  the file: the layout, host, directory entry, active-task entry and selected
  task go when the last tab closes and no session is listed (see Progress).
  "Current task's directory" for Cmd-N is the directory of the task on
  screen, ahead of the focused session's cwd and the highlighted history row.
- **Revised (T7 r2 review)**: that holds for a remote task too (the launch
  goes to its host, no local path check), and a launch's pending
  bookkeeping is per task until its first tab appears (see Progress).

**T8 — Branch capture uses the session surface's cwd.** Complex (small).
- Files: `AppFeature+Sessions.swift:535-560` (capture), resume-warning path.
- Steps: capture resolves the surface through T4's index. Use the cached
  `sidebarItems[id:].branchName` only when the surface cwd equals that
  directory's working directory; otherwise probe `gitClient.branchName(cwd)`
  with the surface cwd.
- Tests: tangent running in directory B inside task A captures B's branch;
  resuming it in B does not warn; resuming it in A (different branch) warns;
  same-directory capture still uses the cache (no probe).
- Verify: `supacodeFeatureTests/AppFeatureSessionsTests`.
- Assertions: A38.

**T9 — Replacement and task-level settle.** Complex.
- Files: `AppFeature+Sessions.swift:166-244`
  (`settleReplacedOrEndedSession :166`),
  `SessionsSidebarStructure.swift:211-260`.
- Steps: keep `settleSession(key)` as the session-level sidecar mark (closes
  nothing); add `settleTask(id)` (closes every tab, settles the current
  primary's entry). A task is settled iff its **current** primary's entry is
  settled.
  - Replacement (`/new`, `/fork`: changed ref on the same surface): the new
    key takes the replaced key's slot in `sessions` (replacing the primary
    promotes the new key to primary; title follows); the replaced key stays a
    member directly after it and gets `settleSession` only. The task stays
    active; no tab closes; no new task. Same rule for a tangent's slot.
  - Quit (`sessionEnd`, pi non-reload): of a tangent → nothing settles; of
    the primary → `settleTask` only when no other member is live, otherwise
    nothing closes and the task stays active.
  - Manual settle → `settleTask`. Auto-settle evaluates the task: never
    while any member is live or any tab of the task is open (open question
    6: it closes nothing); idle age = newest member activity. Reopen
    resumes the current primary. Settle-and-advance moves to the next live
    task.
- Tests: A19; A37 table: primary `/new`, primary `/fork`, tangent
  replacement, primary quit alone, primary quit with a live tangent, tangent
  quit — each asserting task settled-state, primary, member list and that no
  surface was closed except on `settleTask`; auto-settle with one live
  tangent among idle members does not fire.
- Verify: `supacodeFeatureTests/AppFeatureSessionsTests`,
  `supacodeTests` (structure tests).
- Assertions: A19, A37.

**T10 — Worktrees tab: a directory is a filter.** Complex.
- Files: `RepositoriesFeature.swift` selection handling,
  `WorktreeDetailView.swift`, `SidebarStructure` projections.
- Steps: selecting a worktree row selects that directory's most recent task
  via the resolver; if it has none, show the existing empty detail state
  with a "New task here" action (mints via T7). Worktree-row badges come
  from the T3 aggregates. `sidebarItems[id: selectedWorktreeID]` focus logic
  (`AppFeature.swift:650-657`) keeps working because the directory row still
  exists.
- Tests: `RepositoriesFeatureTests`: select worktree with 0/1/2 tasks.
- Verify: `supacodeFeatureTests`.
- Assertions: A18, A32.

**T11 — CLI, env and deeplinks.** Complex (external contract).
- Files: `TerminalSurfaceRecipe.swift:104-107`, `supacodeApp.swift:807-819`,
  `DeeplinkClient.swift`, `Deeplink.swift`, `AppFeature.swift` deeplink
  handlers (`:2671+`, `handleWorktreeDeeplink :2838`),
  `supacode-cli/Helpers/IDResolvers.swift`, `EnvironmentDefaults.swift`.
- Steps: add `SUPACODE_TASK_ID` to the surface env. Keep
  `SUPACODE_WORKTREE_ID` as the directory path. Worktree-addressed commands
  resolve through the resolver; commands that also carry a tab or surface
  id find the task by that id (ids are globally unique) and ignore the
  directory's "active task". Add an optional task segment to deeplinks and a
  CLI `--task` option defaulting to the env var. One shared parser for the
  percent-decode and trailing-slash rule.
- Tests: `TerminalSurfaceRecipeTests`, `DeeplinkClientTests`,
  `AppFeatureDeeplinkTests`, `AgentHookCommandTests`: A20 cases including two
  tasks on one directory.
- Verify: `supacodeTests`, `supacodeFeatureTests`, `supacodeGitTests`; full
  `make test` (end of phase).
- Assertions: A20.

### Phase S — sub-rows

Membership already exists (T7). This phase is grouping and presentation only.

**S1 — Structure: grouping and status rollup.** Complex, perf-sensitive.
- Files: `SessionsSidebarStructure.swift`, `SessionSidebarItemFeature.swift`.
- Steps: row id becomes `.task(LayoutID)` / `.implicit(SessionKey)` (plus
  the provisional case). Reconcile groups sessions by task via a prebuilt
  `[SessionKey: LayoutID]` map (O(n)), task status = most urgent member,
  sub-row list computed only for the selected task; keep the write-avoidance
  diffing. Session-level-settled members (replaced keys) are dormant
  sub-rows, not top-level rows.
- Tests: A24 table test; A26 with the T4 benchmark unchanged; A23 structure
  half (sub-rows only for selected, closed tangent flagged dormant); A36
  re-run on task rows.
- Verify: `supacodeTests` (structure suite), `supacodeFeatureTests`.
- Assertions: A23, A24, A26, A36.

**S2 — View: sub-rows under the selected task.** Complex (UI).
- Files: `SessionsSidebarListView.swift`.
- Steps: render sub-rows from the cached structure only (never read
  `sessionItems[id:]` in a body, per AGENTS.md). Dimmed dormant tangent;
  click resumes into the same task (new tab in that task). Tooltips with
  hotkeys.
- Tests: reducer test for sub-row activation (live → focus surface,
  dormant → resume in same task).
- Verify: `supacodeFeatureTests`; `make build-app`.
- Assertions: A23; A35 (UI).

**S3 — Shell-only tasks become agent tasks.** Mechanical-ish.
- Files: `SessionsSidebarStructure.swift`, title derivation.
- Steps: a task with no sessions is titled by directory name; once T7 adds
  its first session the title switches to the primary's and the T5
  shell-only row is replaced by the task row (same id, no selection loss).
- Tests: A27.
- Verify: `supacodeTests`, `supacodeFeatureTests`; full `make test`.
- Assertions: A27.

### Phase K — tangent keyboard

**K1 — Task chord vs tab chord.** Complex.
- Files: `SessionsSidebarStructure.swift:18-65`, `TerminalCommands.swift`,
  `AppFeature+Sessions.swift`.
- Steps: the T5 cycle now steps one **task** per press (a task is live if
  any member or shell surface is live), not one member. The existing tab
  chord (`selectRelativeTab`) walks surfaces of the selected task; no new
  chord. Cycling never mints or resumes.
- Tests: A25 task and tab halves; a cycling test asserting zero terminal
  commands other than focus.
- Verify: `supacodeTests`, `supacodeFeatureTests`.
- Assertions: A25.

**K2 — Jump-to-attention targets the exact surface.** Complex.
- Files: `SessionsSidebarStructure.swift:28` (`nextNeedingAttention`).
- Steps: return `(task, tab, surface)`; selecting it selects the task and
  focuses that surface, including a tangent in a non-selected task.
- Tests: A25 attention half across two tasks.
- Verify: `supacodeTests`, `supacodeFeatureTests`; full `make test`.
- Assertions: A25; A33 (UI).

### Phase M — merge and detach

**M1 — Pure layout operations.** Complex, pure.
- Files: new `Features/Terminal/BusinessLogic/LayoutTransfer.swift`.
- Steps: `flatten(A, into: B)` (all of A's tabs, in pane order, appended to
  B's focused pane; splits inside a tab kept) and `extract(tab, from:)`.
  Content, tab and surface ids preserved.
- Tests: `LayoutsTransferTests` (Terminal bundle): id preservation, A with
  splits, empty A, focus after transfer.
- Verify: `make generate-project`; `…/LayoutsTransferTests`.
- Assertions: A28 (layout half), A29 (layout half).

**M2 — Runtime surface transfer between hosts.** Complex, highest risk.
- Files: `WorktreeTerminalManager.swift`, `WorktreeContentHost.swift`,
  `TerminalClient.swift`, `LayoutFeature.swift`.
- Steps: a `transferTabs(from:to:)` command moves live content runtimes and
  their surfaces from one host to another without closing them: no zmx
  kill, no tombstone, no `userClosedSurfaces`/settle signal, no
  explicit-close marker. The emptied host is detached without session
  teardown. Hibernation and pane-window state re-key to the destination.
- Tests: manager tests: after transfer the zmx kill list is empty, surface
  ids unchanged, source host gone, no settle-triggering events emitted.
- Verify: `supacodeTerminalTests`.
- Assertions: A28.

**M3 — Merge and detach reducer actions and UI.** Complex.
- Files: `AppFeature+Sessions.swift`, `RepositoriesFeature+Sessions.swift`,
  `SessionsSidebarListView.swift`, `CommandPaletteFeature.swift`.
- Steps: `mergeTask(A, into: B)`: M2 transfer, append A's sessions to B's,
  delete A's record, select B. `detach(tab)`: mint a task with that tab and
  its session; refused for the primary's tab. Entry points: row context menu
  ("Merge into…" lists other live tasks; "Detach" on a sub-row) and palette.
  No drag and drop.
- Tests: A28, A29, A30 (merge a previously merged task; detach a plain shell
  tab → shell-only task).
- Verify: `supacodeFeatureTests`; full `make test`; `make build-app`.
- Assertions: A28, A29, A30; A35 (UI).

### Phase P — picker

**P1 — Cmd-Shift-N picker.** Complex (UI).
- Files: existing new-session directory-picker path
  (`AppFeature+Sessions.swift`, `TerminalCommands.swift`,
  `CommandPaletteFeature.swift`), view for the picker.
- Steps: extend the existing fuzzy directory picker with one extra choice,
  agent or shell. Sources: known directories including remote ones. Confirm
  mints via T7 (agent) or mints a shell-only task. No model/machine field.
- Tests: reducer tests for A31 (local agent, local shell, remote directory).
- Verify: `supacodeFeatureTests`; `make build-app`.
- Assertions: A31; A35 (UI).

### Phase Z — cleanup

**Z1 — Remove worktree-owned layout remnants.** Mechanical.
- Steps: delete the legacy-id fallback in the resolver once every directory
  with tabs has a task; restrict `init(legacyWorktreeKey:)` to the migrator;
  drop dead `Worktree`-named helpers in the terminal layer; rename
  `WorktreeTerminalManager`/`WorktreeContentHost` only if it is a pure
  rename commit.
- Added by T11 (2026-10-09), not mechanical, each needs reducer tests:
  - App-menu terminal commands (new tab, close, split, search, rename; ~35
    reducer sites on `state.layoutID(forDirectory:)` behind
    `selectedWorktreeID`) target the shown task: enabled while an orphan task
    is shown, and through `AppFeature.State.commandLayoutID(forDirectory:)`
    so a task selected but not yet echoed by the terminal is the target (T11
    r1 closed that window for deeplinks, the CLI and socket queries only).
  - Agent CLI (`agent prompt|send-keys|resume|read`): take the task segment /
    `--task` and narrow the surface set to that task before the kind lookup
    (followups, "Agent commands cannot tell…"). Until this lands Z2 must
    document the family as directory-scoped, not task-aware.
- Verify: `rg -n 'legacyWorktreeKey' supacode --type swift` shows only the
  migrator and tests; A2/A3 commands; full `make test`; `make build-app`.
- Assertions: A32, A1.

**Z2 — Docs.** Mechanical.
- Steps: update AGENTS.md architecture notes, `supacode-cli` skill docs for
  `SUPACODE_TASK_ID`/`--task`, mark `task-as-unit-sizing.md` as landed, and
  record the decision in the decisions memory.
- Assertions: none (documentation).

## Assertion coverage

| Assertion | Slices |
|---|---|
| A1 | R1–R10, F1, Z1 |
| A2 | R1–R3, R10 |
| A3 | R4, R5a, R5b, R10 |
| A4 | F1 |
| A5 | R9, F1, T2 |
| A6 | R8 |
| A7, A8 | T1, T6 |
| A9 | T2, T6 |
| A10 | T1, T2, T6 |
| A11, A14 | T3 |
| A12 | R8, T3 |
| A13 | T3, T4 |
| A15 | T7 |
| A16 | T5 |
| A17 | T5 |
| A18 | T5, T10 |
| A19 | T9 |
| A20 | T11 |
| A21, A22 | T7 |
| A23 | S1, S2 |
| A24 | S1 |
| A25 | K1, K2 |
| A26 | T4 (baseline), S1 |
| A27 | S3 |
| A28 | M1, M2, M3 |
| A29 | M1, M3 |
| A30 | M3 |
| A31 | P1 |
| A32 | R6, T10, Z1 |
| A33 | K2 (UI) |
| A34 | T6 (UI) |
| A35 | S2, M3, P1 (UI) |
| A36 | T4, T5, T6, S1 |
| A37 | T9 |
| A38 | T8 |

## What only the live UI can verify

An agent can build and run tests; it cannot judge any of these. cj checks
them at the marked checkpoints, on his real state.

- A34 after T6: real zmx sessions reattach with scrollback after the
  migration launch, each reachable by click and by the cycling chord. Take a copy of the `layoutsFile` default first.
- A33 after K2: cycling speed and feel under key repeat, no flicker.
- A35 after S2, M3, P1: sub-row appearance, dimming, rollup badge, menus,
  picker, tooltips.
- After F1 and after T3: a day of normal use with no visible change
  (hibernation wake, pane windows, remote worktrees, setup scripts).
- After T11: an already-running shell (old env, no `SUPACODE_TASK_ID`) still
  drives the CLI and agent hooks correctly.
- Remote tasks end to end (host reachable, restore while repos resolve).
- Downgrade behaviour: launching an older build against a v3 store shows no
  layouts and reaps nothing.

## Risks

- **Silent destructive prune** (R8, T3). A key/directory mismatch kills zmx
  sessions and clears snapshots with no error. Mitigation: R8 lands under
  the alias with explicit tests before any id can differ from its directory.
- **Migration data loss** (T1, T4). Mitigation: pure splitter with multiset
  equality tests, backup before write, integrity check at migration time
  that aborts to the unsplit store, reachability (A36) landed before the
  split, UI checkpoint before T7.
- **No downgrade after T2.** Older builds read v3 as unreadable. The v2
  backup is the only way back.
- **R5 breadth.** 50 command cases and 40 call sites; split in three commits
  and keep it purely mechanical. Any behaviour question found there is
  deferred to a later slice, not fixed inline.
- **Runtime surface transfer** (M2). Moving live surfaces between hosts
  touches teardown, hibernation and settle signalling; a stray close signal
  would settle the session being merged. Highest-risk slice; it may need to
  split in two.
- **Reconcile performance** (S1). It runs on every status flip; grouping
  must not add writes. The benchmark lands in T4, before any task code.
- **Stale `DirectoryContext`.** The host is the source of cwd/host; a
  worktree rename or move leaves it stale. Already latent today; R4 keeps
  it, T3 should refresh contexts on `repositoriesChanged`.
- **Hibernation visibility** is tied to selection; with several tasks per
  directory the visible set is the selected task only. Covered by R7's
  rename but needs the UI day after T3.
- **Selection removal.** History and `selectionWasRemoved` are
  worktree-keyed; T5 must retarget `selectedTaskID` or the detail view shows
  a layout whose directory is gone.
- **Notification scope `.selected`** changes meaning (see open questions).
- **Upstream drift.** Every R slice widens the diff from upstream's terminal
  layer; see the TODO in the sizing notes. Not solved here.
- **Name collision.** `Task` (Swift) and `WorktreeTaskStatus` (existing).
  Handled by `TaskRecord` and the R3 rename.
- **Graveyard failure modes.** No slice may add snooze, pin, PR rules or
  auto-worktrees, and nothing sits on a side branch.

## Open questions and the assumption taken

1. Is the task id a separate type from the layout id? **Assumed no**: one
   `LayoutID`, since a task owns exactly one layout.
2. Where does task settle state live? **Assumed** on the primary session's
   existing sidecar entry; no sidecar migration.
3. Do dead-flagged agent tabs count as agent tabs in migration? **Assumed
   yes**: each becomes its own (dormant-capable) task, so no history is
   folded into a shell task.
4. What happens to a shell-only task when its last tab closes or it is
   settled? **Assumed** it is deleted; there is nothing to resume.
5. Orphan tasks (directory deleted outside the app, or never a registered
   worktree)? **Assumed** kept and listed; never pruned automatically; the
   user settles them.
6. Auto-settle rule for a task with mixed members? **Assumed** never while
   any member is live; idle age is the newest member's activity.
   **Decided 2026-10-09**: auto-settle never closes a tab. A task that still
   has any open tab (shell, or an agent tab whose agent has ended) is not
   auto-settled at all; only a task with no open tabs is, by sidecar mark as
   today. Closing tabs is reserved for the settle the user asks for (D6), so
   nothing running is ever killed by a timer.
7. Harness-end of a tangent? **Assumed** it does not settle the task. The
   primary quitting settles the task only when no other member is live
   (otherwise settle would kill live tangents).
8. Detaching the primary? **Assumed** refused; merge the other way instead.
9. Merge and detach entry points? **Assumed** context menu and palette only,
   no drag and drop.
10. Which task does a bare `-w <path>` or worktree deeplink mean when a
    directory has several? **Assumed** the directory's most recently
    selected task; commands carrying a tab or surface id resolve by that id.
11. Worktrees tab: what does selecting a directory with no task show?
    **Assumed** the existing empty state plus a "New task here" action; no
    task is minted on selection.
12. Notification scope `.selected`: this task or this directory? **Assumed**
    this directory (unchanged behaviour); revisit after S2.
13. Per-directory features for a task whose tabs span directories?
    **Assumed** (as in the sizing notes) they follow the task's directory.
14. Setup script with two tasks on one directory? **Assumed** once per
    directory, on its first task.
15. Default agent for Cmd-N? **Assumed** `pi`, as hardcoded today.
16. Are the Worktrees and Agents sidebar tabs kept? **Assumed** kept through
    this plan; removal is a later call.
17. `SUPACODE_WORKTREE_ID` for a tab running outside the task directory?
    **Assumed** still the task's directory.
18. Keep `origin` (v1 snapshot) in v3? **Assumed** yes, in a top-level
    directory-keyed `origins` field (not on any task).
19. `/new` or `/fork` in a task: same task or a new one? **Assumed** same
    task, stays active; the new session takes the replaced one's slot
    (primary if it replaced the primary) and the replaced one stays as a
    session-level-settled dormant member.
20. Rows before phase S: **assumed** one row per session (as today) plus one
    per shell-only task; a task with two agents shows two rows until S1
    groups them.
21. Primary quits while a tangent is live: **assumed** the task stays active
    with a dormant primary; should the live tangent be promoted instead?

## Review notes

Independent review (9 findings), each checked against source. All applied;
none rejected.

- P1 migration before reachability: held (`sessionSnapshots` and
  `worktreeIDForSurface` walk worktrees, one layout each). Enumeration (T4)
  and selection + keyboard (T5) now precede the split (T6); A36 gates it.
- P1 `/new` vs settle: held (`settleReplacedOrEndedSession` settles the old
  key on a changed ref). Replacement semantics specified in T9; A37.
- P1 T1 unwired vs `LayoutsFile`: held (`.worktrees` read at
  `TerminalsFeature.swift:179`, `AgentPresenceFeature.swift:628`). T1 uses a
  separate DTO; T2 switches atomically.
- P1 branch capture: held (capture reads the owning worktree's cached branch
  or cwd). New slice T8; A38.
- P1 origin coverage: held (`allKnownSurfaceIDs` includes origin ids;
  all-agent directory had no owner). Top-level `origins`; A8/A10 tightened.
- P2 membership too late: held. Moved into T7; S is presentation only.
- P2 keyboard too late: held. Minimum cycling in T5, gated in T6.
- P2 perf baseline: held. Benchmark lands in T4; A26 made deterministic plus
  same-run scaling.
- P3 full-test policy: held. Ground rule 4 and A1 aligned.

## Progress

A2 allow-list after R10 (`Worktree.ID` in Terminal layer): `TerminalClient`
`prune(keepingDirectories:)`, `removeLayouts(forDirectory:)`,
`notificationReceived`, `runStatusChanged`, `blockingScriptCompleted`,
`worktreeProjectionChanged`, `worktreeStateTornDown`; manager
`worktreeProjection`/`runStatus` observation keys, `removeLayouts`, `prune`,
`forceEmitProjection`, `emitProjection`, `markNotificationRead`,
`dismissNotification`, `killSession`; `PaneWindowManager.headerInfo`;
`DirectoryContext.worktreeID`, host `worktreeID`, `TerminalSession.worktreeID`,
`NotificationLocation.worktreeID`; the `LayoutID` alias. A3 allow-list:
`DirectoryContext.init(worktree:)` only.

Update this section per slice: id, commit, date, and any allow-list or
deviation.

- R0 (unplanned), 2026-10-08: `make check` was red on cj-main (format
  drift in 20 files, 2 complexity violations). Fixed so the gate can run.
  Full `make test` baseline recorded in the ground rules.
- R1, 2026-10-08: `LayoutID` alias added; `LayoutFeature` and
  `ContentRequest` retyped. `ContentRequest.worktreeID` keeps its name
  (rename belongs to a later slice). Gate: check 0, build-app 0, full test
  run shows only the 5 baseline failures.
- R2, 2026-10-08, `1c122e3a` + `51886759` (review fix: private layout
  helpers in the manager and `PaneWindowManager`): manager storage (7 collections), `focus` observation
  key, `layoutState`/`sendLayout`/`hostIfExists`, `TerminalsFeature`
  layout actions/recents/helpers, and `PaneWindowManager` keys retyped to
  `LayoutID`. `worktreeProjection`/`taskStatus` observation keys left
  worktree-facing (R3 allow-list). Gate: check 0, TerminalTests 340 (only
  the 2 baseline Ghostty failures), TerminalsFeatureTests 24 pass,
  build-app 0.
- R3, 2026-10-08, `bf857eb0` + `45178def`: `TerminalClient` `Worktree.ID`
  closures retyped to `LayoutID`; the 12 layout events relabelled
  `worktreeID:` → `layoutID:`. A2 allow-list (stay worktree-facing):
  `worktreeProjectionChanged`, `runStatusChanged`, `worktreeStateTornDown`,
  plus `notificationReceived`/`blockingScriptCompleted` (not in the R3 list,
  left as is). Deviation: the run-status rename also covers the host's
  `taskStatus`/`onTaskStatusChanged`/`emitTaskStatusIfChanged` and the
  manager's `.taskStatus` observation key. AppFeature's own ack-match enum
  (`tabRemoved`/`tabRenamed` with `worktreeID:`) untouched. Gate: check 0,
  TerminalTests 340 (2 baseline Ghostty failures), TerminalsFeatureTests 24
  pass, FeatureTests 987 (2 baseline failures), build-app 0.
- R4, 2026-10-08: `DirectoryContext` added (`init(worktree:)`, plus
  `scriptEnvironment` so the recipe never needs a `Worktree`). Host stores
  `context` and exposes `worktreeID`; its `repositoryID` standardization moved
  into the context. Recipe `launch`/`environment`/`PlanSeed` and the builder
  lookup (`directory: (LayoutID) -> DirectoryContext?`) take the context; the
  app wires the lookup by mapping the repository worktree. Gate: check 0,
  TerminalTests 340 (2 baseline Ghostty failures), TerminalsFeatureTests 24,
  TerminalSurfaceRecipeTests 8, DirectoryContextTests 2 pass, build-app 0.
- R5a, 2026-10-08: audit moved 15 cases to `LayoutID` (focus family:
  `selectTabAtIndex`, `selectRelativeTab`, `focusRelativePane`,
  `splitFocusedPane`, `focusSplit`, `toggleSplitZoom`, `equalizeSplits`,
  `focusPane`, `toggleZoomPane`, `toggleWindowModeForPane`, `moveTabToSplit`,
  `toggleWindowModeForFocusedPane`; destroy/rename family: `destroyTab`,
  `renameTab`, `closePane`). Deviation: fewer than the planned ≈35, because
  `closeFocused*`, `beginTabRename`, `selectTab`, `focusSurface`,
  `splitSurface`, `destroySurface`, `splitPane`, `performBindingAction*` and
  the 4 search cases call `host(for:)` (may create a host), so they go to R5b.
  Gate: check 0, TerminalTests 340 (2 baseline Ghostty failures),
  TerminalsFeatureTests 24, FeatureTests 987 (2 baseline failures),
  build-app 0.
- R5b, 2026-10-08: the remaining 21 `Command` cases (`createTab*`,
  `openFileWithScript`, `ensureInitialTab`, script cases, `closeFocused*`,
  `beginTabRename`, `selectTab`, `focusSurface`, `splitSurface`,
  `destroySurface`, `splitPane`, `performBindingAction*`, 4 search cases)
  now carry `(LayoutID, DirectoryContext)`; manager helpers and
  `host(for:context:)` take the pair. Deviation: the `focusSurface`/
  `closeSurface` client closures also take the pair and `closeTab` takes
  `LayoutID`, so the `\(Worktree[,)]` check on `TerminalClient.swift` is
  empty. Test asserts that compared a sent `Worktree` now compare its id and
  `DirectoryContext(worktree:)`.
  Gate: check 0, TerminalTests 340 (2 baseline Ghostty failures),
  TerminalsFeatureTests 24, FeatureTests 987 (2 baseline failures),
  build-app 0.
- R6, 2026-10-08, `d5fcb3ad`: `AppFeature.State.layoutID(forDirectory:)`
  (identity) added; every app-layer `terminalClient` command/query that took
  `worktree.id` as a layout (incl. `sendTerminalCommand`, whose builder now
  gets `(LayoutID, Worktree)`, and `launchSessionTab`) and the
  `layouts[id: worktree.id]` reads in `AppFeature+Sessions` and
  `WorktreeDetailView` go through it. `SessionLocation.worktreeID` →
  `layoutID` plus a stored `directoryID` (used by `focusTerminalSurface`
  callers). Deviations: `WorktreeLayoutView` now takes `layoutID` instead of
  `worktree` (its only use was as the layout key); `PaneWindowManager` and the
  `AppFeature` `layouts[id:]` reads keyed by a `.layouts(.element(id:))`
  action id were already layout-keyed, left as is. Gate: check 0,
  TerminalTests 340 (2 baseline Ghostty failures), TerminalsFeatureTests 24,
  AppFeatureSessionsTests 64 pass, build-app 0.
- R6 review fix, 2026-10-08: the first pass routed commands but not the
  queries beside them. Now every `terminalClient` query whose key is a
  directory id from a deeplink, CLI agent command or the selected worktree
  (`selectedTabID`, `selectedSurfaceID`, `paneExists`, `tabExists`,
  `tabCanRename`, `surfaceExists`, `surfaceExistsInWorktree`,
  `canMoveTabToNewSplit`, `sendTextToSurface`) resolves through the seam.
  Left as is because the key already comes from the terminal layer:
  `markUserCloseIntent` (layout element id), `tabID` in `surfaceDeeplinkURL`
  (id from `.notificationReceived`), `markNotificationRead` (notification
  location), `sessionPreview` (grid tile from `listSurfaces`). Not done here:
  those same terminal-origin ids are still used as worktree ids (deeplink
  URL, `worktree(for:)`), and deeplink ack matchers compare a directory id to
  an event's layout id; both are the R7 split. Gate: check 0, TerminalTests +
  TerminalsFeatureTests + FeatureTests 1351 (4 baseline failures),
  build-app 0.
- R6 review fix 2, 2026-10-08: view-side `hostIfExists` lookups keyed by a
  directory id now resolve first: toolbar and sidebar notification focus,
  sidebar typing/right-arrow, inspector mark-all/dismiss-all, window title
  (`WindowTitle.compute` takes a `layoutID:` closure). Sidebar views only
  hold a repositories store, so they read `DirectoryLayoutResolver` from the
  environment (set in `ContentView`, equal by store identity); unset means
  no host, never a second identity mapping. Left as is: the inspector's
  per-row `markNotificationRead`/`dismissNotification` (manager API is still
  `worktreeID:`-typed and emits the worktree projection, R7), the
  `supacodeApp` client closures and `PaneWindowManager` (keys already
  resolved by the caller / layout-origin). Gate: check 0, WindowTitleTests +
  AppFeatureSessionsTests + TerminalTests + TerminalsFeatureTests 447 (2
  baseline Ghostty failures), build-app 0.
- R7 (rename half; the rest moved to T5, see the revised R7 text), 2026-10-08: `setSelectedWorktreeID` →
  `setSelectedLayoutID` (terminal client only; the watcher's stays),
  manager `selectedLayoutID`, `TerminalsFeature.selectedLayoutID`/
  `recentLayoutIDs`/`.selectedLayoutChanged`. The app handler sends the
  resolved layout id; `focusedSurfaceID` reads `terminals.selectedLayoutID`
  directly (already a layout id, no resolver). Left on
  `repositories.selectedWorktreeID` as directory sites that already resolve
  through the seam: `AppFeature` `newTerminal`/palette-dismiss/
  `ghosttyCommand`, `WorktreeDetailView.hasFocusedTab`, `supacodeApp`
  `isFocused`. NOT done, blocked on decisions: the delegate payload carrying
  a layout id (`RepositoriesFeature` cannot reach the R6 seam), the
  layout-half/directory-half gating (no stored "previous" ids in
  `AppFeature`; id-only gating would skip the directory half on the same-id
  re-sends `hasSelectionChanged` emits for path changes), and its AppFeature
  test. Gate: check 0, TerminalTests + TerminalsFeatureTests + FeatureTests
  1351 (4 baseline failures), build-app 0.
- R8, 2026-10-08, `bde1569b`: `prune(keepingDirectories:)` keeps a host by
  `host.worktreeID` (was the key); `removeWorktreeLayout` →
  `removeLayouts(forDirectory:)`, looping the unchanged per-layout teardown
  over every host on that directory. `handleSurfacesClosed`/
  `invalidateCaches` relabelled to layout ids. Decision: a hostless layout
  (hydrated, never selected) has no directory to match, so
  `removeLayouts(forDirectory:)` also tears down the layout keyed by the
  directory id itself when no host sits under that key, as before; that
  directory-id-as-layout-id use is an F1/T3 site. Also left for F1/T3: the
  per-layout `worktreeStateTornDown(worktreeID:)` carries the layout id
  (A2 allow-list, retargeted in T3), and `prune` still cannot see hostless
  layouts (unchanged). Tests: 2 new cases in
  `WorktreeTerminalManagerAckTests`. Gate: check 0, TerminalTests 342 (2
  baseline Ghostty failures), build-app 0, full `make test` 3983 with only
  the 5 baseline failures.
- R9, 2026-10-08, `2afd7ec1`: `init(legacyWorktreeKey:)` and
  `persistenceKey` added (declared on `WorktreeID`: Swift rejects
  `extension LayoutID` on an alias; F1 moves them onto the struct).
  Hydration and the 3 writer sites (`flushLayoutSnapshot`,
  `deleteLayoutSnapshot`, `saveAllLayoutSnapshots`) use them;
  `LayoutsIncrementalWriter` keeps its `String` keys (already the
  persistence form, nothing to change). Decision: the session-name fallback
  is now `worktree?.name ?? host?.context.name ?? URL(path of
  persistenceKey)`; the path parse stays last because a hydrated, never
  opened layout has no host and no context, and dropping it would change the
  name shown. Left for F1/T2: that last path fallback. Tests: new
  `LayoutsLegacyKeyTests` (golden v2 blob, 2 keys → layout/pane/tab/content
  ids). Gate: check 0, TerminalTests + TerminalsFeatureTests 368 (2
  baseline Ghostty failures), build-app 0.
- R10, 2026-10-08, `a8deb176`: 18 manager functions that only index
  `hosts`/layout state (`handleLayoutChanged`, `markUserCloseIntent`,
  `handleUnexpectedZmxClose`, `paneExists`, `canMoveTabToNewSplit`,
  `markLayoutDirty`, `tabExists`, `tabCanRename`, `surfaceExists`,
  `surfaceExistsInWorktree`, `surfaceIDs`, `sessionPreview`, `sendText`,
  `focusedSurfaceID`, `screenPreview`, `isBlockingScriptRunning`,
  `hasUnseenNotifications`, `tabID(forWorktreeID:)`) and 5 `PaneWindowManager`
  keys retyped to `LayoutID`. Decision: A3's `: Worktree\b` also matches
  `: Worktree.ID`; read as "no stored `Worktree` value", which holds. Left
  for F1 (mixed layout key + directory use): `killSession`
  (`worktree(for:)` fallback), `markNotificationRead`/`dismissNotification`
  (host lookup + projection emit), `headerInfo`, `TerminalSession`/
  `NotificationLocation.worktreeID` (carry a layout key, read as a
  directory). Gate: check 0, build-app 0, full `make test` 3985 with only
  the 5 baseline failures.
- F1, 2026-10-08: `LayoutID` is a struct (private string, only
  `init(legacyWorktreeKey:)` / `persistenceKey` / `description`). Production
  constructions: the resolver and hydration only. Decisions, all keeping
  today's behaviour and adding no stored state:
  - Reverse lookups go through `AppFeature.State.worktree(forLayout:)`, which
    scans the roster through `layoutID(forDirectory:)` (no second
    conversion). Used by the content factory's directory lookup,
    `wireSurface`, `killSession` (now `layoutID:`-typed, off the A2
    allow-list), `terminalSessions`, the pane-window header, and the
    layout-keyed events that feed directory actions (`tabCreated`,
    `initialTabCreationFailed`, `setupScriptConsumed`). A layout whose
    directory is not in the roster now skips that directory half (before:
    the action was sent with an id no worktree matched). T3 replaces the
    scan with the task record.
  - Review fix: `commandPaletteToggleRequested` is not one of those. Its
    `selectWorktree` moves the selection even for an id the roster lacks, so
    skipping it changed behaviour. The event now carries the host's
    `worktreeID` next to `layoutID` and the reducer selects it
    unconditionally, as before F1. Test:
    `terminalToggleFromNonRosterOriginStillSelectsIt`.
  - Ack matchers compare `layoutID(forDirectory: ackWorktree)` to the
    event's layout id.
  - Review fix: the roster skip above covers only the
    `worktreeCreationSettled` half of `tabCreated` /
    `initialTabCreationFailed`. Their worktree-new ack resolves from the
    ack's own bound directory (matched through the seam; the success
    `resourceID` is that bound directory), roster or not, as before F1.
    The first F1 cut guarded the whole case, so such an ack rode the
    watchdog and a creation error became a timeout. Tests:
    `tabCreatedResolvesWorktreeNewAckForDirectoryOutsideRoster`,
    `initialTabCreationFailedFailsWorktreeNewAckForDirectoryOutsideRoster`.
  - Manager: worktree-facing events (`notificationReceived`,
    `runStatusChanged`, `blockingScriptCompleted`,
    `worktreeProjectionChanged`, `NotificationLocation`) carry the host's
    `worktreeID`; `emitProjection`/`forceEmitProjection` are layout-keyed
    inside; `markNotificationRead`/`dismissNotification`/shed replay find
    hosts by directory. `worktreeStateTornDown` gained `layoutID:` (its
    coalesce purge needs both keys). The hostless layout in
    `removeLayouts(forDirectory:)` and the CLI `listTabs`/`listPanes`/
    `listSurfaces` resolve through the seam via `appStore`.
    `TerminalClient.markNotificationRead` is `Worktree.ID`-typed.
  - `TerminalSession` and the grid `Tile` gained `layoutID`; their
    `worktreeID` is optional (nil = directory not in the roster; focus/close
    are no-ops there, as they already were). Preview and sort use the layout.
  - Tests: `Worktree(.ID).layoutID` and a `LayoutID` string literal in
    `WorktreeTestSupport`; 3 new cases (seam read-back, non-roster
    `tabCreated`, non-roster tile).
  Left for T2/T3: the `persistenceKey` path parse for a hostless layout's
  display name; `ContentRequest.worktreeID` and manager `worktreeID:` labels
  that carry a layout id (names only). Gate: check 0, build-app 0, full
  `make test` 3988 with only the 5 baseline failures.
- T1, 2026-10-08: `TaskRecord` (+ `Directory { worktreeID, host }`),
  the v3 DTO `TaskLayoutsFile` (schema 3, `tasks`, top-level `origins`,
  `allKnownSurfaceIDs`) and the pure `LayoutsTaskSplitter.split(_:now:makeUUID:)`
  added. Nothing wired; `LayoutsFile` and its consumers untouched. Decisions:
  - `LayoutID.init(task: UUID)` is the one new constructor (a minted task id;
    not a worktree conversion, so A32 still holds).
  - Clock and ids are injected (`now`, `makeUUID`); directories are walked in
    key order so a run is reproducible. All tasks of one migration share
    `createdAt = now`.
  - An agent task's pane gets a fresh pane id (two agent tabs from one v2
    pane would otherwise share one); tab and content ids never change. The
    shell task keeps its v2 pane ids and tree.
  - The directory's host is parsed from the v2 key
    (`RepositoryLocation.parse(persistedID:)`), the same form worktree ids
    use; no roster lookup, so the split stays pure.
  - `sessions` holds only keys that pass `SessionKey.isValid` (unknown
    harness or unusable ref → the tab is still an agent task, with no
    session), de-duplicated in record order.
  - An empty v2 layout yields no task; its origin still moves to `origins`.
  - The DTO decodes tolerantly like `LayoutsFile` and counts a dropped task,
    a dropped origin or dropped tab content in `undecodedEntryCount`; the
    splitter carries the input's count over. Stricter than v2 on origins
    (v2 drops a rotten origin silently) because the origin still owns
    surface ids. T2 owns refusing a lossy value (A9).
  Gate: check 0, `LayoutsTaskSplitterTests` 17 pass, build-app 0.
- T2, 2026-10-08, `6f0dd838`: production codec and every consumer are on
  `TaskLayoutsFile` (schema 3), still one task per directory. `LayoutsFile`
  stays as the legacy v2 decode type only (`readPersisted`/`readFromDisk`/
  `DiskState` moved to `TaskLayoutsFile`). Decisions:
  - One decode for readers and writer, `TaskLayoutsFile.classify`: `.tasks`,
    `.legacy` (v2 or v1 mapped by `init(oneTaskPerDirectory:)`, legacy id,
    directory parsed from the key, origin → `origins`, no split), `.newer`,
    `.lossy`, `.undecodable`. Readers serve only the first two.
  - Backup: the v2 bytes go to the defaults key `layoutsFile.pre-tasks.bak`,
    write-once, before the first v3 write. Two writers can be first: the
    launch upgrade `LayoutsMigrator.migrateStoreToTasksIfNeeded` (called
    after `SettingsRelocationMigrator.run()`) and the incremental writer;
    both back up. Lossy/newer/undecodable defer and leave the blob as is.
  - A mapped task has no real creation date: `TaskRecord.legacyCreatedAt`
    (fixed), so the mapping is pure and re-reads compare equal. T6's split
    stamps its own `now`.
  - v3 also encodes an empty `worktrees` key. Without it a pre-v3 build's
    writer fails the `LayoutsFile` decode, stashes the v3 blob as corrupt
    and starts fresh; with it the old build sees schema 3 > 2 and stays
    read-only, which is what the T2 note promises.
  - Writer changes are keyed by `LayoutID`; `.record(layout:directory:
    createdAt:)` is an upsert (an existing task keeps directory, sessions,
    `createdAt`). `.delete` also drops `origins[key]`, as v2 did when the
    origin lived on the record. A new task's directory is its host's, or for
    a hostless layout the one its legacy key spells.
  - `TerminalsFeature.State.directories` holds each hydrated layout's record
    directory; `worktree(forLayout:)` reads it first, the roster scan is the
    fallback for a layout created this run.
  - Sidebar surface seeding groups persisted tasks by
    `directory.worktreeID` (no key conversion in `RepositoriesFeature`);
    `AppFeature+Sessions` reads `persistedLayout(forDirectory:)` through the
    seam.
  - `SettingsRelocationMigrator` seeds v3 straight from the legacy
    `layouts.json` (which it then moves to `.backup`) and treats any blob
    `classify` can name as valid, so a v3 store is never overwritten by a
    legacy file. `SidebarPersistenceMigrator.rekeyLayouts` untouched: it
    only rewrites the legacy file, which never holds v3.
  Left for T3: `directories` for layouts created this run and the
  `persistenceKey` path parse for a hostless layout's name and directory;
  for T3/T6: `.delete` drops an origin only under the task's own key, so a
  directory whose tasks all have minted ids keeps its origin until the
  directory is removed. Gate: check 0, build-app 0, full `make test` 4023
  with only the 5 baseline failures.
  - Review fix r1, `ce81139d`: a present, non-null v2 `origin` that fails
    to decode now counts as decode loss (it was dropped silently, so the
    upgrade wrote v3 without it and its surface ids left the reaper's set).
    The blob then classifies `.lossy`: upgrade and incremental writer leave
    the v2 bytes and write no backup, readers return unreadable. Absent or
    null origins stay valid. This supersedes the T1 remark that v2 drops a
    rotten origin silently. Choice taken: such a store stays unrestored
    until repaired, the non-destructive option and the same as v3's rule.
    Gate: check 0, build-app 0, full `make test` 4026 with only the 5
    baseline failures.
- T3, 2026-10-08, `a43677e0`: the runtime allows several layouts per
  directory. Nothing mints a second task yet (T6/T7), so behaviour for
  today's stores is unchanged. Decisions:
  - Resolver: `TerminalsFeature.State.activeTasks: [Worktree.ID: LayoutID]`
    and `layoutID(forDirectory:)` there; the `AppFeature` seam delegates to
    it. A directory's own-key layout is stored as "no entry", so selecting a
    one-task directory changes no state and writes nothing (a write per
    worktree switch would re-encode the whole blob). Updated on
    `selectedLayoutChanged`, on `attachLayout` when the selected layout's
    host arrives after the selection, and after hydration (a selection made
    before hydration wins over the stored entry); `detachLayout` drops the
    entries naming that layout.
  - Persisted as `TaskLayoutsFile.activeTasks` (directory → task key),
    encoded only when non-empty so existing blobs keep their bytes, decoded
    leniently (a selection hint owns no sessions, so it is never decode
    loss). Written through `LayoutChangeObserver.activeTaskChanged` →
    `LayoutsIncrementalWriter.flush(activeTask:forDirectory:)`; a task
    `.delete` drops the entries naming it. Hydration serves an entry only
    when its task hydrated and sits on that directory.
  - `attachLayout` carries the host's directory, so `directories` now covers
    layouts created this run (left by T2). A hydrated record's directory is
    never replaced.
  - Orphan rule, taken in `AppFeature` (`allowed` ∪ task directories that
    match no sidebar row), manager `prune` API unchanged. Consequence: only
    an archived directory's tasks are pruned. A worktree deleted in the app
    still tears down through `removeLayouts(forDirectory:)`; one deleted
    outside the app, or whose **repository is removed from the app**, now
    keeps its tasks and sessions as orphans (before: prune killed them).
    Chosen as the non-destructive reading of open question 5; they are not
    listed anywhere until T4/T5.
  - `removeLayouts(forDirectory:)` also finds never-opened tasks by their
    recorded directory, not only the one the seam resolves to.
  - Setup script: the pending flag moved from the host to the manager,
    keyed by directory. It arms only while no layout of that directory holds
    a tab (a brand-new host ignores its own layout, as before), so a second
    task never reruns it. Host `runSetupScript:` init parameter and its four
    setup methods are gone.
  - `worktreeProjectionChanged` is one merged projection per directory
    (`WorktreeRowProjection.merged`; a single task passes through
    untouched), deduped per directory; `runStatusChanged` is running while
    any task there is. `worktreeStateTornDown` unchanged (both ids since F1).
  Left for later: A13's "listed in the sidebar" half is T4/T5. With no
  entry the resolver returns the own-key id even when that layout does not
  exist but other tasks do (an all-agent directory after T6), so selecting
  the worktree row would bootstrap a new shell task: T5/T10 must select a
  real task first. Ack matchers and the manager's CLI list queries still
  compare against the directory's *current* active task (T11 resolves by
  tab/surface id). The `persistenceKey` path parse for a hostless layout's
  display name stays (T5/T7). Gate: check 0, build-app 0, full `make test`
  4045 with only the 5 baseline failures.
- T3 review fix, 2026-10-08: archive pruning now reaches never-opened
  (hostless) tasks, closing the A12 gap R8 left. Decision: `.prune` gained
  `archivedDirectories` (sidebar rows that are archived and not running a
  delete script); the manager removes a hostless task only when its recorded
  directory is in that set and not in the kept set, using the record's
  remote host. Not inferred from "absent from the kept set": that set is
  computed in the reducer and applied later, so a task hydrated in between,
  or one on a not-yet-loaded repository, would have lost its sessions. A
  hostless task with no recorded directory is never pruned.
  `protectingRepositoryIDs` is not consulted for hostless tasks (a record
  carries no repository id); protected repositories have no rows, so they
  are never in `archivedDirectories`. Gate: check 0, build-app 0,
  `supacodeTerminalTests` + `supacodeFeatureTests` 1382 tests with only 4
  baseline failures.
- T3 review fix 2, 2026-10-08: an own-key selection made before hydration
  now outranks the stored active task even after the user moved on to
  another directory (before: only the current selection was reapplied, and
  an own-key selection leaves no `activeTasks` entry, so hydration restored
  the older stored task). Decision: `TerminalsFeature.State.selectedDirectories`
  records every directory whose selection resolved, hydration skips the
  stored entry for those and empties the set; the skipped entry is also
  cleared from the file through `activeTaskChanged(directory, nil)`, else
  the next launch would restore it. Not covered: a selection whose host
  attaches only after hydration (directory unknown at selection time, and no
  longer selected) still loses to the stored entry. Gate: check 0,
  build-app 0, full `make test` 4047 with only the 5 baseline failures.
- T3 review fix 3, 2026-10-08: closes the gap fix 2 left. A selection whose
  directory becomes known only later (host attached after the user moved on,
  or the record that names it hydrated later) now still outranks the stored
  entry, and its hint is persisted. Decision: `selectedDirectories` is
  replaced by `TerminalsFeature.State.selectionOrder`, every layout selected
  this run, oldest first, uncapped (`recentLayoutIDs` is capped and reset on
  memory pressure, so it cannot serve), dropped on `detachLayout`. Whenever a
  directory is named (`attachLayout`, hydration) the latest selected layout
  on it wins; an attach never overrides a later selection on the same
  directory. Hydration applies run selections before the stored entries so a
  directory gets one write rather than a clear racing a set. The log is kept
  after hydration (the late attach needs it); it is runtime only. Gate:
  check 0, build-app 0, `supacodeTerminalTests` + `supacodeFeatureTests` +
  `supacodeTests/TerminalsFeatureTests` with only baseline failures.
- T3 review fix 4, 2026-10-08, `b268f33d`..`f468f271`: four findings, all held.
  - Stale prune (P0, A13): hosted tasks were still pruned by absence from the
    kept set, which is computed before the async send, so a task attached or
    hydrated in between lost host, record and sessions. Decision: the manager
    prunes a task, hosted or not, only when its directory is in
    `archivedDirectories` and not kept or protected. `keepingDirectories` now
    only outranks the archive (delete script running); the orphan union in
    `AppFeature` is redundant but harmless. This supersedes the "prune killed
    them" wording above for every non-archive case: nothing but an archive or
    an explicit `removeLayouts(forDirectory:)` tears a task down.
  - Origin lifetime: `.delete` no longer drops `origins[task key]`. An origin
    is released when no task names its directory any more (decided from the
    deleted record's directory; a task never written falls back to its own
    key). Closes the T2 "left for T3/T6" note in both directions.
  - Backup: `backUpLegacyIfAbsent` reports whether a backup is held; the
    launch upgrade, the incremental writer and the `layouts.json` relocation
    all write v3 only after it. The relocation now backs the file's bytes up
    to `layoutsFile.pre-tasks.bak` first (it used to rely on the later move
    to `.backup`), and a legacy file whose backup failed keeps the relocation
    pending instead of being stamped complete.
  - Tests: multi-task archive and delete, local and remote, now assert the
    persisted tombstones, the origin release and the exact kill targets.
  Siblings checked, no change needed: `removeLayouts(forDirectory:)` (explicit
  deletion), `saveAllLayoutSnapshots` (hosts only, never deletes by absence),
  the launch reaper (reads the persisted file, refuses unreadable stores).
- T3 review fix 5, 2026-10-08, `69ad4e98`: one finding (P0, A12), held.
  `removeLayouts(forDirectory: A)` fell back to the layout the seam resolves
  A to whenever it had no host, so a never-opened task stored under A's key
  but recorded on directory B lost its record and its sessions (killed with
  A's remote host). Decision: the fallback runs only when no runtime record
  names that layout's directory (every layout in `TerminalsFeature` state has
  one, so in practice: not hydrated yet, or dropped at hydration), and its
  stored delete is the new writer change `.deleteIfOn(directory)`, which
  leaves a record naming another directory alone while still releasing the
  deleted directory's own origin. Tests: manager regression, hydrated and
  unhydrated, asserting the record, origin and both kill sides; writer test.
  Siblings checked, no change needed: `prune` and `pruneHostlessLayouts`
  decide by the host's or the record's directory, never the key; every other
  `deleteLayoutSnapshot` caller acts on a layout the runtime already holds.
  Left for T5/T6: the seam itself still resolves a directory with no active
  task to its own-key layout without checking that layout's recorded
  directory, so opening A would host B's task under A's context (and a later
  delete of A would then take it, by host directory). No app path writes such
  a record today (migration keys a task by its own directory, minted tasks
  use `task:` keys); T5/T6 must make the resolver skip an own-key layout
  recorded elsewhere before anything can store one. Gate: check 0,
  build-app 0, full `make test` 4064 with only the 5 baseline failures.
- T4, 2026-10-08, `4621e97e` (A26 baseline tests) + `ff48fc21`: surface
  discovery walks tasks. `AppFeature.surfaceIndex(state:)` returns
  `surface → SurfaceEntry { layoutID, tabID, directoryID, directoryPath,
  cwd }` over every live layout, then every persisted record with no live
  layout (key order; the first owner of a surface id wins). It feeds
  `sessionSnapshots`, `hasUnresolvedLivePresence` and `worktreeIDForSurface`,
  built once per reducer pass. Decisions:
  - A26 baseline, debug build, pre-task code, two runs: unchanged reconcile
    median ≈ 12 ms at 3,000 rows and ≈ 22 ms at 6,000 (ratio ≈ 1.9, gate
    3×). Informational. Tests live in
    `RepositoriesFeatureSessionsScaleTests`: `unchangedReconcileWritesNothing`
    (observation tracking over the row collection, the selection and every
    row field, plus state equality) and `unchangedReconcileScalesLinearly`.
  - `focusedSurfaceID` is unchanged: since R7 it reads the selected layout
    directly and never went through the roster, so it has nothing to take
    from the index.
  - `SessionLiveSnapshot.cwd` stays the task directory's path, as today; the
    tab's own cwd is only exposed as `SurfaceEntry.cwd`, for T8. Reason:
    reconcile's branch annotation matches the row cwd exactly against a
    worktree's working directory, so a tab sitting in a subdirectory would
    show a false branch mismatch. T8 owns the cwd-aware branch logic.
  - `SurfaceEntry.cwd` is the tab state's `workingDirectory` in the layout
    walked. A live tab's state holds its launch or restored value (the
    current pwd is only read at snapshot time), so a tab opened this run
    falls back to the task directory. T8 must not assume it is the live pwd.
  - A task's directory comes from `terminals.directories` (live) or its
    record (persisted). A live layout nothing has named a directory for
    falls back to `worktree(forLayout:)`; with no match it is skipped, as
    before. An orphan's path is parsed from its directory id.
  - Persisted tasks are now found before the roster loads and for
    directories outside it (before: only through a roster worktree).
  Left for T5: a row for an orphan or a second task appears as soon as an
  agent reports on it, but activating it still focuses by
  `location.directoryID` (`focusSession` → `focusTerminalSurface`), so an
  orphan row cannot be focused and a second task's row goes through the
  seam; T5 routes by `location.layoutID`. `SessionSidebarItemFeature` and
  `SessionsSidebarStructure` needed no change (`SessionLocation.layoutID`
  exists since R6). Gate: check 0, `supacodeFeatureTests` + `supacodeTests`
  3189 tests with only 3 baseline failures (ack flake, settings-changed,
  bracket chords), build-app 0.
  Review fix r1: mapping a non-active or orphan task's provisional agent
  cleared the global unresolved-presence gate, but auto-settle then protected
  only the task directory, so an old session indexed where the tab actually
  ran could be settled while possibly being that agent. The snapshot now
  also carries `surfaceCwd` (the tab's recorded cwd when it differs from the
  task directory) and `autoSettleSessions` protects both directories. Chosen
  over putting the tab cwd in `SessionLiveSnapshot.cwd` because row cwd and
  branch annotation stay T8's; over keeping the global gate because that
  blocks all settlement for any mapped provisional agent. Reducer tests drive
  restore then refresh for a live non-active task and a persisted orphan.
  Left for T8: a tab that `cd`s after launch has no recorded cwd until the
  next layout snapshot, so only its task directory is protected (same as
  before T4 for the active task); T8's cwd-aware work should feed the live
  pwd here. Gate: check 0, `AppFeatureSessionsTests` 71 pass,
  `supacodeFeatureTests` 1004 and `supacodeTests` 2187 with only the 3
  baseline failures, build-app 0.
- T5, 2026-10-08, `5c0793d1`: a row selects its own task, a task with no
  live agent has a row, and the existing shortcuts walk both. Decisions:
  - `selectedTaskID` is computed, not stored: `RepositoriesFeature.State`
    holds `selectedTask { id, directoryID }` (the directory is kept with the
    selection because this feature has no task table) and `selectedTaskID`
    answers only while `selection` still sits on that directory.
    `.selectTask` always moves `selection` to the task's directory, so the
    planned `tasks[selectedTaskID]?.directory ?? selection?.worktreeID` is
    just `selection?.worktreeID` and `selectedWorktreeID` is unchanged (A18
    by construction). A removed or deselected directory therefore drops the
    task with no extra write on the many selection paths; `AppFeature` sends
    `.selectedTaskRemoved` when the task itself is gone (no live layout and
    no record: a selection hint, nothing is torn down on it).
  - Row rule: a `.task(LayoutID)` row for every task that holds at least one
    tab and has no live agent in it. Deviation from "no sessions": decided by
    the agents present, not by `TaskRecord.sessions`. Membership is not
    recorded until T7, so today every record has no sessions and the plan's
    wording would give each agent task a second row; and after T6 a task
    whose agent died keeps its tab but would have no live row. An empty task
    gets no row (activating it would bootstrap a tab, i.e. mint). Rows come
    from `AppFeature.taskSnapshots` over the same task walk as T4's index
    (`taskEntries`, shared) and reach the sidebar as `.taskSnapshotsChanged`.
    `createdAt` is the record's; a task not stored yet keeps the date it was
    first seen. Legacy records carry `legacyCreatedAt`, so their rows sort
    last in Active.
  - A task row's location anchors on the task's first tab so the row does not
    change (and reconcile does not rerun) on every tab switch. Activation
    ignores the anchor: `.focusTask` selects the task and sends
    `ensureInitialTab(focusing: true)`, which only focuses what the task had
    focused because the row exists only for a task with tabs. Session rows
    keep `focusSurface`, now with `location.layoutID`.
  - All four session focus sites (row, next/previous and slots,
    settle-and-advance, resume of an already live session) go through
    `AppFeature.focusSession`/`focusTask`. `.focusTerminalSurface` stays for
    the grid, settings and deeplinks, still directory-resolved (T11).
  - `selectedWorktreeChanged(worktree, layoutID:)`: one handler, both halves
    on every send, as the revised R7 says. A17 is therefore met as "nothing
    on the directory side changes": the watcher is re-sent the id it already
    has (its manager returns early on an equal id), the repository's scripts
    are kept, and settings are re-read for the same key. It is not "no
    send". The test asserts the layout command, that the watcher is never
    given another id and that the scripts survive.
  - The focused surface maps to its task row when no agent is on it, so the
    sidebar highlight and Cmd-N's directory follow a shell-only task.
  - Tests: `RepositoriesFeatureTaskSelectionTests` (new) and a T5 block in
    `AppFeatureSessionsTests`, including A36 over six tasks on two
    directories (own-key, agent, shell-only, never-opened record), cycling
    from every row in both directions. Two existing tests gained a clock,
    and one an index-backed row, because a roster or terminal change now
    reconciles task rows.
  Left for later:
  - Orphan tasks: fixed in review round 1, see the T5 r1 entry below.
  - Resolver (T6/T10), both from T3: a directory with no `activeTasks` entry
    still resolves to its own-key id even when that layout does not exist or
    is recorded on another directory. Not changed here: the fallback would
    have to scan every task on each call from view code. T6 can write an
    `activeTasks` entry for every directory it leaves without an own-key
    task; T10 owns worktree-row selection.
  - T7: a re-sent `selectedWorktreeChanged` with no `layoutID` (roster reload
    with a changed path) resolves through the seam, which follows the
    selected task only after the terminal echoes the selection.
  Gate: check 0, `supacodeFeatureTests` + `supacodeTests` 3216 tests with
  only 3 baseline failures (ack flake, settings-changed, bracket chords),
  build-app 0.
- T5 review round 1, 2026-10-08: an orphan task (directory not in the
  roster) is now shown and focused from its row and from the cycle (A36);
  before, both focus helpers returned without doing anything. Decisions the
  plan did not make, taken as the non-destructive and smallest option:
  - Context: `DirectoryContext(orphan:)` is built from the directory the task
    recorded (live `terminals.directories`, else the stored record): the id
    is the path, which also stands in for name, repository root and
    repository id; host from the record. Nothing is added to the roster and
    no `Worktree` is invented.
  - Selection: `.selectTask` on an unknown directory clears the worktree
    selection, keeps `selectedTask`, and sends
    `selectedWorktreeChanged(nil, layoutID: task)`. The handler then selects
    that layout in the terminal instead of none, points the watcher at
    nothing, drops the repo scripts, and leaves `sidebar.focusedWorktreeID`
    alone so the next launch still restores the last real worktree.
    `orphanTaskID` answers only while `selection == nil` and the directory is
    still unknown; a plain deselect (`selectedWorktreeChanged(nil)` with no
    task) clears `selectedTask`, and any other selection ends it by
    construction. `selectedWorktreeID` is nil for an orphan, so A18 reads as
    "no directory, no directory features".
  - Detail view: with no selected worktree and an `orphanTaskID`, it mounts
    `WorktreeLayoutView` for that layout with none of the directory chrome.
    Checked safe: roster prune removes a host only for a directory named as
    archived, so hosting an orphan does not expose it to prune.
  - Tests (`AppFeatureSessionsTests`): the test that pinned the no-op is
    replaced by activation of an orphan shell row and an orphan agent row
    (record-only), the orphan context, cycling in both directions from every
    row over the six tasks plus two orphans, and leaving an orphan.
  Left for later (T10/T11): the app-menu terminal commands (new tab, close
  tab, split, search, rename) resolve through `selectedWorktreeID` and are
  disabled while an orphan is shown; typing in its terminals and the
  session shortcuts work. Branch capture for an agent in an orphan is
  skipped (needs a roster worktree; T8). Not verified in the live UI.
  `RepositoriesFeatureTaskSelectionTests` had a second test pinning the
  no-op; it now asserts the orphan selection and leaving it.
  Gate: check 0, `supacodeFeatureTests` + `supacodeTests` 3220 tests with
  only the 3 baseline failures (ack flake, settings-changed, bracket
  chords), build-app 0.
- T5 review round 2, 2026-10-08:
  - Missing directory (fixed): a task on a directory that is still a roster
    worktree but gone from disk (`isMissing`) was hidden behind
    `MissingWorktreeDetailView`. `AppFeature.State.taskOnMissingDirectory`
    (selected task that still exists, on a missing roster worktree) now takes
    precedence: the detail view mounts that task's layout through the normal
    worktree branch. The toolbar's directory chrome was already off for a
    missing worktree. Decision the plan did not make: a directory-only
    `selectedWorktreeChanged` for a different directory now clears
    `selectedTask`, so selecting the missing directory's own row after
    leaving shows the placeholder (and its delete action) again instead of
    the remembered task. While the task is shown the placeholder is one
    row-switch away. Menu commands still resolve through the seam (T10/T11,
    as for orphans).
  - Focus of a populated task (finding rejected, test added): the
    `.ensureInitialTab` command handler calls `host.focusSelectedTab()`
    whenever `focusing` is true, after the private bootstrap returns, so a
    populated layout is focused: at once when its surface is live in the key
    window (`claimFocus` → `requestFocus`, whatever the first responder
    was), otherwise latched and claimed by `applySurfaceActivity`. The
    view's `forceAutoFocus: false` only governs the separate view-level
    path. Pinned by
    `WorktreeTerminalManagerAckTests/ensureInitialTabOnAPopulatedOrphanTaskRequestsFocusWithoutATab`
    (focus requested, no tab made, selection kept). The first-responder
    handoff itself is not verified in the live UI.
  - T5 regression found here: `taskSnapshotsChanged` reads `date.now`, which
    failed 19 `WorktreeTerminalManagerAckTests`/`PaneCycleTests` cases that
    drive a real `AppFeature` store; T5's gate never ran
    `supacodeTerminalTests`. Their harnesses now inject a date.
  Gate: check 0, `supacodeFeatureTests` + `supacodeTerminalTests` +
  `supacodeTests` 3624 tests with only the 5 baseline failures, build-app 0.
- T5 review round 3, 2026-10-08:
  - Shared session identity (fixed, `74705ba1`): two tasks reporting one
    session share one session row, which leads to one of them; the other
    had no row and cycling skipped it. `AppFeature.taskSnapshots` now lists
    every task that holds tabs (candidates, no agent filter) and
    `reconcileSessionItems` keeps a task row unless a session row's
    `location` actually leads to that layout. `focusedSessionRowID` follows
    the same rule, so focus in the task the shared row does not lead to
    highlights its task row. `RepositoriesFeature.State.taskSnapshots` is
    therefore "candidates", not "rows": read `sessionItems` for rows.
  - Focus of an unmounted agent surface (fixed, `25de6c99`): the
    `.focusSurface` command only asked the live renderer; it now also calls
    `host.focusSelectedTab()` after waking and selecting the tab, so the
    request is latched when the surface is hibernated or not mounted. This
    is the one command path for every agent row, roster or orphan. The
    first-responder handoff itself is still not verified in the live UI.
  Gate: check 0, `supacodeFeatureTests` + `supacodeTerminalTests` +
  `supacodeTests` with only baseline failures, build-app 0.
- T6, 2026-10-09, `a6ea2c0d` + `2ec24480`: the split is wired into
  `LayoutsMigrator.migrateStoreToTasksIfNeeded` (launch, before hydration).
  Decisions:
  - Marker: `TaskLayoutsFile.tasksSplit`, encoded only when true. A blob
    without it (v2, or v3 written by T2–T5 builds) decodes as unsplit. A
    store created fresh (`TaskLayoutsFile()`, the writer's value for an
    absent or stashed-corrupt blob) is born split: nothing in it predates
    task ownership, and splitting a post-T7 multi-tab task would be wrong.
  - The splitter's core now takes the v3 shape
    (`split(_: TaskLayoutsFile, …)`); the v2 overload maps one task per
    directory first. Leftover tabs keep their record (id, directory,
    sessions); a mapped v2 record's `legacyCreatedAt` becomes `now`.
  - Active task: a directory follows the task that took its focused tab
    when that tab was an agent; a directory left with no own-key task
    follows its first agent task. Entries naming a task that no longer
    exists are dropped. Closes the T3/T5 "all-agent directory resolves to a
    layout that does not exist" note for migrated stores.
  - Integrity, checked on the value that would be written after reading it
    back through `classify`: same tab items (multiset, content included),
    same origins, same `allKnownSurfaceIDs`, same agent-record surfaces,
    every task under its own key, every active-task entry resolvable. Any
    failure writes nothing for an unsplit v3 store; a v2 blob still gets the
    T2 one-task-per-directory upgrade. Retried next launch.
  - Backup: the replaced bytes go to `layoutsFile.pre-task-split.bak`,
    write-once, before the split is written (`pre-tasks.bak` usually already
    holds older v2 bytes and is write-once, so it cannot serve). A v2 blob
    is written to both. A refused backup writes nothing.
  - Rerun safety beyond the marker: a minted task holding exactly one agent
    tab is left as is, so a split store rewritten without the marker by a
    T2–T5 build keeps its task ids and sessions. Not covered: on such a
    downgrade round trip after T7, a minted task with several tabs would be
    split again (tabs and sessions are never lost, they move).
  - `SettingsRelocationMigrator` needed no change: it seeds an unsplit v3
    value from `layouts.json` and the store migration, which runs right
    after it, splits that.
  - Tests: new `LayoutsTaskSplitMigrationTests` (Terminal bundle; v2 and
    unsplit-v3 end to end, backup order, idempotence, lost marker, abort
    paths, integrity cases) and
    `AppFeatureSessionsTests/everyMigratedTaskHasARowAndIsInTheCycle`.
  Left for later: the resolver still returns the own-key id for a directory
  with no entry without checking that layout exists or sits on that
  directory (T10; no app path stores such a record, and the split writes an
  entry wherever it removes the own-key task). The incremental writer still
  upgrades a v2 blob unsplit if it runs before the launch migration could
  (deferred backup); the next launch splits it. **A34 UI checkpoint is
  cj's, before T7**: copy the real `layoutsFile` default aside, launch,
  confirm every agent and shell reattached and is reachable by click and by
  the cycling chord. Gate: check 0, `supacodeTerminalTests` +
  `AppFeatureSessionsTests` 511 tests with only the 2 baseline Ghostty
  failures, build-app 0, full `make test` 4125 with only the 5 baseline
  failures.
- T6 review round 1, 2026-10-09, `310067d5` + `067601a7`:
  - Marker (P1, held): a present but unreadable `tasksSplit` (`"true"`, `1`,
    `null`, `{}`) decoded as unsplit and authorised the split. Only an
    absent marker means unsplit now. Choice: the unreadable marker is
    counted in `undecodedEntryCount` (blob classifies `.lossy`) instead of
    the reviewer's throwing decode, because a throw classifies
    `.undecodable` and `LayoutsIncrementalWriter.readPersisted` stashes such
    a blob aside and starts fresh. Lossy is the non-destructive one:
    migration defers, the writer aborts its flush, readers report unreadable
    so nothing is reaped.
  - Stale hint (P2, held): a hint whose target is not in the file now reads
    as no hint, and every directory whose own-key task the split removes
    gets a fallback entry (its first minted task) if nothing valid is left
    after the stale-entry filter; that also covers a hint naming another
    task that the split itself removes. The integrity check gained
    "directory left without a task": a directory that had an own-key task
    must still resolve (`activeTasks[dir] ?? dir`) to an existing task.
  - Tests: `unreadableSplitMarkerLeavesTheStoreUntouched`,
    `staleHintOnAnAllAgentDirectoryStillMapsItToARealTask`, the new
    integrity case, and
    `AppFeatureSessionsTests/allAgentDirectoryWithAStaleHintResolvesToAMigratedTask`
    (split, hydrate, resolve). All red before the fixes.
  Still left for T10: the runtime resolver's unchecked own-key fallback
  (deleting a directory's active task at runtime clears the hint in
  `LayoutsIncrementalWriter`, which is the T3 behaviour, not the split's).
  Gate: check 0, focused Terminal migration suites + `AppFeatureSessionsTests`
  170 tests 0 failures, build-app 0, full `make test` exit 2 with 4128 tests
  and only the 5 baseline failures.
- T6 review round 2, 2026-10-09, `2f2ce547` + `58269dd3`:
  - Empty directory (P1, held): the splitter drops a directory with no tabs
    (T1 decision), but "directory left without a task" demanded a task for
    it, so one empty own-key layout failed the check for the whole store on
    every launch. The check now applies only to a directory that had tabs
    under its own key. Its origin still has to survive ("origins differ").
  - Cross-directory hint (P1, held): a hint naming an existing task on
    another directory counted as valid, suppressing both the focused-tab
    mapping and the all-agent fallback, while hydration ignores such a hint.
    The splitter now uses hydration's rule (task exists and its recorded
    directory is the hinted one) when reading a hint and when filtering the
    result, so the entry is dropped and the fallback applies. The integrity
    check gained "active task on another directory", and "directory left
    without a task" requires the resolved task to sit on that directory.
  - Tests: `emptyDirectoryDoesNotBlockTheSplit` (v2 and unsplit v3),
    `hintNamingAnotherDirectorysTaskDoesNotCostAnAllAgentDirectoryItsMapping`,
    the new integrity case, and `AppFeatureSessionsTests/
    allAgentDirectoryWithACrossDirectoryHintResolvesToItsOwnMigratedTask`
    (split, codec, hydrate, resolve). All red before the fixes.
  Left for T7: the splitter drops a record whose layout is empty even if it
  carries `sessions`, and drops the record's `sessions` when every tab was an
  agent. No store written before T7 has such a record (sessions are only
  filled by the split itself or by T7, whose stores are born split), but T7's
  "task with sessions keeps its record with an empty layout" must not be fed
  through the splitter by a lost-marker rerun.
  Gate: check 0, focused split suites + `AppFeatureSessionsTests` 133 tests
  0 failures, build-app 0, full `make test` exit 2 with 4131 tests and only
  the 5 baseline failures.
- T7, 2026-10-09, `672f3f55` + `489508b7` + `aa02291e`: Cmd-N and the
  resume of a session no task lists mint a task; a reporting agent joins the
  task that owns its surface. Started without the A34 UI checkpoint being
  confirmed in this plan (still cj's). Decisions:
  - Membership: `TerminalsFeature.State.members: [LayoutID: [TaskMember]]`
    (`.session(key)` or `.provisional(harness, surfaceID)`), primary first.
    `TaskMembership.reconciled` (pure) runs in `sessionsLinkReducer` over
    presence × T4's surface index and is applied by `.membersChanged` only
    when it differs. A session is appended once and never removed here; a
    provisional member becomes its session in place (so the agent started
    first stays primary), is dropped when its session is already listed,
    and goes when its agent does. Only `.session` members are stored.
    Hydration loads `record.sessions` (stored first, then anything this run
    added before the file loaded); `detachLayout` forgets them.
  - Storage: no new write path. `.record` gained `sessions`, read by the
    manager from `members` at flush time; a change in stored sessions marks
    the layout dirty through the new `LayoutChangeObserver.sessionsChanged`.
    The writer only ever adds to the stored sessions (the caller may not
    have loaded them). T9 (slot replacement) and M (merge/detach) need their
    own reorder/remove change.
  - Last tab closed: the manager no longer decides. It sends the empty
    layout and the writer deletes the record only when the stored record,
    after the merge, lists no session; otherwise the record stays with an
    empty layout, its directory and its active-task hint. (The first cut
    left the emptied runtime layout and host in place; r1 below removes them.)
  - Splitter: a record that lists sessions is left as is (covers the T6 r2
    note: an empty task with sessions, and a multi-agent task on a
    lost-marker rerun). Consequence: if the split was deferred by an
    integrity failure and this build then adds sessions to an unsplit
    own-key record, a later retry leaves that record's agent tabs together.
  - Minting: the id is minted in `launchSessionTab` (`LayoutID(task:)`), the
    task comes into being through `createTabWithInput` on that id, so a
    launch whose tab is never created leaves no layout or record (and, since
    r1, no member: the first cut listed a resume's session up front).
    Resume reuses the task that lists the session only when that task sits
    on the directory the session resumes in (its tabs start in its own
    directory; a tangent that ran elsewhere gets a new task and stays listed
    in the old one too); the minted resume task is seeded with the session
    as primary before the agent reports.
  - Showing it: `AppFeature.State.pendingTaskSelection` holds the launch's
    task and `.selectTask` is sent from the reducer pass that first sees a
    tab in it. Selecting earlier would run `ensureInitialTab` on an empty
    layout and bootstrap a plain shell tab beside the agent (tab creation
    is asynchronous in the manager). If the tab never appears the pending
    selection is simply replaced by the next launch.
  - T5's note for T7: a `selectedWorktreeChanged` with no `layoutID` now
    keeps the task still selected on that directory (when it exists) before
    falling back to the seam, so a roster reload cannot flip back to the
    directory's previous active task before the terminal echoes the new one.
  - Default agent stays `pi` (open question 15). No row or grouping change.
  Left for later:
  - T9: membership appends every valid ref a surface reports, so `/new`,
    `/fork` and (if the follow-up's hypothesis holds) workflow sub-agent refs
    all become trailing members; T9's slot rule and sub-agent filter must
    also clean those. A session resumed by hand in another task's tab is
    listed by both tasks; resume picks the one on its directory, lowest key.
  - T8/S: resuming a member whose task sits on another directory mints a
    task instead of reopening it there.
  - Not verified in the live UI: the first-responder handoff of the
    deferred selection. (The manager passing `members` into the record is
    covered since r1.)
  Tests: `AppFeatureSessionsTests` (minting and membership block, A15, A21,
  A22), `LayoutsIncrementalWriterTests` (sessions and the last tab),
  `LayoutsTaskSplitterTests`, `TerminalsFeatureTests`. Gate: check 0,
  `supacodeFeatureTests` + `supacodeTerminalTests` +
  `supacodeTests/TerminalsFeatureTests` 1519 tests with only 4 baseline
  failures (ack flake, settings-changed, 2 Ghostty), build-app 0.
- T7 r1 (review fixes), 2026-10-09. Four findings, all held:
  - Cmd-N directory (P1): `newSessionCwdFallback` now starts with
    `currentTaskDirectory`: the task on screen (`selectedTaskID`, else the
    terminal's selected layout, when `hasTask`) and its recorded directory.
    The focused session's cwd and the highlighted history row only decide
    when no task is on screen or the task is remote (the launch path checks
    the directory with `FileManager`, as before). The Cmd-Shift-N browse
    panel starts from the same place. The old test asserting "focused
    session's cwd first" encoded the bug and was replaced.
  - Sessionless task, last tab closed (P1): removed at runtime too.
    `handleLayoutChanged` removes the task when the layout is empty, the
    host's last lifecycle sweep still held a tab (so a task being minted,
    empty before its first tab, is never taken for an emptied one), the file
    is not read-only, and neither `members` nor the launch-time record lists
    a session. It flushes the empty record at once (the writer still has the
    last word and keeps a record whose stored sessions it finds), tears the
    host down, detaches the layout, and if the task was the one on screen
    re-selects what the directory resolves to. Nothing is killed there: the
    tabs' sessions went with the tabs; the remote host is remembered so the
    close's own session kill, which runs after, still reaches it. A task
    with sessions keeps its empty layout, host and record. Applies to a
    directory's own-key task as well (open question 4).
    Decision (not in the plan): after removing the selected task the
    directory shows its resolver target (own-key layout, usually the empty
    state), not "the next task". It closes nothing and mints nothing; moving
    on to another task is T9's settle-and-advance.
  - Launch-time file vs removed tasks (found with the above; archive and
    delete have hit it since T4): `persistedLayouts` is read once, so a
    detached task came back as a dormant row and `hasTask` stayed true,
    which kept a dead `selectedTask` that a roster reload would re-bootstrap
    with a shell tab. `TerminalsFeature.State.removedLayoutIDs` (set by
    `detachLayout`, cleared by `attachLayout`) is honoured by
    `storedTask(s)`, now the only app-layer readers of stored records for
    task identity (`hasTask`, `taskEntries`, `task(listing:)`,
    `directoryContext`). Not switched: the `persistedSurfaces` seeding in
    `syncSidebar` and `persistedLayout(forDirectory:)`.
  - Manager boundary (P1 test gap): `LayoutChangeObserver.persisting(through:)`
    is the app's wiring and the tests', so `WorktreeTerminalManagerAckTests`
    drives membership change, dirty notification, debounce, the real writer
    and last-tab close against in-memory defaults: sessions reach the record
    and the emptied task survives; the sessionless one is deleted (record,
    host, layout, active-task entry, selection) with its sibling untouched;
    the quit-time save carries sessions too (same `recordChange`).
  - Failed resume (P2): the resume's primary rides in
    `PendingTaskSelection.primary` and is listed (ahead of anything the agent
    reported) in the pass that first sees the task's tab; a resume whose tab
    never appears lists nothing.
  Left for later:
  - T9: after a sessionless selected task is removed, selection falls to
    the directory, not the next live task.
  - T10: `persistedLayouts` stays a launch-time snapshot; `removedLayoutIDs`
    only covers removals. Any new reader of stored records for task identity
    must go through `storedTask(s)`.
  Tests: red before the fixes (the four behaviour tests failed with the
  fixes disabled, everything else green), green after:
  `AppFeatureSessionsTests` (Cmd-N directory, removed task, resume seeding),
  `WorktreeTerminalManagerAckTests` (four new), `TerminalsFeatureTests`.
  Gate: check 0, `supacodeFeatureTests` + `supacodeTerminalTests` +
  `supacodeTests/TerminalsFeatureTests` 1528 tests with only 4 baseline
  failures (ack flake, settings-changed, 2 Ghostty), build-app 0, full
  `make test` exit 2 with 4163 tests and only the 5 baseline failures.
- T7 r2 (review fixes), 2026-10-09, `c034d74a` + `be532240`.
  Two findings, both held; this supersedes two notes above ("the pending
  selection is simply replaced by the next launch" and "the highlighted
  history row only decide when ... the task is remote"):
  - Two launches before either tab (P1): `launchSessionCompleted` frees the
    launch slot when the command is sent, before the tab exists, so the
    single `pendingTaskSelection` was overwritten and the first resumed
    task never had its session seeded as primary. Now
    `pendingTaskLaunches: [PendingTaskLaunch]`, one entry per task until
    its first tab appears; every entry seeds its primary, only the latest
    (`isShown`) is selected, whichever tab arrives first.
    Decision: an entry whose tab never appears stays in the list for the
    run (it used to be dropped by the next launch). It names a task that
    does not exist, so it lists and selects nothing; nothing reports a
    failed tab creation to clear it on.
  - Cmd-N on a remote task (P1): `currentTaskContext` resolves the task on
    screen to its `DirectoryContext`, host included (roster worktree or
    recorded directory). A remote one launches straight into it; the
    `FileManager` check and folder registration only run for local
    directories. `launchSessionTab` takes a `DirectoryContext`.
  Same class, checked and left:
  - P: the Cmd-Shift-N browse panel still starts from a local path when the
    task on screen is remote (`currentTaskDirectory` is nil there); a remote
    directory is the picker's job (A31).
  - T8/S: resume validates the session's cwd with the local `FileManager`
    and finds its directory by local path, so a session that ran on a remote
    host cannot be resumed from its history row (alert, nothing launched).
  Tests, red before the fixes: `AppFeatureSessionsTests`
  `twoResumesLaunchedBeforeEitherTabAppearsEachLeadTheirOwnTask` (both tab
  orders) and `newSessionOnARemoteTaskStartsOnItsHostNotInALocalDirectory`.
  Gate: check 0, `supacodeFeatureTests` + `supacodeTerminalTests` +
  `supacodeTests/TerminalsFeatureTests` 1530 tests with only 4 baseline
  failures (ack flake, settings-changed, 2 Ghostty), then
  `AppFeatureSessionsTests` 119 tests 0 failures on the final tree (a
  test-only lint fix came after the wide run), build-app 0. No full
  `make test` (T7 is not a full-run slice).
- T7 r3 (review fix), 2026-10-09, `dbc47cfd`. One finding, held: the
  remote-host fallback that lets a close's delayed kill reach the host after
  `removeTaskIfEmptied` dropped it (r1) had no test; the sessionless-task
  test was local with a stubbed killer. `WorktreeTerminalManagerAckTests`
  now runs the app's real `ContentSessionKiller` wiring on a remote
  sessionless task with a surviving sibling, in a roster-less store so only
  the fallback can supply the host: explicit close kills that tab's session
  on the host and locally, a self-ended (local-only) close spares the host
  session, a spared close kills nothing, the sibling is never touched.
  Mutation-checked: dropping the fallback fails the first test.
  Production change is a seam only: the three spare/local-only marks in
  `handleUnexpectedZmxClose` go through `limitSessionKill(of:to:)`, because
  the harness has no live Ghostty surface to drive that probe with.
  Same class, checked and left: `remoteHostsOfEmptiedTasks` is never pruned
  (one host per removed task for the run; a live host and the map agree on
  the same key, so a stale entry cannot redirect a kill).
  Gate: check 0, `AppFeatureSessionsTests` + `supacodeTerminalTests` 551
  tests with only the 2 Ghostty baseline failures, build-app 0.
- T7 r4 (review fixes), 2026-10-09, `aa7aa5cb` + `130b1465` + `db889e97` +
  `7a5d616c`. Four findings, all held; this supersedes "neither `members`
  nor the launch-time record lists a session" (r1) and "the writer only
  ever adds to the stored sessions" is now also "and never moves one":
  - Partial list replaced the primary (P1): the writer put the caller's
    list first. Stored order now stands and unlisted sessions are appended
    (`task.sessions += new`), the same order `TaskMembership.merged` hydrates
    in. Same class, checked and left: `showLaunchedTaskIfReady` puts a
    resume's primary first, but only for a task minted by that launch
    (`owner == nil`), which has no stored record; the splitter leaves a
    record that lists sessions alone. T9 (slot replacement) and M still need
    their own reorder/remove change.
  - Stale archived set (P1): `handleCommand(.prune)` intersects the
    command's `archivedDirectories` with `AppFeature.State.archivedDirectories`
    read from the store at delivery (the reducer computes its set from the
    same property). No store, nothing pruned. `prune(...)` itself still
    tears down what it is given; the teardown tests call it directly
    because the harness store has no roster. Same class, checked and left:
    `.removeLayouts(forDirectory:)` follows `worktreeDeleted` (the directory
    is gone from disk, nothing to reverse); the protected-repository set is
    only ever a shield, and a repository that stops loading loses its rows,
    so its directories are no longer "archived now".
  - Removal decided from two sources (P2): the race was real (mutation
    check: with the launch-time check restored, a task whose stored record
    lists a session the runtime never loaded was detached while its record
    stayed). `removeTaskIfEmptied` now asks
    `LayoutsIncrementalWriter.storedSessions(of:)`, which reads behind every
    queued flush on the writer's queue. Runtime members ∪ that read is
    everything the writer will merge, so both keep or both drop.
    Decisions (not in the plan): an unreadable store (lossy, newer) keeps
    the runtime task, since the writer aborts and the record stays; an
    undecodable blob counts as "no record". The read blocks the main actor
    behind queued layout flushes, as the quit-time `flushSync` does; it runs
    only when a task's last tab closed and the runtime lists no session.
    Not verified in the live UI: that this wait is unnoticeable.
  - Unchecked stash (P1): `stashCorrupt` reads the stash back; a flush that
    cannot stash aborts and leaves the blob. Same class, fixed:
    `SettingsRelocationMigrator.seedLayouts` wrote over an unreadable value
    after the same unchecked stash; it now leaves the value and
    `layouts.json`, and `legacyLayoutsAwaitStash` withholds the relocation
    marker so the seed retries. Left (not layouts, pre-dates this work): the
    sidebar seed's `stashCorruptUserDefaults` and `SidebarPersistenceKey`
    stash are still unchecked; a second undecodable blob overwrites the
    first stash.
  Tests, red before the fixes: `LayoutsIncrementalWriterTests`
  (`recordNeverDropsOrReordersAStoredSession`,
  `aPartialListNamingAStoredTangentDoesNotPromoteIt`,
  `aCorruptBlobThatCannotBeStashedIsLeftInPlace`),
  `SettingsRelocationMigratorTests`
  (`legacyLayoutsAreNotSeededOverAnUnreadableValueThatCannotBeStashed`),
  `WorktreeTerminalManagerAckTests`
  (`anArchiveReversedBeforeThePruneIsDeliveredTearsNothingDown`,
  `aPruneDeliveredWithoutAStoreTearsNothingDown`,
  `aTaskIsRemovedOnlyWhenTheStoredRecordListsNoSessionEither`,
  `aSessionlessTaskIsNotRemovedWhileItsStoredRecordCannotBeRead`; plus the
  positive `aDeliveredPruneTearsDownADirectoryThatIsStillArchived`).
  Test note: a task's last-tab removal needs the layout change of its first
  tab to have reached the manager, so these tests await the first flush
  before closing, as the r1 ones do.
  Gate: check 0, the three suites above 89 tests 0 failures, build-app 0,
  full `make test` exit 2 with 4176 tests and only the 5 baseline failures.
- T8, 2026-10-09, `6d1f8c6a`: branch capture follows the session surface's
  cwd. `enqueueBranchCapture` resolves the surface through T4's index: the
  directory's cached `sidebarItems[id:].branchName` is used only when
  `SurfaceEntry.cwd` (standardized) equals the task directory's path;
  otherwise `gitClient.branchName` is probed at the surface cwd, through the
  same FIFO queue. `worktreeIDForSurface` had no other caller and is gone.
  The resume-warning path needed no change: it already probes the directory
  the session resumes in (the row's cwd, which for an indexed session is
  the session's own), so with B's branch recorded a resume in B is silent
  and a resume in A warns. Decisions (not in the plan):
  - Remote task: cache only. Its paths name nothing on this machine, so a
    surface outside the task directory (or one with no cached branch)
    records nothing rather than the branch of a same-named local path.
    Before, an uncached remote directory was probed locally.
  - Orphan task (directory not in the roster): now probed at its cwd; before
    it recorded nothing because capture required a roster worktree.
  - The live row's branch annotation still compares against the task
    directory (`SessionLiveSnapshot.cwd`), so a live tangent in B shows B's
    branch beside the task's directory name. Left as is: it is a label, not
    a warning, and it is true (the session is not on the task directory's
    branch); a tab in a subdirectory of the task directory probes to the
    same branch and shows nothing.
  Left for later:
  - **Revised (T8 r1)**: the note that stood here deferred the live pwd to
    S/K and was wrong on two points. Capture now reads it (see T8 r1). The
    live pwd sits on the surface bridge (`bridge.state.pwd`), not on
    `TabChrome`; and a layout snapshot does not refresh the reducer's
    layout: persistence overlays the live pwd onto a copy
    (`LayoutPersistence.swift:19-25`), so `SurfaceEntry.cwd` stays the
    launch or restored cwd for the whole run.
  - T8/S notes from T7 still open: a member whose task sits on another
    directory resumes into a newly minted task, and a session that ran on a
    remote host cannot be resumed from its history row.
  Tests (`AppFeatureSessionsTests`): tangent in B inside task A captures
  B's branch with A's branch cached (red before the change, the only one);
  same-directory capture uses the cache with no probe (tab with no recorded
  cwd and tab recorded in the directory); same-directory with no cache
  probes the directory; a remote task's tab elsewhere is never probed;
  resume in B silent, resume in A warns (parameterised).
  Gate: check 0, `supacodeFeatureTests/AppFeatureSessionsTests` 124 tests
  0 failures, build-app 0. No full `make test` (not a full-run slice).

- T8 r1, 2026-10-09, `0e31f535`, `e3a90a9d`: review fixes.
  - P1 (held): capture went by the layout's recorded cwd. A new tab
    records none (`createTabAsync` passes `workingDirectory: nil`) and can
    launch in an inherited directory, and a restored tab can `cd`, so both
    kept recording the task directory's cached branch. Capture now asks
    the running surface through a new `TerminalClient.surfaceWorkingDirectory
    (LayoutID, UUID) -> String?` (live: the host's live surface
    `bridge.state.pwd`; default and test value `nil`), falling back to
    `SurfaceEntry.cwd` when it is nil or empty. One synchronous read per
    busy/idle hook, no layout action. The same-directory check compares
    standardized paths, not URLs, so a reported trailing slash still hits
    the cache.
  - P1 (held): orphan-task capture had no test. Added, see below.
  Left for later:
  - S/K: `sessionSnapshots` still derives `surfaceCwd` (auto-settle
    protection of provisional rows, `SessionsSidebarStructure.swift:236`)
    and the live row's branch annotation from the recorded cwd. Reading the
    live pwd there needs a trigger when it changes, which is the
    per-report traffic AGENTS.md forbids; capture has a natural trigger
    (the hook), those do not.
  - A remote task's live pwd is whatever the surface reports (remote path
    with shell integration over ssh, else nothing); it is only compared
    with the task path for the cache, never probed.
  Tests (`AppFeatureSessionsTests`): tab with no recorded cwd and tab
  recorded in A, both running in B with A's branch cached, probe B (red
  before the fix; also asserts the owning layout is the one asked); tab
  recorded elsewhere but running in the task directory uses the cache (red
  before); orphan task, running and persisted-only, probes its recorded
  directory and stores the branch; remote orphan, running and
  persisted-only, is never probed.
  Gate: check 0, `supacodeFeatureTests/AppFeatureSessionsTests` 128 tests
  0 failures, build-app 0. No full `make test` (not a full-run slice).

- T9, 2026-10-09, `317c945e` + `8374ff71` + `7011b2f7`: replacement,
  quit and settle at the level of a task; the sub-agent follow-up folded in.
  - Replacement: a changed ref on a surface puts the new session in the
    replaced one's slot (`TerminalsFeature` `.sessionReplaced`,
    `TaskMembership.replacing`), marks the replaced one with `settleSession`
    and lifts a settled mark on the new one (it is running). Nothing closes,
    no task is minted. Pi ends the old session before it starts the next, so
    the record is gone by then: `AppFeature.State.endedSessions` remembers,
    per agent and surface, the session that ended there (Pi `new`, `resume`,
    `fork`; any bare end of another harness) until the next ref arrives or
    the surface closes.
  - Stored order: the writer still never moves or drops a stored session and
    never reorders on the caller's list alone. The reducer names each
    replacement for the run (`replacedSessions`, new → replaced), the manager
    passes it with the record, and `TaskMembership.storing` places only an
    unlisted session whose replaced one is stored. Chains written at once
    keep their order. This is T7 r4's "T9 needs its own reorder change".
  - Quit: a tangent's quit settles nothing; the primary's settles nothing
    while any other agent runs in the task (reported or not).
    Decision (not in the plan): `settleTask` on quit, which closes tabs,
    needs a quit that is positively identified: Pi `reason=quit` from a local
    process. A bare end (Claude ends its session on `/clear` too) or a
    pid-less remote end of a lone primary only marks the primary, as before.
    Reason: closing a tab under an agent that is still there kills a session.
  - `settleTask(id)`: marks the current primary (if it has reported) and
    asks every pane to close all its tabs through `contentRequestedClose`,
    so the close-confirmation setting still applies. `isTaskSettled` is the
    current primary's entry. No row reads it yet: rows stay per session
    until S1, each with its own mark.
  - Manual settle. Decision: on a task's primary it is `settleTask`; on any
    other session's row it stays what it was (mark that session, close its
    own tab). Until S1 groups rows, a tangent's row must not take its task's
    other tabs down. Settle-and-advance does the same, also works on a
    shell-only task's row, and advances to the next live row outside the
    settled task (this is T7 r1's "next live task", for the chord only: a
    plain last-tab close still falls back to the directory).
  - Auto-settle. Decision: every member is judged with its task: none
    settles while an agent runs in a task that lists it (by layout, so a
    provisional agent counts) and the idle age is the newest member's
    activity. All members of an idle task settle together, not only the
    primary, so no tangent row is left behind in Active before S1.
    Membership reaches `RepositoriesFeature` as `taskSessions`.
  - Reopen needed no change: a row resumes its own session into the task
    that lists it, so reopening the primary resumes only the primary.
  - Sub-agents (follow-up, 2026-10-08). Cause checked from inside one, not
    from the app's signals (the app was not run): this slice's agent was a
    workflow sub-agent whose pi process had the parent's
    `SUPACODE_SURFACE_ID`, the parent's controlling tty, and a session file
    under `~/.pi/agent/subagent-sessions`, so the Pi extension in it reports
    its own session and end on the parent's surface. With T9 that would have
    read as replace-then-quit and closed the parent's tabs. Fix is on the app
    side and not Pi-specific: an event whose pid is a descendant of a pid the
    surface's record tracks (`ProcessAncestryClient`, a bounded `sysctl`
    parent walk) is ignored by presence and by everything in the hook
    handler. The session ref cannot be used: it is an id, not a path.
  Left for later:
  - S1: `userClosedSurfaces` still marks whatever session was on a closed
    tab, primary or not, and closes nothing else; `settleTask` on a task
    whose primary has not reported marks nothing; trailing members that T7
    appended for earlier `/new` and sub-agent refs stay (nothing identifies
    them after the fact); a session already listed keeps its slot when it is
    resumed over another, so the replaced primary stays first and settled
    while the resumed one runs.
  - A remote (pid-less) sub-agent cannot be told apart and still replaces
    the parent's session; it can no longer close tabs. Sub-agent
    notifications are a separate path and still arrive.
  - A local agent that dies without an end and is replaced by a child of
    the same shell within the 2 s liveness sweep is unaffected (a sibling is
    not a descendant).
  Only the live UI can confirm: Pi quitting closes the task's tabs and the
  row moves to Settled; `/new` keeps the tab and the row; a workflow no
  longer flips the parent row to "New session" or settles it; the wait on
  several panes' close confirmations when one is busy.
  Tests: new `AppFeatureSessionsTaskSettleTests` (A37 table, A19, sub-agent,
  settle-and-advance, reopen), `RepositoriesFeatureAutoSettleTests` (four),
  `LayoutsIncrementalWriterTests` (four), `TerminalsFeatureTests`,
  `WorktreeTerminalManagerAckTests`. Mutation-checked: slot, nested check,
  running-tangent guard and task-level liveness each fail their tests.
  Gate: check 0, full `make test` exit 2 with 4212 tests and only the 5
  baseline failures, build-app 0.
- T9 r1 (review fixes), 2026-10-09, `6f4a37c1` + `15745cd1`. **Revised**:
  this overrides the T9 entry above where they differ.
  - Task settle and close confirmation (P1). `settleTask` no longer asks
    each pane: a layout has one alert, so the requests replaced each other
    and confirming closed one pane. It sends `LayoutFeature`
    `.closeAllTabsRequested`: one confirmation naming every tab of every
    pane (`.confirmCloseAll`), same confirm-close-tab mode, no owning pane
    (`alertPaneID` nil, so the main layout's host presents it and the
    user-close intents of all tabs are kept while it waits). The primary is
    marked after the layout reducer ran, when the tabs closed without a
    confirmation or on `.confirmCloseAll`; cancelling marks and closes
    nothing. A task with no tab open is only marked.
    Decision: a named local quit still marks the ended primary at once and
    then asks; the session is over whatever the answer, as before T9.
  - Replacement of a session already listed (P1, A37). It now moves up
    into the replaced one's slot (`/new` then `/resume` of the old primary
    makes it primary again; a dormant tangent resumed over the primary
    leads). Decision: it only moves up. A session already ahead of the one
    it replaced stays (a primary resumed on a tangent's surface is still
    the primary); moving it down would hand the title to a dormant tangent,
    against D5. This drops the S1 item "a session already listed keeps its
    slot".
  - Stored order. `TaskMembership.storing` moves a stored session only for
    a replacement the caller names, only upwards, and only when both
    sessions are in the caller's list in that order. `replacedSessions` is
    never retired, so that last check is what stops a stale entry undoing a
    later replacement on every write. Hydration (`merged`) applies the same
    rule to a replacement made before the file loaded.
  Left for later:
  - S1: `settleAndCloseSession` on a non-primary session sends one `.tab`
    close per surface showing it; a session on two surfaces under a
    confirming mode would still overwrite its own alert (closes one tab,
    nothing wrongly marked beyond the session itself).
  - A close-all confirmation on a task that is not on screen waits until
    the task is selected (the main host only shows the selected layout),
    as pane confirmations already did.
  Only the live UI can confirm (cj): Pi quit closes the task's tabs and
  the row moves to Settled; `/new` keeps tab and row; `/new` then `/resume`
  of the old session shows it as the row again; a workflow no longer flips
  the parent row; the single "Close N Tabs?" alert for a task with split
  panes, in the main window even when a pane is in its own window, and
  Cancel leaving the row Active.
  Tests: `AppFeatureSessionsTaskSettleTests` (two panes under always/busy:
  confirm, cancel, no confirmation, quit; replacement of a listed
  session), `LayoutFeatureTests` (close-all), `LayoutsIncrementalWriterTests`
  (named move, stale and partial lists, both halves at once),
  `TerminalsFeatureTests` (move up, never down, hydration). The ordering
  tests were seen failing before the fix; the confirmation tests were
  written with it. Existing direct-close settle tests now set the mode to
  never and stub the session killer: under the default (busy) they had
  only ever raised an alert.
  Gate: check 0, full `make test` exit 2 with 4226 tests and only the 5
  baseline failures, build-app 0.
- T9 r2 (review fixes), 2026-10-09, `5842507d` + `55533f2f` + `c8c73da7`.
  **Revised**: this overrides the T9 and T9 r1 entries where they differ.
  - Close-all confirmation on a changed tab set (P1, A19). The answer
    covers only the tabs the confirmation named. `.confirmCloseAll` now
    compares them with the layout's tabs: if a tab is open that was not
    named, nothing closes and the confirmation is shown again for the tabs
    there are now; if tabs only went away, the rest close. The task's
    primary is marked only when, after the layout reducer ran, the task has
    no tab and no alert left (same test for the unconfirmed close-all). The
    user-close intent is marked on the confirmation as well as the request,
    so a late tab closes as a user close.
    Decision: the re-ask always asks, even under the busy-only mode with
    nothing busy; the user was already asked once and the set changed
    under them. Looked at the sibling, a pane's `.confirmClose`: it closes
    only the tabs it named and marks no task, so a tab added meanwhile
    simply stays; left as it was.
  - Replacement first seen on another event (P1, A37). Replacement is now
    detected on every event that puts its ref on the presence record
    (`AgentPresenceFeature.recordsSessionRef`: any event but an end when a
    record exists; a start, or a pid-less busy/awaiting-input/error/
    compacting, when none does), not only on a start or a busy. A remote
    (pid-less) sub-agent's notification carrying its own ref therefore
    replaces the parent's session on that event, as its busy already did;
    still nothing closes.
  - Nested agent of another harness (P2). `isFromNestedAgent` checks the
    event's pid against every record on the surface, so Claude or Codex
    started by the surface's Pi is ignored like a Pi child. A pid already
    tracked by its own harness's record is never treated as nested.
  Only the live UI can confirm (cj), unchanged from r1 plus: opening a tab
  in a task while its "Close N Tabs?" alert waits, then confirming, shows
  the alert again with the new count and leaves the row Active.
  Tests: `AppFeatureSessionsTaskSettleTests` (tab added between request and
  confirmation; idle/awaiting_input/error/notification(B) then busy(B);
  remote activity-seeded replacement; cross-harness child and sibling),
  `LayoutFeatureTests` (re-ask on an added tab, close the rest on a closed
  one). The confirmation and replacement tests and the cross-harness child
  test were seen failing before their fixes.
  Gate: check 0; `supacodeFeatureTests` + `supacodeTests` +
  `supacodeTerminalTests/LayoutFeatureTests` exit 2 with 3406 tests and
  only three of the five baseline failures; build-app 0. No full run.
- T9 r3 (review fixes), 2026-10-09, `6a541e25` + `14c22bfa` + `2248deb9`.
  **Revised**: this overrides the T9, r1 and r2 entries where they differ.
  - Quit beside another process on the same surface (P0). A presence
    record can track several pids of one harness. A named local quit of the
    primary now closes tabs only when the record tracks no other pid.
    Decision (differs from the review's "settle nothing"): the ended
    session is still marked, nothing closes. A pid stays on the record
    after its late end is rejected until the liveness sweep, so a sibling
    pid is "not known dead", not "running"; settling nothing would leave
    such a quit unmarked for good
    (`newProcessIdentityRejectsLateEndThenAcceptsCurrentEnd` covers that
    case and would fail). The mark closes and kills nothing, and a later
    busy from the survivor unsettles or replaces as usual. Other callers of
    `settleTask` are user-initiated (settle, settle-and-advance) and go
    through the close confirmation; `userClosedSurfaces` only marks.
  - Two replacements of one session (P1). `TaskMembership.storing` put
    each replacement directly ahead of the replaced session, reversing two
    that shared it (stored `[A,B]`, run `[B,C,A]` came out `[C,B,A]`). A
    session is now placed ahead of whatever this pass already placed at
    its slot, so the run's order holds; chains, stale entries and partial
    lists behave as before. Hydration (`merged`) uses the same function.
    A wrong order written by an earlier build is not repaired: stored
    sessions still move only for a named replacement.
  - Auto-settle is one decision per task (P1). Decisions: the
    short-session rule reads the sum of the members' message counts (a
    task is as long as all its sessions), and a member the user unsettled
    whose hold still stands on its own activity holds every member (before,
    a sibling's newer activity lifted the hold and the session re-settled
    on the next pass). Members of a task that is not running and not held
    are all classified on the same activity and count, so they settle
    together or not at all.
  Only the live UI can confirm (cj), unchanged from r2: a workflow leaves
  the parent row alone; `/new` and `/resume` change title and row as
  described; the single "Close N Tabs?" alert in the main window with a
  pane detached, Cancel leaving the row Active, and the re-ask after a
  late tab.
  Tests: `AppFeatureSessionsTaskSettleTests` (two pids on the primary's
  surface), `LayoutsIncrementalWriterTests` (shared replaced session, at
  once and written between, repeated flushes; chains and bystanders),
  `TerminalsFeatureTests` (hydration, twice),
  `RepositoriesFeatureAutoSettleTests` (short primary with a substantive
  tangent, either order; summed counts; held primary or tangent). All
  seen failing before their fixes. A failed write is not simulated: it
  leaves the stored list as it was, which is the at-once case.
  Gate: check 0; `supacodeFeatureTests` + `supacodeTests` +
  `supacodeTerminalTests/LayoutFeatureTests` + `LayoutsIncrementalWriterTests`
  exit 2 with 3449 tests and only three of the five baseline failures;
  build-app 0. No full run.
- T9 r4 (review fixes), 2026-10-09, `88f8a85a` + `7c54240b`. **Revised**:
  this overrides the T9 and r1-r3 entries where they differ.
  - Resume over a session's own replacement (P1). Stored `[A]`,
    A→B→C→resume B: `replacedSessions[B]` was overwritten from A to C,
    leaving B→C→B with no link to A, so writer and hydration produced
    `[A,B,C]`. `TaskMembership.recording` now hands the moved session's
    link on to whatever had replaced it (`{C:A, B:C}`).
  - Same class, wider (found by an exhaustive walk of four replacements
    over two stored sessions): the "sits ahead of" map cannot express
    every order a run reaches (a>b, b>a, b>c, a>b gives `[b,a,c]`, the map
    stores `[b,c,a]`), with or without the fix above. Decision: the map is
    used only until the stored sessions are loaded. New
    `TerminalsFeature.State.storedSessionsLoaded`, set by
    `layoutsHydrated`; from then on `members` lists every stored session
    (hydration merges them, nothing removes one), so the writer
    (`RecordChange.record(sessionsLoaded:)`) and any later hydration take
    the reducer's order as it is, stored sessions it lacks appended, never
    dropped. `hydrateLayouts` now also sends an empty file when the store
    is `.absent` (nothing stored is loaded too); `.unreadable` still sends
    nothing and stays on the map. Before the load the map is still an
    approximation: several replacements on one task inside the launch
    window can store an order that differs from the run's, never a lost
    session.
  - Auto-settle with an unread member (P1). A task of several sessions
    settles only when every member has a verified summary in that
    refresh. Decision: a member with no summary at all counts as unread,
    because `PiSessionSource` leaves out a file it cannot parse exactly as
    one that is gone, so absence is not proof of no activity. Cost,
    accepted as the non-destructive side: a task with a member that never
    gets a summary (transcript deleted or never written, or a harness
    with no session source, which today is every harness but pi) is not
    auto-settled; manual settle is unaffected. Lifting that needs the
    source to report failed reads apart from absent files; recorded in
    `task-as-unit-followups.md`. One-session tasks are unchanged.
  Only the live UI can confirm (cj), unchanged from r2/r3: a workflow
  leaves the parent row alone; `/new` and `/resume` change title and row
  as described; the single "Close N Tabs?" alert in the main window with
  a pane detached, Cancel leaving the row Active, and the re-ask after a
  late tab.
  Tests: `TerminalsFeatureTests` (A→B→C→B and a moved session's
  replacements, before the load, hydrated twice; order stands after the
  load), `LayoutsIncrementalWriterTests` (A→B→C→B with each intermediate
  write present or missing, which is what a failed write leaves; loaded
  order written and nothing dropped; exhaustive loaded walk),
  `WorktreeTerminalManagerAckTests` (loaded order reaches the store
  end to end), `RepositoriesFeatureAutoSettleTests` (unverified tangent,
  either membership order, released by a verified refresh; missing
  member, either order; one-session task still settles). The reducer and
  auto-settle tests were seen failing before their fixes; the manager
  test was not run without the fix, the writer test asserts the map alone
  gets that order wrong.
  Gate: check 0; `supacodeFeatureTests` + `supacodeTests` +
  `supacodeTerminalTests/LayoutFeatureTests` + `LayoutsIncrementalWriterTests`
  + `WorktreeTerminalManagerAckTests` exit 2 with 3494 tests and only
  three of the five baseline failures; build-app 0. No full run.
- T9 r5 (review fixes), 2026-10-09, `364ea2f2` + `82b473fa` + `8435f991`.
  **Revised**: this overrides the T9 and r1-r4 entries where they differ.
  In particular r4's "before the load the map is still an approximation"
  no longer holds: there is no map and no approximation.
  - Membership before the stored sessions load (P1, A37, D5). Exact now.
    `replacedSessions`, `TaskMembership.recording` and the map half of
    `storing`/`merged` are gone. `TerminalsFeature.State.storedSessions`
    is `.pending` until hydration; while it is, every membership change
    is queued in order (`pendingMembership`: the agents each
    `membersChanged` was reconciled from, and every `sessionReplaced`,
    also one that moves nothing in the run's list because only the store
    names the replaced session). `layoutsHydrated` applies the queue to
    each stored list through the same `reconciled` and `replacing` the
    run uses (`TaskMembership.replaying`), so a task ends as if its
    stored sessions had been there from the start, whichever agent
    reported first. `membersChanged` carries the agents for that.
    Decisions:
    - Nothing is written from the run's list while pending
      (`RecordChange.record(storedSessions: .pending)` leaves a stored
      list alone and stores a new task with no session), so the list the
      replay starts from is the one the last run left; the load then asks
      for a write of every task whose sessions differ from the record.
      Cost: a quit inside the launch window (before
      `resolveLiveZmxSessions` returns) stores no session that first
      appeared in it; the agent reports it again next launch.
    - A task stored with no session keeps the run's list as it is: it was
      minted this run (launch primary first), so there is nothing stored
      to replay onto.
    - An unreadable store (`hydrateLayouts` `.unreadable`) now sends
      `.storedSessionsUnreadable`: the queue is dropped and writes only
      add after whatever is stored (the T7 rule). In every such case the
      writer either aborts (newer, lossy) or starts from an empty file
      (undecodable), so nothing stored is reordered.
    - Same class, destructive side: a named local quit of the run's first
      member closed the task's tabs; before the load that member may be a
      stored tangent, so while pending the quit only marks its session.
      Other pre-load readers of the primary only mark or are user actions
      on tasks that are not on screen until the load.
  - Auto-settle and open tabs (P1, D6, A19, open question 6). A session
    is not auto-settled while a task that lists it has any tab open
    (`TaskIdleness.openTasks`, from `taskSnapshots`, which also lists a
    stored task not attached yet). A task with no tab settles by mark as
    before. Sessions in no task are unchanged.
  Left for later: nothing new. The r4 follow-up (a member with no summary
  holds its task) stands.
  Only the live UI can confirm (cj), plus r2-r4's list: after a relaunch
  with several agents resuming at once, each task's row keeps the title
  it had; an idle task with a shell tab left stays in Active past the
  idle limit and settles once that tab is closed.
  Tests: `TerminalsFeatureTests` (the review's sequence with either agent
  reporting first, hydrated twice; replacement of a store-only session;
  tangent first with a waiting agent; minted task; unreadable store; what
  the load writes; removed task), `LayoutsIncrementalWriterTests`
  (pending writes leave stored sessions alone, in any number; the
  sequence with a write after every step; exhaustive walk of four
  replacements on two surfaces with the load and a write at any step,
  compared with the same walk loaded first; `replaying`; loaded and
  add-only orders), `WorktreeTerminalManagerAckTests` (sessions reach the
  store only after the load, end to end), `AppFeatureSessionsTaskSettleTests`
  (quit before the load), `RepositoriesFeatureAutoSettleTests` (open tab,
  one or two sessions, then closed; another task's tab). Mutation-checked:
  dropping the replay, the open-tab check and the pending quit guard each
  fail their test. The old map was not re-run against the new sequence
  tests (it is deleted); the writer tests for the map went with it.
  Gate: check 0, full `make test` exit 2 with 4251 tests and only the 5
  baseline failures, build-app 0.
- T9 r6 (review fixes), 2026-10-09, `2675d8ee`. **Revised**: this overrides
  r5 where they differ. In particular r5's accepted cost ("a quit inside
  the launch window stores no session that first appeared in it") is gone.
  - Membership lost by a quit or a last-tab close before the load (P1, D5).
    Confirmed: while `storedSessions` was `.pending` the writer kept the
    stored list, so a task minted in the window was saved with no session
    and, once its last tab closed, deleted. Fix: remove the window rather
    than approximate it. `SupacodeApp.init` sends
    `TerminalsFeature.Action.storedSessions(readPersisted)` right after the
    store is wired, with no suspension in between: `.storedSessionsLoaded`
    (a readable or absent store) or `.storedSessionsUnreadable`. It runs
    the same merge-and-replay the layouts' load ran
    (`State.loadStoredSessions`), creates no layout, and flips to
    `.loaded`. `layoutsHydrated` still follows `resolveLiveZmxSessions` and
    calls the same helper, which by then only adds stored sessions the run
    does not list. So in the app `storedSessions` is never `.pending` once
    `init` returns; every write, the quit's included, merges the run's
    list over the stored one (`.loaded`) or adds after it (`.unreadable`).
    Decisions:
    - Load early over "durably preserve pending operations": one
      synchronous read removes the case, where persisting a queue would
      add a second stored format.
    - The pending queue, `storing(.pending)` and the pending quit guard
      stay: they are what makes the reducer exact when driven without the
      early load (tests, and `layoutsHydrated` alone), and cost nothing.
    - Same class checked: `removeTaskIfEmptied` already decides on the
      run's members and the writer's stored list, so with the run's list
      now written it keeps the emptied task; `saveAllLayoutSnapshots`,
      `flushLayoutSnapshot` all go through `recordChange`, which reads
      `storedSessions`; nothing else writes or deletes on membership.
  - Live-only checks (P3): not run here, for cj. The r1-r5 lists stand.
  Not unit-tested: the one line in `SupacodeApp.init` that sends the
  action (the mapping it sends and everything after it are).
  Tests: `TerminalsFeatureTests` (sessions load ahead of the layouts with
  a queued replacement, the layouts' load then changes no member; the
  disk-state mapping), `WorktreeTerminalManagerAckTests` (quit save
  before the layouts load, for a stored task with a replacement and a
  minted one, then a relaunch with no agent; last tab closed before the
  layouts load, record kept empty with its session, then relaunch).
  Mutation-checked: with `.storedSessionsLoaded` a no-op the reducer test
  fails and the two manager tests never get their write (the run hung
  and was killed).
  Gate: check 0, focused (`TerminalsFeatureTests` +
  `WorktreeTerminalManagerAckTests`) exit 0 with 89 tests, build-app 0,
  full `make test` exit 2 with 4255 tests and only the 5 known failures.
- T10, 2026-10-09, `58540f0f`: a worktree row shows its directory's most
  recent task and selecting it mints nothing. Decisions:
  - Resolver: `TerminalsFeature.State.task(forDirectory:)` answers only with
    a task that holds a tab and sits on that directory: the recorded active
    task when it still is one (O(1), the usual case), else the one selected
    last this run (`selectionOrder`), else the first by key; nil when the
    directory has none. `layoutID(forDirectory:)` is now
    `task(forDirectory:) ?? recorded-or-own-key`, so all seam callers
    (commands, CLI queries, the manager's re-select after a task's last tab
    closes) agree with the row. Closes the T3/T5/T6 "unchecked own-key
    fallback" notes. A layout nothing names yet (no `directories` entry)
    still counts as its directory's when it is the recorded id, as before.
    Chosen over repairing `activeTasks` on every removal and at hydration:
    one function, no new write, and the scan only runs for a directory whose
    recorded task is not showable.
  - Selection (`selectedWorktreeChanged` with no task named): with a task,
    select it and send `ensureInitialTab` for focus only. With none, send
    only `setSelectedLayoutID` (the id a first tab would land in, so Cmd-T
    there shows up; `nil` if that id is another directory's task) plus the
    directory sends; no `ensureInitialTab`, so no shell task is bootstrapped
    (open question 11). `selectedTask` is not set by a directory selection,
    so the missing-directory placeholder rule from T5 r2 is unchanged.
  - A freshly created worktree still gets its first tab and setup script,
    from `worktreeCreated` alone (the selection no longer races it). Not a
    selection, so outside question 11; kept for A14.
  - "New task here": `AppFeature.Action.newTask(inDirectory:)` starts the
    default agent in a minted task on that roster directory, local or
    remote, through `launchSessionTab` (shown once its first tab exists, as
    Cmd-N). Not routed through Cmd-N because its directory follows the
    current task or session row, not the worktree row. Refused for a missing
    or unlisted directory. The button sits in the existing "No terminals
    open" state of `WorktreeLayoutView`, only on the worktree branch of the
    detail view; it has no shortcut, and its tooltip says what it does.
  - Badges: nothing to do; rows already read the per-directory merged
    projection from T3.
  - Tests are in `AppFeatureSessionsTests` (0/1/2 tasks, removed active task,
    empty and cross-directory tasks, the mint and its refusal), not
    `RepositoriesFeatureTests`: that feature has no task table, the
    resolution is `AppFeature`'s. Behaviour-changed tests: the two
    `AppFeatureTerminalSetupScriptTests` that pinned the selection bootstrap
    became one pinning that selection sends no bootstrap and
    `worktreeCreated` does; the focus test now has a task to focus;
    `WorktreeTerminalManagerAckTests/aTaskWithNoSessionIsRemovedWhenItsLastTabCloses`
    now expects the directory to follow its sibling task.
  Left for later:
  - T11: the app-menu terminal commands still resolve through
    `selectedWorktreeID`, so they stay disabled while an orphan task is
    shown (T5 r1 note).
  - Z1 (A32): with no task, the seam still falls back to the own-key id;
    a first plain tab (Cmd-T) on an empty directory lands there.
  - Across a relaunch, a directory whose active task was removed while it
    was not on screen has no stored hint, so it shows its first task by key
    until one is selected.
  Only the live UI can confirm: the empty state and button look right; the
  brief empty state between creating a worktree and its first tab; focus
  after "New Task Here".
  Gate: check 0, focused (`supacodeFeatureTests` + `supacodeTerminalTests` +
  `supacodeTests/TerminalsFeatureTests`) exit 2 with 1626 tests and only 4
  known failures (ack flake, settings-changed, 2 Ghostty), build-app 0,
  full `make test` exit 2 with 4262 tests and only the 5 known failures.
- T10 r1, 2026-10-09, `f5090863`, `b3ad3ebe`, `35dda9cb`: review fixes.
  - Resolver order (`f5090863`): no `activeTasks` entry is no longer read as
    a vote for the own-key task (removing the active task clears the entry
    too). `task(forDirectory:)` is now: valid recorded entry, else the task
    on the directory selected last this run (`selectionOrder`, which holds
    the own-key task when it was the one selected), else the own-key task,
    else the first by key. Still no scan in the usual cases.
  - Directory-only selection (`b3ad3ebe`): the selected-task override holds
    only while that task has a tab on the directory (`taskHoldsTabs`: the
    runtime layout once there is one, else the stored record, so a stored
    task picked before hydration is still shown). An emptied task that
    lists a session keeps its row and `selectedTask`, but selecting its
    directory sends no bootstrap to it. An explicit task-addressed
    selection (`layoutID:` on the delegate, `focusTask`, resume) is
    unchanged.
  - One projection for selection and detail view (`b3ad3ebe`):
    `TerminalsFeature.State.displayLayoutID(forDirectory:)` =
    `task(forDirectory:)`, else the layout a first tab lands in, else nil
    when that layout is another directory's. `AppFeature.State
    .detailLayoutID(forDirectory:)` adds the missing-directory task in
    front. `WorktreeDetailView` mounts `WorktreeLayoutView` only for a
    non-nil answer and otherwise renders `EmptyTerminalPaneView` with New
    Task Here. Choice: with no task, a recorded entry naming an empty task
    of this directory is still what is selected and mounted (its empty
    state, New Task Here, and where Cmd-T lands), rather than the own key:
    it is what the seam already answers, so view and commands agree.
  - Tests (`35dda9cb` and the two above): own-key sibling with the active
    minted task removed; selected session-bearing task with no tab, with
    and without a populated sibling; the detail projection for none, two
    and cross-directory; `newTask(inDirectory:)` on a listed missing
    directory, a remote roster directory while a local task is selected
    (minted id, exact `DirectoryContext`), and with a launch pending.
    Seen red before the fix: the no-tab selection test. The own-key test
    was rewritten after its red run (the first form hit an unimplemented
    test dependency) and the projection tests need the new API, so those
    two are red by construction against the old code, not by a run.
  Left for later:
  - Z1 (A32): the command seam `layoutID(forDirectory:)` is still
    non-optional and, for a directory whose only resolvable id is another
    directory's layout, still answers that id. Nothing is mounted or
    selected for it now, but a seam command (Cmd-T from the menu) would
    target it. No app path stores such a record; removing the own-key
    fallback in Z1 closes it.
  - In that same cross-directory empty state a pending terminal-focus flag
    is not consumed until a layout is mounted.
  Only the live UI can confirm: New Task Here appearance and focus after
  it; the hint wording of the cross-directory empty state.
  Gate: check 0, focused (`supacodeFeatureTests` + `supacodeTerminalTests` +
  `supacodeTests/TerminalsFeatureTests`) exit 2 with 1632 tests and only 4
  known failures (ack flake, settings-changed, 2 Ghostty), build-app 0.
- T10 r2, 2026-10-09, `967697ea`: review fix.
  - Revised (replaces the r1 line "keeps its row and `selectedTask`"): a
    directory-only selection drops `selectedTask` whenever what it resolves
    to (the task, else the landing layout) is not that task. Before, a task
    picked on a missing directory that later lost its last tab but kept a
    session stayed mounted through `taskOnMissingDirectory` while the
    terminal was sent to a sibling. Now the pick ends there and the missing
    directory shows its placeholder, as for any directory-only selection.
    An emptied task with no sibling that is still the recorded landing
    layout keeps its pick (view and terminal both name it). Explicit
    task-addressed selection is unchanged. Chosen over gating
    `taskOnMissingDirectory` on holding a tab: that would hide an explicitly
    activated empty task behind the placeholder.
  - Same class checked, no change needed: a task that empties while shown
    and keeps a session stays the terminal's selected layout (the manager
    re-selects the directory only when it removes the task, and then
    `selectedTaskRemoved` drops the pick); the nil-worktree path already
    drops the pick on a plain deselect.
  - Tests: missing directory with an emptied session-bearing pick, with a
    populated sibling (seen red before the fix) and without; the r1 no-tab
    test now also pins the pick being dropped or kept. The sibling's
    selection echo is applied to the state directly, not sent: the reducer
    action wakes tabs through a test-unimplemented content factory.
  Left for later, unchanged: Z1 owns the non-optional command seam's
  cross-directory fallback; T11 owns app-menu command targeting while an
  orphan task is shown.
  Only the live UI can confirm: New Task Here appearance, focus after the
  launch, and the brief empty state during worktree creation.
  Gate: check 0, focused (`supacodeFeatureTests` + `supacodeTerminalTests` +
  `supacodeTests/TerminalsFeatureTests`) exit 2 with 1634 tests and only 4
  known failures (ack flake, settings-changed, 2 Ghostty), build-app 0.
- T11, 2026-10-09, `21470977` + `374b6b70` + `8d99410e`.
  - Env: `SUPACODE_TASK_ID` is the task's layout id, percent-encoded the same
    way as the worktree id (the own-key task's id is a path).
    `SUPACODE_WORKTREE_ID` is unchanged. The agent hook guard is unchanged, so
    a shell with no task variable still fires its hooks.
  - One resolver, `TerminalsFeature.State.commandLayoutID(forDirectory:task:holding:)`:
    a pane, tab or surface id the command carries finds the task on that
    directory that holds it; else the task the command names, which must sit
    on that directory; else `layoutID(forDirectory:)`. Used by worktree
    deeplinks, the confirm re-dispatch (resolved again there, the task rides
    on the dialog state), the tab/pane/surface list queries, the agent
    prompt/send-keys/resume/read paths (they find a surface across the
    directory's tasks), grid/settings focus and close, and the notification
    deeplink URL.
  - Decisions the plan did not make:
    - An id wins over a named task when both are given (a tab lives in one
      task; this also keeps an id-carrying command working from a shell whose
      task variable has gone stale).
    - An id is looked up only among the tasks of the addressed directory. An
      id that lives on another directory is not adopted: the command fails
      its existing "not found" validation. Chosen as the non-destructive
      side for close commands.
    - A named task that is unknown or on another directory fails the command
      ("Task not found", `ok: false`), it does not fall back to the shown task.
    - The task segment is a path pair behind the worktree id:
      `worktree/<id>/task/<task-id>/<action…>`. Only worktree deeplinks take
      it. Query params carry `taskID`.
    - A command addressed to a task other than the one the directory shows
      selects that task (`selectTask`) instead of the directory; `background`
      still selects nothing. `AppFeature.State.shownTask(forDirectory:)` is the
      one statement of what a directory selection shows.
    - CLI `--task` is on the `tab` and `pane` commands. Its env default
      applies only when the command's worktree is the environment's own
      worktree: the env task belongs to that directory, and the go-forward
      commands default to the focused worktree, which may be another one.
      The deprecated `surface` commands take no `--task`; they always carry
      ids.
    - Tab and surface acks (`tabInWorktree`, `surfaceSplit`, `tabRemoved`,
      `tabRenamed`, `surfaceClosed`) now hold the `LayoutID` fixed at
      dispatch instead of a directory re-resolved at completion. Closes the
      T3 note on ack matchers.
    - The manager's `listTabs`/`listPanes`/`listSurfaces` take a `LayoutID`;
      the app layer resolves. Closes the T3 note on CLI list queries.
    - Shared parser: `WorktreeID(external:)` (percent-decode, non-empty, one
      trailing slash dropped) and `LayoutID(external:)` (as written) over
      `ExternalID`. Roster matching of the slash-keeping spelling stays in
      `AppFeature.State.resolveWorktreeID`.
  - Not done, left for later:
    - Z1: app-menu terminal commands (new tab, close, split, search, rename)
      still resolve through `selectedWorktreeID` and stay disabled while an
      orphan task is shown. T5 r1 and T10 named T11 for this; it is menu
      enablement plus ~35 reducer sites and no CLI/env/deeplink contract, so
      it was not folded into this slice. Nothing regresses: same as before.
    - M2: a merge moves a shell into another task and leaves its
      `SUPACODE_TASK_ID` naming the removed one. Id-carrying commands still
      work (the id wins); `tab new`/`tab list`/`pane equalize` from that
      shell in its own worktree would get "Task not found". M2 has to decide
      (keep the merged id resolvable, or fall back).
    - Unowned: `agent/<worktree>/<kind>/…` still picks one agent of a kind
      across the whole directory, so two tasks each running the same harness
      on one directory are not told apart (see followups).
    - The Grok hook env passthrough does not forward `SUPACODE_TASK_ID`.
  - Tests: `AppFeatureDeeplinkTaskTests` (new: resolution table, two tasks on
    one directory for bare/tab/surface/task-segment/background/refused/close/
    confirm/ack), `DeeplinkClientTests` (task segment, shared parser),
    `TerminalSurfaceRecipeTests` (env for two tasks on one directory),
    `TaskTargetCLITests` (new: the built CLI against a fixture socket),
    `AgentHookCommandTests` (guard unchanged). `AppFeatureCommandAckTests`
    updated for the ack payload.
  Only the live UI can confirm: an already-running shell (no
  `SUPACODE_TASK_ID`) still drives the CLI and hooks; a notification tap or
  `supacode tab focus` on a tab of a task that is not shown brings that task
  up and focuses it; the two reference-sheet rows read right.
  Gate: check 0, focused (`supacodeFeatureTests` + `supacodeTerminalTests` +
  the five touched `supacodeTests` suites) exit 2 with 1759 tests and only 4
  known failures (ack flake, settings-changed, 2 Ghostty), build-app 0, full
  `make test` exit 2 with 4300 tests and only the 5 known failures.
- T11 r1 (review fixes), 2026-10-09, `925579f4` + `cecdd1b7`.
  - P2, held (seen red: 3 tests). With a task selected and the terminal not
    yet having recorded it as the directory's active task, a bare directory
    command resolved to the old task, acted there and selected it back.
    `AppFeature.State.commandLayoutID(forDirectory:task:holding:)` is now the
    app-layer entry: it hands `shownTask(forDirectory:)` to the terminal
    resolver as the directory's own answer (`shown:`), so commands, the
    confirm re-dispatch, socket list queries, `layoutID(forDirectory:holding:)`
    and agent read's focused surface agree with what a directory selection
    shows. Ids and a named task still decide first.
  - Same class, fixed: `run`, `stop`, `run --script` and `stop --script`
    resolved the directory themselves and ignored a named task, so they could
    act in a task other than the one the command's select step showed. They
    use the command's resolved layout now, and the script confirmation
    carries the named task. Decision the plan did not make: a script command
    with a task segment runs/stops in that task (running-state checks stay
    directory-wide, as before).
  - P1, held as a missing test; the routes were correct (the new tests passed
    against the unfixed source). Added two-task surface-close and pane-close
    tests: owner-only close with exact layout/target, stale tab hint, ack on
    the owner's layout, confirm, cancel, target gone during the confirmation
    (terminal-side and state-side), other directory's ids refused.
  - P3: orphan app-menu targeting and the agent CLI follow-up are now written
    into Z1 (agent CLI was unowned); the menu sites still read the recorded
    task during the echo window, also Z1. M2 keeps the merged-shell task env.
    Still only the live UI can confirm: an old shell with no
    `SUPACODE_TASK_ID`, notification/`tab focus` bringing up a hidden task,
    the reference-sheet rows.
  Gate: check 0, focused `supacodeFeatureTests/AppFeatureDeeplinkTaskTests`
  exit 0 with 28 tests, build-app 0, full `make test` exit 2 with 4311 tests
  and only the 5 known failures.
- T11 r2 (review fixes), 2026-10-09, `2047cd07` + `e70c81af` + `60ab217a`.
  - P2, held (seen red). A script stop was validated against the row's
    mirror, which covers the whole directory, then sent to the resolved task:
    with the script in task A and the command meaning task B the terminal
    did nothing and the socket answered `ok: true`. The reducer now asks the
    terminal per task (`TerminalClient.runningScripts(LayoutID)`, the host's
    own tracking, so it cannot lag like the mirror). Decisions the plan did
    not make:
    - `stop --script` naming a task stops it only there; if that task does
      not run it the command fails ("not running in that task") and the task
      that does run it is untouched.
    - A bare `stop --script` stops the script in whichever task of the
      directory runs it, the shown one first. A script runs once per
      directory (the duplicate-run check stays directory-wide, on the
      mirror), so the script id names one run, the same way a tab id names
      its task. No task runs it: "not running", `ok: false`; if the mirror
      still claims it runs, the old no-match stop is sent to force the
      projection re-emit (#573).
  - Same class, fixed: the toolbar/palette `stopScript` and `stopRunScripts`
    and the bare deeplink `stop` went to the shown task only, while the
    toolbar lists what runs anywhere on the directory, so a script started
    in a task the user then left could not be stopped from its sibling. They
    reach the task(s) that run it; with none, the shown task as before. A
    `stop` naming a task still stops only there.
  - P1, held as missing tests; the routes were correct. Added two-task
    reducer tests for bare `run`, `run` naming a task, `run --script` (named
    and bare, confirm, cancel, named task removed while the dialog waits,
    already running on the directory) including the selected-before-echo
    window, and a new `AppFeatureAgentTaskTests` for agent prompt, send-keys
    and resume into a task that is not shown (exact layout, surface and
    bytes; refusal when the surface is not live; resume offer kept on
    refusal). Checked by mutation: with the three agent routes and the
    script start sent back through the directory seam, 10 of these tests
    fail.
  - P3, unchanged, only the live UI can confirm: an old shell with no
    `SUPACODE_TASK_ID`, notification/`tab focus` bringing up a hidden task,
    the reference-sheet rows. Also live-only now: Stop in the toolbar while
    the script runs in a sibling task closes that task's script tab.
  Gate: check 0, focused `AppFeatureDeeplinkTaskTests` +
  `AppFeatureAgentTaskTests` exit 0 with 50 tests (`AppFeatureDeeplinkTests`
  and `AppFeatureRunScriptTests` also green with the fix), build-app 0, full
  `make test` exit 2 with 4333 tests and only the 5 known failures.
- T11 r3 (review fixes), 2026-10-09, `ca0e6a2a`.
  - P1, held (seen red: 4 tests). A `tab new` with input or a script run
    that names no task and carries no id left nothing on the confirmation
    dialog, so confirming resolved the bare directory again and ran in
    whichever task it showed by then. The dialog now holds the layout the
    command resolved to (`target`). On confirm an action with no id of its
    own runs there while that layout is still a task of the directory
    (`AppFeature.State.confirmedLayoutID`), else "Task not found",
    `ok: false`. Actions carrying a tab, pane or surface id are unchanged:
    the id's current owner decides. Decisions the plan did not make:
    - Refuse, do not fall back, when the target is gone (non-destructive:
      nothing is typed into a task the user did not approve).
    - A target with no task record (a directory with no task yet, where the
      first tab lands) stays valid only while the directory still resolves
      to it. If a task appears on the directory meanwhile the command is
      refused.
  - Same class, checked: the bare `run` confirms through the same script
    path (covered by the fix); archive/delete confirmations are
    directory-scoped; agent prompt/send-keys/resume and the stop commands
    raise no confirmation.
  - Tests: bare `tab new` and bare `run --script`, each with the directory
    switched to a sibling and with the original task removed while the
    dialog waits, plus a directory with no task (dispatch, dialog, confirm).
  - P3, unchanged, only the live UI can confirm: an old shell with no
    `SUPACODE_TASK_ID` driving CLI and hooks, notification/`tab focus`
    bringing up a hidden task, the reference-sheet rows, toolbar Stop
    reaching a sibling task's script.
  Gate: check 0, focused (`AppFeatureDeeplinkTaskTests`, `DeeplinkTests`,
  `CommandAckTests`, `AgentTaskTests`, `RunScriptTests`) exit 0 with 286
  tests, build-app 0, full `make test` exit 2 with 4338 tests and only the 5
  known failures.
- S1, 2026-10-09, `ba775d7d`. The Sessions sidebar lists tasks: a row is
  `.task(LayoutID)`, `.implicit(SessionKey)` (an indexed session no task
  lists) or `.provisional` (an unreported agent on a surface no known task
  holds). Decisions the plan did not make:
  - Grouping rule. A session belongs to every task that lists it
    (`taskSessions`) and, while it runs, to the known task that holds its
    surface (a task is known when it lists a session or holds a tab). So an
    agent joins its task's row at once, reported or not, without waiting for
    membership; `.implicit`/`.provisional` rows for a live agent only exist
    when nothing names its layout (the A26 fixture; in the app every agent
    sits on a tab of a task). A session two tasks list is grouped under
    both. The map is `[SessionKey: [LayoutID]]`, built once per pass.
  - Row facts. Title: the primary's; "New session" while a running primary
    is not on disk; else the first indexed member's; else the directory
    name (so S3's switch falls out, same row id). `createdAt`: the oldest
    indexed member's, so `/new` or a tangent does not move the row. Status,
    `allowsAttentionNavigation` and `location`: the most urgent agent's
    (needs you > working > done unseen > idle; then one that can be jumped
    to; then the one the row already led to, so it does not hop); with no
    agent, the T5 first-tab anchor. `primary` is on the row; `sessionKey`
    is the session a row settles by.
  - Settled, shown. A task row is in Settled when its primary is marked
    **and** it has no tab and no agent. This covers T9's "left for S1"
    item (`userClosedSurfaces` marks the primary while other tabs stay
    open): the mark stands, the task stays in Active until its tabs are
    gone, in line with open question 6 (a task with a tab open is not
    settled by anything but the user's task settle).
  - A row needs something to show: a task with no tab, no agent and no
    member on disk has none (its placeholder row lives until the next scan,
    as a session's did). Same for sub-rows and `session list`: a member
    neither running nor indexed is left out. That hides the trailing refs
    T7 stored for sub-agents and `/new` before T9 (T9's third S1 item);
    they stay in the record.
  - Sub-rows: `SessionsSidebarStructure.subRows` + `subRowsTaskID`, for the
    selected row's task only (`sessionSelection`, the sidebar highlight,
    which follows focus), in member order, then unlisted agents by
    surface. Empty for a task of one agent. Recomputed with the structure
    and by `selectSessionRow`, which every selection write now goes
    through (the two `AppFeature` writes included).
  - Activation. Live task row: `focusTask` (its own focus, T5). Dormant
    task row: resume the primary, into the task (D6). Jump-to-attention
    selects the task row and focuses the row's location, i.e. the most
    urgent agent's own surface, so it did not regress to "whatever the
    task had focused"; K2 still owns a needy tangent masked by a more
    urgent member that cannot be jumped to.
  - Settle from a task row names the task (`settleTaskRequested` →
    `settleTask`), not its primary's key: a session can lead two tasks and
    `taskLed(by:)` would pick by where it runs. Key-based settle stays for
    `.implicit` rows, the CLI and the chord's implicit case. A shell-only
    task row still offers no settle (T9's second S1 item, unchanged).
  - No per-session row is read any more for a session's surface or
    directory: `sessionLocation(for:)`/`sessionCwd(for:)` answer from the
    row when the session has one, else from the snapshots/index (resume,
    deeplink, `taskLed`).
  - `supacode session list` still names every session: a task row answers
    for its primary, its other indexed-or-running sessions follow it.
  - `taskSessionsChanged` now reconciles and invalidates the structure.
  - View (S2's file) touched only as far as the new ids need: context menu
    by `sessionKey`, "Settle and Close Tabs" for a task, help text.
  Left for later:
  - S2: render `subRows`; sub-row activation (live → `focusSession`,
    dormant → `resumeSession`, which reuses the task when it sits on the
    session's directory; T7's "member whose task sits elsewhere mints a
    task" stands for T8/S); per-sub-row settle (T9 r1's
    `settleAndCloseSession` double-alert note applies there).
  - K1: the chord already steps one task per press (rows are tasks). K2 as
    above.
  - A task whose only indexed member is a tangent keeps a row titled by
    that tangent once its tabs close, and settles by its (unindexed)
    primary's mark.
  Only the live UI can confirm (cj): a task with two agents is one row
  showing the more urgent status; the highlight stays on the task while
  tabs switch; a `/new` keeps the row in place with the new title; history
  rows are unchanged; Settled shows a closed task once, not per session.
  Tests: new `SessionsSidebarTaskRowsTests` (grouping, A24 table both
  orders, A23 structure half, settled rule, selection folding, write-free
  and order-stable reconcile with tasks, activation, task settle, session
  list); `AppFeatureSessionsTests` task-row block re-pointed at task rows
  (A36: six tasks, shared identity, cycling, slots) plus attention on a
  tangent; `AppFeatureSessionsTaskSettleTests` (settle names its task when
  the primary leads two; reopen from the task row). A26:
  `RepositoriesFeatureSessionsScaleTests` unmodified and green. Tests that
  only named a row id were renamed `.session` → `.implicit`; those that
  asserted one row per agent of a task now assert the task row.
  Gate: check 0; `supacodeTests` + `supacodeFeatureTests` exit 2 with 3426
  tests and only three of the five baseline failures (ack flake,
  settings-changed, bracket chords); build-app 0. No full run (not the
  phase's last slice).
- S1 review r1, 2026-10-09, `2ff4fe92`, `fc3c5e8b`. Three findings, all held.
  - Revised: `supacode session list`. The S1 line "a task row answers for
    its primary" is replaced. A task row only places its sessions (primary
    first, then the rest, then any reported agent on one of its surfaces
    the task does not list yet); every entry is the session's own: title
    and cwd from its index entry, `lifecycle` from its own sidecar mark
    (so a marked primary reads settled while the task row stays in Active
    with tabs open), `live`/`status`/`surfaceID` from the agent running it
    (the one on this task's surface first, else wherever it runs), empty
    with no agent even if the task has a shell or a tangent open. Every
    task's members are walked before deduplicating, so two tasks sharing a
    primary both list their other sessions. A member neither running nor
    indexed is still left out, except the primary a placeholder task row
    is waiting on (named until the next scan, as before). `.implicit` rows
    answer from the row as before: the row is the session.
  - Linear grouping. `members(of:)` checks through a set; the selected
    task's sub-rows use a key set and a member-to-agent map built once.
    Measured in the new fixture before the fix: 0.93s per status flip at
    3,000 sessions, 3.76s at 6,000. `RepositoriesFeatureSessionsScaleTests`
    keeps its three baseline tests unmodified and gains a task-bearing
    index (600 tasks of five, one selected task listing half the index
    with an agent on every other member): member count, write-free
    unchanged pass including the structure, and a 3,000 vs 6,000 linearity
    check.
  Left for later:
  - T9 (auto-settle, not S1): `TaskIdleness.judged` walks all of a task's
    members for each of its sessions, so a closed task with m indexed
    members costs O(m²) per auto-settle pass. It returns early for an open
    or running task and runs on refresh, not on a status flip. Not
    exercised by the scale suite's `settle` budget (no tasks there).
  - T7: `TaskMembership.reconciled` scans a task's member list per agent
    (`list.contains`); bounded by agents × members of one task.
  Tests: `SessionsSidebarTaskRowsTests` session-list block (primary with a
  more urgent tangent, dormant primary with open tabs and a shell-only
  task, session cwd vs task directory, shared primary with two distinct
  tangents, unlisted reported agent, placeholder primary); five of the six
  fail on the old code. Scale tests as above; the linearity one fails on
  the old code.
  Gate: check 0; `supacodeFeatureTests` + the three sessions suites of
  `supacodeTests` (task rows, CLI, observation) exit 2 with 1228 tests and
  only two baseline failures (ack flake, settings-changed); build-app 0.
- S1 review r2, 2026-10-09. One finding (P1), held: a dormant task row
  resumed by its primary's key alone, so with two closed tasks on one
  directory listing the same primary, clicking the higher-key one reopened
  the other.
  - Fixed: `resumeSession(key, task:)` carries the clicked row's `LayoutID`
    (nil for `.implicit` rows and every other caller, which keep key-only
    resolution). It rides on `PendingSessionLaunch.task` through the branch
    probe, the mismatch confirmation and folder registration, and
    `task(listing:onDirectory:preferring:)` checks it again at launch: it
    wins only while it still exists, lists the session and sits on the
    resume directory; otherwise lowest key, then a minted task, as before.
  - Decided (not in the plan): a dormant task whose primary is running in
    another task. One session never gets a second agent, so the click
    shows where it runs (the other task) and launches nothing. Starting a
    second agent on a session already being written was the alternative;
    refused as the only option that can damage a session. The clicked task
    stays closed until its primary is free. Unchanged behaviour, now
    pinned by a test.
  Left for later:
  - S2: a dormant sub-row's resume should pass its task the same way
    (`resumeSession(key, task:)`); today only task rows do.
  - The 10s `recentSessionLaunchDate` guard is per key, so clicking the
    second task sharing a primary within 10s of reopening the first is
    ignored (it would be the "already running elsewhere" case anyway).
  Tests: `AppFeatureSessionsTaskSettleTests` (reopen the higher-key task of
  two closed owners; shared primary live in the other task; fallback when
  the task asked for no longer lists the session); the first and third
  fail without the preference (checked by disabling that line: exit 2,
  those two). `SessionsSidebarTaskRowsTests` activation asserts the task.
  Gate: check 0; `AppFeatureSessionsTaskSettleTests`,
  `AppFeatureSessionsTests`, `RepositoriesFeatureSessionsTests`,
  `SessionsSidebarTaskRowsTests` exit 0 with 250 tests; build-app 0.
- S2, 2026-10-09, `06cc7f20`, `c09262ef`. Sub-rows under the selected task
  (A23 view and activation half; A35 UI). Brief: `plans/briefs/S2.md`.
  - View: the selected task's `subRows` render under its row from the
    cached structure only (no store read in a sub-row), indented, dormant
    ones dimmed with the moon glyph, untagged so the highlight and the
    arrow keys stay on tasks. Tooltips: live names the effective Next/
    Previous Tab chords, dormant "Resume this session in a new tab of this
    task"; a dormant task row now reads "Reopen this task on its primary
    session".
  - `activateSessionSubRow(task:member:)` acts on the current structure and
    writes no state: live → `focusSession`; dormant here but running in
    another task → focused there (one process per session); dormant →
    `resumeSession(key, task:)`. A click for a task no longer selected or a
    member no longer listed does nothing.
  - Revised (S1 r2): a resume that names a task now launches into it
    whatever directory the session ran in, while the task still exists and
    still lists the session (`taskDirectory(_:listing:)`, checked after
    the probe and any alert). r2's "sits on the resume directory" condition
    is gone: when the session's cwd is not the task's directory the input
    is `cd '<cwd>' && <resume command>`, otherwise the bare command. No
    task is minted, no folder registered, no primary seeded, member order
    untouched. This also covers a dormant task row whose primary ran
    elsewhere. A task gone or no longer listing the session falls back to
    the untargeted path unchanged (reuse by directory, else mint).
  - The "already live" checks prefer the named task's own surface.
  - Differences from the brief: the source already had
    `resumeSession(key, task:)` and `PendingSessionLaunch.task` (S1 r2), so
    no `resumeSessionInTask` delegate was added; the target must still list
    the session (r2's rule, the brief only asked that it exist);
    `shellQuote` is `ZmxAttach`'s; the cwd comparison uses paths without
    the trailing slash.
  - Decided (brief §8, D6): no settle or menu on a sub-row (M3 adds the
    menu); sub-rows are not selections (K1/K2 own keyboard reach); a
    tangent resume does not resume or unsettle the primary.
  Left for later:
  - M3: sub-row context menu. K1/K2: keyboard reach of a sub-row.
  - Remote tasks: a sub-row resume is refused by the existing local cwd
    check (unchanged; no test added here).
  - Same-directory resume into a task whose focused tab has `cd`ed away
    starts in the inherited pwd (pre-existing; in the follow-ups file).
  Not done from the brief's test list: the "red first" runs on cj-main were
  skipped to save test runs; no separate tests for clicked-not-lowest-key
  and second-click-while-pending (already pinned by S1 r2's
  `reopeningATaskThatSharesItsPrimary…` and
  `resumeProbeReservationRejectsDuplicates…`), for a stored-only dormant
  task, a remote task, or the cancel variant of the mismatch alert.
  Only the live UI can confirm (cj, A35): sub-rows appear only under the
  selected task and the highlight stays on it; dimming and glyphs; a live
  click focuses that tab, a dormant click opens a tab in the same task and
  a tangent from another directory visibly `cd`s first; arrows skip
  sub-rows and Return acts on the task; no stray highlight from untagged
  rows; tooltips show the overridden chords; a settled task with a resumed
  tangent goes Active and back to Settled when the tab closes.
  Tests: `SessionsSidebarTaskRowsTests` sub-row activation (live, dormant,
  running elsewhere, unreported agent, stale task, stale member, shared
  primary from the task row); `AppFeatureSessionsTests` "Resume into a
  task" (other directory with `cd`, bare command, quoting, member order
  after the agent reports, task removed during the probe, mismatch
  confirmed, live in the named task, orphan task).
  Gate: check 0; `SessionsSidebarTaskRowsTests`, `AppFeatureSessionsTests`,
  `AppFeatureSessionsTaskSettleTests`, `RepositoriesFeatureSessionsTests`,
  `RepositoriesFeatureSessionsScaleTests` exit 0 with 271 tests;
  build-app 0. No full run (not the phase's last slice).
- S2 r1 (review fix), 2026-10-09. Test only; no source change.
  - P1 held: the targeted resume had no test for a task that is only its
    stored record, so `taskDirectory`'s stored directory and membership
    fallbacks ran in no test. Added
    `aTangentOfAStoredOnlyTaskResumesInItAndTheTaskIsShown` in
    `AppFeatureSessionsTests`: a persisted record listing [primary,
    tangent], no runtime layout, directory or member. It pins the stored
    task's own id and directory, the `cd` input, no primary seed, no folder
    registered, the task selected only once its first tab exists, members
    still [primary, tangent] after the agent reports, the primary neither
    launched nor unsettled. It passed against the unchanged source, so the
    finding was a coverage gap, not a defect.
  - Runs twice: with the stored sessions read before the resume (the usual
    launch order, where runtime members already list both) and after it
    (the stored membership fallback proper). Corrects the note above:
    "stored-only dormant task" is no longer untested; a remote task and the
    mismatch-cancel variant still are.
  - Read from the source, not asserted or changed (pre-existing, T-phase
    behaviour): while the
    stored sessions are still pending, the run's own list for that task is
    [tangent] alone until the read replays onto the stored order.
  Gate: check 0; `AppFeatureSessionsTests` exit 0 (154 tests); build-app 0.
- S3, 2026-10-09, `a2640ca7`, `a4a7f661`. Shell-only tasks become agent
  tasks (A27, D4). Brief: `plans/briefs/S3.md`. Tests only; no source
  change: S1's `taskDraft` title order and stable `.task(LayoutID)` id
  already make the switch, and every new test passed on the unchanged
  source. The plan's "the T5 shell-only row is replaced by the task row" no
  longer describes anything: it is one row throughout.
  - Pinned, structure (`SessionsSidebarTaskRowsTests`, "Shell-only to
    agent"): the walk shell-only → unreported agent → reported → listed →
    indexed → agent ended on one row (directory name → "New session" → the
    session's title; primary set as soon as the ref is reported, before the
    membership lists it; no `.implicit`/`.provisional` row, no sub-rows);
    the selection holds and the Active order changes exactly once, when the
    row takes its session's date; an agent that ended before any turn
    leaves the row under the directory name with its primary listed; a
    later agent neither retitles nor replaces the primary; a session
    already marked settled joining leaves the task Active while a tab is
    open and the mark untouched; a closed one resumes its primary into the
    task.
  - Pinned, app (`AppFeatureSessionsTests`): the same switch end to end
    (provisional member not stored, the first session stored once,
    `primarySession`, `taskSessions`, selection and `selectedTaskID`
    unchanged, the sibling task untouched, codec and relaunch).
  - Pinned, destructive paths a shell-born task now reaches
    (`AppFeatureSessionsTaskSettleTests`): its first agent's named Pi quit
    closes every tab of the task, the plain shells included, and no other
    task's; with confirmation on the alert is raised and no tab leaves the
    layout while the session is still marked; an unreported agent's end
    closes and marks nothing; a bare (Claude) end marks only. Kept, not
    byte-for-byte the existing "bare" case: here the member arrives through
    `session_start` on a sessionless task.
  - Pinned, store (`WorktreeTerminalManagerAckTests`): a record on disk
    with no session gains its first and second in order, is kept (empty
    layout, host, no kills, not in `removedLayoutIDs`) when its last tab
    closes, and hydrates in that order; a session listed in the reducer but
    not yet flushed still keeps the task, and the next write carries it.
  - Differences from the brief: S2 had landed (no helper renamed, title
    order unchanged). Test 8b does not assert `recorded.closed` empty:
    `markUserCloseIntent` is called at the close request, before the
    confirmation (pre-existing, `AppFeature` `.closeAllTabsRequested`), so
    the fixture records intent, not closes; the test asserts the alert and
    that both tabs are still in the layout. The brief's "mutation" runs
    (temporary source edits to see each test go red) were not done, to save
    test runs.
  - Decided (brief §8, kept as the agreed decisions give them): no special
    case for a quit in a shell-born task; `createdAt` moves once at
    indexing; a settled mark on a hand-resumed primary is not lifted; a
    primary never indexed stays primary (row falls back to the directory
    title, record kept after the last tab closes); no view change.
  For cj to confirm (not blocking): a Pi quit in a task that began as
  shells, including the migrated per-directory leftover-shell task, closes
  the user's idle shells with it (behind the close-confirmation setting).
  If unwanted, the smallest rule is in `settleReplacedOrEndedSession`:
  close only when the task holds no tab but the quitting agent's, else mark
  only; that narrows T9 for every task.
  Left for later: S2/Z2: a shell-only row has an empty context menu and the
  accessibility label "Live session". The index-absence follow-up (a member
  with no summary) is untouched.
  Only the live UI can confirm (cj): typing an agent command in a
  shell-only task's tab turns the same row from directory name to "New
  session" to the session's title with a status icon, no second row, the
  highlight staying through the row's one re-sort; quitting that agent
  closes every tab of the task behind the confirmation setting; the context
  menu gains "Settle and Close Tabs" once the agent reports; relaunch with
  the agent gone and the shell open keeps the session's title.
  Gate: check 0; narrow suites (task rows, scale, `AppFeatureSessionsTests`,
  task settle, manager ack) exit 2 with 281 tests and one failure of mine
  (8b's assertion, corrected as above); full `make test` on the final tree
  exit 2 with 4407 tests and only the 5 known failures; build-app 0.
- S3 r1, 2026-10-09, `5326bfa4`: review fix, tests only.
  - Held (P1): `theFirstAgentOfAShellBornTaskQuittingClosesItsTabsLikeAnyPrimary`
    asserted `recorded.closed`, which only `markUserCloseIntent` fills, so
    it pinned intent and not the close. It now also asserts the task's
    layout holds no surface. The S3 line above ("closes every tab") was
    unsupported until this commit.
  - Siblings, same gap, same assertion added: `thePrimaryQuittingAloneSettlesTheTask`
    and `settleAndAdvanceOnAShellOnlyTaskClosesItAndMovesOn` (the latter
    also needed `skipReceivedActions` to see the layout's close in state).
  - Mutation run, done this time: with `LayoutFeature`'s
    `.closeAllTabsRequested` case returning `.none`, the S3 test went red
    on the new assertion; `thePrimaryQuittingAloneSettlesTheTask` and the
    shell-only settle-and-advance test stayed green before theirs was
    added. Handler restored; no source change committed.
  Gate: check 0; `AppFeatureSessionsTaskSettleTests` exit 0 (39 tests);
  full `make test` exit 2 with 4407 tests and only the 5 known failures;
  build-app 0.
- K1, 2026-10-09, `ae0b4452`, `0af0bea7`, `a0c04284`, `d43ca726`. Task chord
  correct under key repeat and unable to mint; tab chords target the task
  on screen. App layer only: no new state, action, view or persistence.
  - Task chord: `core`'s arm steps from `sessionCycleOrigin` (the task last
    asked for, `selectedTaskID`, else the focused row).
    `syncSessionSelectionToFocus` does not follow the terminal while an
    asked task has not been echoed. `focusTask` refuses a task that holds
    no tab (`taskHoldsTabs(_:state:)`, live layout else stored record), for
    the chord and for a click.
  - Tab chords (`selectNext/PreviousTerminalTab`, `selectTerminalTabAtIndex`)
    resolve through `AppFeature.State.tabChordLayoutID`: orphan task, task
    on a missing directory, else `shownTask(forDirectory:)`, else the
    directory seam as before.
  - Red first, run: on unmodified source the held-chord, stale-row and
    four tab-chord tests failed on their assertions. The echo-bounce test
    (§2b) was not discriminating until §2a landed; with §2a/§2c/§2d in and
    §2b out it failed on the highlight assertion, then passed with §2b. So
    all four brief changes were proven, none dropped.
  - Difference from the brief: the §2b hold is bounded by
    `taskHoldsTabs(asked)`, not `hasTask(asked)`. A selected task whose
    last tab closed but which still lists a session keeps its record and
    row; the manager then shows the directory's other task, and with
    `hasTask` the highlight would never follow it. `taskStore` gained
    `hostingContent:` (content dependencies) because
    `selectedLayoutChanged` / `detachLayout` re-diff hibernation;
    `Recorded.resumes` counts `resumeSession` delegates through a wrapping
    reducer.
  - Decided (brief §8): tab chord stays "tabs of the focused pane" of the
    selected task, never another task's (narrows the plan's "surfaces of
    the selected task"; cj to confirm or ask for a cross-pane walk); the
    task chord shows the task with its own focus, not a member's surface;
    a stale live row is refused, not skipped, so the chord sits on it
    until the next snapshot drops the row; the task chord still accepts
    auto-repeat, the tab chord still drops it; a sub-row is not a keyboard
    stop.
  Left for later:
  - K2: use `sessionCycleOrigin` in `handleNextSessionNeedsMe` /
    settle-and-advance (still on `focusedSessionRowID`); exact-surface
    targeting; keyboard reach of a sub-row.
  - Z1: the other menu sites still on the directory seam (rename tab,
    split, close, search, new tab).
  - Whoever next edits `ensureInitialTab`: a tab closing between
    `focusTask`'s guard and the manager handling the command can still
    bootstrap a shell tab (needs a non-bootstrapping show command).
  - Not addressed: two `setSelectedLayoutID` effects from consecutive
    presses delivered out of order (pre-existing, unstructured effects).
  Only the live UI can confirm (cj): holding the task chord walks every
  live task once per lap with no stall or highlight bounce and the detail
  pane ends on the highlighted task; the chord returns to the tab and pane
  each task last had focused; the tab chord right after a task switch acts
  on the task now on screen, works on an orphan task and on a task whose
  directory is gone, and its menu items are enabled there (enablement not
  read); with splits it stays in the focused pane; no shell tab ever
  appears from cycling.
  Gate (final tree): check 0; `AppFeatureSessionsTests`,
  `AppFeatureSelectTerminalTabTests`, `RepositoriesFeatureTaskSelectionTests`,
  `SessionsSidebarTaskRowsTests`, `WorktreeTerminalManagerPaneCycleTests`
  exit 0 (220 tests); build-app 0. No full `make test` (K2 closes the
  phase). The first K1 commit was not built on its own.
- K2, 2026-10-09, `e1cb0f89`. Jump-to-attention lands on the agent that needs
  it, on its own surface, in whichever task holds it. Two source files
  (`SessionsSidebarStructure.swift`, `AppFeature+Sessions.swift`); no new
  state, action, view or persistence.
  - `RepositoriesFeature.State.nextAttentionTarget(after:focusedSurfaceID:)`
    replaces `nextNeedingAttention`: walks `liveIDs`, and inside a task
    row its agents (`sessionSnapshots`) in member order; returns
    `AttentionTarget { rowID, location }`. `.implicit` / `.provisional`
    rows still read the row. Computed per press, nothing cached (A26).
  - `handleNextSessionNeedsMe` no-ops when the target's task is gone
    (`hasTask`), else selects the row and sends `focusSession` only.
  - Decided (brief §8, unchanged): list order and circular, not urgency
    order; own task first from a shell tab; `.error` not jumpable; a gone
    task is a no-op, not a skip; no stored "last target".
  - Differences from the brief: (1) the origin row is K1's
    `sessionCycleOrigin` (K1's left-for-K2 item), not
    `focusedSessionRowID`; the focused surface is used as the cursor only
    when that origin is the focused row. A press that outruns the focus
    still repeats its target. (2) Test 12's masked tangent is done-unseen,
    not awaiting input: an awaiting-input tangent already outranks a
    working primary on the row (A24), so the brief's precondition could
    not hold. The awaiting-input-behind-an-error mask is covered at the
    structure level.
  - Red first: not run. The tests name the new function, so they do not
    compile against the old source; no mutation run either.
  Left for later:
  - Settle-and-advance still steps from `focusedSessionRowID` (K1 named
    it for K2). Not changed: with the asked-for task as origin, a held
    chord would settle and close a task not yet on screen. Needs cj's
    call; Z1 or its own slice.
  - Keyboard reach of a sub-row as a selection (K1 named it): the
    attention chord now reaches a needy sub-row's surface; a plain
    "step to sub-row" chord is not in K2's plan text and was not added.
  Only the live UI can confirm (cj): A33, holding the chord with several
  needy agents is instant with no highlight or detail flicker across
  tasks and directories; a tangent that finished behind a working primary
  is reached, its tab frontmost with keyboard focus; the visited agent's
  badge clears so the next press moves on; a hibernated target wakes; a
  target in a pane window behaves sensibly; sub-rows appear for the task
  jumped into.
  Gate (final tree): check 0; `SessionsSidebarTaskRowsTests`,
  `RepositoriesFeatureSessionsScaleTests`, `AppFeatureSessionsTests`
  exit 0 (229 tests; a first run exit 2 on test 12's precondition, fixed
  as above); build-app 0; full `make test` exit 2 with 4439 tests and
  only the 5 known failures.
- M1, 2026-10-09, `8ece6b08`. Pure layout operations: new
  `LayoutTransfer` (`flatten`, `extract`) and `LayoutsTransferTests`
  (23 tests, Terminal bundle). No existing file changed; nothing calls it
  until M2/M3. Built to `plans/briefs/M1.md`; no K1/K2 cross-pane order
  helper exists on `PaneLayout`, so the brief's own order rule is used.
  Decisions (the brief's, taken as written):
  - "Splits inside a tab kept" no longer describes the model: a tab holds
    one content and splits are between panes. A's panes dissolve; every
    tab lands in B's focused pane after B's tabs, in tree leaf (visual)
    order then strip order, not `panes` (creation) order.
  - Flatten leaves B's selection, focus, tree and zoom alone and returns
    `sourceActiveTabID`; an empty B gets one fresh pane showing A's active
    tab; both empty invents no pane (`targetPaneID` nil).
  - Extract always uses a fresh pane id, follows the close-tab rules for
    the remainder (selection to previous else first; an emptied pane is
    removed, focus to `focusTargetAfterClosing`, zoom cleared), and allows
    the last tab (empty remainder).
  - Inconsistent input or a shared tab/content id throws; nothing is
    repaired and no partial result is returned.
  - Test helper `ids` returns "tab/content" strings instead of tuples so
    multisets compare with `sorted()`; same intent.
  - Red first: not run. The tests name the new type, so they do not
    compile against the old source; no mutation run either.
  Left for later:
  - M2: `LayoutFeature.State` bookkeeping for a `collapsedPaneID` and for
    every pane of a flattened source (`windowedPaneIDs`, `alert` /
    `alertPaneID`, `editingTabID`, `equalizeIfEnabled`).
  - M2/M3: whether to refuse a merge or detach while a tab is a locked
    blocking-script runner (it has no zmx session to re-home); M1 moves it
    unchanged.
  - M3: sessions riding with a tab, primary refusal on detach (Q8),
    deleting A's record, whether extracting a task's last tab is allowed
    (Q4), and whether to select `sourceActiveTabID` after a merge. Read
    both layouts and apply the result in one reducer turn; leave both
    tasks untouched on a throw.
  Only the live UI can confirm (cj): nothing in M1. For M3's A35: merged
  tabs appear right of B's focused pane's tabs in A's visual pane order,
  and B keeps showing the tab it was showing.
  Gate (final tree): check 0; `LayoutsTransferTests` exit 0 (23 tests);
  build-app 0. No full `make test` (not a phase end, not destructive).

- M2, 2026-10-09, `4a13aab8` (writer), `8504bb31` (M2a owner lookup),
  `a2c82a53` (M2b transfer + M2c alias). Runtime tab transfer between
  tasks, built to `plans/briefs/M2.md`. Nothing calls the command until M3;
  M2 is proved by tests only. M2 closes no phase but is the highest-risk
  slice, so the full suite was run.
  What landed:
  - A content's owner is looked up (`TerminalsFeature.State.layoutID(
    holdingContent:)`, manager `owningLayoutID(of:)`, builder `owner`), for
    spawn, wake, wiring and the unexpected-close probe. First spawn is
    unchanged (nothing holds the tab yet).
  - `TerminalClient.Command.transferTabs(from:into:_:scope:)` with scopes
    `.all` (merge) and `.tab(_, members:)` (detach), answered by
    `.tabsTransferred` / `.tabsTransferFailed`. `AppFeature` ignores both
    until M3.
  - `TerminalsFeature.Action.transferTabs` moves tabs (via M1's `flatten` /
    `extract`) and members in one turn, both layouts or neither; members
    move here, not in M3 (brief §8.2).
  - `WorktreeContentHost.relinquish` / `adopt` / `bare` carry the
    per-surface bookkeeping; the manager re-wires live surfaces.
  - One flush carries both records; `RecordChange.record(releasing:)` and
    `.mergedInto`; `TaskLayoutsFile.mergedTasks` + state `mergedTasks` keep a
    merged id addressable on its own directory (decides the T11 hand-off).
  Decisions and differences from the brief:
  - Labels are `from:into:`, not `from:to:` (swiftlint identifier length).
  - M1 has `flatten`/`extract`, not the brief's `orderedTabs` / `removing` /
    `appending`; the reducer uses M1 as is. No file added to M1.
  - `.transferTabs` is dispatched from `handleManagementCommand`
    (`handleTabCommand` is at the lint body limit).
  - New refusal `.layoutRejected`: the reducer moved nothing (a tab or
    content id on both sides, an inconsistent layout). Logged and reported,
    not `assertionFailure`: it is a data condition, and the bookkeeping is
    put back. Success is checked on both layouts, so an empty-source merge
    the reducer refused is not reported as moved.
  - `removedByTransfer` holds the removal change, not just the id, so a quit
    before the transfer flush still writes `.mergedInto` (the alias
    survives), not a bare delete.
  - The source's dormant watchers are reconciled before the destination
    adopts, so two watchers never share a session socket.
  - Two merges carried in one flush resolve to the task that stays.
  - `detachLayout` drops aliases that point at the removed task (the writer
    does the same on disk).
  - No `equalizeIfEnabled` for a source pane a detach collapses: it follows
    the close-tab rules, which do not equalize either.
  - Refused, each narrowing D8 (brief §8.5, cj to confirm): different
    machines, a running blocking-script tab, a pending close confirmation,
    not yet hydrated / read-only / unreadable store, quit in progress.
  Tests: `TerminalsFeatureTransferTests` (new, 19), `WorktreeTerminalManager
  TransferTests` (new, 17), plus additions to `WorktreeContentHostTests`
  (8), `LayoutsIncrementalWriterTests` (8), `TerminalSurfaceRecipeTests`
  (2), `AppFeatureDeeplinkTaskTests` (2). Not written from the brief's list:
  `paneWindowOfSourceCloses` at manager level (needs real windows; the
  reducer test `windowedSourcePaneIsForgotten` covers the state half), and
  `mergeEmitsNoSettleInTheApp` is the light form (members and
  `agentPresence` unchanged, no close event; no presence records or sidecar
  seeded).
  Red first: not run before the implementation. One mutation run after it
  (no `relinquish`, no re-wire, no quit-time removal, probe keeps its wired
  id) failed exactly `detachLeavesTheSourceRunning`,
  `liveSurfaceIsRewiredToTheDestination`, `quitRightAfterMergeStoresNoSource`
  and `unexpectedCloseProbeFollowsTheMove`. `mergeKillsNothingAndClosesNothing`
  stayed green under it: a merged source's host is removed unswept, so the
  detach test is the one that guards the close signal. The reducer-level
  timer re-arm was not mutation-tested.
  Left for later:
  - M3: entry points, which members ride on a detached tab, refusing the
    primary (Q8), minting the id, app-level `selectedTask` after a merge
    (the manager's own selection already moves), handling the two events,
    showing a moved tab (the destination keeps its selection).
  - M3 or later: a detached tab's shell still names its source task
    (brief §4.17); origins of a directory whose last task is merged away
    are released as on a last-tab close (brief §8.9).
  - Found, not fixed (brief §8.11): `cancelPendingLayoutSaves` cancels flush
    tasks that do not check cancellation; `.layoutsHydrated` does not skip
    `removedLayoutIDs` (transfers are refused until hydration, so M2 does
    not depend on it).
  Only the live UI can confirm (cj, at the M3 checkpoint; nothing is
  reachable before): a moved live terminal keeps rendering and taking input
  with no flash or lost focus; a moved agent keeps reporting and is not
  settled; a moved hibernated tab wakes with scrollback and a hidden moved
  tab hibernates and wakes again; a windowed source pane closes its window
  without closing the terminal; quit and relaunch after a merge reattaches
  every session in the destination in order; `supacode tab new` from a
  merged shell opens in the destination.
  Gate (final tree): check 0; narrow suites exit 0 (400 tests, 0 failed);
  build-app 0; full `make test` exit 2 with 4518 tests and only the 5 known
  failures.
- M2 r1, 2026-10-09: review fix (P0, held).
  - A quit right after a detach lost the transfer's source update: the
    quit-time save carried only removed sources and hosted tasks. A
    never-opened source stayed stored with the moved tab (two stored tasks
    holding one tab, so hydration drops a whole task), and a hosted source
    was written without `releasing`, so the detached session stayed in its
    stored list. Fix: the manager keeps `unwrittenTransfers` (flush
    generation -> the two tasks and the sessions moved out), cleared when
    that transfer's flush lands; `saveAllLayoutSnapshots` writes every such
    task from the store as it is now, hosted or not, with the pending
    releases. Removed sources stay on `removedByTransfer`.
  - Sibling: a session moved out and back before either write landed (detach
    then merge back) would be released from the task it returned to.
    `recordChange` never releases a session the task lists now.
  - Revised (brief §3 "quit right after"): the quit save is no longer
    "removals + hosted layouts only".
  Tests (`WorktreeTerminalManagerTransferTests`, +3, no suspension between
  transfer and quit save, each re-hydrated into a fresh state):
  `quitRightAfterDetachReleasesTheSessionFromTheStoredSource` and
  `quitRightAfterDetachFromATaskNeverOpenedStoresEachTabOnce` failed before
  the fix; `aSessionThatCameBackIsNotReleasedAtQuit` guards the sibling
  (green before: it only fails with the fix minus the filter, not run).
  Still open (already under "Found, not fixed"): a transfer flush queued
  before `saveAllLayoutSnapshots` still lands after it with the records as
  they were at the transfer. Harmless at quit (nothing changes in between).
  Gate (final tree): check 0; `WorktreeTerminalManagerTransferTests` +
  `WorktreeTerminalManagerAckTests` exit 0 (62 tests); build-app 0; full
  `make test` exit 2 with 4521 tests and only the 5 known failures.
- M2 r2, 2026-10-09: review fix (P0, held).
  - Revised: r1's "Still open ... Harmless at quit (nothing changes in
    between)" was wrong, and the M2 "Found, not fixed" note on
    `cancelPendingLayoutSaves` is now fixed. A transfer's write waiting on an
    earlier flush was cancelled by quit but wrote anyway, after the quit
    save, with the records built at the transfer: a tab opened since was
    dropped from the destination and a source created again was deleted,
    leaving their live sessions to the orphan reaper.
  - Fix: every queued write task (`persistTransfer`, `flushLayoutSnapshot`,
    `deleteLayoutSnapshot`) checks cancellation on the main actor right
    before it enqueues on the writer, so a cancelled one never writes and
    one already enqueued is ordered before the quit save's `flushSync`.
    `persistAndTerminateAllSessions` now cancels before it saves, as
    `applicationWillTerminate` did.
  - Siblings, so that a cancelled write is never a lost one: the quit save
    stands in for all of them. `unwrittenRemovals` (flush generation -> the
    delete, or the last write of an emptied task) is carried by the save
    until that write lands; `cancelledSaves` (tasks whose queued save quit
    cancelled) are written from the store as they are now, hosted or not.
    A task hosted again is written over its pending removal.
  - Assumption taken: a hostless task that still has a removal pending is
    not re-written from the store at quit (the removal stands); the
    alternative risks resurrecting a removed task.
  - Not changed: `handleActiveTaskChanged`'s write is still unguarded (it
    touches only `activeTasks`, and a stale entry falls back to the
    directory's own task).
  - `layoutsWriter` is no longer private, so tests can drain the writer.
  Tests (`WorktreeTerminalManagerTransferTests`, +2):
  `aTransferWaitingOnAnEarlierWriteCannotUndoTheQuitSave` holds an earlier
  save inside the store, merges, opens a tab in the destination and in the
  source created again, quits, drains every task and the writer, then
  hydrates the final blob: every tab is stored exactly once. Run without
  the `persistTransfer` guard it fails.
  `aRemovalCancelledByQuitIsCarriedByTheQuitSave` guards the delete stand-in
  (it only fails with the guard minus `unwrittenRemovals`, not run).
  Gate (final tree): check 0; `WorktreeTerminalManagerTransferTests` exit 0
  (22 tests); build-app 0; full `make test` exit 2 with 4523 tests and only
  the 5 known failures.
- M2 r3, 2026-10-10, `9ca909c5`: review fix (P0, held), by
  redesign rather than a fourth patch. Written by odango, which was cut off
  after its focused test run; gated, committed and recorded by Fable 5.1.
  - Every layout write (debounced snapshot, transfer, delete, active-task
    hint) is built from current state and put on the writer's serial queue
    in the same main-actor turn, through the new
    `LayoutsIncrementalWriter.enqueue(records:)` /
    `enqueue(activeTask:forDirectory:)`. Nothing holding a record waits in
    a `Task` any more, so queue order is state order and an older record can
    never land on a newer one. The quit save's `flushSync` runs behind
    everything already enqueued on the same queue.
  - Removed as no longer needed: `layoutFlushTasks`, `layoutFlushGeneration`,
    `removedByTransfer`, `unwrittenTransfers`, `unwrittenRemovals`, and the
    quit-save stand-ins built from them. `cancelledSaves` stays, now only for
    debounce timers that had not fired (their task is written as it is now).
    `saveLayoutsAndScrollback` cancels the timers itself;
    `persistAndTerminateAllSessions` no longer does it separately.
  - Only the debounce timer waits, and it carries no record. A quit that
    cancels it writes the task from current state.
  Tests (`WorktreeTerminalManagerTransferTests`, 26, +4): the review's exact
  ordering (`aSaveMadeAfterATransferIsNotUndoneByIt`, with and without quit),
  a source recreated while the earlier write is stuck
  (`aSourceCreatedAgainSurvivesTheTransferThatRemovedIt`, with and without
  quit), quit before later debounces fire, and a seeded interleaving walk
  over open, merge, debounce, stuck write, release and quit
  (`noInterleavingOfWritesLosesATab`, 6 seeds); each ends by draining the
  writer and rehydrating, asserting every tab is stored exactly once and no
  task is lost.
  Gate (final tree, Fable 5.1): check 0 (no reformat outside the slice);
  build-app 0; full `make test` exit 2 with 4528 tests, the 5 known
  failures only. The xcresult also lists "Issues recorded without an
  associated test or suite" under `supacodeGitTests`: 27 `@Dependency(\.date)
  has no test implementation` warnings from
  `RepositoriesFeature+Sessions.swift:26`, not a test failure and not from
  this slice; xcodebuild's own failing-tests list names only the 5.

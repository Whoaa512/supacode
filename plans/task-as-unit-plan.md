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
  shown layout and emits no directory-side effects (no watcher reselect, no
  script/settings reload).
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
- Tests: `TerminalsFeatureTests` renames; add an `AppFeature` test that the
  handler does the layout half only when just the layout id changes (using
  the alias, feed same worktree with a different layout id).
- Verify: R block + `supacodeFeatureTests`.
- Assertions: A1, A17 (mechanism).

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
  never mint or resume.
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
    while any member is live; idle age = newest member activity. Reopen
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
| A17 | R7, T5 |
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

Nothing landed. Update this section per slice: id, commit, date, and any
allow-list or deviation.

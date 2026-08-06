# Task Inbox Sidebar — Implementation Plan (v1.0, final)

Scope: `plans/task-inbox-sidebar-scope.md` (locked — do not relitigate).
Inspiration source: `~/code/t3code` (`apps/web/src/components/SidebarV2.tsx`,
`Sidebar.logic.ts`, `packages/client-runtime/src/state/threadSettled.ts`).

Produced by plan loop N=2, M=3 (grug-architect, code-critic, product-owner;
mixed anthropic/claude-fable-5 + devai/gpt-5.6-sol, lenses swapped across
models between iterations). Converged at N=2 (PO: converge; critic: converge
after mechanical edits, applied below; grug: dissented on phase order — see
Dissent log).

---

## Architecture posture (consensus)

- **A Task is a lifecycle overlay, not a parallel surface stack.** `TaskRecord`
  is a top-level collection, NEVER a sidebar bucket item —
  `reconcileSidebarState` / `pruneCuratedBuckets` / `seedLiveWorktrees` assume
  bucket items are worktrees and would prune settled tasks whose worktrees were
  cleaned up.
- **Task records live in a sibling file `~/.supacode/tasks.json`**, not inside
  `sidebar.json`. Rationale (code-verified): `SidebarState.encode()` encodes
  only known keys (`SidebarState.swift:70-75`), so any older build re-saving
  sidebar.json would strip an embedded tasks key — downgrade would silently
  erase all tasks under either an additive field or a schema bump. A sibling
  file means old builds never touch it, per-element lossy decode is trivial,
  no migration machinery is needed, and a bad task write can never corrupt
  cj's sidebar curation. Still the "sidebar.json family" per scope §10.
  (Actual sidebar `schemaVersion` today is 0/1 — the migrator writes 1,
  gate is `>= 1` in `SidebarPersistenceMigrator.swift:40-50`.)
- **Explicit surface ownership from day 1**: `Task.ID → Set<UUID>`; reverse
  lookup derived at reconcile time like the existing `surfaceToItemID` pattern
  (not persisted). Terminal persistence is worktree-keyed
  (`WorktreeTerminalManager.states`, `layouts.json`), so two tasks on one
  directory must never trigger worktree-wide destructive ops from a task
  action. One surface belongs to at most one task.
- **Per-leaf invalidation doctrine**: task rows get their own leaf state
  (per-task projection analogous to `SidebarItemFeature.State`) and a cached
  `TasksSidebarStructure` (IDs/order/sections only) computed in the reducer
  post-reduce hook, riding the existing **`.sidebarStructure`
  `CacheInvalidations` bit** — the `AgentDashboardStructure` precedent.
  Code-verified: agent snapshots already invalidate `.sidebarStructure` today
  (`SidebarStructure.swift:654`) and recomputes are Equatable-diffed before
  publish (`:325-326`), so view fan-out is bounded. Escape hatch: split to a
  dedicated `.tasksStructure` bit only if profiling shows task lifecycle
  mutations rebuilding worktree/agent projections measurably.
- **Pure logic first**: all t3 ports (`effectiveSettled`, snooze/raised-hand,
  `planForwardNavigation`, status model, `canSettle`/`canSnooze`, timestamp
  helpers) are `nonisolated` statics on caseless enums, zero TCA/SwiftUI
  imports, table-tested.
- **Classification computed on coarse clock tick + real events only** — never
  in view bodies, never per-second reducer ticks (working-elapsed timer lives
  in the leaf via `TimelineView`).
- **Capability gating** (scope engineering notes): affordances that can't
  succeed are hidden/disabled via `canSettle`/`canSnooze`, never allowed to
  fail after invocation.
- **Everything additive** for upstream-rebase friendliness; the known
  recurring conflict point is the `cacheInvalidations` exhaustive switch
  (acceptable).

## Load-bearing bets (flagged, accepted for v1)

1. **Task↔surface ownership**: Phase 1 tasks *claim* existing worktree-keyed
   surfaces. Hibernation is worktree/tab-granular today
   (`WorktreeTerminalState.hibernateTab`); surface history bleeds between
   successive tasks on the same directory until surfaces are task-scoped
   (Phase 7). Deliberate; contained blast radius in `WorktreeTerminalManager`
   if it must change. (grug-architect dissents — see Dissent log.)
2. **Seeding evidence is weak** (code-verified): no agent-hook history exists;
   `AgentPresenceFeature.PresenceRecord.lastEventAt` is documented
   never-persisted (AgentPresence Reducer:82-86); `TerminalLayoutSnapshot`
   carries no branch or activity timestamp; scrollback mtimes reflect the 30s
   batch persist cadence (`scrollbackPersistInterval = .seconds(30)`), not
   activity — observed groups of identical mtimes. Seeder carries a small
   evidence value (source + confidence — no framework), never fabricates
   branch/history, and we add real `lastActivityAt` stamps going forward.

---

## Validation contract (written before any code)

Assertions are numbered `A#`; each phase lists which it must turn green. A
phase is done only when its assertions pass and `make build-app` + relevant
test bundles are green (`totalTestCount > 0` verified via xcresulttool per
AGENTS.md — `-only-testing` against the wrong bundle silently passes with 0).

### Tracer / identity
- A1. Fresh launch with existing layouts.json + scrollback seeds one task per
  qualifying **directory** (branch attached only when provable — current
  branch, low confidence; see UNCONFIRMED #3); stale ones land directly in the
  settled tail; seeding is idempotent across relaunches (no duplicates).
- A2. Missing/ambiguous seed branch or activity is user-visible as an unknown
  state (row renders without a branch label / with a low-confidence
  indicator), never a guessed value.
- A3. Each task has a stable opaque ID and owns ≥1 existing surface; one
  surface belongs to at most one task; claiming an owned surface transfers or
  is rejected deterministically; two tasks may point at the same directory
  without sharing surface ownership.
- A4. Tasks tab renders active rows newest-created-first with deterministic ID
  tie-break; agent/terminal activity updates a row but never reorders it.
- A5. Clicking a task focuses its owned surfaces (correct directory/branch).
- A6. Settling an idle task stamps `settledAt`, moves it to the settled tail,
  and hibernates its owned sessions **when it is the directory's sole owner**;
  when the directory is shared, settle defers hibernation (lifecycle moves,
  sessions untouched) until task-scoped hibernation lands in P7. Scrollback is
  preserved in both cases. Unsettle restores the task to active.
- A7. Settling one task never closes, hibernates, or deletes another task's
  surfaces/layout (shared-directory case); settling a task can never hibernate
  a tab containing another task's surface.
- A8. The currently open task is never hidden: if settled it is pulled into
  visibility even when the settled tail is collapsed/paged (t3 route-row
  invariant). (Snooze case added in P4.)
- A9. Existing Worktrees/Agents tabs behave unchanged; unknown persisted
  sidebar-tab value falls back safely (`SidebarView.swift:15` precedent); tab
  routing is exhaustive — the binary Agents↔Worktrees toggle
  (`RepositoriesFeature.swift:~3118`, `SidebarView.swift:~48`) becomes an
  exhaustive switch so Tasks never falls through into worktree navigation.
- A10. Agent/terminal updates invalidate only the affected task leaf, not
  sibling rows or the whole list. Measured, not vibed: debug body-eval counter
  (or Instruments trace) on row views during a synthetic agent-tick storm.
- A10b. Closing an owned surface updates ownership without deleting the task;
  missing surfaces at relaunch are reconciled without deleting the task.

### Persistence
- A11. `tasks.json` writes use the existing atomic-write pattern; every
  ownership/lifecycle mutation survives relaunch; `sidebar.json` is never
  modified by task operations (sections/order/customization byte-identical
  after any task workflow).
- A12. One malformed task record loses at most that task (per-element lossy
  decode), never the whole file; a corrupt `tasks.json` is renamed aside, not
  silently overwritten.
- A13. Running an older build (which ignores `tasks.json`) then upgrading
  loses zero tasks; re-seed after upgrade does not duplicate previously
  seeded/settled tasks.

### Classification (pure logic)
- A14. Every branch of the `effectiveSettled` cascade has a table test;
  precedence (activity blockers > explicit override > PR > inactivity)
  asserted combinatorially; blockers beat explicit settle.
- A15. Explicit override is tri-state (`settled`/`active`/none), effective
  both directions; open PR blocks inactivity auto-settle but never explicit
  settle; merged/closed PR auto-settles now (when setting enabled).
- A16. Snooze > pin > settled precedence; settle clears pin; snooze keeps it.
- A17. Malformed/missing timestamps never cause surprise auto-settle or hidden
  tasks; settled sort key and displayed label use the same resolved timestamp
  (settledAt → latest valid activity → updatedAt); equal timestamps produce
  deterministic order.
- A18. Zero ComposableArchitecture/SwiftUI imports in pure-logic files (grep
  assertion).
- A18b. `canSettle`/`canSnooze` ported and tested; UI affordances are
  hidden/disabled when they return false — a blocked settle is refused at the
  affordance level, never attempted and failed.

### Creation / capture
- A19. ⌘N → optional prompt → fuzzy directory pick → task exists with terminal
  open, in ≤2 interactions, never a worktree decision. Works with the current
  repo-registration UX (improved add/archive UX is P7, not a P3 dependency).
- A20. Directory/branch free → used directly, no worktree created; conflict
  with another *active* task → auto-managed worktree created silently; settle
  cleans up only auto-managed worktrees, only after safe hibernation; never
  deletes a main checkout, pool copy, or manually managed worktree.
  **Gate**: conflict-auto-worktrees ship only after UNCONFIRMED #9 (safe
  marker) is resolved; P3 may ship creation without them.
- A20b. Failed/cancelled creation leaves no task record, no auto-managed
  worktree, and no orphan terminal (rollback).
- A21. Promote-tab-to-task claims the live tab without restarting it or losing
  scrollback; re-promotion does not duplicate.
- A22. Agent-hook children reporting on owned surfaces appear under the task —
  minimum P3 rendering: indented child rows (name + activity dot) beneath the
  task row; drill-in = the task's surface tabs.

### Snooze / wake / forward nav
- A23. Presets computed at menu-open time; Calendar-based, DST-safe; "next
  week" Monday semantics tested; no 32-bit JS timeout clamp ported (dead
  browser constraint) — instead: absolute persisted `Date`s, injected clock,
  coarse settle tick + one cancellable boundary-armed wake effect (+50ms
  overshoot), re-evaluated on launch/app-activation/sleep-wake.
- A24. TestClock: snooze hides; advance past wake → reappears in original
  static position with Woke pill until visited; wake timer re-arms when the
  earliest `snoozedUntil` changes; snoozed open task remains visible (A8
  extension).
- A25. Raised hand is **derived classification, not a one-shot event** — it
  never clears the snooze fields, it only stops the task classifying as
  snoozed (t3 semantics). Per-trigger rules match `threadRaisedHandWhileSnoozed`
  exactly: pending input/approval raises unconditionally; error raises only
  when fresh (newer than `snoozedAt`, via session-updated timestamp);
  completed-turn raises only when completion postdates the snooze. A pre-snooze
  error does not wake. Woke-pill-until-visited carries the "acted on once"
  invariant. (PR-state-change trigger: asserted in P5, where PR data reaches
  tasks — see A29b.)
- A26. Forward navigation: plan snapshotted as a value before mutation;
  background settle/snooze never navigates; failed mutation never navigates;
  user navigation during the async op wins; batch ops skip co-parking rows;
  duplicate dispatches deduped, in-flight state always clears. **No-next-task
  fallback** (t3 navigates home/new-draft; supacode decision): no navigation —
  selection stays on the just-settled row, visible in the settled tail per A8.

### Signals / status
- A27. Each visible task reports exactly one of approval/input/working/failed/
  ready; working shows elapsed time without list-wide invalidation
  (leaf-local `TimelineView`).
- A28. Receded style is applied to rows not needing a human and never applied
  to awaitingInput/error rows (exact fade value is styling, not contract);
  Done pill clears on visit; a fresh seed of N stale tasks shows **zero** Done
  pills (never-visited = read).
- A29. "No PR" / loading / failed / known-state are distinct; PR data reuses
  the existing `WorktreeInfoWatcherManager` refresh pipeline (no second
  poller); late results for a stale branch cannot mutate the task.
- A29b. PR state change raises a snoozed task's hand (moved here from A25 —
  requires P5's PR projection).
- A30. Global auto-settle off-switch kills all auto paths, leaves explicit
  settle working; settings changes recompute immediately and survive restart.

### Keyboard
- A31. Context map doc reviewed by cj BEFORE implementation (explicit gate).
- A32. Modifier-hold shows 1–9 hint pills on exactly the visible rows; ⌘1–9
  opens the matching row; hidden snoozed/paged rows consume no slots; hint and
  target always agree.
- A33. Jump-to-next-needs-me skips working + receded, lands on
  approval/input/failed/unread-done/woke in visible order (pure predicate,
  unit-tested).
- A34. Settle/snooze/pin work on the focused row mouselessly; documented
  terminal↔sidebar-nav escape hatch round-trips focus; typing in
  terminals/text-fields is never intercepted.
- A35. Worktrees/Agents shortcuts regress nothing (existing hotkey tests stay
  green); all new menu actions use the `FocusedAction` wrapper with correct
  tokens (`App/Models/FocusedAction.swift` rules).

### Cutover
- A36. Worktrees/Agents can be hidden/shown independently (never deleted); ≥1
  tab always reachable; default-tab setting honored after restart; registered
  directories remain available to ⌘N with old tabs hidden; repos can be
  added/archived without leaving the Tasks workflow.
- A37. Title search finds active/snoozed/settled tasks without changing
  lifecycle order; clearing restores prior list + selection.

---

## Phases

Sequencing note: P2 is pure logic with zero user-visible change — **P2 ∥ P3 is
permitted** (creation depends only on the conflict rule, not the full
classification port) to avoid a dogfood dead week.

### Phase 1 — Tracer bullet: ugly working Tasks tab
**Assertions: A1–A13** (A6/A8 in their P1-scoped forms)

End-to-end slice cj can dogfood daily for monitoring + settling existing work.

Create:
- `supacode/Features/Repositories/BusinessLogic/TaskRecord.swift` — `TaskID`
  tagged type; `TaskRecord: Codable` { title, directoryPath, branch?,
  repositoryID?, createdAt, settledAt?, settledOverride?, snoozedUntil?,
  snoozedAt?, pinnedAt?, lastVisitedAt?, surfaceIDs, seed evidence
  (source + confidence — small value, no framework) }. Lifecycle fields whose
  semantics are already settled by the scope exist from day 1; nothing
  speculative beyond that.
- `TaskStore` persistence for `~/.supacode/tasks.json` — atomic writes,
  per-element lossy decode, corrupt-file rename-aside, `didSeedTasks` flag.
- `TaskActivitySeeder.swift` — pure: (layouts.json snapshots, scrollback
  mtimes, live sidebarItems) → `[TaskRecord]`; per-directory tasks, branch
  attached only when provable; stale → seeded settled.
- `TasksSidebarStructure.swift` — cached render plan (active list + settled
  tail + open-task pull-in), reducer-computed, Equatable-diffed, riding
  `.sidebarStructure`.
- Per-task leaf state (projection of agent snapshot / unread / dormancy for
  owned surfaces) — the per-leaf invalidation unit.
- `RepositoriesFeature+Tasks.swift` — seed/select/settle/unsettle actions;
  ownership index (reverse lookup derived, not persisted). Keep ALL task arms
  here; `RepositoriesFeature.swift` is already ~6,300 lines.
- Ugly Tasks list view reading ONLY the cached structure + task leaf state —
  never `sidebarItems[id:]` or task dictionaries from a view body.

Modify:
- `SidebarTab.swift` — `case tasks`; convert the binary Agents↔Worktrees
  toggle and tab-routing guards to exhaustive switches (A9).
- `SidebarStructure.swift` — tasks recompute in `applyCacheRecomputes`
  (AgentDashboardStructure pattern).

Settle semantics in P1: explicit only; sole-owner hibernate / shared-directory
defer (A6); unsettle/resume as the recovery path (without recovery, settle is
too dangerous to dogfood). Static ordering (`sortThreadsForSidebarV2` port:
createdAt desc, ID tie-break) lands here.

### Phase 2 — Pure logic port (no UI; may run ∥ P3)
**Assertions: A14–A18b** (+ groundwork for A23–A26 semantics)

All `nonisolated` statics, zero TCA imports, table tests ported from t3 edge
cases:
- `TaskSettlement.swift` — `effectiveSettled` cascade + `canSettle`/`canSnooze`.
  Signal mapping: t3 running → `busy || compacting`; awaitingInput →
  `awaitingInput`. **Drop `hasQueuedTurnStart`** — verified justified: it
  exists solely for t3's dispatch→session-adoption race (2-min grace,
  clock-skew bounds, `serverAdjudicated` forgiveness); supacode's hook socket
  is local with no queue layer, the condition cannot arise. Documented in
  code. Tri-state `SettledOverride`. Unavailable signals (approval,
  queued-turn) are explicit nil/unsupported inputs, never guessed.
- `TaskSnooze.swift` — `raisedHandWhileSnoozed` with t3's exact per-trigger
  rules (see A25), `effectiveSnoozed`, `wokeAt`, `resolveSnoozePresets`
  (Calendar-based, incl. the `|| 7` next-Monday rule), `snoozeWakeLabel`.
- `TaskStatusModel.swift` — 5-state resolve; v1 collapses approval+input into
  `awaitingInput` (4 effective states) unless hook protocol grows a
  discriminator (UNCONFIRMED #1).
- `TaskForwardNavigation.swift` — pure `planForwardNavigation` port
  (wrap-around scan excluding current, skip settled/snoozed/co-parking,
  no-next → nil).
- `TaskTimestamps.swift` — single nil-safe boundary API replicating t3's
  distinct malformed-timestamp policies (missing vs malformed vs valid-epoch),
  `firstValidTimestamp`, settled-timestamp resolver shared by sort key AND
  label (A17).

Test files named to route to the `supacodeTests` bundle; `make
generate-project` before running.

### Phase 3 — Capture: ⌘N prompt-first creation + promote-tab
**Assertions: A19–A22**

Ordering rationale (2-1, dissent logged): until ⌘N exists, every new piece of
work still enters through Worktrees and the Tasks tab only mirrors seeded
history — the dogfood signal tests migration fidelity, not the product bet.
Creation is the first moment cj generates ground-truth tasks, which de-risks
every later phase. P1's settle+unsettle is enough lifecycle to live with.

- Creation flow: optional title → fuzzy directory match over registered repos
  + pool → `TaskRecord` + terminal open. Inspect
  `WorktreeCreationPromptFeature` first; extend if it fits, else new feature
  (UNCONFIRMED #8). Works against current registration UX (A19).
- Conflict rule: another *active* task owns (directory × branch) →
  auto-managed worktree via existing plumbing — **gated on UNCONFIRMED #9
  (safe marker)**; if unresolved, ship creation without conflict-auto-worktrees
  rather than guess. Cleanup on settle only for auto-managed, only after safe
  hibernation. Creation failure rolls back cleanly (A20b).
- Promote-tab-to-task claim gesture; idempotent; ownership transfer/reject
  deterministic (A3).
- Hook-reported child agents (already in `agentSnapshot.agents` per leaf)
  render as indented child rows under the owning task (A22).

### Phase 4 — Lifecycle wiring: snooze, pin, wake timers, forward nav
**Assertions: A16 (wired), A23–A26**

- Snooze/unsnooze/pin/keep-active actions; snoozed shelf (collapsed default,
  soonest-wake-first, countdown). **Snooze-hibernate decision owned here**
  (UNCONFIRMED #13): recommend per-action toggle with a global default.
- Two-clock trick, Swift-native: coarse `clock.timer` (30–60s) for settle
  classification; one cancellable boundary-armed effect for exact wakes
  (+50ms overshoot; re-arm on earliest `snoozedUntil` change; re-evaluate on
  launch/activation/sleep-wake). TestClock-driven tests, no `Task.sleep`.
- Raised-hand wake wiring from agent events and terminal notifications (bell
  mapping UNCONFIRMED #7; defer bell-specific handling until a distinct event
  is verified — generic notification wake already exists). PR trigger lands
  in P5.
- Forward navigation: `ForwardNavigationPlan` value snapshotted pre-mutation,
  carried in the completion action, applied only if the open task is still the
  plan's source; in-flight ID sets cleared on success/failure/cancellation;
  no-next → stay put (A26).

### Phase 5 — Signals & status: PR integration, pills, recession, settings
**Assertions: A27–A30, A29b**

- PR: feed existing per-row `pullRequest` into classification via task leaf
  projection; verify `GithubPullRequest.state` values and whether CLOSED is
  returned by the current GraphQL query BEFORE coding the mapper (UNCONFIRMED
  #4 — query is known to support OPEN/MERGED); explicit
  unknown/loading/failed PR state; no second poller. PR-change raised-hand
  trigger (A29b).
- Status strip + working elapsed timer (leaf-local `TimelineView`; start
  timestamp on `RowSnapshot` — may need small `AgentPresenceFeature`
  addition, UNCONFIRMED #5).
- Recession styling; unread Done pill (`lastVisitedAt`, never-visited = read,
  zero-pill seed check per A28); Woke pill.
- Settings via `@Shared` app-storage keys (doctrine: no new dependency
  client): global auto-settle off, inactivity window, PR-state toggles.

### Phase 6 — Keyboard-context design pass (§7 — fuzziest; design gate first)
**Assertions: A31–A35**

Deliverable 1 is a written context map (no code): shortcut availability matrix
across (sidebar tab × focus context: terminal / sidebar-nav / text field /
sheet / menu). Reviewed by cj before implementation (A31). Then:
- ⌘1–9 against `TasksSidebarStructure` visible order + hint pills (extend
  existing `hotkeySlots`/commandKeyObserver plumbing; do NOT wedge task IDs
  into `HotkeyWorktreeSlot` — new slot type).
- Next/prev cycling; jump-to-next-needs-me (pure predicate over status model).
- Mouseless settle/snooze/pin on focused row; terminal↔sidebar-nav escape
  hatch.
- All menu actions via `FocusedAction` wrapper with correct tokens.

### Phase 7 — Hardening & cutover
**Assertions: A6 (full form), A36–A37**

- Task-scoped terminal lifecycle: hibernate/restore keyed by owned surface
  IDs (terminal API operating on tab/surface IDs, not worktree — the Phase-1
  accepted debt; retires A6's shared-directory deferral).
- Hide/show settings for Worktrees/Agents tabs (never delete); default-tab
  setting; add/archive-repo improvements — "sufficient" = add + archive
  reachable from the ⌘N flow without visiting the Worktrees tab (A36).
- Title-only search; empty/loading/migration-failure states.

Explicitly out (per scope): LLM idle-classifier, overview rework, tmux
introspection beyond hook socket, non-title search.

---

## Test bundle routing (per AGENTS.md globs)

- Pure logic (`TaskSettlementTests`, `TaskSnoozeTests`, `TaskTimestampsTests`,
  `TaskForwardNavigationTests`, `TaskActivitySeederTests`) → `supacodeTests`.
- Reducer tests named `RepositoriesFeature*Tests.swift` →
  `supacodeFeatureTests`.
- Terminal ownership/lifecycle named `WorktreeTerminalManager*Tests.swift` →
  `supacodeTerminalTests`.
- Anything named `Git*`/`Github*` → `supacodeGitTests`.
- New files: `make generate-project` first; verify `totalTestCount > 0`.

---

## UNCONFIRMED (flag, don't guess — consolidated)

1. **Approval vs input**: hook socket exposes only `awaitingInput`; no
   awaiting-approval signal exists. v1 = 4 effective states unless protocol
   grows a discriminator. Needs cj call.
2. **Seeding evidence fidelity**: does Ghostty skip writing unchanged
   scrollback buffers (decides whether mtime is weak or useless)? Is git
   reflog an acceptable evidence source? Gate: seeder claims only provable
   facts.
3. **Historical branch identity for pooled directories**: current code cannot
   reconstruct it. P1 seeds per-directory; branch = current branch, low
   confidence.
4. **`GithubPullRequest.state` values + CLOSED availability** in the current
   GraphQL query (OPEN/MERGED confirmed supported) — verify before Phase 5.
5. **Working-elapsed start timestamp** on `RowSnapshot` — exists? Else small
   AgentPresence addition.
6. **Task selection identity**: reuse `selectedWorktreeID` vs parallel
   `selectedTaskID`. grug recommends reuse; check archived-selection flows.
7. **Terminal bell → raised hand**: which notification event maps
   (`WorktreeTerminalNotification`?) and does it distinguish bell. Defer
   bell-specific handling until verified.
8. **`WorktreeCreationPromptFeature` extendability** for prompt-first
   creation — inspect at P3 start.
9. **Auto-managed worktree safe marker** (proof of cleanup eligibility).
   Gates A20's conflict-auto-worktree half.
10. **Multi-tab claim rules**: promote several tabs into one task vs
    separate; one terminal tab split across tasks → reject (A7).
11. **Creation-conflict definition** when directory matches but branch is
    detached/dirty/changing.
12. **Fuzzy-match candidate set + ranking** for directory pick.
13. **Snooze hibernation**: per-action vs global default vs both — decided in
    P4 (recommend both: per-action toggle, global default).
14. **Concrete keybindings** for next/prev, next-needs-me, triage, escape
    hatch — Phase 6 design doc output.
15. **Seeded title derivation** + collision handling.
16. **Branch changes after task creation** — effect on task identity.

## Dissent log (preserved per loop protocol)

- **Phase order** — grug-architect (both iterations, final ITERATE vote):
  task-scoped surface lifecycle should land immediately after the tracer
  (P2), before seeding and creation, because P1 cannot honestly satisfy full
  A6/A7 while hibernation is worktree-granular, and creation multiplies tasks
  before safe settle/cleanup exists. Outvoted 2-1 (code-critic: no dependency
  inversion exists, A19–A22 need nothing from snooze, restated A6 is honest;
  product-owner: creation is the tipping point for testing the actual bet —
  learning per phase beats engineering coherence). grug's safety assertions
  were absorbed into the contract (A3 uniqueness, A7 split-tab, A10b
  reconciliation, A20b rollback) as the compromise.
- **Invalidation bit** — iteration-1 code-critic (and iteration-2 grug)
  wanted a dedicated `.tasksStructure` bit. Final: ride `.sidebarStructure`
  (iteration-2 code-critic reversed with code evidence: snapshots already
  invalidate it today, Equatable diffing bounds fan-out; AgentDashboard is the
  proven precedent). Dedicated bit kept as a profiling-gated escape hatch.
- **Persistence** — grug wanted an additive `decodeIfPresent` field
  (no bump); product-owner wanted a schema bump + backup on data-loss
  grounds. Both were superseded by the code-verified finding that
  `SidebarState.encode()` strips unknown keys on downgrade re-save, making
  both positions lose tasks. Sibling `tasks.json` adopted unanimously in
  effect: satisfies grug's no-migration-machinery, PO's
  can't-corrupt-curation, and critic's downgrade-safety.
- **32-bit timeout clamp** — scope's engineering notes mention honoring it;
  consensus: it is a dead browser constraint — honor the *intent*
  (boundary-armed timer robust to sleep/relaunch), not the literal clamp.

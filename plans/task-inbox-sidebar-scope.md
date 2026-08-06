# Task Inbox Sidebar — Scope

Status: **scope agreed** (2026-08-05 interview). Implementation planning happens in a
follow-up session. Inspiration: t3code's Sidebar V2 (`~/code/t3code
apps/web/src/components/SidebarV2.tsx` + `Sidebar.logic.ts` +
`packages/client-runtime/src/state/threadSettled.ts`). Explainer doc:
`/tmp/2026-08-05-explain-t3code-sidebar-v2.html` (regenerable).

## The problem

Supacode's sidebar is organized around **worktrees**. cj doesn't think in worktrees —
he thinks in **problems** ("tasks"). Evidence from his live instance: ~20 registered
"worktrees" are almost all `main`-status monorepo directory copies (ergo1–5, twig1–4)
used as a **directory pool**; the actual unit of work is one level below, at
**(directory × branch × agent session)**. A directory hosts a *sequence* of tasks
over time; surfaces drift across directories; stale scrollback orphans pile up.

Worktree friction (all confirmed): creation ceremony, mental mapping, cleanup,
switching cost, forced isolation when the main checkout would do.

## The bet

A new sidebar tab — **Tasks** — implementing t3code's inbox model with a new
first-class `Task` entity. Side-by-side with the existing tabs; the old ones get a
hide setting later (hide, not delete, to keep upstream rebases easy).

## Core decisions

### 1. Task entity (new domain concept)
- A **Task** owns 1+ terminal surfaces and points at a **directory** (a main
  checkout, a directory copy from the pool, or an auto-managed worktree).
- Repo **registration stays** (filtering/tethering is good); the complaint was
  visual weight, not registration itself. Improve the add/archive-repo interface.
- Sub-agent hierarchy (orchestrator driving children) surfaces via the **existing
  agent-hook socket**: agents that report in appear under the task; drill-in is the
  task's surface tabs. tmux panes we can't see stay invisible (fine for v1).

### 2. Creation: prompt-first, anti-ceremony
- ⌘N → type what you're doing (or nothing) → pick/fuzzy-match a directory →
  task exists, terminal opens.
- **Worktrees are an implementation detail**: created automatically only on
  conflict (another active task already owns that directory/branch), cleaned up on
  settle. Never a required decision at creation time.

### 3. Lifecycle × runtime (orthogonal axes)
- **Lifecycle**: `active` / `snoozed` / `settled`, plus `pinned` flag — t3 semantics:
  - snooze > pin > settled precedence; settling clears the pin; snoozing keeps it.
  - Settled tail: slim dimmed rows, sorted by when work *ended*, paged.
  - Snoozed shelf: collapsed by default, sorted soonest-wake-first, wake countdown.
- **Runtime**: `live` / `hibernated` — hibernate kills sessions but keeps the
  scrollback snapshot (existing persistence) and is resumable. Settle always
  hibernates; snooze optionally does.
- Open task can never be hidden (t3 invariant — route row pulls into visibility).

### 4. Classification rules (t3 `effectiveSettled` cascade, verbatim)
1. Activity blockers always win: agent running / awaiting input / awaiting approval.
2. Explicit user override (settled / keep-active) both directions.
3. PR merged/closed → auto-settle now; **open PR blocks inactivity auto-settle**;
   open PR never blocks explicit settle.
4. Inactivity window (`autoSettleAfterDays`-equivalent).
- **All auto-settle rules get settings**: global off-switch + tunables (which PR
  states count, inactivity window, sensitivity).

### 5. Ordering & status (t3 verbatim)
- **Static creation order, newest first. Activity never reorders.** Rows move only
  at lifecycle transitions.
- 5-state status model: `approval` / `input` / `working` / `failed` / `ready`;
  color rationed to act-now / in-motion / broken. Working shows elapsed timer.
- **Recession**: rows not needing a human fade (~70% + lighter weight). Unread
  "Done" pill; "Woke" pill after snooze-wake (never-visited counts as read).
- Signals map to existing plumbing: agent-hook states
  (`running/awaitingInput/idle/error`), per-leaf unread, GitHub PR client.

### 6. Snooze + raised-hand wake
- Presets at menu-open time (1h / evening / tomorrow / next week), derived wakes
  (timer armed at next wake boundary), t3-style.
- Raised hand (early wake): awaiting input, fresh error, agent finished
  (running→idle), PR state change, terminal bell/notification ping.
- **Phase 2**: LLM idle-classifier to split "done" vs "still needs human" on idle —
  cheap model via shell-out to `pi`, swappable/configurable.

### 7. Keyboard (all in)
- ⌘1–9 jump to Nth visible row (hold-modifier hint pills).
- Next/prev row cycling.
- **"Jump to next thing that needs me"** — skips working/receded rows.
- Mouseless triage: settle / snooze / pin the focused row.
- Clean terminal-focus escape hatch into sidebar nav mode.
- General principle: get intelligent about which shortcuts are active per
  context/surface/tab — needs a focused design pass during planning.

### 8. Forward navigation
- Settling/snoozing the open task advances to the next remaining task
  (plan snapshotted before the mutation; never navigate on failure; batch ops
  skip co-parking rows — t3's `planForwardNavigation` semantics).

### 9. Day-one population
- **Seed from activity**: one task per (directory × branch) with a live/recent
  agent session (scrollback mtime + agent-hook history + layouts.json give this).
  Stale ones seed directly into the settled tail.
- Plus a **"promote this tab to a task"** claim gesture.
- No 1:1 worktree→task shim — worktrees are the pool, not the tasks.

### 10. Persistence
- Extend the existing `SidebarState` persistence (`~/.supacode/sidebar.json`
  family) with task records: id, title, directory, branch, lifecycle fields
  (`settledAt`, `settledOverride`, `snoozedUntil`, `snoozedAt`, `pinnedAt`),
  runtime state, owned surface IDs.

## Explicitly deferred / out of scope for v1
- LLM idle-classifier (phase 2, see §6).
- Overview page rework to task-level grid — separate conversation; noted that the
  task-oriented model wants overview at task granularity, maybe "grid layout of
  the new sidebar".
- tmux/sub-agent introspection beyond the hook socket.
- Removing/reworking the old sidebar tabs (hide-setting comes after comparison).
- Search beyond title match (t3 scope).

## Engineering notes from the t3 source worth honoring
- Pure, unit-tested classification logic separated from view orchestration
  (maps to supacode's reducer-computed `sidebarStructure` doctrine).
- Per-leaf invalidation only (existing sidebar performance rule applies).
- Two-clock trick: coarse clock for settle checks, precise boundary-armed timer
  for snooze wakes; 32-bit timeout clamp.
- NaN-safe timestamp helpers; sort key == label key for settled rows.
- Capability/feature gating hides affordances rather than letting them fail.

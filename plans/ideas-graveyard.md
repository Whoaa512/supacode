# Ideas Graveyard

Parked concepts with post-mortems. Branches archived but pushed; resurrect the
*idea*, not the code.

## Command Center (branch: `fable-5-cmd-center`, archived 2026-08)

**Concept**: a mission-control surface for launching and monitoring agent
workflows. `WorkflowDefinition` model persisted in settings, workflow launches
into tabs, an inspector panel with per-project cards and follow-up buttons that
route input back to the linked run tab, and a provider-agnostic workflow seam
(documented in the branch's final commit).

**Why it didn't land**:
- Too heavyweight relative to the command palette — a full inspector plus
  settings-managed workflow definitions where a palette action would do.
- `WorkflowDefinition` was too rigid: pre-defining workflows in settings
  doesn't match how agent work actually gets launched (ad-hoc prompts).
- Largely obsoleted by the Agents sidebar tab + terminal grid overview, which
  now cover the monitoring half of the value.

**If retried**: start from the palette and ad-hoc prompts, not from a
persisted workflow model. The monitoring half already exists; only the
launch/follow-up half might deserve a comeback.

## Factory / Decision Inbox (branches: `fable-5-supacode-factory`, `sol-56-supacode-factory`, archived 2026-08)

**Concept**: operate a fleet of agents at a higher level of abstraction.
Durable append-only agent hook-event log with replay corpus, a deterministic
`AttentionDetector` projecting hook events into "agent needs a decision"
candidates, and a Decision Inbox (sidebar badge + card popover) with
resolution persistence and pasteboard copy. sol-56 was Phase 0/1 foundation
(replay corpus + attention adapter contract).

**Why it didn't land**: the implementation was just not good overall. The
vision is driving, inspecting, and operating agents at a higher level of
abstraction while keeping cognitive debt low and understanding high — the
workflows here didn't deliver that, and the UX never felt right.

**If retried**: hold the bar on the vision statement above. The inbox framing
(badge + popover triage) wasn't it; whatever the next attempt is, it has to
*increase* understanding of what the fleet is doing, not add another surface
to check.

## Task Inbox Sidebar (branch: `task-inbox-sidebar`, archived 2026-10)

**Concept**: a port of t3code's Sidebar V2. A new first-class `Task` entity
owning surfaces and a directory, with settle, snooze, pin, PR-driven
auto-settle, auto-managed worktrees and forward navigation. 303 commits and
about 61k lines; plans in `task-inbox-sidebar-scope.md` and
`task-inbox-sidebar-plan.md`.

**Why it didn't land**:
- Wrong unit. A Task had to be created or promoted; the agent session is the
  real unit of work and already exists.
- Started from scratch. With seeding turned off, none of the existing history
  showed up, so the inbox was empty or stale.
- Too much friction: making a task, cycling rows with the keyboard, mapping
  rows to different kinds of work. It was never better than cycling worktrees.
- Rows weren't meaningful. Titles were branch names like `main`.
- Too much surface: snooze, pin, PR rules, auto-worktrees.
- Never reached the daily build. The branch fell 210 commits behind `cj-main`
  across the terminal rewrite and the rebase stalled.

**If retried**: don't. `sessions-sidebar-scope.md` replaces it: index the
sessions that already exist, land thin slices on `cj-main`, and beat keyboard
worktree cycling before adding anything else. Only the ideas carry over
(static creation order, settled section, status vocabulary), not the code.

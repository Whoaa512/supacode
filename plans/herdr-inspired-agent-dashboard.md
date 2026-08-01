# Plan: Herdr-Inspired Agent Dashboard & Automation

> Source: herdr (`~/code/herdr`) feature analysis + cj interview, 2026-02.
> Goal: bring herdr's agent-first UX into the supacode fork without abandoning
> the worktree-centric sidebar — sidebar gains tabs, agents get a triage
> dashboard, and supacode-cli grows agent-lifecycle automation primitives.

## Interview decisions (locked)

- Sidebar gets tabs: **Worktrees** (today's tree, unchanged) + **Agents** (herdr-style).
- Agents tab = full herdr layout: **Agents panel** (top) + **Spaces panel** (compact repo/worktree list, bottom).
- Agents panel has a **group-by-state toggle**: flat vs sections (Blocked / Working / Done / Idle / Unknown).
- Adopt explicit **done-until-seen** state (done ≠ idle; done clears when the worktree/surface is focused).
- State authority: **hooks only**. Agents without hook integration show `unknown`. No screen-manifest scraping.
- **Agent naming**: display rename in sidebar + addressable by name via supacode-cli.
- **Full CLI lifecycle primitives**: `agent start/prompt/wait/read`, `terminal wait-output`.
- **Native agent session resume** after app restart (`claude --resume <id>`, `pi --session`, `codex resume`), on top of zmx.
- Extras: custom metadata tokens (`$summary`, `$model`), configurable sidebar rows, state-explain inspector, custom state labels.
- Config surface: **VS Code model** — every setting lives in `supacode.json` AND has a Settings UI counterpart. File-based ships first per feature; UI follows.
- Execution: drive implementation phases via workflow orchestration with gpt-5.6-sol through openai-codex/devai subagents; code-critic review per phase.

## Architectural decisions

Durable decisions that apply across all phases:

- **Agent state model**: extend `AgentPresenceFeature.Activity` semantics into a
  sidebar-facing enum `AgentDashboardState { blocked, working, done, idle, unknown }`.
  Mapping: `awaitingInput → blocked`, `busy/compacting → working`,
  `idle + unseen-since-finish → done`, `idle + seen → idle`, `error` renders as
  blocked-severity with error styling. No new detection pipeline — derive from
  existing hook events (`AgentHookEvent`) + focus/seen tracking.
- **Seen-tracking**: "seen" = the surface hosting the agent was focused after
  the agent's last busy→idle transition. Lives in `AgentPresenceFeature`
  state (per `PresenceKey`), not in the view.
- **Sidebar tabs**: a segmented control at the top of the existing sidebar
  container. Tab selection is `@Shared` app storage. The Worktrees tab renders
  today's `SidebarStructure` untouched; the Agents tab renders a new
  `AgentDashboardStructure` computed in the reducer post-reduce hook (same
  cached-structure pattern as `sidebarStructure` — per AGENTS.md sidebar
  performance rules).
- **Agent identity**: agents keyed by existing `PresenceKey`; optional
  user-assigned name (`[a-z][a-z0-9_-]{0,31}`, unique among live agents,
  cleared on agent exit) stored in presence state and exposed over the CLI
  socket.
- **CLI surface**: new `agent` command tree in supacode-cli
  (`supacode agent list|rename|prompt|wait|read|start|explain`) plus
  `supacode terminal wait-output`. All JSON responses, IDs returned by
  creation commands (herdr pattern: capture IDs from responses, never predict).
- **Metadata tokens**: reported over the CLI socket
  (`supacode agent report-metadata --token summary=...`), stored ephemerally
  in presence state, rendered by row-layout config. Semantic state and display
  metadata are separate channels (herdr rule: tokens/labels are visual-only;
  waits and rollups use semantic state).
- **Session resume**: hook payloads already carry session identity per agent
  kind where available; persist the latest session ref per worktree surface in
  the existing persistence layer; on restore-without-live-zmx, offer/perform
  native resume command per agent kind.
- **Settings**: each new setting is a key in `supacode.json` with a
  `SupacodeSettingsFeature` UI counterpart. Row-layout config schema mirrors
  herdr's token arrays: `sidebar.agents.rows = [["state_icon","workspace"],["agent"]]`
  with per-agent overrides.

## Validation contract

Pass/fail assertions defining "done" — these drive QA, written before code:

- **VC1**: Sidebar shows two tabs; switching preserves each tab's scroll/selection; Worktrees tab is pixel-identical in behavior to today.
- **VC2**: Agents tab lists every live hook-reporting agent across all repos with state icon + repo·branch subtitle; clicking a row focuses that agent's surface.
- **VC3**: An agent finishing while unfocused shows `done`; focusing its surface transitions it to `idle`; state survives sidebar tab switches.
- **VC4**: Group-by-state toggle reorders the panel into Blocked/Working/Done/Idle/Unknown sections; empty sections hidden; toggle state persists across launches.
- **VC5**: Spaces panel lists repos/worktrees with rolled-up worst-state icon (blocked > working > done > idle).
- **VC6**: `supacode agent rename <target> reviewer` renames; name appears in sidebar; `supacode agent wait reviewer --until idle` targets by name; name clears when agent exits.
- **VC7**: `supacode agent prompt reviewer "..." --wait` submits and blocks until settled state; `supacode agent read reviewer --lines 80` returns terminal text; `supacode terminal wait-output <id> --regex "passed|failed"` matches.
- **VC8**: After app quit + zmx session death, a worktree whose agent reported a session ref restores by relaunching the agent with its native resume command.
- **VC9**: `report-metadata --token summary=x` renders in an Agents row configured with `$summary`; token never affects state rollups or waits.
- **VC10**: Row layout in `supacode.json` changes Agents-tab rendering without rebuild; invalid config falls back to defaults with a logged warning; Settings UI edits write the same keys.
- **VC11**: `supacode agent explain <target>` reports current state, authoring hook source, last transition timestamps, and seen/unseen status.
- **VC12**: All phases: `make build-app` green, new reducer logic has tests, no `Task.sleep` in tests.

---

## Phase 1: Sidebar tabs + flat Agents panel

**Covers**: VC1, VC2, VC12

### What to build

Tabbed sidebar container. Worktrees tab = existing view unchanged. Agents tab
v1 = flat list of live agents derived from `AgentPresenceFeature`, mapped to
the 5-state model (done-until-seen deferred to Phase 2 — for now
`idle` covers both). Row: state icon, agent kind, repo·branch subtitle.
Click focuses the hosting surface. Cached `AgentDashboardStructure` computed
post-reduce, per-leaf invalidation rules respected.

### Acceptance criteria

- [ ] VC1: tab switching, persistence, Worktrees untouched
- [ ] VC2: cross-repo agent list, click-to-jump
- [ ] Reducer tests for dashboard structure computation
- [ ] `make build-app` green

---

## Phase 2: Done-until-seen + group-by-state + Spaces panel

**Covers**: VC3, VC4, VC5, VC12

### What to build

Seen-tracking in `AgentPresenceFeature` (busy→idle transition while unfocused
⇒ `done`; focus clears). Group-by-state toggle on the Agents panel
(flat ↔ sectioned), persisted via `@Shared`. Compact Spaces panel under the
Agents panel with worst-state rollup per repo/worktree.

### Acceptance criteria

- [ ] VC3: done vs idle lifecycle with tests (TestClock, no Task.sleep)
- [ ] VC4: toggle + persistence
- [ ] VC5: rollup ordering blocked > working > done > idle
- [ ] `make build-app` green

---

## Phase 3: Agent naming + CLI wait/read

**Covers**: VC6, partial VC7, VC12

### What to build

Name registry in presence state (validation, uniqueness, exit-clears).
Sidebar context-menu rename. supacode-cli: `agent list`, `agent rename`,
`agent wait --until <state>` (repeatable).
CLI targets accept unique live name or worktree ID / branch.

`agent read` is deferred to Phase 4, where the terminal-text plumbing it needs
(`terminal wait-output`) is already in scope.

### Acceptance criteria

- [x] VC6 end-to-end via CLI against a running app
- [x] `agent wait` returns immediately when state already matches; honors `--timeout`
- [ ] `agent read` returns stripped-ANSI text by default (moved to Phase 4)
- [x] `make build-app` green

---

## Phase 4: Full CLI lifecycle + metadata tokens

**Covers**: VC7, VC9, VC12

### What to build

`agent start` (launch supported agent kind in an existing worktree surface,
return after ready), `agent prompt [--wait]` (bracketed-paste aware, stall
detection), `agent send-keys`, `agent read --lines N` (deferred from Phase 3),
`terminal wait-output --regex`. Metadata
channel: `agent report-metadata --token k=v [--ttl-ms]`, stored ephemerally,
never authoritative for state.

### Acceptance criteria

- [ ] VC7 full recipes work (herdr-style: split → start reviewer → prompt --wait → read)
- [ ] VC9: tokens render, semantic state unaffected
- [ ] Prompt-stall returns a distinct error rather than hanging
- [ ] `make build-app` green

---

## Phase 5: Session resume + explain + configurable rows (file + Settings UI)

**Covers**: VC8, VC10, VC11, VC12

### What to build

Persist native session refs per agent kind from hook events; on restore
without live zmx session, relaunch with the agent's native resume command
(opt-out setting). `agent explain` inspector (CLI + optional popover).
Row-layout config in `supacode.json` (token arrays, per-agent overrides,
custom `$tokens`, state-label overrides) with Settings UI editor writing the
same keys — VS Code duality.

### Acceptance criteria

- [ ] VC8: resume after zmx death for at least pi + claude + codex
- [ ] VC10: file ↔ UI parity, invalid-config fallback
- [ ] VC11: explain output complete
- [ ] `make build-app` green

---

## Execution model

Each phase runs as a workflow: implementation agents on gpt-5.6-sol via
openai-codex/devai, structured handoffs, code-critic review, then QA against
this file's validation contract. Phases are sequential; a phase merges only
when its VC assertions pass.

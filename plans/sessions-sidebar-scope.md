# Sessions Sidebar — Scope

Status: **scope agreed** (2026-10-02 interview, two rounds). Implementation
planning is a follow-up. Supersedes `task-inbox-sidebar-scope.md` (see
`ideas-graveyard.md` for that post-mortem).

## The problem

When the sprawl gets wide, cj can't find what he was working on or which tab
or pane it lives in. The sidebar is organized by worktree; he thinks in units
of agent work. Goal: trigger, manage and see more parallel work without more
cognitive load.

## The bet

**The harness session is the unit.** It already exists on disk, with no
ceremony:

- `~/.pi/agent/sessions/<cwd>/<created-ts>_<id>.jsonl`; header line carries
  `id`, `timestamp` (creation) and `cwd`.
- Title: latest `session_info.name` entry (resume-plus auto-titling). 211 of
  227 sessions in the last 30 days had one.
- Live link: the pi extension already reports the session id per surface
  (`sid` on the presence signal); it is persisted as `sessionRef` in layout
  snapshots.
- Resume: `AgentResumeCommand` already builds the command for pi, claude and
  codex.

So the feature is a read-only index over session files, a small sidecar for
settled state, and click-to-focus or click-to-resume. Nothing is created or
promoted by hand, and history is there on first launch.

## Bar to clear

The Task Inbox was never better than cycling worktrees with the keyboard. This
must be, from the first slice that lands:

1. Keyboard cycling at least as fast as today's next/previous worktree.
2. New session in one chord.
3. All existing sessions visible on day one.
4. Lands on `cj-main` in thin slices, each used daily before the next starts.

## Decisions

### 1. Row = one harness session
- Flat rows in V1. Leave room for manual grouping later ("these three sessions
  are one problem"); do not build it now.
- Agent sessions only. Plain shells stay as tabs and splits.
- Subagent sessions (`~/.pi/agent/subagent-sessions`) and temp-dir sessions
  (`/private/tmp`, `/var/folders`) are excluded.

### 2. Placement and scope
- New `SidebarTab.sessions`, global across all directories, becomes the
  default tab. Worktrees and Agents tabs stay for now.
- Each row: status, title, directory chip. Untitled sessions fall back to the
  first user message.

### 3. Order
- Creation time, newest at top. Activity never reorders.
- Two sections: **Active**, then **Settled** below. Rows move only when
  settled or unsettled.

### 4. Row states
- Lifecycle: `active` or `settled`.
- Runtime: `live` (has a surface) or `dormant` (file only). Dormant active rows
  render dimmed.
- Status for live rows, from the existing hook states: needs you / working /
  done-unseen / idle. No work-type tags.

### 5. Settling
- Manual settle and unsettle: chord, context menu, CLI.
- Closing the session's tab settles it. App quit, hibernation and crashes do
  not; those leave the row active and dormant.
- Auto-settle after 3 idle days (setting). A live session never auto-settles.
  A manual unsettle holds until new activity.
- Sessions under 4 messages with no live surface go straight to Settled.
  Low impact (8 of 199 in 30 days); cut if it complicates anything.
- Settled state lives in a sidecar keyed by `(harness, sessionId)`, e.g.
  `~/.supacode/sessions.json`. Harness files are never written.

### 6. Click and resume
- Live row: focus its surface.
- Dormant row: open a new tab in the session's cwd running the harness resume
  command. Resuming a settled row unsettles it.

### 7. Keyboard
- Existing next/previous-worktree chords walk **live rows only**, jump on
  move. Cycling never spawns a process.
- ⌘1–9 jumps to the Nth live row.
- Jump to the next session that needs me.
- Settle the current session and advance to the next live row.
- Dormant rows are reached with arrow keys in the sidebar; Enter resumes.

### 8. New session
- One chord: new tab in the current session's cwd with `pi` already running.
  No prompts.
- Variant chord: fuzzy directory picker first, then the same.

### 9. Harness-agnostic seam
- One small `SessionSource` protocol: list sessions (id, createdAt, cwd,
  title, lastActivity) and build a resume command.
- V1 ships the pi adapter only. Claude and codex adapters come after V1 is in
  daily use (2 and 10 sessions in the last 30 days, against 227 for pi).

## Out of scope for V1
- Search over titles or contents.
- Grouping sessions, pinning, snoozing, PR-driven auto-settle.
- Auto-created worktrees.
- Transcript preview for dormant rows.
- Retiring the Worktrees or Agents tabs.

## Slices (each lands on cj-main and gets used before the next)

1. **See**: Sessions tab listing every pi session, newest first, with live
   rows marked. Click focuses or resumes.
2. **Move**: next/previous over live rows, ⌘1–9, new-session chord and its
   directory-picker variant.
3. **Settle**: sidecar, manual settle/unsettle, close-tab settles, Settled
   section, settle-and-advance chord.
4. **Triage**: status on rows, next-needs-me chord, 3-day auto-settle.

## Validation contract

- **VC1**: First launch after install lists every existing pi session outside
  temp dirs, newest first, with its title and directory. No user action needed.
- **VC2**: A session receiving messages does not change position.
- **VC3**: Clicking a live row focuses the surface that hosts it.
- **VC4**: Clicking a dormant row opens a tab in its cwd and the agent resumes
  that session id.
- **VC5**: Next/previous chords visit only live rows, in list order, and start
  no processes.
- **VC6**: The new-session chord yields a running `pi` in the current
  session's cwd with no prompt; the variant asks for a directory first.
- **VC7**: Settle moves a row to Settled; unsettle returns it to its
  creation-order position in Active. Both survive relaunch.
- **VC8**: Closing a session's tab settles it. Quitting the app or hibernating
  does not.
- **VC9**: A session idle for 3 days with no surface is settled; a live one
  never is.
- **VC10**: Settle-and-advance lands on the next live row; next-needs-me lands
  only on rows awaiting input or done-unseen.
- **VC11**: A status change on one row invalidates only that row (existing
  sidebar per-leaf rule).
- **VC12**: `make build-app` green; new reducer logic has tests; no
  `Task.sleep` in tests.

## Open items for planning

- **Unregistered cwd**: surfaces are worktree-keyed. Resuming a session whose
  cwd is not a registered repo needs an answer. `RepositoryKind.folder`
  exists; check whether auto-registering a folder repo is acceptable.
- **Session swap inside one pi** (`/new`, `/resume`, `/fork`): the surface
  moves to a new session id. Proposed: the old session is treated like a
  closed tab and settles. Confirm with cj.
- **Fresh `pi` with no prompt yet**: the session id rides the first `busy`
  signal, so there is no id until the first turn. Proposed: show a provisional
  "New session" row for the surface.
- **Tab close vs teardown**: confirm the terminal layer can tell a user close
  from hibernation or app quit.
- **Directory pool drift**: a dormant session's cwd (ergo1–5) may be on a
  different branch at resume time. Session files do not record the branch.
  V1 ignores this.
- **Index cost**: about 2,900 session files today. Read header and last
  `session_info` only; cache by mtime and size (resume-plus does the same).
- **Pi-side settle**: a `/settle` command that calls the supacode CLI.
  Cheap follow-up, not V1.

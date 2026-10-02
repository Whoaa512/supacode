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
- A session settles when the user ends it:
  - an explicit tab or pane close (the confirm-close path, CLI and deeplink
    destroys);
  - the harness reports the session ended: quit, or replaced by `/new`,
    `/resume` or `/fork`. Pi's `session_shutdown` carries this `reason`.
- A session does not settle when the app or system ends it: hibernation, app
  quit, Terminate Sessions, system restart, a zmx session dying, a failed zmx
  probe. Those leave the row active and dormant.
- `.closeTab` alone is not a user signal. `handleUnexpectedZmxClose` sends it
  for three non-user cases, so settle hangs off the explicit-close marker
  (`consumeExplicitClose`), one layer above the reducer.
- Pi reports `reason: "quit"` on SIGHUP and SIGTERM too. Supacode ignores a
  harness end that arrives while it is itself tearing that surface down or
  quitting.
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

### 10. Branch tracking (directory pool drift)
- Supacode records, per session in the sidecar, the ordered set of branches
  the session's worktree was on at each turn start and end. Supacode already
  tracks each worktree's branch; no harness involvement, so it works for any
  harness. A Graphite stack shows up as several branches on one session.
- At resume: if the cwd's current branch is in the session's set, resume
  silently. If not, one confirm naming both branches. Never auto-checkout.
- The row shows the session's last branch when it differs from the cwd's.
- Sessions from before this feature have no branch data and never warn.

### 11. Session identity on a surface
- A surface with a running agent and no reported session id yet shows a
  provisional "New session" row. It becomes the real row when the id arrives.
- The pi extension reports the id on pi's `session_start` as well as on each
  turn, so restored and freshly resumed sessions link without waiting.
- A cwd that is not a registered repo is auto-registered as a folder-kind
  repository on resume.

## Out of scope for V1
- Resuming a session in a different pool directory that has its branch
  checked out.
- Search over titles or contents.
- Grouping sessions, pinning, snoozing, PR-driven auto-settle.
- Auto-created worktrees.
- Transcript preview for dormant rows.
- Retiring the Worktrees or Agents tabs.

## Slices (each lands on cj-main and gets used before the next)

1. **See**: Sessions tab listing every pi session, newest first, with live
   rows marked. Click focuses or resumes. Branch capture starts here so the
   data accrues.
2. **Move**: next/previous over live rows, ⌘1–9, new-session chord and its
   directory-picker variant.
3. **Settle**: manual settle/unsettle, user-ended sessions settle, Settled
   section, settle-and-advance chord, branch-mismatch confirm at resume.
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
- **VC8**: Closing a session's tab, quitting the agent, or `/new` settles the
  session. Hibernating, quitting the app, Terminate Sessions and a killed zmx
  session do not.
- **VC13**: Resuming a session whose cwd is on a branch the session never
  worked on asks once, naming both branches; a branch in the session's set
  resumes without asking.
- **VC14**: After quit-without-terminate and relaunch, every running agent tab
  appears as a live row and every plain shell stays where it was in the
  Worktrees tab.
- **VC9**: A session idle for 3 days with no surface is settled; a live one
  never is.
- **VC10**: Settle-and-advance lands on the next live row; next-needs-me lands
  only on rows awaiting input or done-unseen.
- **VC11**: A status change on one row invalidates only that row (existing
  sidebar per-leaf rule).
- **VC12**: `make build-app` green; new reducer logic has tests; no
  `Task.sleep` in tests.

## Open items for planning

- **Shell `exit` vs zmx crash**: both arrive as "session already dead" and
  cannot be told apart at that layer. Treated as not settled; an agent that
  quit first has already reported its own end.
- **Harness end during teardown**: confirm whether pi's shutdown signal
  reaches the app during Terminate Sessions or system shutdown, and that the
  guard in §5 covers it.
- **Already-running pi processes** keep the old extension until restarted, so
  on first launch they sit as provisional rows until their next turn, with
  their session file listed as a dormant row meanwhile.
- **Index cost**: about 2,900 session files today. Read header and last
  `session_info` only; cache by mtime and size (resume-plus does the same).
- **In-harness settle**: `supacode session settle` defaults to the calling
  surface's session, so any harness can run it; a pi `/settle` command is a
  thin wrapper. Cheap follow-up, not V1.

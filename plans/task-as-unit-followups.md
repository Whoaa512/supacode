# Task as the unit — follow-ups found while executing

Issues noticed during the work that are not in `task-as-unit-plan.md` yet.
Fold each into the named slice when that slice is implemented.

## Workflow sub-agents disturb the parent session's row (reported 2026-10-08)

**Folded into T9 (2026-10-09)**: fixed app-side by ignoring events from a
process the surface's own agent started. See the T9 Progress entry; the live
UI still has to confirm the symptom is gone.

**Symptom** (cj, live): while a pi session runs background workflows, its
sidebar row keeps reverting to "New session" or gets settled unexpectedly.

**Hypothesis, not verified**: workflow sub-agents are child pi processes of
the session's terminal surface and inherit its surface identity, so each one
reports its own session id (and its own end) against the parent's surface.
A changed ref on a surface is treated as a replacement, which settles the
old key (`settleReplacedOrEndedSession`), and the untitled child shows as
"New session". A child exiting would then look like the harness ending.

**Fix with**: T9 (replacement and task-level settle), which already redefines
what a changed ref on a surface means. Before T9, reproduce and confirm the
cause from the presence signals; do not fix on the hypothesis. Likely shape:
a sub-agent's signals must not replace or end the surface's session, either
by the pi extension not reporting for sub-agent sessions or by the app
ignoring refs under `~/.pi/agent/subagent-sessions` (the index already
excludes those). Add a reducer test for: child ref arrives and ends while the
parent is live; the parent row keeps its title, stays unsettled and stays
primary.

## A task with a member that has no summary never auto-settles (T9 r4, 2026-10-09)

Auto-settle waits until every session of a multi-session task is verified
in one refresh, and a member the refresh lists nothing for counts as unread
(`TaskIdleness` in `SessionsSidebarStructure.swift`). That is the safe side,
but a member whose transcript was deleted or never written, or whose harness
has no session source (all but pi today), holds its task for good; only
manual settle clears it.

**Fix with**: whichever slice next touches the session index. The source
would have to report "read failed" apart from "no such file" (and a harness
with no source as positively unreadable), so absence can release the hold.


## Agent commands cannot tell two same-harness agents on one directory apart (T11, 2026-10-09)

**Folded into Z1 (2026-10-12)**: `149fbdc6`. See the Z1 Progress entry.

`supacode agent prompt|send-keys|resume|read` address `(worktree, agent
kind)` and take the first live record of that kind across every task on the
directory. T11 made them reach that surface through the task that holds it,
but with two tasks each running the same harness on one directory the pick is
still arbitrary.

**Fix with**: Z1 (assigned by T11 r1; until then the family is directory-scoped
and must be documented so). Likely shape: the
task segment / `--task` on agent routes, narrowing the surface set to that
task's before the kind lookup.

## A resume in the task's own directory starts in the focused tab's pwd (S2, 2026-10-09)

A resume into a task sends the bare command when the session ran in the
task's directory. A new tab inherits the focused surface's pwd, so if that
tab has `cd`ed away the agent resumes there, not in the task directory.
Pre-existing (every same-directory resume and new session); S2 only added
the `cd` prefix for a session that ran elsewhere.

**Fixed** (resume-settled, 2026-10-20): `resumeInput` always prefixes the `cd`.

## Assumptions confirmed by cj (2026-10-09)

These were assumptions in the plan's open questions; cj confirmed each, so
they are decisions now and need no further change.

- Q6: auto-settle never closes a tab; a task with any open tab is not
  auto-settled.
- Q4: a shell-only task is deleted when its last tab closes.
- Q21/Q7: the primary quitting while a tangent is live leaves the task
  active with a dormant primary; the tangent is not promoted.
- Q19: `/new` or `/fork` stays in the same task and takes the replaced
  session's slot.
- Q8: detaching the primary is refused.
- Q5: tasks of a removed repository or deleted directory are kept as
  orphans until settled by hand.
- The real-data migration checkpoint (A34) is deferred to one test at the
  end, by cj's choice.

## Chords: rebind to D3 (cj, 2026-10-10) — do in Z1

**Folded into Z1 (2026-10-12)**: `08cab125`, `5a59be35`. See the Z1 Progress entry.

P1 left the chords as found because ⌘N was New Worktree. cj chose D3's
literal chords. ⌘⌥N (his first pick for New Worktree) is taken by
`toggleNotificationsInspector`, so New Worktree takes the slot the picker
vacates. Change the three defaults in `AppShortcuts` and `SessionShortcutTests`
(including the Ghostty unbind lines), menu titles/help, the CLI reference
and docs:

| action | was | now |
|---|---|---|
| `newSession` (new task, default agent) | ⌘⇧N | ⌘N |
| `newSessionInDirectory` (picker) | ⌘⌥⇧N | ⌘⇧N |
| `newWorktree` | ⌘N | ⌘⌥⇧N |

User overrides of any of the three are kept as they are.

## Decide-at-delivery sweep of older paths — do in Z1

**Folded into Z1 (2026-10-12)**: `c4e71f9d`. See the Z1 Progress entry.

The final audit of 2026-10-10 found three paths from earlier slices that
carry precomputed state across an asynchronous boundary. Fix under the rule
in the plan's fixed-design section, with a stale-delivery test each:
- `removeLayouts(forDirectory:remoteHost:)`: the app precomputes the remote
  host and the manager does not re-check that the directory is still being
  deleted; a queued deletion can hit tasks created or re-registered on that
  directory id since.
- Commands that reach `host(for:context:)` (select, focus, rename, search,
  close, binding actions) attach a layout unconditionally, so a stale one
  against a task removed by transfer re-attaches it. Non-creating commands
  must use a lookup that cannot attach.
- Resume carries a precomputed `DirectoryContext` and target through
  `createTabWithInput` to `createTabAsync` with no eligibility check at
  delivery; a target merged, removed or archived before delivery can be
  resurrected.

## Left after the final audits (Z2, 2026-10-12)

Found by the Z1 reviews and the final decide-at-delivery audit, judged below
the bar for a slice of their own. Each is pre-existing or guarded; none loses
data today.

- ~~**Same-directory resume still inherits the focused tab's pwd.**~~ Fixed
  (resume-settled, 2026-10-20): `resumeInput` always prefixes the `cd`, own
  directory included; `aResumeInTheTasksOwnDirectoryStillChangesToIt` covers
  a task whose focused tab recorded another pwd.
- ~~**`prune(keepingDirectories:protectingRepositoryIDs:archivedDirectories:)`
  carries precomputed sets across the boundary.**~~ Fixed
  (carry-identity-followups, 2026-10-21): `.prune` carries nothing; the
  manager reads `archivedDirectories` and `pruneShieldedRepositoryIDs` from
  the store at delivery. A host goes only when its directory is archived then.
- ~~**`deliveryContext` falls back to the carried `DirectoryContext` for an
  unknown layout.**~~ Fixed (carry-identity-followups, 2026-10-21): an
  unknown layout is refused; `carried:` is gone from `deliveryContext` and
  the creating paths. Manager tests that open a layout without the reducer
  seed it with `seedDirectoryForTesting` (DEBUG only).
  `aCreatingCommandOnAnUnknownLayoutCreatesNothingFromItsCarriedContext`
  covers the refusal.
- ~~**Reaper race not covered.**~~ Fixed (carry-identity-followups,
  2026-10-21): `aKillThatLandedBeforeTheBudgetExpiredIsNotKilledAgain`
  forces the ordering on a `TestClock` (the kill budget now sleeps on the
  manager's injected clock) and exposed a real double kill: a local kill
  that landed just before the budget cancelled its task was not recorded as
  attempted, so `killSurvivingLocalSessions` killed it again.
  `ZmxClient.killSurfaceSessions` now reports whether it issued the local
  kill and the manager records that instead of reading the cancellation flag.


## Workflow sub-agents still disturb the parent task's row (cj, live, 2026-10-20)

**Fixed 2026-10-21** (`ba4dfb27` extension, `8026b3d3` app). Root cause,
read from the signal path rather than the hypothesis above:

- The `workflow` tool does not spawn a child process. It calls
  `createAgentSession` inside the parent Pi process (quintinshaw-pi-dynamic-
  workflows `src/agent.ts`), one session per `agent()`, with the default
  resource loader, so each child session loads the supacode extension again.
  Pi loads extensions with `moduleCache: false`, so each is a fresh module
  with no shared state.
- Those sessions never call `bindExtensions`, so they emit no `session_start`
  or `session_shutdown`; they emit `agent_start` / `agent_end` only. The
  extension turned those into `busy` / `idle` with the child's sid and the
  **parent's pid** (it is the same process). Their session files live under
  `~/.pi/agent/subagent-sessions`, which the index excludes, hence the
  untitled "New session" member.
- App side, T9's `isFromNestedAgent` is pid-ancestry based and explicitly
  trusts a pid already on the record, so the child's `busy` passed. Presence
  takes a changed ref from any event on a live record, so
  `settleReplacedOrEndedSession` read it as a replacement: the parent was
  marked settled and dropped from the primary slot, the child took it, then
  the parent's next `idle` swapped them back, and so on per turn. A child's
  `session_end` with reason `quit` from the same pid removed the record
  entirely (seen in the negative test).
- The `subagent` tool (dotfiles `extensions/subagent/index.ts`) spawns a
  separate `pi -p` process, not detached, which shares the controlling tty;
  that is the case T9 already covered by pid ancestry and it still is.

**Fix**, both layers:
- Extension (`PiExtensionContent.swift`): one session per process owns the
  surface, tracked on `globalThis` keyed by `ctx.sessionManager` identity;
  non-owner sessions emit nothing. The owner releases on `session_shutdown`,
  so `/new`, `/resume`, `/fork`, `/reload` hand over as before. The installer
  sees the content change as `.outdated` and reinstalls.
- App (`AgentPresenceFeature.isFromNestedAgent`): a Pi process changes its
  session only through `session_start` (it ends the old one first), so any
  other event from a tracked pid under a different ref is a nested session
  and is dropped. Covers an older installed extension.
- Tests: `PiExtensionSessionLifecycleTests` (node-driven, nested session
  silent while owner live; handover after shutdown) and
  `AppFeatureSessionsTaskSettleTests.aSessionNestedInTheParentsProcess…`
  (child busy/idle/quit under the parent's pid: title, primary, members and
  record unchanged, nothing settled). The two tests that modelled a harness
  swapping sessions without an end now run on Claude; Pi never does that.

Screenshot evidence: pi-clipboard-2cf85d72 (2026-10-20).

## ⌘P should search tasks, not worktrees (cj, 2026-10-20)

⌘P today is "jump to worktree". With tasks as the unit cj wants ⌘P to fuzzy
search active tasks plus recently settled ones (title, directory, agent) and
jump to the chosen task (resuming it if settled, decide-at-delivery). Keep a
way to reach worktrees from the same palette (e.g. a `w:` prefix or a second
section below tasks). Factory item for the next run.

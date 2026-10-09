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

`supacode agent prompt|send-keys|resume|read` address `(worktree, agent
kind)` and take the first live record of that kind across every task on the
directory. T11 made them reach that surface through the task that holds it,
but with two tasks each running the same harness on one directory the pick is
still arbitrary.

**Fix with**: Z1 (assigned by T11 r1; until then the family is directory-scoped
and must be documented so). Likely shape: the
task segment / `--task` on agent routes, narrowing the surface set to that
task's before the kind lookup.

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

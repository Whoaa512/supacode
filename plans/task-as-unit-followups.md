# Task as the unit — follow-ups found while executing

Issues noticed during the work that are not in `task-as-unit-plan.md` yet.
Fold each into the named slice when that slice is implemented.

## Workflow sub-agents disturb the parent session's row (reported 2026-10-08)

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

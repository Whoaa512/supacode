# Task Inbox Sidebar — Dev Loop Kickoff

You are driving the implementation of the task-inbox sidebar in supacode.
Work in THIS directory (a git worktree on branch `task-inbox-sidebar`).

## Authoritative docs (read all three fully before any code)
1. `plans/task-inbox-sidebar-scope.md` — locked scope. Do not relitigate.
2. `plans/task-inbox-sidebar-plan.md` — locked plan: architecture posture,
   validation contract (A1–A37), 7 phases, and a fully **Resolved** decisions
   section (all 16 former UNCONFIRMED items are decided with evidence — treat
   every entry there as binding).
3. `AGENTS.md` — build/test commands, test-bundle routing globs, code
   guidelines (TCA, @ObservableState, SupaLogger, sidebar per-leaf
   invalidation doctrine, FocusedAction rules).

Reference implementation to port semantics from: `~/code/t3code`
(`apps/web/src/components/SidebarV2.tsx`, `Sidebar.logic.ts`,
`packages/client-runtime/src/state/threadSettled.ts`). Port t3 semantics
faithfully where the plan says "t3 verbatim"; the plan's Resolved section
overrides t3 where they differ.

## Protocol: dev loop
Loop until the current phase's assertions pass:
1. Spawn a super-coder subagent to implement ONE plan item at a time.
2. Spawn a code-critic subagent to review the diff against the plan +
   AGENTS.md doctrine.
3. Fix findings; repeat.

Each subagent writes a structured handoff: what done, what undone,
commands run + exit codes, issues found.

## Execution order
- Phase 1 first (tracer: A1–A13). Then Phase 2 ∥ Phase 3 per the plan.
  Work phase by phase; do NOT start a phase before the previous one's
  assertions are demonstrably green (except the sanctioned P2∥P3 overlap).
- Commit small and focused after each green step. Never `git add .` — stage
  the specific files. No AI co-author lines in commit messages.
- After each feature: `make build-app` must pass, plus the relevant test
  bundle with `totalTestCount > 0` verified via
  `xcrun xcresulttool get test-results summary --path build/supacode-tests.xcresult`.
  Remember: new test files need `make generate-project` first, and
  `-only-testing` must target the correct bundle per the AGENTS.md globs.
- The validation contract drives QA: a phase is done when its listed
  assertions each have a passing test or a documented manual verification.

## Hard rules from the plan (do not drift)
- `TaskRecord` is a top-level collection, NEVER a sidebar bucket item.
- Tasks persist to a sibling `~/.supacode/tasks.json`, never inside
  sidebar.json. Atomic writes, per-element lossy decode, corrupt-file
  rename-aside.
- Pure logic ports are `nonisolated` statics on caseless enums, zero
  TCA/SwiftUI imports (A18 grep assertion).
- Views read ONLY the cached `TasksSidebarStructure` + per-task leaf state;
  never dictionaries from a view body.
- Selection: add `case task(TaskID)` to `SidebarSelection` (Resolved #6).
- Status model is 5 states incl. `approval` via a new hook discriminator
  (Resolved #1).
- Conflict cascade + auto-worktree safety per Resolved #9/#11 (pre-delete
  precondition recheck; never delete on any mismatch).
- Tab-granular claims (Resolved #10).

When the full loop for a phase completes, run a final code-critic pass over
the whole phase diff, then stop and summarize: assertions green, assertions
deferred (with reason), files touched, next phase.

Start now with Phase 1.

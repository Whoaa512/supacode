# Command Center: engine-agnostic workflow provider (future work)

Goal: let the Command Center drive *real* multi-agent workflow engines — pi-dynamic-workflows
and Claude Code dynamic workflows — instead of faking a "workflow" with a single backgrounded
`pi "..."` tab. Expose one neutral contract both engines map onto.

## Verified current state (as of this commit)

The Command Center today is a curated launcher palette + a coarse status board. It does **not**
orchestrate anything itself.

- `WorkflowDefinition` (`SupacodeSettingsShared/Models/WorkflowDefinition.swift`) — engine-neutral
  named launchers (Ship Check, Dev Loop, Fix CI, Investigate, Handoff), bucketed by
  `WorkflowCategory` (understand/build/review/ship/package). Each carries a `{{mustache}}`
  `promptTemplate`. The prompts are plain natural language.
- `CommandCenterFeature.launchWorkflow` (`supacode/Features/CommandCenter/Reducer/CommandCenterFeature.swift`)
  renders the template, then emits `delegate(.createTabWithInput(...))` with
  `input = "pi \"<escaped prompt>\"\n"`. So a "workflow run" = one `pi` invocation typed into one
  new terminal tab in one worktree.
- `WorkflowRun` / `WorkflowRunStatus` (`supacode/Features/CommandCenter/WorkflowRun.swift`) — a
  4-state enum: `idle | active | attentionNeeded | complete`.
- Status is **inferred from coarse terminal task status**, not from any real run record.
  `AppFeature.terminalEvent(.taskStatusChanged)` (`supacode/Features/App/Reducer/AppFeature.swift`,
  ~line 1019) maps `status == .running ? .active : .idle` for every non-complete run on that
  worktree. `attentionNeeded` and `complete` are not currently produced by this path.

Implication: the Command Center has **zero visibility** into a real workflow's phases, per-agent
progress, model routing, token/cost, or approval gates. It only knows "the terminal in this
worktree is busy or not."

## The agnostic seam: both engines share one on-disk run contract

pi-dynamic-workflows and Claude Code dynamic workflows independently converged on the **same
primitives**. That convergence — not the CLI string — is the thing to integrate against.

|                        | pi-dynamic-workflows                          | Claude Code workflows                          |
| ---------------------- | --------------------------------------------- | ---------------------------------------------- |
| Trigger                | keyword `workflows` / `/ultracode` / `/<saved>` | keyword `ultracode` / "run a workflow" / `/<saved>` |
| Saved command          | `/<name>`                                     | `/<name>`                                      |
| Script on disk         | `~/.pi/workflows/projects/<project>/`         | `~/.claude/projects/<session>/`                |
| Run state              | journal: per-phase, per-agent, tokens, cost   | journal: per-phase, per-agent, tokens, elapsed |
| Structure              | `phase()` → `agent()` / `parallel()` fan-out  | phases → agents fan-out                        |
| Background + resumable  | yes                                           | yes (resume within same session)              |
| Approval / pause gate  | `checkpoint()`                                | per-run approval prompt (permission-mode gated) |
| Concurrency / total cap | 16 concurrent / 1000 total                    | 16 concurrent / 1000 total                     |

The Command Center's `WorkflowRun` is a **lossy projection** of exactly this run record. The fix
is to read the real record, not to keep guessing from terminal idle/running.

(Sources: pi-dynamic-workflows README `~/code/quintinshaw-pi-dynamic-workflows`; Claude Code
"Orchestrate subagents at scale with dynamic workflows" docs, code.claude.com.)

## Proposed contract

Define one normalized snapshot as *the* Command Center vocabulary, plus a provider protocol with
one adapter per engine.

```swift
enum WorkflowRunStatus {           // grows from today's 4-state enum
  case running, needsApproval, paused, done, failed
}

struct WorkflowAgentSnapshot {
  let id: String
  let label: String
  let model: String?               // real per-agent model routing
  let status: WorkflowRunStatus
  let tokens: Int
  let costUSD: Double?
  let lastResultPreview: String?
}

struct WorkflowPhaseSnapshot {
  let title: String
  let agents: [WorkflowAgentSnapshot]
  let tokens: Int
  let elapsed: Duration?
}

struct WorkflowRunSnapshot: Identifiable, Equatable, Sendable {
  let id: String
  let name: String
  let cwd: URL
  let status: WorkflowRunStatus
  let phases: [WorkflowPhaseSnapshot]
  let totalTokens: Int
  let totalCostUSD: Double?
}

protocol WorkflowRunProvider {
  func launch(prompt: String, cwd: URL, args: [String: Any]?) async -> String   // runID
  func runs(in project: URL) -> AsyncStream<[WorkflowRunSnapshot]>               // tail the journal
  func pause(_ id: String); func resume(_ id: String); func stop(_ id: String)
}
```

Two adapters:

- `PiWorkflowProvider` — launch via `pi` (arm with `workflows` keyword or a saved `/<name>`),
  tail `~/.pi/workflows/projects/<project>/`.
- `ClaudeWorkflowProvider` — launch via `claude` (arm with `ultracode` or a saved `/<name>`),
  tail `~/.claude/projects/<session>/`.

The Command Center renders `WorkflowRunSnapshot`s and sends control commands. It stops caring
which engine runs underneath.

## What changes in fable-5

- `WorkflowRunStatus` grows into the snapshot above (per-phase / per-agent children, `needsApproval`,
  `paused`). `attentionNeeded` becomes `needsApproval`, mapped from Claude's approval prompt /
  pi's `checkpoint()`.
- `AppFeature` stops the `taskStatus == .running ? .active : .idle` inference (~line 1019) and
  instead subscribes to the provider's `runs(in:)` stream.
- `WorkflowDefinition` stays engine-neutral. Provider selection becomes a global setting
  ("Workflow engine: pi / claude") or is auto-detected from which CLI the worktree's repo uses.
  The only engine-specific bits are the **arm prefix** (`workflows` vs `ultracode`) and the
  **launch binary** — both owned by the provider, not the definition.
- `CommandCenterFeature.launchWorkflow` delegates to `provider.launch(...)` instead of hardcoding
  `pi "..."` into a tab. (A terminal tab can still host the run for visibility, but status comes
  from the journal.)

## Honest risk

Both journals are **private, undocumented formats** that will drift. The concept-level contract
(phases / agents / tokens / status / resumable) is solid; the *adapters* are reverse-engineered
and brittle. De-risk options:

1. **Cheap/robust:** parse only the stable surfaces each tool already prints — pi `/workflows`
   list output and Claude `/workflows` print mode. Coarser, but far less likely to break than the
   raw journal.
2. **Ideal/upstream:** ask pi-dynamic-workflows (Quintin's; we have influence) to emit a small
   **stable status JSON** (e.g. `runs.json` matching `WorkflowRunSnapshot`). Then `PiWorkflowProvider`
   reads a contract instead of guessing, and that schema becomes the spec Claude's adapter conforms to.

## Recommendation

1. Define `WorkflowRunSnapshot` + `WorkflowRunProvider` as the Command Center's vocabulary.
2. Build `PiWorkflowProvider` first (we control that journal and live in pi).
3. Lead with the upstream ask to pi-dynamic-workflows for a stable status file — single move that
   turns a brittle integration into a clean one.
4. Ship `ClaudeWorkflowProvider` as a thin second adapter to prove the abstraction holds.

Net: Supacode becomes the visual cockpit both engines lack, while each keeps owning the actual
multi-agent execution.

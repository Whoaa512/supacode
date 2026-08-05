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

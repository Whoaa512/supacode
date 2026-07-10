import Foundation
import SupacodeSettingsShared

/// A raw agent event tagged with the identity the extraction pipeline needs:
/// a stable source id (for idempotent dedup and reply routing) and the session
/// it belongs to. Adapters see only this normalized envelope, never the wire.
nonisolated struct NormalizedAgentEvent: Sendable, Equatable {
  let sourceEventID: String
  let sessionID: SessionID
  let occurredAt: Date
  let raw: AgentHookEvent
}

/// The adapter contract. An adapter turns one agent's raw events into
/// normalized attention candidates using deterministic rules only. It never
/// invents options or evidence absent from the source event (principle 3), and
/// returns `nil` for events that carry no attention signal.
///
/// This is the seam the Pi and Claude Code adapters implement in Phase 1. The
/// replay corpus exercises adapters against recorded fixtures, decoupled from
/// live orchestration.
nonisolated protocol AgentEventAdapter: Sendable {
  /// The agent whose events this adapter understands.
  var agent: SkillAgent { get }

  /// Extract a candidate from a single event, or `nil` when the event is not
  /// an attention moment. Must be pure and deterministic.
  func candidate(from event: NormalizedAgentEvent) -> AttentionCandidate?
}

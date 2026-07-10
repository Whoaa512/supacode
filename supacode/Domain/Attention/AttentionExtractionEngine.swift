import Foundation
import SupacodeSettingsShared

/// Replays a stream of raw agent events through the matching adapter and
/// produces a deterministic set of attention candidates.
///
/// Determinism is the whole point: the same event log always yields the same
/// candidates regardless of delivery order or duplicate deliveries, so replay
/// fixtures give stable regression coverage for extraction changes.
///
/// - Ordering: events are sorted by `(occurredAt, sourceEventID)` so an
///   out-of-order or interleaved delivery replays identically.
/// - Idempotency: the first event seen for a `sourceEventID` wins; later
///   duplicates (hook retries) are dropped.
nonisolated struct AttentionExtractionEngine: Sendable {
  private let adapters: [SkillAgent: any AgentEventAdapter]

  init(adapters: [any AgentEventAdapter]) {
    self.adapters = Dictionary(
      adapters.map { ($0.agent, $0) },
      uniquingKeysWith: { first, _ in first }
    )
  }

  /// Convenience: the default hook-based adapters for the agents the corpus
  /// currently covers.
  static func hookBased(agents: [SkillAgent] = [.pi, .claude]) -> AttentionExtractionEngine {
    AttentionExtractionEngine(adapters: agents.map { HookEventAdapter(agent: $0) })
  }

  /// Extract candidates from a replay corpus. Events lacking a registered
  /// adapter for their agent are skipped rather than dropped silently in a way
  /// that hides them — the caller can diff input vs output counts.
  func extract(from corpus: ReplayCorpus) -> [AttentionCandidate] {
    let deduped = Self.dedupedInOrder(corpus.events)
    return deduped.compactMap { event in
      guard let adapter = adapters[corpus.agent] else { return nil }
      let normalized = NormalizedAgentEvent(
        sourceEventID: event.sourceEventID,
        sessionID: SessionID(event.raw.surfaceID.uuidString),
        occurredAt: event.raw.timestamp ?? .distantPast,
        raw: event.raw
      )
      return adapter.candidate(from: normalized)
    }
  }

  /// Sorts by `(occurredAt, sourceEventID)` and keeps the first occurrence of
  /// each `sourceEventID`. Stable regardless of input order.
  private static func dedupedInOrder(_ events: [ReplayEvent]) -> [ReplayEvent] {
    let sorted = events.sorted { lhs, rhs in
      let lhsTime = lhs.raw.timestamp ?? .distantPast
      let rhsTime = rhs.raw.timestamp ?? .distantPast
      if lhsTime != rhsTime { return lhsTime < rhsTime }
      return lhs.sourceEventID < rhs.sourceEventID
    }
    var seen: Set<String> = []
    var result: [ReplayEvent] = []
    for event in sorted where seen.insert(event.sourceEventID).inserted {
      result.append(event)
    }
    return result
  }
}

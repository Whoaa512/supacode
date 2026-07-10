import Foundation
import SupacodeSettingsShared

/// Deterministic rules adapter over the unified `AgentHookEvent` wire format.
///
/// Both the Pi and Claude Code hooks emit the same OSC 3008 envelope today, so
/// a single rules table serves both while the extraction spike measures
/// precision/recall. When the two diverge (Phase 1 slice 2), split this into
/// agent-specific adapters — the `AgentEventAdapter` seam already allows it.
///
/// Rules map event name + `data` payload to a candidate kind. Unknown or
/// non-attention events (`session_start`, `busy`, `idle`, unclassified
/// notifications) return `nil`; extraction must never guess.
nonisolated struct HookEventAdapter: AgentEventAdapter {
  let agent: SkillAgent

  func candidate(from event: NormalizedAgentEvent) -> AttentionCandidate? {
    guard let name = event.raw.eventName else { return nil }
    let data = event.raw.decodeData(HookAttentionData.self)

    guard let kind = Self.kind(for: name, data: data) else { return nil }

    return AttentionCandidate(
      id: AttentionID(event.sourceEventID),
      sessionID: event.sessionID,
      occurredAt: event.occurredAt,
      kind: kind,
      question: data?.question,
      options: data?.decisionOptions ?? [],
      recommendation: nil,
      evidence: data?.artifactReferences ?? [],
      sourceEventID: event.sourceEventID
    )
  }

  private static func kind(
    for name: AgentHookEvent.EventName,
    data: HookAttentionData?
  ) -> AttentionCandidate.Kind? {
    switch name {
    case .awaitingInput:
      return .explicitInputRequested
    case .notification:
      return notificationKind(category: data?.category)
    case .sessionEnd:
      return sessionEndKind(data: data)
    case .sessionStart, .busy, .idle:
      return nil
    }
  }

  private static func notificationKind(category: String?) -> AttentionCandidate.Kind? {
    switch category {
    case "permission": return .permissionRequested
    case "command_failed": return .commandFailed
    case "tests_failed": return .testsFailed
    case "merge_conflict": return .mergeConflict
    default: return nil
    }
  }

  private static func sessionEndKind(data: HookAttentionData?) -> AttentionCandidate.Kind {
    if data?.reason == "completed" { return .agentCompleted }
    if let exitCode = data?.exitCode, exitCode == 0 { return .agentCompleted }
    // An end with a non-zero/unknown exit is an unexpected exit until proven
    // otherwise; process lifecycle later corroborates or overrides (Phase 1.4).
    if data?.exitCode != nil || data?.reason != nil { return .agentExitedUnexpectedly }
    return .agentCompleted
  }
}

/// The per-event `data` payload shape the rules read. Every field is optional:
/// a missing field simply removes signal, never crashes extraction.
nonisolated struct HookAttentionData: Decodable, Sendable {
  let category: String?
  let question: String?
  let reason: String?
  let exitCode: Int?
  let options: [RawOption]?
  let evidence: [RawEvidence]?

  private enum CodingKeys: String, CodingKey {
    case category, question, reason, options, evidence
    case exitCode = "exit_code"
  }

  var decisionOptions: [DecisionOption] {
    (options ?? []).map { DecisionOption(id: $0.id, label: $0.label) }
  }

  var artifactReferences: [ArtifactReference] {
    (evidence ?? []).map {
      ArtifactReference(
        id: $0.id,
        kind: ArtifactReference.Kind(rawValue: $0.kind) ?? .log,
        label: $0.label,
        uri: $0.uri
      )
    }
  }

  nonisolated struct RawOption: Decodable, Sendable {
    let id: String
    let label: String
  }

  nonisolated struct RawEvidence: Decodable, Sendable {
    let id: String
    let kind: String
    let label: String
    let uri: String?
  }
}

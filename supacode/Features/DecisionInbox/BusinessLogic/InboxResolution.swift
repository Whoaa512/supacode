import Foundation
import SupacodeSettingsShared

/// The human's disposition of one `AttentionCandidate`. Persisted verbatim to
/// the durable `AgentEventLog` as an `inbox_resolution` record so decision
/// history ships for free (one log line, no second store). Every field the
/// plan asks for — chosen action, resolution time, whether the recommendation
/// was accepted, optional dismissal reason — travels in the record's `data`.
nonisolated struct InboxResolution: Equatable, Sendable {
  /// How the user disposed of the card. `focused` routed to the terminal,
  /// `copied` put the suggested response on the pasteboard, `dismissed` cleared
  /// it without acting.
  enum ChosenAction: String, Sendable {
    case focused
    case copied
    case dismissed
  }

  let candidateID: String
  /// Un-namespaced protocol request id when the candidate came from an
  /// `input_requested`; nil for synthesized kinds. Lets a later resolve
  /// transport correlate this disposition back to the originating request.
  let requestID: String?
  let sessionID: UUID
  /// Stable string form of `AttentionCandidate.Kind` so the log stays readable
  /// without decoding an enum with an associated value.
  let kind: String
  let chosenAction: ChosenAction
  let resolvedAt: Date
  /// Whether the user took the recommended action. Copy accepts the suggested
  /// response (true); dismiss rejects it (false); focus is unknown (nil) — the
  /// user went to look, we can't claim acceptance.
  let recommendationAccepted: Bool?
  let dismissalReason: String?

  /// The durable log line for this resolution: an `inbox_resolution` event keyed
  /// by the originating surface, agent-agnostic (`supacode` is the actor that
  /// recorded it). Pure so callers and tests build the same record.
  var eventRecord: AgentEventRecord {
    var fields: [String: JSONValue] = [
      "candidate_id": .string(candidateID),
      "kind": .string(kind),
      "chosen_action": .string(chosenAction.rawValue),
    ]
    if let requestID { fields["request_id"] = .string(requestID) }
    if let recommendationAccepted { fields["recommendation_accepted"] = .bool(recommendationAccepted) }
    if let dismissalReason { fields["dismissal_reason"] = .string(dismissalReason) }
    return AgentEventRecord(
      timestamp: resolvedAt,
      sessionKey: sessionID.uuidString,
      agent: "supacode",
      event: AgentEventKind.inboxResolution.rawValue,
      data: .object(fields))
  }
}

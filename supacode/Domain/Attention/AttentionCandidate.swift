import Foundation
import SupacodeSettingsShared

/// Branded identifier for an `AttentionCandidate`. String-backed so it is
/// stable across replay/restart and safe as a dedup key.
nonisolated struct AttentionID: Hashable, Sendable, Codable, CustomStringConvertible {
  let rawValue: String

  init(_ rawValue: String) { self.rawValue = rawValue }

  var description: String { rawValue }

  init(from decoder: any Decoder) throws {
    self.rawValue = try decoder.singleValueContainer().decode(String.self)
  }
  func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

/// Branded identifier for the agent session (surface) a candidate belongs to.
nonisolated struct SessionID: Hashable, Sendable, Codable, CustomStringConvertible {
  let rawValue: String

  init(_ rawValue: String) { self.rawValue = rawValue }

  var description: String { rawValue }

  init(from decoder: any Decoder) throws {
    self.rawValue = try decoder.singleValueContainer().decode(String.self)
  }
  func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

/// A selectable option an agent offered for an explicit decision.
nonisolated struct DecisionOption: Hashable, Sendable, Codable, Identifiable {
  let id: String
  let label: String
}

/// An externally supplied recommendation. Recommendations stay external
/// (principle 4): the app renders and records them, it never invents one.
/// Every recommendation must reference the evidence it rests on.
nonisolated struct Recommendation: Hashable, Sendable, Codable {
  let optionID: String?
  let rationale: String
  let evidence: [ArtifactReference]
}

/// A pointer to supporting evidence (diff, test output, log, artifact) so a
/// card's claims can be grounded (principle 5). Never fabricated; only lifted
/// from source event context.
nonisolated struct ArtifactReference: Hashable, Sendable, Codable, Identifiable {
  enum Kind: String, Sendable, Codable {
    case diff
    case testOutput = "test_output"
    case commandOutput = "command_output"
    case log
    case file
    case url
  }

  let id: String
  let kind: Kind
  let label: String
  let uri: String?
}

/// Normalized output of an agent adapter: a moment that *may* deserve human
/// attention. Candidates are ephemeral extraction output; only promoted,
/// deduplicated candidates become durable attention items (Phase 2).
nonisolated struct AttentionCandidate: Hashable, Sendable, Codable, Identifiable {
  /// The classes of attention moment v1 recognizes. Raw string backing keeps a
  /// candidate decodable even if a newer emitter adds a kind this build lacks.
  enum Kind: String, Sendable, Codable, CaseIterable {
    case explicitInputRequested = "explicit_input_requested"
    case permissionRequested = "permission_requested"
    case commandFailed = "command_failed"
    case testsFailed = "tests_failed"
    case mergeConflict = "merge_conflict"
    case agentCompleted = "agent_completed"
    case agentExitedUnexpectedly = "agent_exited_unexpectedly"
  }

  let id: AttentionID
  let sessionID: SessionID
  let occurredAt: Date
  let kind: Kind
  let question: String?
  let options: [DecisionOption]
  let recommendation: Recommendation?
  let evidence: [ArtifactReference]
  let sourceEventID: String

  /// A candidate is actionable when a human could resolve it from the inbox
  /// without opening the terminal: it presents a question or concrete options.
  var isActionable: Bool {
    question != nil || !options.isEmpty
  }

  /// A candidate is grounded when at least one claim links to evidence.
  var isGrounded: Bool {
    !evidence.isEmpty
  }
}

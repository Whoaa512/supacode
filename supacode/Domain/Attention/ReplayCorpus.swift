import Foundation
import SupacodeSettingsShared

/// A sanitized, labeled replay fixture: one recorded agent session's raw event
/// log plus the human labels used to score extraction. Decoded from JSON so
/// fixtures live as data, not code, and can grow without recompiling logic.
nonisolated struct ReplayCorpus: Decodable, Sendable {
  let name: String
  let agent: SkillAgent
  let events: [ReplayEvent]

  /// Decode a single corpus from JSON data.
  static func decode(from data: Data) throws -> ReplayCorpus {
    try JSONDecoder().decode(ReplayCorpus.self, from: data)
  }

  /// Load and decode every `*.json` corpus in a directory, sorted by file name
  /// for deterministic iteration.
  static func loadAll(from directory: URL) throws -> [ReplayCorpus] {
    let urls = try FileManager.default
      .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
      .filter { $0.pathExtension == "json" }
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
    return try urls.map { try decode(from: Data(contentsOf: $0)) }
  }
}

/// One event in a corpus: a stable source id, the raw wire event, and an
/// optional attention label. Labels are ground truth for scoring and are never
/// read by extraction.
nonisolated struct ReplayEvent: Decodable, Sendable {
  let sourceEventID: String
  let raw: AgentHookEvent
  let label: AttentionLabel?

  private enum CodingKeys: String, CodingKey {
    case sourceEventID = "source_event_id"
    case raw
    case label
  }
}

/// Human ground-truth for one event: did it genuinely need attention, and if so
/// what kind, whether evidence was available, and whether it was resolvable
/// without opening the terminal.
nonisolated struct AttentionLabel: Decodable, Sendable {
  let attentionExpected: Bool
  let expectedKind: AttentionCandidate.Kind?
  let expectsEvidence: Bool?
  let expectsActionable: Bool?

  private enum CodingKeys: String, CodingKey {
    case attentionExpected = "attention_expected"
    case expectedKind = "expected_kind"
    case expectsEvidence = "expects_evidence"
    case expectsActionable = "expects_actionable"
  }
}

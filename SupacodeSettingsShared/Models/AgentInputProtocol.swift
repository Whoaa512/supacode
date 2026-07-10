import Foundation

/// A structured decision an agent asks the user to make instead of blocking on
/// a terminal prompt. Carried in the `data` payload of an `input_requested`
/// hook event and persisted to the append-only event log. `id` is a stable
/// string so the later `input_resolved` reply can be correlated without holding
/// an open file descriptor through app state.
public nonisolated struct InputRequested: Equatable, Sendable, Codable {
  public let id: String
  public let question: String
  public let options: [String]
  public let recommendation: String?
  public let contextRefs: [String]

  public init(
    id: String,
    question: String,
    options: [String],
    recommendation: String? = nil,
    contextRefs: [String] = []
  ) {
    self.id = id
    self.question = question
    self.options = options
    self.recommendation = recommendation
    self.contextRefs = contextRefs
  }

  private enum CodingKeys: String, CodingKey {
    case id, question, options, recommendation
    case contextRefs = "context_refs"
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.id = try container.decode(String.self, forKey: .id)
    self.question = try container.decode(String.self, forKey: .question)
    self.options = try container.decodeIfPresent([String].self, forKey: .options) ?? []
    self.recommendation = try container.decodeIfPresent(String.self, forKey: .recommendation)
    self.contextRefs = try container.decodeIfPresent([String].self, forKey: .contextRefs) ?? []
  }
}

/// The user's answer to an `InputRequested`, matched back by `id`. Carried in
/// the `data` payload of an `input_resolved` hook event.
public nonisolated struct InputResolved: Equatable, Sendable, Codable {
  public let id: String
  public let choice: String

  public init(id: String, choice: String) {
    self.id = id
    self.choice = choice
  }
}

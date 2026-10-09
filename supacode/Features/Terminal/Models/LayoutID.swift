/// The key a terminal layout is stored under. Distinct from `Worktree.ID` so a directory id
/// can only become a layout id through the resolver seam (`layoutID(forDirectory:)`).
nonisolated struct LayoutID: Hashable, Sendable, Codable, CustomStringConvertible {
  private let rawValue: String

  /// A layout id read from a persisted layouts blob, whose keys are worktree paths.
  init(legacyWorktreeKey key: String) { rawValue = key }

  /// The key this layout is written under in the persisted layouts blob.
  var persistenceKey: String { rawValue }

  var description: String { rawValue }

  init(from decoder: any Decoder) throws {
    rawValue = try decoder.singleValueContainer().decode(String.self)
  }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

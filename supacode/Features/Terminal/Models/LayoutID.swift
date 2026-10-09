import Foundation

/// The key a terminal layout is stored under. Distinct from `Worktree.ID` so a directory id
/// can only become a layout id through the resolver seam (`layoutID(forDirectory:)`).
nonisolated struct LayoutID: Hashable, Sendable, Codable, CustomStringConvertible {
  private let rawValue: String

  /// A layout id read from a persisted layouts blob, whose keys are worktree paths.
  init(legacyWorktreeKey key: String) { rawValue = key }

  /// A task minted by the app; never derived from a directory.
  init(task uuid: UUID) { rawValue = uuid.uuidString }

  /// A task id as `SUPACODE_TASK_ID`, a deeplink's task segment or the CLI's
  /// `--task` names it. Taken as written: it only ever addresses a task that
  /// already exists, and never becomes one.
  init?(external raw: String) {
    guard let decoded = ExternalID.decode(raw) else { return nil }
    rawValue = decoded
  }

  /// The form `init(external:)` reads back.
  var externalID: String { ExternalID.encode(rawValue) }

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

import Foundation

/// The key a terminal layout is stored under, and the task's id. Distinct from `Worktree.ID`:
/// a directory never becomes a layout id. The app-layer seam
/// (`AppFeature.State.layoutID(forDirectory:) -> LayoutID?`) answers which task a directory
/// means, and nil when it has none; only the v2 migrator still reads an id off a directory path.
nonisolated struct LayoutID: Hashable, Sendable, Codable, CustomStringConvertible {
  private let rawValue: String

  /// A layout id read from a v2 layouts blob, whose keys are worktree paths. For the migrator
  /// (`LayoutsMigrator`, `LayoutsTaskSplitter`) and test fixtures only: nothing else derives a
  /// layout id from a directory.
  init(legacyWorktreeKey key: String) { rawValue = key }

  /// A stored task id read back as written (`persistenceKey`): the inverse of the key a record
  /// or a merged-away entry is filed under. It names a task that was stored, never a directory.
  init(persistenceKey key: String) { rawValue = key }

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

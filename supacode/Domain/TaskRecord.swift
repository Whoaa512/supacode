import Foundation
import SupacodeSettingsShared

/// A task: one layout (agent sessions and plain shells) rooted in a directory.
/// Flat by construction: there is no parent or child field.
nonisolated struct TaskRecord: Equatable, Codable, Sendable, Identifiable {
  /// Where a task's tabs start by default. Tabs may run elsewhere.
  struct Directory: Hashable, Codable, Sendable {
    var worktreeID: Worktree.ID
    /// SSH host the directory lives on, or `nil` for a local one.
    var host: RemoteHost?

    init(worktreeID: Worktree.ID, host: RemoteHost? = nil) {
      self.worktreeID = worktreeID
      self.host = host
    }
  }

  let id: LayoutID
  var directory: Directory
  /// Empty for a task whose tabs are all closed.
  var layout: PaneLayout
  /// Agent sessions that belong to the task, primary first. Empty for a shell-only task.
  var sessions: [SessionKey]
  var createdAt: Date

  init(
    id: LayoutID,
    directory: Directory,
    layout: PaneLayout = PaneLayout(),
    sessions: [SessionKey] = [],
    createdAt: Date
  ) {
    self.id = id
    self.directory = directory
    self.layout = layout
    self.sessions = sessions
    self.createdAt = createdAt
  }
}

/// The v3 layouts shape: task-owned layouts, plus the write-once v1 originals
/// keyed by directory so a directory with no shell task still keeps its origin.
nonisolated struct TaskLayoutsFile: Equatable, Codable, Sendable {
  static let currentSchemaVersion = 3

  var schemaVersion: Int
  /// Keyed by `LayoutID.persistenceKey`.
  var tasks: [String: TaskRecord]
  /// Keyed by directory (the v2 worktree key). Never read by the app.
  var origins: [String: TerminalLayoutSnapshot]
  /// A directory's most recently selected task, directory → task key. A
  /// directory with no entry resolves to the task stored under its own key.
  var activeTasks: [String: String] = [:]
  /// Entries or tabs a tolerant decode dropped; never encoded. A non-zero
  /// count marks the value as lossy, so readers and writers must reject it.
  var undecodedEntryCount = 0

  private enum CodingKeys: String, CodingKey {
    case schemaVersion
    case tasks
    case origins
    case activeTasks
    /// Always written empty: lets a pre-v3 build decode the stamp, see a newer
    /// schema and leave the blob alone instead of stashing it as corrupt.
    case worktrees
  }

  init(
    schemaVersion: Int = TaskLayoutsFile.currentSchemaVersion,
    tasks: [String: TaskRecord] = [:],
    origins: [String: TerminalLayoutSnapshot] = [:]
  ) {
    self.schemaVersion = schemaVersion
    self.tasks = tasks
    self.origins = origins
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
    // Element-wise so one rotten task drops that task, not the file.
    let rawTasks = try container.decode([String: FailableDecodable<TaskRecord>].self, forKey: .tasks)
    tasks = rawTasks.compactMapValues(\.value)
    // An origin still owns its surface ids, so a dropped one is a loss too.
    let rawOrigins =
      try container.decodeIfPresent(
        [String: FailableDecodable<TerminalLayoutSnapshot>].self, forKey: .origins) ?? [:]
    origins = rawOrigins.compactMapValues(\.value)
    // A selection hint, never an owner of sessions: an unreadable one is not a loss.
    activeTasks = (try? container.decodeIfPresent([String: String].self, forKey: .activeTasks)) ?? [:]
    let droppedContent = (decoder.userInfo[.layoutDecodeLoss] as? LayoutDecodeLoss)?.droppedCount ?? 0
    undecodedEntryCount =
      (rawTasks.count - tasks.count) + (rawOrigins.count - origins.count) + droppedContent
  }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(schemaVersion, forKey: .schemaVersion)
    try container.encode(tasks, forKey: .tasks)
    try container.encode(origins, forKey: .origins)
    if !activeTasks.isEmpty {
      try container.encode(activeTasks, forKey: .activeTasks)
    }
    try container.encode([String: String](), forKey: .worktrees)
  }

  /// Every session identity persisted anywhere in the file, origins included,
  /// so the orphan reaper can never kill a session an origin still owns.
  var allKnownSurfaceIDs: Set<UUID> {
    var ids: Set<UUID> = []
    for task in tasks.values {
      ids.formUnion(task.layout.allContentIDs.map(\.rawValue))
    }
    for origin in origins.values {
      ids.formUnion(origin.allSurfaceIDs)
    }
    return ids
  }
}

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
  /// Set once agent tabs have been split into their own tasks. A file written
  /// before the split decodes as false; a store created fresh starts true,
  /// because nothing in it predates task ownership.
  var tasksSplit = true
  /// Entries or tabs a tolerant decode dropped; never encoded. A non-zero
  /// count marks the value as lossy, so readers and writers must reject it.
  var undecodedEntryCount = 0

  private enum CodingKeys: String, CodingKey {
    case schemaVersion
    case tasks
    case origins
    case activeTasks
    case tasksSplit
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
    // The marker authorises the one-time regrouping, so only an absent one
    // means "not split". An unreadable one is counted as a loss rather than
    // thrown: a thrown decode reads as corrupt and the writer would stash the
    // whole store and start fresh.
    let marker = container.contains(.tasksSplit) ? try? container.decode(Bool.self, forKey: .tasksSplit) : false
    tasksSplit = marker ?? false
    let droppedContent = (decoder.userInfo[.layoutDecodeLoss] as? LayoutDecodeLoss)?.droppedCount ?? 0
    undecodedEntryCount =
      (rawTasks.count - tasks.count) + (rawOrigins.count - origins.count) + droppedContent
      + (marker == nil ? 1 : 0)
  }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(schemaVersion, forKey: .schemaVersion)
    try container.encode(tasks, forKey: .tasks)
    try container.encode(origins, forKey: .origins)
    if !activeTasks.isEmpty {
      try container.encode(activeTasks, forKey: .activeTasks)
    }
    if tasksSplit {
      try container.encode(true, forKey: .tasksSplit)
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

/// One agent of a task, in member order (the first is the primary). Only
/// `.session` is stored; a provisional member is an agent that has not
/// reported its session yet and holds its place until it does.
nonisolated enum TaskMember: Hashable, Sendable {
  case session(SessionKey)
  case provisional(harness: SkillAgent, surfaceID: UUID)

  var sessionKey: SessionKey? {
    guard case .session(let key) = self else { return nil }
    return key
  }
}

/// An agent presence reports on a surface, with the task that owns the surface.
nonisolated struct TaskAgent: Equatable, Sendable {
  var layoutID: LayoutID
  var harness: SkillAgent
  var surfaceID: UUID
  var sessionRef: String?
}

nonisolated enum TaskMembership {
  /// Adds every reporting agent to the task that owns its surface. A session
  /// is appended once and never removed here; a provisional member takes the
  /// session's identity in place when it arrives, and goes when its agent does.
  static func reconciled(_ members: [LayoutID: [TaskMember]], agents: [TaskAgent]) -> [LayoutID: [TaskMember]] {
    var result = members
    let ordered = agents.sorted {
      ($0.surfaceID.uuidString, $0.harness.rawValue) < ($1.surfaceID.uuidString, $1.harness.rawValue)
    }
    var waiting: Set<Waiting> = []
    for agent in ordered {
      var list = result[agent.layoutID] ?? []
      let provisional = TaskMember.provisional(harness: agent.harness, surfaceID: agent.surfaceID)
      let slot = list.firstIndex(of: provisional)
      // An unusable ref is no identity: the agent keeps waiting.
      let key = agent.sessionRef.map { SessionKey(harness: agent.harness, sessionID: $0) }
      if let key, key.isValid {
        if list.contains(.session(key)) {
          if let slot { list.remove(at: slot) }
        } else if let slot {
          list[slot] = .session(key)
        } else {
          list.append(.session(key))
        }
      } else {
        waiting.insert(Waiting(layoutID: agent.layoutID, member: provisional))
        if slot == nil { list.append(provisional) }
      }
      result[agent.layoutID] = list
    }
    for (layoutID, list) in result {
      let kept = list.filter { $0.sessionKey != nil || waiting.contains(Waiting(layoutID: layoutID, member: $0)) }
      result[layoutID] = kept.isEmpty ? nil : kept
    }
    return result
  }

  /// Stored sessions first, then whatever this run added before they loaded.
  static func merged(stored: [SessionKey], runtime: [TaskMember]) -> [TaskMember] {
    let known = stored.map(TaskMember.session)
    return known + runtime.filter { !known.contains($0) }
  }

  private struct Waiting: Hashable {
    var layoutID: LayoutID
    var member: TaskMember
  }
}

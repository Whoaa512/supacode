import Foundation

/// Branded identifier for a `TaskRecord`. Same string-backed shape as
/// `WorktreeID` / `RepositoryID` so the three are compiler-distinct, but unlike
/// those two it is *opaque*: the raw value is a generated UUID string, never
/// derived from a path or a branch. A task's identity must survive the
/// directory being re-pointed, the branch being renamed mid-task, and the
/// worktree being deleted (plan Resolved #16), so nothing about the task's
/// current location may leak into its id.
nonisolated struct TaskID: Hashable, Sendable, Codable, CustomStringConvertible {
  let rawValue: String

  init(_ rawValue: String) { self.rawValue = rawValue }

  /// Fresh opaque id. Seeding and creation are the only callers.
  init() { self.rawValue = UUID().uuidString }

  var description: String { rawValue }

  init(from decoder: any Decoder) throws {
    self.rawValue = try decoder.singleValueContainer().decode(String.self)
  }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

/// A unit of work cj is tracking, persisted to `~/.supacode/tasks.json`.
///
/// A task is a lifecycle overlay over directories and terminal surfaces, not a
/// sidebar bucket item: it outlives the worktree it started in, so it must
/// never be reconciled against live worktrees the way `SidebarState.Item` is.
///
/// Identity is `(id, directoryPath)`; `branch` is a live-observed display field
/// that a `checkout -b` mid-task is allowed to change without splitting,
/// merging, or re-keying the task.
///
/// Pure model: Foundation only. No ComposableArchitecture, no SwiftUI, no
/// filesystem access — `TaskStore` owns persistence and the reducer owns
/// lifecycle transitions.
nonisolated struct TaskRecord: Codable, Equatable, Identifiable, Sendable {
  /// Explicit user intent about settled-ness, overriding the derived cascade in
  /// either direction. Absent (`nil`) means "no override, derive it".
  nonisolated enum SettledOverride: String, Codable, Sendable, CaseIterable {
    case settled
    case active
  }

  /// Why the seeder believed this task existed, and how much to trust it. A
  /// small value rather than a framework: the seeder never fabricates a branch
  /// or an activity timestamp, so the row can render an honest low-confidence
  /// state instead of a guess (assertion A2).
  nonisolated struct SeedEvidence: Codable, Equatable, Sendable {
    nonisolated enum Source: String, Codable, Sendable, CaseIterable {
      /// Branch read from the live worktree watcher at seed time.
      case currentBranch
      /// `.git/logs/HEAD` checkout history for the directory.
      case reflog
      /// A tab/surface present in `layouts.json`.
      case layoutSnapshot
      /// Scrollback file mtime — a *last-mounted* signal only, never activity.
      case scrollbackMtime
      /// Created by the user, not inferred.
      case manual
    }

    nonisolated enum Confidence: String, Codable, Sendable, CaseIterable {
      case high
      case medium
      case low
    }

    var source: Source
    var confidence: Confidence
  }

  /// Marker for a worktree Supacode created on the task's behalf. This record is
  /// the *only* delete authority for such a directory (plan Resolved #9): git
  /// itself carries no provenance, and a filesystem marker would be a
  /// delete-authorizing artifact — the worse failure mode when stale. Written
  /// from Phase 3 onward; the field exists from day 1 so a task created by a
  /// later build is never un-decodable by an earlier one.
  nonisolated struct AutoManagedWorktree: Codable, Equatable, Sendable {
    var path: String
    /// The branch the worktree was created on. Cleanup re-checks that `path`
    /// still resolves to this branch and refuses to delete on any mismatch.
    var branch: String
    var createdAt: Date
  }

  let id: TaskID
  var title: String
  var directoryPath: String
  /// Live-observed branch, or `nil` when it isn't provable (detached HEAD,
  /// unreadable repo, folder synthetic). Never guessed.
  var branch: String?
  /// Owning repository, when the directory maps to a registered one.
  var repositoryID: Repository.ID?
  var createdAt: Date
  /// When the task moved to the settled tail. `nil` while active.
  var settledAt: Date?
  var settledOverride: SettledOverride?
  var snoozedUntil: Date?
  /// When the snooze was applied. Raised-hand rules compare event freshness
  /// against this, so it must survive independently of `snoozedUntil`.
  var snoozedAt: Date?
  var pinnedAt: Date?
  /// Last time the user opened the task. `nil` = never visited, which reads as
  /// *read* (a fresh seed of stale tasks shows zero unread pills, A28).
  var lastVisitedAt: Date?
  /// Terminal surfaces this task owns. Claims are made at tab granularity
  /// (plan Resolved #10) — claiming a tab stores every surface in its split
  /// tree — so a tab can never contain surfaces from two tasks.
  var surfaceIDs: Set<UUID>
  var seedEvidence: SeedEvidence?
  var autoManagedWorktree: AutoManagedWorktree?

  init(
    id: TaskID = TaskID(),
    title: String,
    directoryPath: String,
    branch: String? = nil,
    repositoryID: Repository.ID? = nil,
    createdAt: Date,
    settledAt: Date? = nil,
    settledOverride: SettledOverride? = nil,
    snoozedUntil: Date? = nil,
    snoozedAt: Date? = nil,
    pinnedAt: Date? = nil,
    lastVisitedAt: Date? = nil,
    surfaceIDs: Set<UUID> = [],
    seedEvidence: SeedEvidence? = nil,
    autoManagedWorktree: AutoManagedWorktree? = nil
  ) {
    self.id = id
    self.title = title
    self.directoryPath = directoryPath
    self.branch = branch
    self.repositoryID = repositoryID
    self.createdAt = createdAt
    self.settledAt = settledAt
    self.settledOverride = settledOverride
    self.snoozedUntil = snoozedUntil
    self.snoozedAt = snoozedAt
    self.pinnedAt = pinnedAt
    self.lastVisitedAt = lastVisitedAt
    self.surfaceIDs = surfaceIDs
    self.seedEvidence = seedEvidence
    self.autoManagedWorktree = autoManagedWorktree
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case title
    case directoryPath
    case branch
    case repositoryID
    case createdAt
    case settledAt
    case settledOverride
    case snoozedUntil
    case snoozedAt
    case pinnedAt
    case lastVisitedAt
    case surfaceIDs
    case seedEvidence
    case autoManagedWorktree
  }

  /// Hand-written so the decode is *additively tolerant*: unknown keys from a
  /// future schema are ignored, and a value this build can't understand (a new
  /// `SettledOverride` case, a malformed evidence object) drops that one field
  /// instead of the whole record. Only `id` / `title` / `directoryPath` /
  /// `createdAt` are load-bearing — without them there is no task to render, so
  /// a record missing them is genuinely malformed and `TaskStore` drops it.
  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.id = try container.decode(TaskID.self, forKey: .id)
    self.title = try container.decode(String.self, forKey: .title)
    self.directoryPath = try container.decode(String.self, forKey: .directoryPath)
    self.createdAt = try container.decode(Date.self, forKey: .createdAt)
    self.branch = try? container.decodeIfPresent(String.self, forKey: .branch)
    self.repositoryID = try? container.decodeIfPresent(Repository.ID.self, forKey: .repositoryID)
    self.settledAt = try? container.decodeIfPresent(Date.self, forKey: .settledAt)
    self.settledOverride = try? container.decodeIfPresent(SettledOverride.self, forKey: .settledOverride)
    self.snoozedUntil = try? container.decodeIfPresent(Date.self, forKey: .snoozedUntil)
    self.snoozedAt = try? container.decodeIfPresent(Date.self, forKey: .snoozedAt)
    self.pinnedAt = try? container.decodeIfPresent(Date.self, forKey: .pinnedAt)
    self.lastVisitedAt = try? container.decodeIfPresent(Date.self, forKey: .lastVisitedAt)
    self.surfaceIDs = (try? container.decodeIfPresent(Set<UUID>.self, forKey: .surfaceIDs)) ?? []
    self.seedEvidence = try? container.decodeIfPresent(SeedEvidence.self, forKey: .seedEvidence)
    self.autoManagedWorktree = try? container.decodeIfPresent(
      AutoManagedWorktree.self,
      forKey: .autoManagedWorktree
    )
  }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(title, forKey: .title)
    try container.encode(directoryPath, forKey: .directoryPath)
    try container.encode(createdAt, forKey: .createdAt)
    // Optional lifecycle fields are omitted when unset so `tasks.json` stays
    // readable by hand and a diff shows only what actually changed.
    try container.encodeIfPresent(branch, forKey: .branch)
    try container.encodeIfPresent(repositoryID, forKey: .repositoryID)
    try container.encodeIfPresent(settledAt, forKey: .settledAt)
    try container.encodeIfPresent(settledOverride, forKey: .settledOverride)
    try container.encodeIfPresent(snoozedUntil, forKey: .snoozedUntil)
    try container.encodeIfPresent(snoozedAt, forKey: .snoozedAt)
    try container.encodeIfPresent(pinnedAt, forKey: .pinnedAt)
    try container.encodeIfPresent(lastVisitedAt, forKey: .lastVisitedAt)
    if !surfaceIDs.isEmpty {
      try container.encode(surfaceIDs.sorted { $0.uuidString < $1.uuidString }, forKey: .surfaceIDs)
    }
    try container.encodeIfPresent(seedEvidence, forKey: .seedEvidence)
    try container.encodeIfPresent(autoManagedWorktree, forKey: .autoManagedWorktree)
  }
}

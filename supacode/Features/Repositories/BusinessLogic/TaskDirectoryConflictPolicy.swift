import Foundation

/// What creating a task in a directory another live task already owns should do.
///
/// The seam for Resolved #11 of `plans/task-inbox-sidebar-plan.md`. Phase 3b
/// answers `.share` for every directory: A19 forbids putting a worktree decision
/// in front of the user at capture time, and A3 already allows two active tasks
/// over one directory as long as they share zero surfaces. Phase 3c replaces the
/// body with the per-repository isolation setting (and the warm auto-managed
/// worktree pool that `.isolate` implies) — the call site does not move.
nonisolated enum TaskDirectoryConflictPolicy: Equatable, Sendable {
  /// Both tasks live in the same directory; the newcomer starts with no surfaces.
  case share
  /// The newcomer gets its own worktree. Unreachable until Phase 3c.
  case isolate

  static func resolve(directoryPath _: String) -> TaskDirectoryConflictPolicy {
    .share
  }
}

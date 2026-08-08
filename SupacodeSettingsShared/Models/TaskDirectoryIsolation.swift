import Foundation

/// What a repository has decided to do when a task is captured in a directory
/// another live task already owns (plan Resolved #11).
///
/// Per repository, asked once: A19 only budgets one interaction for isolation,
/// so the answer is remembered in `supacode.json` rather than re-asked per
/// capture. *Absent* is a third state — it means the repository has never been
/// asked — which is why `RepositorySettings.taskDirectoryIsolation` is optional
/// rather than defaulted at rest.
public nonisolated enum TaskDirectoryIsolation: String, CaseIterable, Codable, Equatable, Sendable,
  Identifiable
{
  /// Both tasks live in the same directory; the newcomer starts with no surfaces.
  case share
  /// The newcomer gets a Supacode-created worktree of its own.
  case isolate

  public var id: String { rawValue }

  /// What the sheet offers, and what a caller that cannot ask falls back to.
  public static let `default` = TaskDirectoryIsolation.isolate

  public var title: String {
    switch self {
    case .share:
      return "Share the directory"
    case .isolate:
      return "Create a worktree"
    }
  }

  public var detail: String {
    switch self {
    case .share:
      return "Both tasks work in the same directory. The new task starts with no terminals of its own."
    case .isolate:
      return "Supacode creates a worktree for the new task and opens a terminal there."
    }
  }
}

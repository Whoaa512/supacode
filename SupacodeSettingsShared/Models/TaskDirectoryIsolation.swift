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
  /// Both tasks work in the same directory. The newcomer still opens a terminal
  /// of its own there — what it shares is the working tree, not the session.
  case share
  /// The newcomer gets a Supacode-created worktree of its own, and opens its
  /// terminal in that.
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

  /// Both answers open a new terminal for the task; the only thing they decide
  /// is *where*. Saying otherwise (an older draft claimed sharing left the task
  /// with no terminal of its own) makes the cheaper answer read as the one that
  /// does less, which is the opposite of true.
  public var detail: String {
    switch self {
    case .share:
      return "Opens the new task's terminal in this same directory, next to the task already here."
    case .isolate:
      return "Copies this directory into a new worktree and opens the new task's terminal there."
    }
  }
}

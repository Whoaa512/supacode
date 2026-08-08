import Foundation
import SupacodeSettingsShared

/// What creating a task in a directory another live task already owns should do
/// (Resolved #11 of `plans/task-inbox-sidebar-plan.md`, plan assertion A20).
///
/// A function of two inputs and nothing else: whether the directory is owned by
/// another live task, and what this repository has already answered. No
/// filesystem, no clock, no reducer state.
///
/// `.ask` is what makes "default isolate" and "the sheet appears once"
/// compatible. An unanswered repository is not silently isolated — that would
/// spend a worktree without ever offering the user "share anyway" — it is asked,
/// with `TaskDirectoryIsolation.default` as the offered answer.
nonisolated enum TaskDirectoryConflictPolicy: Equatable, Sendable {
  /// Nobody else is in there: create in the directory the user picked. A free
  /// directory must never reach the sheet and must never mint a worktree (A19).
  case useDirectly
  /// First conflict in this repository: put the question to the user, once.
  case ask
  /// Both tasks work in the same directory. The newcomer still gets a terminal
  /// of its own there — what it shares is the working tree, not the session.
  case share
  /// The newcomer gets a Supacode-created worktree of its own, and its terminal
  /// opens in that.
  case isolate

  static func resolve(
    isDirectoryBusy: Bool,
    repositoryIsolation: TaskDirectoryIsolation?
  ) -> TaskDirectoryConflictPolicy {
    guard isDirectoryBusy else { return .useDirectly }
    switch repositoryIsolation {
    case .none:
      return .ask
    case .share:
      return .share
    case .isolate:
      return .isolate
    }
  }
}

/// The one interaction A19's budget can afford: which directory is contested,
/// who is already in it, and whether the answer should be remembered for the
/// whole repository.
///
/// Carries the capture it is blocking (`title`, `directoryURL`) so answering it
/// resumes creation without the reducer having to park a second copy of the
/// request somewhere.
nonisolated struct TaskDirectoryConflictPrompt: Equatable, Sendable, Identifiable {
  /// The typed capture title, or `nil` for an untitled one (the seeder's
  /// naming cascade fills it in later, exactly as on the un-contested path).
  var title: String?
  var directoryURL: URL
  /// Canonical spelling, the one a `TaskRecord` would store.
  var directoryPath: String
  /// The repository the worktree would be branched from. Non-optional: a
  /// directory outside every registered repository has nothing to branch from,
  /// so it never reaches the sheet.
  var repositoryID: Repository.ID
  /// Title of the live task already in the directory, when there is one to name.
  var incumbentTitle: String?
  /// Opt-in: an unchecked box answers this capture only.
  var shouldRemember = false

  var id: String { directoryPath }
}

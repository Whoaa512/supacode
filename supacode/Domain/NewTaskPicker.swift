import Foundation

/// What a picked task starts with (D3): the default agent, or a plain shell.
nonisolated enum NewTaskKind: Equatable, Sendable {
  case agent
  case shell
}

/// Where a new task's first tab was asked for. It crosses the launch boundary
/// in place of a resolved directory: the manager re-derives the directory on
/// current state when the command lands, by the route's own rule. Neither
/// route falls back to the other's.
nonisolated enum NewTaskSource: Equatable, Sendable {
  /// A roster row (picker, "New task here", a path that names one): the
  /// directory must still be a live roster entry at delivery.
  case roster(Worktree.ID)
  /// Cmd-N on a task: that task's directory as it is at delivery, while the
  /// task still exists.
  case task(LayoutID)
}

/// A roster directory the new-task picker can start a task on. A snapshot
/// taken when the picker opens: only `id` is trusted at confirm time, the
/// rest is display.
nonisolated struct NewTaskDirectory: Equatable, Identifiable, Sendable {
  let id: Worktree.ID
  let name: String
  /// `nil` for a folder.
  let repositoryName: String?
  /// Remote: the remote path. Local: the tilde-abbreviated path.
  let path: String
  /// Absolute local path, `nil` for a remote directory.
  let localPath: String?
  /// `host.displayAuthority`, `nil` for a local directory.
  let hostLabel: String?

  var searchText: String {
    [repositoryName, name, hostLabel, path].compactMap { $0 }.joined(separator: " ")
  }
}

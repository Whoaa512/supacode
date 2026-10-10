import Foundation

/// What a picked task starts with (D3): the default agent, or a plain shell.
nonisolated enum NewTaskKind: Equatable, Sendable {
  case agent
  case shell
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

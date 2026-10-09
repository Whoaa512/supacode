import Foundation
import SupacodeSettingsShared

/// The directory facts the terminal layer needs from a worktree, so a layout
/// can be hosted without holding the `Worktree` itself.
nonisolated struct DirectoryContext: Hashable, Sendable {
  let worktreeID: Worktree.ID
  let repositoryID: Repository.ID
  let name: String
  /// Display / env-var working-directory URL. For a remote worktree this is a
  /// synthetic `file://` over the remote path; never hand it to FileManager.
  let workingDirectory: URL
  let repositoryRootURL: URL
  /// SSH host the directory lives on, or `nil` for a local one.
  let host: RemoteHost?

  init(worktree: Worktree) {
    self.worktreeID = worktree.id
    self.repositoryID = Self.repositoryID(for: worktree.location.repositoryLocation)
    self.name = worktree.name
    self.workingDirectory = worktree.workingDirectory
    self.repositoryRootURL = worktree.repositoryRootURL
    self.host = worktree.host
  }

  /// A task whose directory is no roster worktree (deleted outside the app, or
  /// its repository removed) is still shown: the id it was recorded under is
  /// the directory's path, and stands in for the repository too.
  init(orphan directory: TaskRecord.Directory) {
    let location = RepositoryLocation.parse(persistedID: directory.worktreeID.rawValue)
    let path =
      switch location {
      case .local(let url): url.standardizedFileURL.path(percentEncoded: false)
      case .remote(_, let path): path
      case nil: directory.worktreeID.rawValue
      }
    let url = URL(fileURLWithPath: path)
    self.worktreeID = directory.worktreeID
    self.repositoryID = RepositoryID(location?.host == nil ? path : directory.worktreeID.rawValue)
    self.name = url.lastPathComponent.isEmpty ? path : url.lastPathComponent
    self.workingDirectory = url
    self.repositoryRootURL = url
    self.host = directory.host ?? location?.host
  }

  /// Base environment variables for Supacode scripts (supplemented per-surface).
  var scriptEnvironment: [String: String] {
    [
      "SUPACODE_WORKTREE_PATH": workingDirectory.path(percentEncoded: false),
      "SUPACODE_ROOT_PATH": repositoryRootURL.path(percentEncoded: false),
    ]
  }

  // Standardized to match `loadFailuresByID` keys (built from
  // `standardizedFileURL.path`) so prune protection lines up.
  private static func repositoryID(for location: RepositoryLocation) -> Repository.ID {
    switch location {
    case .local(let url):
      RepositoryID(url.standardizedFileURL.path(percentEncoded: false))
    case .remote:
      location.id
    }
  }
}

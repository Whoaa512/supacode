import Foundation

@testable import SupacodeSettingsShared
@testable import supacode

extension Worktree {
  /// Test convenience: a git worktree without the explicit `kind` the production
  /// initializers now require. Folder tests pass `kind: .folder` directly.
  init(
    id: WorktreeID,
    name: String,
    detail: String,
    workingDirectory: URL,
    repositoryRootURL: URL,
    createdAt: Date? = nil,
    isMissing: Bool = false,
    isAttached: Bool = true,
    host: RemoteHost? = nil
  ) {
    self.init(
      id: id,
      kind: .git,
      name: name,
      detail: detail,
      workingDirectory: workingDirectory,
      repositoryRootURL: repositoryRootURL,
      createdAt: createdAt,
      isMissing: isMissing,
      isAttached: isAttached,
      host: host
    )
  }
}

// Tests address a layout by the legacy key of its directory, the same id the
// app's resolver seam hands out.
extension WorktreeID {
  var layoutID: LayoutID { LayoutID(legacyWorktreeKey: rawValue) }
}

extension Worktree {
  var layoutID: LayoutID { id.layoutID }
}

extension LayoutID: @retroactive ExpressibleByStringLiteral {
  public init(stringLiteral value: String) { self.init(legacyWorktreeKey: value) }
}

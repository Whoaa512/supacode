import Foundation
import IdentifiedCollections

@testable import SupacodeSettingsFeature
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

// Tests address a layout by the legacy key of its directory: the own-key
// task a migrated directory keeps. It is a task only once seeded as one
// (`seedTask`); the app never derives it from the directory.
extension WorktreeID {
  var layoutID: LayoutID { LayoutID(legacyWorktreeKey: rawValue) }
}

extension AppFeature.State {
  /// Seeds a task properly: a layout holding one tab, and the record that puts
  /// it on the directory. Without the record a layout is no directory's task.
  @discardableResult
  mutating func seedTask(
    _ layoutID: LayoutID, on directoryID: Worktree.ID, tabID: TabID = TabID(), surfaceID: UUID? = nil,
    host: RemoteHost? = nil
  ) -> LayoutID {
    let paneID = PaneID()
    let tab = TabItem(
      id: tabID, title: "shell",
      content: ContentSnapshot(
        id: ContentID(rawValue: surfaceID ?? tabID.rawValue),
        state: .terminal(TerminalContentState(workingDirectory: nil))))
    terminals.layouts[id: layoutID] = LayoutFeature.State(
      id: layoutID,
      layout: PaneLayout(
        tree: SplitTree(view: paneID), panes: [Pane(id: paneID, tabs: [tab], selectedTabID: tab.id)],
        focusedPaneID: paneID))
    terminals.directories[layoutID] = TaskRecord.Directory(worktreeID: directoryID, host: host)
    return layoutID
  }

  /// The shape most suites were written against: the roster, with the
  /// directory's own-key task seeded so a bare command on it lands there.
  static func seeded(
    repositories: RepositoriesFeature.State, settings: SettingsFeature.State, ownKeyTaskOn worktree: Worktree
  ) -> AppFeature.State {
    seeded(repositories: repositories, settings: settings, ownKeyTasksOn: [worktree])
  }

  static func seeded(
    repositories: RepositoriesFeature.State, settings: SettingsFeature.State, ownKeyTasksOn worktrees: [Worktree]
  ) -> AppFeature.State {
    var state = AppFeature.State(repositories: repositories, settings: settings)
    for worktree in worktrees { state.seedOwnKeyTask(on: worktree) }
    return state
  }

  /// Seeds the directory's own-key task: what a migrated directory shows.
  @discardableResult
  mutating func seedOwnKeyTask(on worktree: Worktree, tabID: TabID = TabID(), surfaceID: UUID? = nil) -> LayoutID {
    seedTask(worktree.layoutID, on: worktree.id, tabID: tabID, surfaceID: surfaceID, host: worktree.host)
  }
}

extension Worktree {
  var layoutID: LayoutID { id.layoutID }
}

extension LayoutID: @retroactive ExpressibleByStringLiteral {
  public init(stringLiteral value: String) { self.init(legacyWorktreeKey: value) }
}

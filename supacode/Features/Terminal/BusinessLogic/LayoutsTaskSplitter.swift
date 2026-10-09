import Foundation
import IdentifiedCollections
import SupacodeSettingsShared

/// Splits v2 per-directory layouts into v3 task-owned ones: every agent tab
/// becomes its own task, the leftover tabs of a directory stay together as one
/// shell-only task under the directory's legacy id. Pure; moves tabs, never
/// drops or re-identifies a tab or its content.
nonisolated enum LayoutsTaskSplitter {
  static func split(
    _ file: LayoutsFile,
    now: Date,
    makeUUID: () -> UUID = { UUID() }
  ) -> TaskLayoutsFile {
    var result = TaskLayoutsFile()
    result.undecodedEntryCount = file.undecodedEntryCount
    // Sorted so injected ids land on the same tabs every run.
    for (key, record) in file.worktrees.sorted(by: { $0.key < $1.key }) {
      if let origin = record.origin {
        result.origins[key] = origin
      }
      let directory = directory(forLegacyKey: key)
      for pane in record.layout.panes {
        for tab in pane.tabs where isAgentTab(tab) {
          let task = TaskRecord(
            id: LayoutID(task: makeUUID()),
            directory: directory,
            layout: singlePaneLayout(tab, paneID: PaneID(rawValue: makeUUID())),
            sessions: sessions(of: tab),
            createdAt: now
          )
          result.tasks[task.id.persistenceKey] = task
        }
      }
      let leftover = TerminalRestorePruner.prunedLayout(record.layout) { content in
        !hasAgentRecord(content)
      }
      guard let leftover else { continue }
      result.tasks[key] = TaskRecord(
        id: LayoutID(legacyWorktreeKey: key),
        directory: directory,
        layout: leftover,
        createdAt: now
      )
    }
    return result
  }

  /// A v2 key is a worktree id: a local absolute path, or `<authority><path>` for a remote one.
  static func directory(forLegacyKey key: String) -> TaskRecord.Directory {
    TaskRecord.Directory(
      worktreeID: WorktreeID(key),
      host: RepositoryLocation.parse(persistedID: key)?.host
    )
  }

  private static func isAgentTab(_ tab: TabItem) -> Bool {
    hasAgentRecord(tab.content)
  }

  /// Dead-flagged records count: a resumable agent tab must not fold into a shell task.
  private static func hasAgentRecord(_ content: ContentSnapshot) -> Bool {
    guard case .terminal(let state) = content.state else { return false }
    return state.agents?.isEmpty == false
  }

  private static func sessions(of tab: TabItem) -> [SessionKey] {
    guard case .terminal(let state) = tab.content.state else { return [] }
    var keys: [SessionKey] = []
    for record in state.agents ?? [] {
      guard let ref = record.sessionRef else { continue }
      let key = SessionKey(rawValue: "\(record.agent):\(ref)")
      guard key.isValid, !keys.contains(key) else { continue }
      keys.append(key)
    }
    return keys
  }

  private static func singlePaneLayout(_ tab: TabItem, paneID: PaneID) -> PaneLayout {
    PaneLayout(
      tree: SplitTree(view: paneID),
      panes: [Pane(id: paneID, tabs: [tab], selectedTabID: tab.id)],
      focusedPaneID: paneID
    )
  }
}

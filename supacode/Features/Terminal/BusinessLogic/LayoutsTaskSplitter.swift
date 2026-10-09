import Foundation
import IdentifiedCollections
import SupacodeSettingsShared

/// Splits per-directory layouts into task-owned ones: every agent tab becomes
/// its own task, the leftover tabs of a task stay together as one shell-only
/// task under the id they already had. Pure; moves tabs, never drops or
/// re-identifies a tab or its content.
nonisolated enum LayoutsTaskSplitter {
  static func split(
    _ file: LayoutsFile,
    now: Date,
    makeUUID: () -> UUID = { UUID() }
  ) -> TaskLayoutsFile {
    split(TaskLayoutsFile(oneTaskPerDirectory: file), now: now, makeUUID: makeUUID)
  }

  /// Splits an unsplit v3 file. Origins stay with their directory. A
  /// directory follows the task that took its focused tab, and one left with
  /// no task under its own key follows its first agent task whatever its hint
  /// said, so it never resolves to a task that does not exist or that sits on
  /// another directory.
  static func split(
    _ file: TaskLayoutsFile,
    now: Date,
    makeUUID: () -> UUID = { UUID() }
  ) -> TaskLayoutsFile {
    var result = file
    result.tasksSplit = true
    // Directories whose own-key task the split removes, and a task each can fall back on.
    var fallbacks: [String: LayoutID] = [:]
    // Sorted so injected ids land on the same tabs every run.
    for (key, record) in file.tasks.sorted(by: { $0.key < $1.key }) where !isAlreadySplit(record) {
      var minted: [LayoutID] = []
      var focused: LayoutID?
      for pane in record.layout.panes {
        for tab in pane.tabs where isAgentTab(tab) {
          let task = TaskRecord(
            id: LayoutID(task: makeUUID()),
            directory: record.directory,
            layout: singlePaneLayout(tab, paneID: PaneID(rawValue: makeUUID())),
            sessions: sessions(of: tab),
            createdAt: now
          )
          result.tasks[task.id.persistenceKey] = task
          minted.append(task.id)
          if pane.id == record.layout.focusedPaneID, pane.selectedTabID == tab.id {
            focused = task.id
          }
        }
      }
      let leftover = TerminalRestorePruner.prunedLayout(record.layout) { content in
        !hasAgentRecord(content)
      }
      result.tasks[key] = leftover.map { layout in
        var shell = record
        shell.layout = layout
        // A mapped v2 record never had a date; the split is when it became a task.
        if shell.createdAt == TaskRecord.legacyCreatedAt { shell.createdAt = now }
        return shell
      }
      let directory = record.directory.worktreeID.rawValue
      if key == directory, leftover == nil { fallbacks[directory] = minted.first }
      // A hint naming no task on this directory reads as no hint, as it does at hydration.
      let hint = file.activeTasks[directory].flatMap { isTask($0, in: file, onDirectory: directory) ? $0 : nil }
      guard (hint ?? directory) == key,
        let active = focused ?? (leftover == nil ? minted.first : nil)
      else { continue }
      result.activeTasks[directory] = active.persistenceKey
    }
    result.activeTasks = result.activeTasks.filter { isTask($0.value, in: result, onDirectory: $0.key) }
    for (directory, task) in fallbacks where result.activeTasks[directory] == nil {
      result.activeTasks[directory] = task.persistenceKey
    }
    return result
  }

  static func isTask(_ key: String, in file: TaskLayoutsFile, onDirectory directory: String) -> Bool {
    file.tasks[key]?.directory.worktreeID.rawValue == directory
  }

  /// A minted task holding exactly one agent tab is what a split produces. Left
  /// alone so a store that lost its marker (rewritten by an older build) is
  /// not re-identified, which would drop the task's sessions.
  private static func isAlreadySplit(_ record: TaskRecord) -> Bool {
    guard record.id.persistenceKey != record.directory.worktreeID.rawValue,
      record.layout.panes.count == 1, let pane = record.layout.panes.first,
      pane.tabs.count == 1, let tab = pane.tabs.first
    else { return false }
    return isAgentTab(tab)
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

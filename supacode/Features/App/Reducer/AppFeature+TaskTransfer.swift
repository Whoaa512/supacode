import ComposableArchitecture
import Foundation
import SupacodeSettingsShared

extension AppFeature {
  /// Why a merge or detach is not sent, or why the terminal layer refused it.
  enum TaskTransferRefusal: Error, Equatable, Sendable {
    /// The tab the task's primary session runs on (Q8: merge the other way).
    case primaryTab
    /// The task's only tab, with no session that would keep the task.
    case onlyTab
    /// A launch into the source whose tab has not appeared yet.
    case launchPending
    case runtime(TabTransferRefusal)

    var message: String {
      switch self {
      case .primaryTab: "The primary session can't be detached. Merge the other way instead."
      case .onlyTab: "This is the task's only tab."
      case .launchPending: "A session is still starting in this task."
      case .runtime(.differentMachine): "Tasks on different hosts can't be merged."
      case .runtime(.confirmationPending): "Answer the close confirmation first."
      case .runtime(.scriptRunning): "Wait for the running script to finish."
      case .runtime(.notReady): "Tasks are still loading."
      case .runtime(.quitting): "Supacode is quitting."
      case .runtime: "That task is no longer available."
      }
    }
  }

  /// The sessions presence reports on a surface right now, by harness.
  static func sessions(onSurface surfaceID: UUID, state: State) -> [SessionKey] {
    let keys: [SessionKey] = state.agentPresence.records.compactMap { key, record in
      guard key.surfaceID == surfaceID, let ref = record.sessionRef else { return nil }
      return SessionKey(harness: key.agent, sessionID: ref)
    }
    return keys.sorted { $0.rawValue < $1.rawValue }
  }

  /// The members that ride on a tab: the sessions reporting on its surface
  /// and any provisional member waiting there, in member order.
  static func members(onSurface surfaceID: UUID, of layoutID: LayoutID, state: State) -> [TaskMember] {
    let keys = Set(sessions(onSurface: surfaceID, state: state))
    return (state.terminals.members[layoutID] ?? []).filter { member in
      switch member {
      case .session(let key): keys.contains(key)
      case .provisional(_, let surface): surface == surfaceID
      }
    }
  }

  static func mergeRefusal(_ source: LayoutID, into target: LayoutID, state: State) -> TaskTransferRefusal? {
    guard let destination = state.terminals.directories[target] else { return .runtime(.unknownDestination) }
    if let reason = state.terminals.transferRefusal(from: source, into: target, scope: .all, destination: destination) {
      return .runtime(reason)
    }
    return state.pendingTaskLaunches.contains { $0.layoutID == source } ? .launchPending : nil
  }

  /// The detach the state allows now: the new task's directory and the
  /// members moving, or why not.
  static func detachPlan(
    _ source: LayoutID, tabID: TabID, into target: LayoutID, state: State
  ) -> Result<(directory: TaskRecord.Directory, members: [TaskMember]), TaskTransferRefusal> {
    guard let directory = state.terminals.directories[source],
      let layout = state.terminals.layouts[id: source]?.layout,
      let tab = layout.pane(containingTab: tabID)?.tabs[id: tabID]
    else { return .failure(.runtime(.unknownTab)) }
    let members = state.terminals.members[source] ?? []
    let moving = Self.members(onSurface: tab.content.id.rawValue, of: source, state: state)
    if let primary = members.first, moving.contains(primary) { return .failure(.primaryTab) }
    let kept = members.filter { !moving.contains($0) }
    if layout.allContentIDs.count == 1, !kept.contains(where: { $0.sessionKey != nil }) { return .failure(.onlyTab) }
    if let reason = state.terminals.transferRefusal(
      from: source, into: target, scope: .tab(tabID, members: moving), destination: directory)
    {
      return .failure(.runtime(reason))
    }
    if state.pendingTaskLaunches.contains(where: { $0.layoutID == source }) { return .failure(.launchPending) }
    return .success((directory, moving))
  }

  static func mergeTask(_ source: LayoutID, into target: LayoutID, state: State) -> Effect<Action> {
    @Dependency(TerminalClient.self) var terminalClient
    if let refusal = mergeRefusal(source, into: target, state: state) { return toast(refusal) }
    guard let directory = state.terminals.directories[target] else { return toast(.runtime(.unknownDestination)) }
    let context = directoryContext(forTask: target, directoryID: directory.worktreeID, state: state)
    return .run { _ in
      await terminalClient.send(.transferTabs(from: source, into: target, context, scope: .all))
    }
  }

  static func detachTab(_ source: LayoutID, tabID: TabID, state: State) -> Effect<Action> {
    @Dependency(TerminalClient.self) var terminalClient
    @Dependency(\.uuid) var uuid
    let minted = LayoutID(task: uuid())
    switch detachPlan(source, tabID: tabID, into: minted, state: state) {
    case .failure(let refusal):
      return toast(refusal)
    case .success(let plan):
      let context = directoryContext(forTask: source, directoryID: plan.directory.worktreeID, state: state)
      return .run { _ in
        await terminalClient.send(
          .transferTabs(from: source, into: minted, context, scope: .tab(tabID, members: plan.members)))
      }
    }
  }

  /// The focused pane's selected tab of the shown task.
  static func detachFocusedTab(state: State) -> Effect<Action> {
    guard let layoutID = state.terminals.selectedLayoutID,
      let layout = state.terminals.layouts[id: layoutID]?.layout,
      let pane = layout.panes.first(where: { $0.id == layout.focusedPaneID }),
      let tabID = pane.selectedTabID
    else { return toast(.runtime(.unknownTab)) }
    return .send(.detachTab(layoutID, tabID: tabID))
  }

  /// The moved tabs' task is the one to show: the merge target, or the task
  /// a detach minted. It holds tabs now, so nothing is bootstrapped into it.
  static func tabsTransferred(into target: LayoutID, state: State) -> Effect<Action> {
    guard let directory = state.terminals.directories[target] else { return .none }
    return focusTask(target, directoryID: directory.worktreeID, state: state)
  }

  private static func toast(_ refusal: TaskTransferRefusal) -> Effect<Action> {
    .send(.repositories(.showToast(.info(refusal.message))))
  }
}

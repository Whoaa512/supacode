import ComposableArchitecture
import Foundation
import SupacodeSettingsShared

extension TabTransferRefusal {
  var message: String {
    switch self {
    case .primaryTab: "The primary session can't be detached. Merge the other way instead."
    case .onlyTab: "This is the task's only tab."
    case .launchPending: "A session is still starting in this task."
    case .differentMachine: "Tasks on different hosts can't be merged."
    case .confirmationPending: "Answer the close confirmation first."
    case .scriptRunning: "Wait for the running script to finish."
    case .notReady: "Tasks are still loading."
    case .quitting: "Supacode is quitting."
    default: "That task is no longer available."
    }
  }
}

extension AppFeature {
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

  /// The transfer the state allows now: what the terminal layer moves, or
  /// why not. Decided twice on the same state-only function: when the user
  /// asks, for the toast, and again by the manager in the turn that moves
  /// the tabs. Nothing decided here is carried across the effect in between,
  /// so an agent that started on the tab, a tab that closed or a launch into
  /// the source since the request is seen, not moved around.
  static func transferPlan(
    from source: LayoutID, into target: LayoutID, request: TabTransferRequest,
    destination: TaskRecord.Directory, state: State
  ) -> Result<TabTransferScope, TabTransferRefusal> {
    let scope: TabTransferScope
    switch request {
    case .all:
      scope = .all
    case .tab(let tabID):
      guard let layout = state.terminals.layouts[id: source]?.layout,
        let tab = layout.pane(containingTab: tabID)?.tabs[id: tabID]
      else { return .failure(.unknownTab) }
      let members = state.terminals.members[source] ?? []
      let moving = Self.members(onSurface: tab.content.id.rawValue, of: source, state: state)
      if let primary = members.first, moving.contains(primary) { return .failure(.primaryTab) }
      let kept = members.filter { !moving.contains($0) }
      if layout.allContentIDs.count == 1, !kept.contains(where: { $0.sessionKey != nil }) {
        return .failure(.onlyTab)
      }
      scope = .tab(tabID, members: moving)
    }
    let terminals = state.terminals
    if let reason = terminals.transferRefusal(from: source, into: target, scope: scope, destination: destination) {
      return .failure(reason)
    }
    if state.pendingTaskLaunches.contains(where: { $0.layoutID == source }) { return .failure(.launchPending) }
    return .success(scope)
  }

  static func mergeTask(_ source: LayoutID, into target: LayoutID, state: State) -> Effect<Action> {
    @Dependency(TerminalClient.self) var terminalClient
    guard let directory = state.terminals.directories[target] else { return toast(.unknownDestination) }
    if case .failure(let refusal) = transferPlan(
      from: source, into: target, request: .all, destination: directory, state: state)
    {
      return toast(refusal)
    }
    let context = directoryContext(forTask: target, directoryID: directory.worktreeID, state: state)
    return .run { _ in
      await terminalClient.send(.transferTabs(from: source, into: target, context, request: .all))
    }
  }

  static func detachTab(_ source: LayoutID, tabID: TabID, state: State) -> Effect<Action> {
    @Dependency(TerminalClient.self) var terminalClient
    @Dependency(\.uuid) var uuid
    guard let directory = state.terminals.directories[source] else { return toast(.unknownSource) }
    let minted = LayoutID(task: uuid())
    if case .failure(let refusal) = transferPlan(
      from: source, into: minted, request: .tab(tabID), destination: directory, state: state)
    {
      return toast(refusal)
    }
    let context = directoryContext(forTask: source, directoryID: directory.worktreeID, state: state)
    return .run { _ in
      await terminalClient.send(.transferTabs(from: source, into: minted, context, request: .tab(tabID)))
    }
  }

  /// The focused pane's selected tab of the shown task.
  static func detachFocusedTab(state: State) -> Effect<Action> {
    guard let layoutID = state.terminals.selectedLayoutID,
      let layout = state.terminals.layouts[id: layoutID]?.layout,
      let pane = layout.panes.first(where: { $0.id == layout.focusedPaneID }),
      let tabID = pane.selectedTabID
    else { return toast(.unknownTab) }
    return .send(.detachTab(layoutID, tabID: tabID))
  }

  /// The moved tabs' task is the one to show: the merge target, or the task
  /// a detach minted. Only its identity crosses to the manager, which checks
  /// at delivery that it still holds tabs; a second transfer or a close in
  /// between leaves it alone.
  static func tabsTransferred(into target: LayoutID, state: State) -> Effect<Action> {
    guard let directory = state.terminals.directories[target] else { return .none }
    return focusTask(target, directoryID: directory.worktreeID, state: state)
  }

  private static func toast(_ refusal: TabTransferRefusal) -> Effect<Action> {
    .send(.repositories(.showToast(.info(refusal.message))))
  }
}

import ComposableArchitecture
import Foundation
import SupacodeSettingsShared

struct PendingSessionLaunch: Equatable {
  let key: SessionKey
  let cwd: URL
  let command: String
  let requestID: UUID
  var launched: Bool = false
  var probing: Bool = false
  /// A brand-new agent rather than the resume of a known session.
  var isNewSession: Bool = false
}

/// A task a launch targeted whose first tab has not appeared yet. A launch
/// is free to start as soon as the previous one's command is sent, so several
/// can be waiting at once.
struct PendingTaskLaunch: Equatable {
  let layoutID: LayoutID
  let directoryID: Worktree.ID
  /// The session a resume minted the task for: its primary, listed once the
  /// task exists. A launch whose tab never appears lists nothing.
  var primary: SessionKey?
  /// Only the latest launch is shown when its tab appears. Selecting it
  /// earlier would bootstrap a plain shell tab into it.
  var isShown = true
}

struct PendingBranchMismatchResume: Equatable {
  let key: SessionKey
  let cwd: URL
  let command: String
  let recordedBranch: String
  let currentBranch: String
  var isProvisionalConflict: Bool = false
}

struct PreparedSessionResume: Equatable {
  let key: SessionKey
  let cwd: URL
  let command: String
}

struct BranchCaptureRequest: Equatable {
  let key: SessionKey
  let cwd: URL
}

extension AppFeature {
  static func focusedSurfaceID(state: State) -> UUID? {
    guard let selectedLayoutID = state.terminals.selectedLayoutID,
      let layout = state.terminals.layouts[id: selectedLayoutID]?.layout,
      let focusedPane = layout.panes.first(where: { $0.id == layout.focusedPaneID }),
      let selectedTab = focusedPane.tabs.first(where: { $0.id == focusedPane.selectedTabID })
    else { return nil }
    return selectedTab.content.id.rawValue
  }

  static func focusedSessionRowID(state: State) -> SessionRowID? {
    guard let surfaceID = focusedSurfaceID(state: state) else { return nil }
    let layoutID = state.terminals.selectedLayoutID
    let taskRow = layoutID.flatMap { state.repositories.sessionItems[id: .task($0)]?.id }
    if let id = state.repositories.sessionSnapshots.first(where: { $0.location.surfaceID == surfaceID })?.id {
      // A session two tasks report has one row, and it leads to the other task.
      if let taskRow, let location = state.repositories.sessionItems[id: id]?.location,
        location.layoutID != layoutID
      {
        return taskRow
      }
      return id
    }
    // No agent on the focused surface: the row is the task's own, when it has one.
    return taskRow
  }

  /// The directory facts for a task: the roster worktree's, else what the task
  /// itself recorded, so a task on a directory the roster no longer lists is
  /// still shown.
  static func directoryContext(forTask layoutID: LayoutID, directoryID: Worktree.ID, state: State) -> DirectoryContext {
    if let worktree = state.repositories.worktree(for: directoryID) { return DirectoryContext(worktree: worktree) }
    let recorded = state.terminals.directories[layoutID] ?? storedTask(layoutID, state: state)?.directory
    return DirectoryContext(orphan: recorded ?? TaskRecord.Directory(worktreeID: directoryID))
  }

  /// Shows the task that owns the session and focuses its surface. The layout
  /// is the location's own, never the directory's active task.
  static func focusSession(_ location: SessionLocation, state: State) -> Effect<Action> {
    @Dependency(TerminalClient.self) var terminalClient
    let context = directoryContext(forTask: location.layoutID, directoryID: location.directoryID, state: state)
    return .merge(
      .send(.repositories(.selectTask(location.layoutID, directory: location.directoryID))),
      .run { @MainActor _ in
        terminalClient.focusSurface(location.layoutID, context, location.tabID, location.surfaceID)
      }
    )
  }

  /// Shows a task with whatever it had focused. Only reached for a task that
  /// already holds tabs, so the bootstrap half of the command never fires.
  static func focusTask(_ layoutID: LayoutID, directoryID: Worktree.ID, state: State) -> Effect<Action> {
    @Dependency(TerminalClient.self) var terminalClient
    let context = directoryContext(forTask: layoutID, directoryID: directoryID, state: state)
    return .concatenate(
      .send(.repositories(.selectTask(layoutID, directory: directoryID))),
      .run { _ in
        await terminalClient.send(
          .ensureInitialTab(layoutID, context, runSetupScriptIfNew: false, focusing: true))
      }
    )
  }

  /// Rows are rebuilt from tasks, so a selected task that no longer exists is dropped here.
  static func hasTask(_ layoutID: LayoutID, state: State) -> Bool {
    state.terminals.layouts[id: layoutID] != nil || storedTask(layoutID, state: state) != nil
  }

  /// Whether a task holds a tab on this directory: by its layout once it
  /// has one this run, else by its stored record.
  static func taskHoldsTabs(_ layoutID: LayoutID, onDirectory directoryID: Worktree.ID, state: State) -> Bool {
    guard state.terminals.layouts[id: layoutID] == nil else {
      return state.terminals.isTask(layoutID, onDirectory: directoryID)
    }
    guard let stored = storedTask(layoutID, state: state) else { return false }
    return stored.directory.worktreeID == directoryID && stored.layout.panes.contains { !$0.tabs.isEmpty }
  }

  /// The stored tasks as read at launch, less the ones removed since: the
  /// file is never re-read, so it still lists a task this run deleted.
  static func storedTasks(state: State) -> [TaskRecord] {
    let removed = state.terminals.removedLayoutIDs
    return state.repositories.persistedLayouts.tasks.values.filter { !removed.contains($0.id) }
  }

  static func storedTask(_ layoutID: LayoutID, state: State) -> TaskRecord? {
    guard !state.terminals.removedLayoutIDs.contains(layoutID) else { return nil }
    return state.repositories.persistedLayouts.tasks[layoutID.persistenceKey]
  }

  /// The sidebar highlight follows the focused tab. It only moves when the
  /// focused session does, so arrowing through dormant rows is not yanked back.
  static func syncSessionSelectionToFocus(state: inout State) {
    let rowID = focusedSessionRowID(state: state)
    // Until the row exists nothing is recorded, so the next pass retries.
    if let rowID, state.repositories.sessionItems[id: rowID] == nil { return }
    guard rowID != state.lastFocusedSessionRowID else { return }
    state.lastFocusedSessionRowID = rowID
    if state.repositories.sessionSelection != rowID { state.repositories.sessionSelection = rowID }
  }

  var sessionsLinkReducer: some Reducer<State, Action> {
    @Dependency(TerminalClient.self) var terminalClient
    return Reduce { state, action in
      switch action {
      case .agentPresence(.restoreFromSnapshotChecked):
        let tasks = Self.taskEntries(state: state)
        let index = Self.surfaceIndex(tasks: tasks)
        let snapshots = Self.sessionSnapshots(state: state, index: index)
        return .concatenate(
          Self.membershipEffect(state: state, index: index) ?? .none,
          .send(.repositories(.sessionSnapshotsChanged(snapshots))),
          .send(.repositories(.taskSnapshotsChanged(Self.taskSnapshots(tasks: tasks)))),
          // Ahead of the auto-settle pass below, which judges tasks as a whole.
          .send(
            .repositories(
              .taskSessionsChanged(
                Self.taskSessions(
                  TaskMembership.reconciled(
                    state.terminals.members, agents: Self.taskAgents(state: state, index: index)))))),
          .send(
            .repositories(
              .sessionsRestorationCompleted(
                Self.liveSessionKeys(state: state),
                hasUnresolvedLivePresence: Self.hasUnresolvedLivePresence(state: state, index: index)))))

      case .repositories(.sessionSnapshotsChanged):
        Self.syncSessionSelectionToFocus(state: &state)
        return .none

      case .agentPresence(.delegate(.surfacesChanged)), .terminals,
        .repositories(.delegate(.repositoriesChanged)):
        Self.syncSessionSelectionToFocus(state: &state)
        var effects: [Effect<Action>] = []
        if let settled = Self.taskClosedForSettle(action, state: state),
          let primary = Self.primarySession(of: settled, state: state)
        {
          effects.append(.send(.repositories(.settleSession(primary))))
        }
        let keys = Self.liveSessionKeys(state: state)
        let tasks = Self.taskEntries(state: state)
        let index = Self.surfaceIndex(tasks: tasks)
        let unresolved = Self.hasUnresolvedLivePresence(state: state, index: index)
        if keys != state.repositories.sessionsLiveKeys
          || unresolved != state.repositories.sessionsHasUnresolvedLivePresence
        {
          effects.append(.send(.repositories(.sessionsLiveKeysChanged(keys, hasUnresolvedLivePresence: unresolved))))
        }
        let snapshots = Self.sessionSnapshots(state: state, index: index)
        if snapshots != state.repositories.sessionSnapshots {
          effects.append(.send(.repositories(.sessionSnapshotsChanged(snapshots))))
        }
        let taskRows = Self.taskSnapshots(tasks: tasks)
        if taskRows != state.repositories.taskSnapshots {
          effects.append(.send(.repositories(.taskSnapshotsChanged(taskRows))))
        }
        let taskSessions = Self.taskSessions(state.terminals.members)
        if taskSessions != state.repositories.taskSessions {
          effects.append(.send(.repositories(.taskSessionsChanged(taskSessions))))
        }
        if let selected = state.repositories.selectedTask, !Self.hasTask(selected.id, state: state) {
          effects.append(.send(.repositories(.selectedTaskRemoved)))
        }
        var members = state.terminals.members
        let selection = Self.showLaunchedTaskIfReady(state: &state, members: &members)
        if let membership = Self.membershipEffect(state: state, index: index, members: members) {
          effects.append(membership)
        }
        if let selection { effects.append(selection) }
        if let pending = state.pendingSessionLaunch,
          !pending.launched, !pending.probing, state.pendingBranchMismatchResume == nil,
          case .repositories(.delegate(.repositoriesChanged)) = action,
          let effect = Self.launchPendingSessionIfReady(pending: pending, state: &state)
        {
          effects.append(effect)
        }
        guard !effects.isEmpty else { return .none }
        return .merge(effects)

      case .repositories(.delegate(.settleAndCloseSession(let key))):
        return Self.settleAndCloseSession(key, state: state)

      case .repositories(.delegate(.resumeSession(let key))):
        return Self.handleResumeSession(key, state: &state)

      case .resumeBranchProbeCompleted(let requestID, let currentBranch):
        return Self.finishResumeBranchProbe(
          requestID: requestID, currentBranch: currentBranch, state: &state)

      case .launchSessionCompleted(let requestID):
        @Dependency(\.date) var date
        guard let pending = state.pendingSessionLaunch, pending.requestID == requestID
        else { return .none }
        let key = pending.key
        state.recentSessionLaunchDate[key] = date.now
        state.pendingSessionLaunch = nil
        guard state.repositories.sessionItems[id: .session(key)]?.lifecycle == .settled
        else { return .none }
        return .send(.repositories(.unsettleSession(key)))

      case .terminalEvent(.agentHookEventReceived(let event)):
        // An agent running inside the surface's own is not its session:
        // nothing here follows it, and presence ignores it too.
        if AgentPresenceFeature.isFromNestedAgent(event, in: state.agentPresence) {
          return .send(.agentPresence(.hookEventReceived(event)))
        }
        let suppressEnd =
          event.eventName == .sessionEnd
          && (state.isQuitting || terminalClient.isHarnessEndSuppressed(event.surfaceID))
        let refresh: Effect<Action> =
          !suppressEnd
            && (event.eventName == .idle || event.eventName == .sessionStart || event.eventName == .sessionEnd)
          ? .send(.repositories(.sessionsRefreshRequested)) : .none
        let branchEffect = Self.enqueueBranchCapture(for: event, state: &state)
        let settlement: Effect<Action> =
          !state.isQuitting && !terminalClient.isHarnessEndSuppressed(event.surfaceID)
          ? Self.settleReplacedOrEndedSession(event: event, state: &state) : .none
        var activity: Effect<Action> = .none
        if event.eventName == .busy || event.eventName == .idle,
          let agent = SkillAgent(rawValue: event.agent), let ref = event.sessionRef,
          let timestamp = event.timestamp
        {
          activity = .send(
            .repositories(
              .sessionActivityObserved(
                SessionKey(harness: agent, sessionID: ref), timestamp)))
        }
        return .merge(.send(.agentPresence(.hookEventReceived(event))), refresh, branchEffect, settlement, activity)

      case .branchCaptureProbeCompleted(let key, let branch):
        state.branchCaptureInFlight = false
        var effects: [Effect<Action>] = []
        if let branch, !branch.isEmpty {
          effects.append(.send(.repositories(.sessionBranchCaptured(key: key, branch: branch))))
        }
        if let next = state.branchCaptureQueue.first {
          state.branchCaptureQueue.removeFirst()
          state.branchCaptureInFlight = true
          effects.append(Self.runBranchProbe(key: next.key, cwd: next.cwd))
        }
        return effects.isEmpty ? .none : .merge(effects)

      default:
        return .none
      }
    }
  }

  /// A changed session on a surface is a replacement, not a quit: the task
  /// stays open and only the replaced session is marked. A quit settles the
  /// task when it was the primary's and no other agent of the task is running.
  static func settleReplacedOrEndedSession(event: AgentHookEvent, state: inout State) -> Effect<Action> {
    guard let agent = SkillAgent(rawValue: event.agent) else { return .none }
    let presenceKey = AgentPresenceFeature.PresenceKey(agent: agent, surfaceID: event.surfaceID)
    let record = state.agentPresence.records[presenceKey]
    // Every event that puts its ref on the record, not only a start or a
    // busy: once presence holds the new ref, no later event differs from it.
    if AgentPresenceFeature.recordsSessionRef(of: event, in: state.agentPresence) {
      guard let newRef = event.sessionRef else { return .none }
      let new = SessionKey(harness: agent, sessionID: newRef)
      guard new.isValid else { return .none }
      if let oldRef = record?.sessionRef {
        guard newRef != oldRef else { return .none }
        state.endedSessions[presenceKey] = nil
        return replaceSession(
          SessionKey(harness: agent, sessionID: oldRef), with: new, onSurface: event.surfaceID, state: state)
      }
      // Pi ends the old session before it starts the next, so by now the
      // record is gone and the ended session is all that names the old one.
      guard let old = state.endedSessions.removeValue(forKey: presenceKey), old != new else { return .none }
      return replaceSession(old, with: new, onSurface: event.surfaceID, state: state)
    }
    guard event.eventName == .sessionEnd, let record, let oldRef = record.sessionRef,
      record.matchesSessionEnd(event)
    else { return .none }
    let key = SessionKey(harness: agent, sessionID: oldRef)
    // Only Pi says why it ended. A bare end may be a quit or the first half
    // of a replacement (Claude ends the session on `/clear` too).
    var reason: String?
    if agent == .pi {
      guard event.sessionRef == oldRef, let named = event.shutdownReason, named != "reload" else { return .none }
      reason = named
    }
    let isQuit = reason == "quit"
    state.endedSessions[presenceKey] = isQuit ? nil : key
    if reason != nil, !isQuit {
      // `new`, `resume`, `fork`: the replaced session is marked, nothing closes.
      return .send(.repositories(.settleSession(key)))
    }
    let index = surfaceIndex(state: state)
    guard let layoutID = index[event.surfaceID]?.layoutID,
      let members = state.terminals.members[layoutID], members.contains(.session(key))
    else {
      // No task lists it: there is only the session to mark.
      return .send(.repositories(.settleSession(key)))
    }
    let othersAreRunning = state.agentPresence.records.keys.contains {
      $0 != presenceKey && index[$0.surfaceID]?.layoutID == layoutID
    }
    // A tangent quitting settles nothing, and the primary quitting beside a
    // running tangent leaves the task open: settling would close its tabs.
    guard members.first == .session(key), !othersAreRunning else { return .none }
    // Tabs close only for a quit the harness named, from a local process. A
    // bare or remote end cannot be told from an agent that is still there.
    // Nor may they close while the record tracks another process: the ending
    // one leaves it, and any other may be an agent still running on this tab.
    // Nor before the stored sessions load: until then the first to report
    // leads the list, and it may be a tangent of a stored primary.
    let hasSiblingProcess = record.pids.contains { $0 != event.pid }
    guard isQuit, event.pid != nil, !hasSiblingProcess, state.terminals.storedSessions != .pending else {
      return .send(.repositories(.settleSession(key)))
    }
    // The session is over whatever the close confirmation says.
    return .merge(.send(.repositories(.settleSession(key))), settleTask(layoutID, state: state))
  }

  /// `new` takes `old`'s slot in the task that owns the surface. `old` is
  /// only marked settled; `new` is running, so a mark on it is lifted.
  private static func replaceSession(
    _ old: SessionKey, with new: SessionKey, onSurface surfaceID: UUID, state: State
  ) -> Effect<Action> {
    var effects: [Effect<Action>] = []
    if let layoutID = surfaceIndex(state: state)[surfaceID]?.layoutID {
      effects.append(.send(.terminals(.sessionReplaced(layoutID, old: old, new: new))))
    }
    if state.repositories.sessions[old]?.settledAt == nil {
      effects.append(.send(.repositories(.settleSession(old))))
    }
    if state.repositories.sessions[new]?.settledAt != nil {
      effects.append(.send(.repositories(.unsettleSession(new))))
    }
    return .concatenate(effects)
  }

  // MARK: - Task settle

  /// The task's primary session: the first member, once its agent has reported.
  static func primarySession(of layoutID: LayoutID, state: State) -> SessionKey? {
    if let members = state.terminals.members[layoutID] { return members.first?.sessionKey }
    return storedTask(layoutID, state: state)?.sessions.first
  }

  /// A task is settled exactly when its current primary's entry is.
  static func isTaskSettled(_ layoutID: LayoutID, state: State) -> Bool {
    guard let primary = primarySession(of: layoutID, state: state) else { return false }
    return state.repositories.sessions[primary]?.settledAt != nil
  }

  /// Settles the task: closes every tab behind one confirmation (the
  /// close-confirmation setting still guards a busy one) and marks its
  /// current primary once they are closing, so a cancelled confirmation
  /// settles nothing. A task with no tabs open is only marked. A shell-only
  /// task has no session to mark; its last tab closing removes it.
  static func settleTask(_ layoutID: LayoutID, state: State) -> Effect<Action> {
    guard let layout = state.terminals.layouts[id: layoutID], !layout.layout.allContentIDs.isEmpty else {
      guard let primary = primarySession(of: layoutID, state: state) else { return .none }
      return .send(.repositories(.settleSession(primary)))
    }
    return .send(.terminals(.layouts(.element(id: layoutID, action: .closeAllTabsRequested))))
  }

  /// The task whose tabs this action just closed for a settle: a close-all
  /// that needed no confirmation, or its confirmation. Read after the
  /// layout reducer ran: a task still asking, or with a tab left open (one
  /// opened while the confirmation waited is asked about again), is not settled.
  static func taskClosedForSettle(_ action: Action, state: State) -> LayoutID? {
    switch action {
    case .terminals(.layouts(.element(let layoutID, .closeAllTabsRequested))),
      .terminals(.layouts(.element(let layoutID, .alert(.presented(.confirmCloseAll))))):
      guard let layout = state.terminals.layouts[id: layoutID] else { return layoutID }
      return layout.alert == nil && layout.layout.allContentIDs.isEmpty ? layoutID : nil
    default:
      return nil
    }
  }

  /// The task a session leads. A session two tasks lead resolves to the one
  /// its row points at, else the lowest key.
  static func taskLed(by key: SessionKey, state: State) -> LayoutID? {
    let led = state.terminals.members.filter { $0.value.first == .session(key) }.map(\.key)
    if let shown = state.repositories.sessionItems[id: .session(key)]?.location?.layoutID, led.contains(shown) {
      return shown
    }
    return led.min { $0.persistenceKey < $1.persistenceKey }
  }

  /// Every task's sessions, primary first, for the task-level auto-settle.
  static func taskSessions(_ members: [LayoutID: [TaskMember]]) -> [LayoutID: [SessionKey]] {
    members.compactMapValues {
      let sessions = $0.compactMap(\.sessionKey)
      return sessions.isEmpty ? nil : sessions
    }
  }

  // MARK: - Launch orchestration

  /// The directory of the task on screen, remote host included. A tab of
  /// that task may run elsewhere (a tangent); the task's directory is still
  /// where its next sibling starts.
  static func currentTaskContext(state: State) -> DirectoryContext? {
    guard let layoutID = state.repositories.selectedTaskID ?? state.terminals.selectedLayoutID,
      hasTask(layoutID, state: state),
      let directoryID = state.terminals.directories[layoutID]?.worktreeID
        ?? storedTask(layoutID, state: state)?.directory.worktreeID
        ?? state.worktree(forLayout: layoutID)?.id
    else { return nil }
    return directoryContext(forTask: layoutID, directoryID: directoryID, state: state)
  }

  /// The local path of the task on screen. A remote task has none: its path
  /// names nothing on this machine.
  static func currentTaskDirectory(state: State) -> URL? {
    guard let context = currentTaskContext(state: state), context.host == nil else { return nil }
    return context.workingDirectory.standardizedFileURL
  }

  static func newSessionCwdFallback(state: State) -> URL {
    if let taskDirectory = currentTaskDirectory(state: state) { return taskDirectory }
    if let focused = focusedSessionRowID(state: state),
      let cwd = cwd(for: focused, state: state)
    {
      return cwd
    }
    if let selected = state.repositories.sessionSelection,
      let cwd = cwd(for: selected, state: state)
    {
      return cwd
    }
    if let worktree = state.repositories.worktree(for: state.repositories.selectedWorktreeID) {
      return worktree.workingDirectory.standardizedFileURL
    }
    return FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
  }

  private static func cwd(for rowID: SessionRowID, state: State) -> URL? {
    guard let item = state.repositories.sessionItems[id: rowID] else { return nil }
    return URL(fileURLWithPath: item.cwd).standardizedFileURL
  }

  /// A manual settle means "done with this". On a task's primary it settles
  /// the task. On any other session it marks that session and closes its own
  /// tab the way Cmd-W would: until rows are grouped by task, a tangent's row
  /// must not take the rest of its task down with it.
  static func settleAndCloseSession(_ key: SessionKey, state: State) -> Effect<Action> {
    if let layoutID = taskLed(by: key, state: state) { return settleTask(layoutID, state: state) }
    let closes = state.repositories.sessionSnapshots.filter { $0.id == .session(key) }.map {
      Effect<Action>.send(
        .terminals(
          .layouts(
            .element(
              id: $0.location.layoutID,
              action: .contentRequestedClose(
                content: ContentID(rawValue: $0.location.surfaceID), scope: .tab)))))
    }
    return .merge([.send(.repositories(.settleSession(key)))] + closes)
  }

  static func handleSettleSessionAndAdvance(state: inout State) -> Effect<Action> {
    let currentID = focusedSessionRowID(state: state) ?? state.repositories.sessionSelection
    let settledTask: LayoutID?
    let settleEffect: Effect<Action>
    switch currentID {
    case .session(let key):
      settledTask = taskLed(by: key, state: state)
      settleEffect = settleAndCloseSession(key, state: state)
    case .task(let layoutID):
      settledTask = layoutID
      settleEffect = settleTask(layoutID, state: state)
    case .provisional, nil:
      return .none
    }
    guard let currentID,
      let target = nextLiveRow(after: currentID, outside: settledTask, state: state),
      let targetItem = state.repositories.sessionItems[id: target],
      let location = targetItem.location
    else { return settleEffect }
    var effects: [Effect<Action>] = [
      settleEffect,
      RepositoriesFeature.focusEffect(id: target, location: location).map(Action.repositories),
    ]
    if case .session(let targetKey) = target, targetItem.lifecycle == .settled {
      effects.append(.send(.repositories(.unsettleSession(targetKey))))
    }
    return .merge(effects)
  }

  /// The next live row after `current`, skipping rows of the task being
  /// settled: its tabs are closing, so advancing must land on another task.
  private static func nextLiveRow(
    after current: SessionRowID, outside settledTask: LayoutID?, state: State
  ) -> SessionRowID? {
    let live = state.repositories.sessionsSidebarStructure.liveIDs
    let start = live.firstIndex(of: current).map { $0 + 1 } ?? 0
    for offset in live.indices {
      let id = live[(start + offset) % live.count]
      guard id != current else { continue }
      if let settledTask, state.repositories.sessionItems[id: id]?.location?.layoutID == settledTask { continue }
      return id
    }
    return nil
  }

  static func handleSessionDeeplink(
    key: SessionKey, action: Deeplink.SessionAction, state: inout State
  ) -> Effect<Action> {
    guard key.isValid else {
      state.alert = AlertState { TextState("Invalid session id. Expected harness:id.") }
      return .none
    }
    let indexed = state.repositories.sessionSummaries.contains { $0.id == key }
    let live = state.repositories.sessionItems[id: .session(key)]?.location != nil
    guard indexed || live else {
      state.alert = AlertState {
        TextState("Session not found. Run `supacode session list` to choose one.")
      }
      return .none
    }
    switch action {
    case .settle: return .send(.repositories(.settleSession(key)))
    case .unsettle: return .send(.repositories(.unsettleSession(key)))
    }
  }

  static func handleUnsettleCurrentSession(state: inout State) -> Effect<Action> {
    let currentID = focusedSessionRowID(state: state) ?? state.repositories.sessionSelection
    guard let currentID, case .session(let key) = currentID else { return .none }
    return .send(.repositories(.unsettleSession(key)))
  }

  static func handleNextSessionNeedsMe(state: inout State) -> Effect<Action> {
    let currentID = focusedSessionRowID(state: state) ?? state.repositories.sessionSelection
    guard
      let id = state.repositories.sessionsSidebarStructure.nextNeedingAttention(
        from: currentID, items: state.repositories.sessionItems
      )
    else { return .none }
    return RepositoriesFeature.focusSessionNavigation(state: &state.repositories, id: id)
      .map(Action.repositories)
  }

  static func handleNewSession(directory: URL?, state: inout State) -> Effect<Action> {
    guard state.pendingSessionLaunch == nil else { return .none }
    @Dependency(\.uuid) var uuid
    // A remote task's directory cannot be checked or registered from here:
    // the launch goes straight to its host.
    if directory == nil, let remote = currentTaskContext(state: state), remote.host != nil {
      return launchNewSession(in: remote, state: &state)
    }
    let cwd = (directory ?? newSessionCwdFallback(state: state)).standardizedFileURL
    let cwdPath = cwd.path(percentEncoded: false)
    var isDir: ObjCBool = false
    guard
      FileManager.default.fileExists(atPath: cwdPath, isDirectory: &isDir),
      isDir.boolValue,
      FileManager.default.isReadableFile(atPath: cwdPath)
    else {
      repositoriesLogger.warning("New session: cwd not found or not readable: \(cwdPath)")
      return .none
    }
    let requestID = uuid()
    var pending = PendingSessionLaunch(
      key: SessionKey(harness: .pi, sessionID: "new:\(requestID.uuidString)"),
      cwd: cwd,
      command: "pi",
      requestID: requestID,
      isNewSession: true
    )
    if let worktree = worktreeForCwd(cwd, state: state) {
      pending.launched = true
      state.pendingSessionLaunch = pending
      return launchSessionTab(pending, directory: DirectoryContext(worktree: worktree), state: &state)
    }
    state.pendingSessionLaunch = pending
    return .send(.repositories(.registerSessionFolder(cwd)))
  }

  /// Mints a task with the default agent on a directory the roster lists,
  /// local or remote. Nothing is asked and no path is checked here: the
  /// directory is the row's own.
  static func handleNewTask(inDirectory directoryID: Worktree.ID, state: inout State) -> Effect<Action> {
    guard state.pendingSessionLaunch == nil,
      let worktree = state.repositories.worktree(for: directoryID), !worktree.isMissing
    else { return .none }
    return launchNewSession(in: DirectoryContext(worktree: worktree), state: &state)
  }

  private static func launchNewSession(in directory: DirectoryContext, state: inout State) -> Effect<Action> {
    @Dependency(\.uuid) var uuid
    let requestID = uuid()
    let pending = PendingSessionLaunch(
      key: SessionKey(harness: .pi, sessionID: "new:\(requestID.uuidString)"),
      cwd: directory.workingDirectory,
      command: "pi",
      requestID: requestID,
      launched: true,
      isNewSession: true
    )
    state.pendingSessionLaunch = pending
    return launchSessionTab(pending, directory: directory, state: &state)
  }

  private static func handleResumeSession(_ key: SessionKey, state: inout State) -> Effect<Action> {
    @Dependency(\.date) var date
    if let last = state.recentSessionLaunchDate[key],
      date.now.timeIntervalSince(last) < 10
    {
      return .none
    }
    guard let prepared = prepareResumeSession(key, state: &state) else { return .none }
    @Dependency(\.uuid) var uuid
    let pending = PendingSessionLaunch(
      key: key, cwd: prepared.cwd, command: prepared.command, requestID: uuid(), probing: true)
    state.pendingSessionLaunch = pending
    return runResumeBranchProbe(pending)
  }

  static func confirmBranchMismatchResume(state: inout State) -> Effect<Action> {
    guard let pending = state.pendingBranchMismatchResume else { return .none }
    state.pendingBranchMismatchResume = nil
    return startPreparedResume(
      PreparedSessionResume(key: pending.key, cwd: pending.cwd, command: pending.command),
      requestID: state.pendingSessionLaunch?.requestID, state: &state)
  }

  static func cancelBranchMismatchResume(state: inout State) -> Effect<Action> {
    state.pendingBranchMismatchResume = nil
    state.pendingSessionLaunch = nil
    return .none
  }

  private static func prepareResumeSession(
    _ key: SessionKey,
    state: inout State
  ) -> PreparedSessionResume? {
    guard state.pendingSessionLaunch == nil, state.pendingBranchMismatchResume == nil else { return nil }
    guard let item = state.repositories.sessionItems[id: .session(key)] else { return nil }
    let rawParts = key.rawValue.split(separator: ":", maxSplits: 1).map(String.init)
    guard rawParts.count == 2, let harness = SkillAgent(rawValue: rawParts[0]) else { return nil }
    guard let command = AgentResumeCommand.command(agent: harness, sessionRef: rawParts[1]) else { return nil }
    let standardCwd = URL(fileURLWithPath: item.cwd).standardizedFileURL
    let cwdPath = standardCwd.path(percentEncoded: false)
    var isDir: ObjCBool = false
    guard
      FileManager.default.fileExists(atPath: cwdPath, isDirectory: &isDir),
      isDir.boolValue,
      FileManager.default.isReadableFile(atPath: cwdPath)
    else {
      repositoriesLogger.warning("Session resume: cwd not found or not readable: \(item.cwd)")
      let name = standardCwd.lastPathComponent.isEmpty ? cwdPath : standardCwd.lastPathComponent
      state.alert = AlertState { TextState("Cannot resume: \"\(name)\" is not accessible.") }
      return nil
    }
    return PreparedSessionResume(key: key, cwd: standardCwd, command: command)
  }

  private static func runResumeBranchProbe(_ pending: PendingSessionLaunch) -> Effect<Action> {
    @Dependency(GitClientDependency.self) var gitClient
    return .run { send in
      let currentBranch = await gitClient.branchName(pending.cwd)
      await send(.resumeBranchProbeCompleted(requestID: pending.requestID, currentBranch: currentBranch))
    }
  }

  private static func finishResumeBranchProbe(
    requestID: UUID,
    currentBranch: String?,
    state: inout State
  ) -> Effect<Action> {
    guard let pending = state.pendingSessionLaunch,
      pending.requestID == requestID, pending.probing
    else { return .none }
    state.pendingSessionLaunch?.probing = false
    let key = pending.key
    let cwd = pending.cwd
    let command = pending.command
    if let location = state.repositories.sessionItems[id: .session(key)]?.location {
      state.pendingSessionLaunch = nil
      state.pendingBranchMismatchResume = nil
      state.alert = nil
      return focusSession(location, state: state)
    }
    let branches = state.repositories.sessions[key]?.branches ?? []
    let hasBranchHistory = !branches.isEmpty
    let resolvedBranch: String?
    if let branch = currentBranch, !branch.isEmpty {
      resolvedBranch = branch
    } else if hasBranchHistory {
      state.pendingSessionLaunch = nil
      state.alert = AlertState {
        TextState("Cannot resume: branch probe failed at \"\(cwd.path(percentEncoded: false))\".")
      }
      return .none
    } else {
      resolvedBranch = nil
    }
    let recordedBranch =
      hasBranchHistory && resolvedBranch.map({ !branches.contains($0) }) == true
      ? branches.last : nil
    let isProvisional = hasProvisionalSameHarnessCwd(key: key, cwd: cwd, state: state)
    let isMismatch = recordedBranch != nil
    guard isProvisional || isMismatch else {
      return startPreparedResume(
        PreparedSessionResume(key: key, cwd: cwd, command: command),
        requestID: requestID, state: &state)
    }
    state.pendingBranchMismatchResume = PendingBranchMismatchResume(
      key: key, cwd: cwd, command: command,
      recordedBranch: recordedBranch ?? "",
      currentBranch: resolvedBranch ?? "",
      isProvisionalConflict: isProvisional)
    let title: String
    let message: String
    if isProvisional && isMismatch {
      title = "Session conflict"
      message =
        "An agent already running in \(cwd.path(percentEncoded: false)) has not reported its "
        + "session yet and may be this session. This folder is on \(resolvedBranch ?? "") but "
        + "the session last worked on \(recordedBranch ?? ""). "
        + "Supacode will not checkout branches for you."

    } else if isProvisional {
      title = "Session already starting"
      message =
        "An agent already running in \(cwd.path(percentEncoded: false)) has not reported its "
        + "session yet and may be this session. Resume Anyway to start a second session."
    } else {
      title = "Resume on different branch?"
      message =
        "This session last worked on \(recordedBranch ?? ""), but this folder is "
        + "on \(resolvedBranch ?? ""). Supacode will not checkout branches for you."
    }
    state.alert = AlertState {
      TextState(title)
    } actions: {
      ButtonState(role: .cancel, action: .cancelBranchMismatchResume) { TextState("Cancel") }
      ButtonState(action: .confirmBranchMismatchResume) { TextState("Resume Anyway") }
    } message: {
      TextState(message)
    }
    return .none
  }

  private static func hasProvisionalSameHarnessCwd(
    key: SessionKey, cwd: URL, state: State
  ) -> Bool {
    let rawParts = key.rawValue.split(separator: ":", maxSplits: 1).map(String.init)
    guard let harness = SkillAgent(rawValue: rawParts.first ?? "") else { return false }
    return state.repositories.sessionSnapshots.contains { snap in
      snap.harness == harness && snap.sessionRef == nil
        && URL(fileURLWithPath: snap.cwd).standardizedFileURL == cwd
    }
  }

  private static func startPreparedResume(
    _ prepared: PreparedSessionResume,
    requestID reservedID: UUID? = nil,
    state: inout State
  ) -> Effect<Action> {
    guard state.pendingSessionLaunch == nil || state.pendingSessionLaunch?.requestID == reservedID
    else { return .none }
    if let location = state.repositories.sessionItems[id: .session(prepared.key)]?.location {
      state.pendingSessionLaunch = nil
      state.pendingBranchMismatchResume = nil
      state.alert = nil
      return focusSession(location, state: state)
    }
    @Dependency(\.uuid) var uuid
    let requestID = reservedID ?? uuid()
    var pending = PendingSessionLaunch(
      key: prepared.key, cwd: prepared.cwd, command: prepared.command, requestID: requestID)
    if let worktree = worktreeForCwd(prepared.cwd, state: state) {
      pending.launched = true
      state.pendingSessionLaunch = pending
      return launchSessionTab(pending, directory: DirectoryContext(worktree: worktree), state: &state)
    }
    state.pendingSessionLaunch = pending
    return .send(.repositories(.registerSessionFolder(prepared.cwd)))
  }

  private static func launchPendingSessionIfReady(
    pending: PendingSessionLaunch,
    state: inout State
  ) -> Effect<Action>? {
    guard let worktree = worktreeForCwd(pending.cwd, state: state) else { return nil }
    state.pendingSessionLaunch?.launched = true
    return launchSessionTab(pending, directory: DirectoryContext(worktree: worktree), state: &state)
  }

  private static func worktreeForCwd(_ cwd: URL, state: State) -> Worktree? {
    let folderID = Repository.folderWorktreeID(for: cwd)
    if let found = state.repositories.worktree(for: folderID) { return found }
    return state.repositories.repositories.flatMap(\.worktrees).first {
      $0.workingDirectory.standardizedFileURL == cwd
    }
  }

  /// Launches into a task, never into "the directory": a new agent always
  /// gets a task of its own, and so does a session no task lists. The task
  /// is created by its first tab, so no launch leaves an empty one behind.
  private static func launchSessionTab(
    _ pending: PendingSessionLaunch, directory: DirectoryContext, state: inout State
  ) -> Effect<Action> {
    @Dependency(TerminalClient.self) var terminalClient
    @Dependency(\.uuid) var uuid
    let owner = pending.isNewSession ? nil : task(listing: pending.key, onDirectory: directory.worktreeID, state: state)
    let layoutID = owner ?? LayoutID(task: uuid())
    // The resumed session is the minted task's primary before its agent
    // reports. It is listed when the task's first tab exists, not here, so a
    // launch that never gets a tab leaves no member for a task that is not there.
    let primary = owner == nil && !pending.isNewSession ? pending.key : nil
    // Earlier launches still waiting for their tab keep their primary; only
    // this one, the latest, is shown.
    state.pendingTaskLaunches.removeAll { $0.layoutID == layoutID }
    for index in state.pendingTaskLaunches.indices { state.pendingTaskLaunches[index].isShown = false }
    state.pendingTaskLaunches.append(
      PendingTaskLaunch(layoutID: layoutID, directoryID: directory.worktreeID, primary: primary))
    let command = pending.command
    let requestID = pending.requestID
    return .run { send in
      await terminalClient.send(
        .createTabWithInput(
          layoutID, directory,
          input: command,
          runSetupScriptIfNew: false,
          title: nil,
          focusing: true,
          anchor: nil
        )
      )
      await send(.launchSessionCompleted(requestID: requestID))
    }
  }

  /// The task that lists a session, when it sits on the directory the session
  /// resumes in. A task elsewhere is not reused: its tabs start in its own
  /// directory, and the session has to resume in the one it ran in.
  static func task(listing key: SessionKey, onDirectory directoryID: Worktree.ID, state: State) -> LayoutID? {
    var owners = state.terminals.members.filter { $0.value.contains(.session(key)) }.map(\.key)
    owners += storedTasks(state: state)
      .filter { $0.sessions.contains(key) && state.terminals.members[$0.id] == nil }.map(\.id)
    return
      owners
      .filter {
        (state.terminals.directories[$0] ?? storedTask($0, state: state)?.directory)?.worktreeID == directoryID
      }
      .min { $0.persistenceKey < $1.persistenceKey }
  }

  /// Every reporting agent with the task that owns its surface.
  static func taskAgents(state: State, index: [UUID: SurfaceEntry]) -> [TaskAgent] {
    state.agentPresence.records.compactMap { key, record in
      guard let entry = index[key.surfaceID] else { return nil }
      return TaskAgent(
        layoutID: entry.layoutID, harness: key.agent, surfaceID: key.surfaceID, sessionRef: record.sessionRef)
    }
  }

  static func membershipEffect(
    state: State, index: [UUID: SurfaceEntry], members: [LayoutID: [TaskMember]]? = nil
  ) -> Effect<Action>? {
    let agents = taskAgents(state: state, index: index)
    let members = TaskMembership.reconciled(members ?? state.terminals.members, agents: agents)
    guard members != state.terminals.members else { return nil }
    return .send(.terminals(.membersChanged(members, agents: agents)))
  }

  /// Lists the session each launched task was minted for, ahead of whatever
  /// its agent reports, as soon as the task holds a tab, and shows the task
  /// when it is the latest launch.
  static func showLaunchedTaskIfReady(state: inout State, members: inout [LayoutID: [TaskMember]]) -> Effect<Action>? {
    let ready = state.pendingTaskLaunches.filter { pending in
      state.terminals.layouts[id: pending.layoutID]?.layout.panes.contains { !$0.tabs.isEmpty } == true
    }
    guard !ready.isEmpty else { return nil }
    state.pendingTaskLaunches.removeAll { ready.contains($0) }
    for pending in ready {
      guard let primary = pending.primary.map(TaskMember.session) else { continue }
      members[pending.layoutID] = [primary] + (members[pending.layoutID] ?? []).filter { $0 != primary }
    }
    guard let shown = ready.last(where: \.isShown) else { return nil }
    return .send(.repositories(.selectTask(shown.layoutID, directory: shown.directoryID)))
  }

  // MARK: - Branch capture (FIFO queue, one in-flight at a time)

  private static func enqueueBranchCapture(
    for event: AgentHookEvent, state: inout State
  ) -> Effect<Action> {
    guard event.eventName == .busy || event.eventName == .idle else { return .none }
    guard let agent = SkillAgent(rawValue: event.agent) else { return .none }
    let presenceKey = AgentPresenceFeature.PresenceKey(agent: agent, surfaceID: event.surfaceID)
    let ref: String? = event.sessionRef ?? state.agentPresence.records[presenceKey]?.sessionRef
    guard let ref, !ref.isEmpty else { return .none }
    let sessionKey = SessionKey(harness: agent, sessionID: ref)
    guard let entry = surfaceIndex(state: state)[event.surfaceID] else { return .none }
    // The branch is the one the surface runs on. The directory's cached branch
    // only speaks for a surface sitting in that directory; a tab elsewhere is probed.
    // The layout records a tab's cwd only at launch or restore (a new tab records
    // none and may inherit another's), so the running surface is asked first.
    @Dependency(TerminalClient.self) var terminalClient
    let liveCwd = terminalClient.surfaceWorkingDirectory(entry.layoutID, event.surfaceID)
      .flatMap { $0.isEmpty ? nil : $0 }
    let cwd = URL(fileURLWithPath: liveCwd ?? entry.cwd).standardizedFileURL
    // Paths, not URLs: a reported directory may carry a trailing slash.
    let runsInTaskDirectory = cwd.path == URL(fileURLWithPath: entry.directoryPath).standardizedFileURL.path
    if runsInTaskDirectory,
      let branch = state.repositories.sidebarItems[id: entry.directoryID]?.branchName, !branch.isEmpty
    {
      return .send(.repositories(.sessionBranchCaptured(key: sessionKey, branch: branch)))
    }
    // A remote task's paths name nothing on this machine: never probe them here.
    let context = directoryContext(forTask: entry.layoutID, directoryID: entry.directoryID, state: state)
    guard context.host == nil else { return .none }
    let request = BranchCaptureRequest(key: sessionKey, cwd: cwd)
    if state.branchCaptureInFlight {
      state.branchCaptureQueue.append(request)
      return .none
    }
    state.branchCaptureInFlight = true
    return runBranchProbe(key: request.key, cwd: request.cwd)
  }

  static func runBranchProbe(key: SessionKey, cwd: URL) -> Effect<Action> {
    @Dependency(GitClientDependency.self) var gitClient
    return .run { send in
      let branch = await gitClient.branchName(cwd)
      await send(.branchCaptureProbeCompleted(key: key, branch: branch))
    }
  }

  // MARK: - Surface index

  /// Where a surface lives: the task that owns it and the directory it runs in.
  struct SurfaceEntry: Equatable {
    var layoutID: LayoutID
    var tabID: TabID
    /// The owning task's directory, in the roster or not.
    var directoryID: Worktree.ID
    var directoryPath: String
    /// The tab's own working directory, or the task's when the tab recorded none.
    var cwd: String
  }

  /// Every surface of every task, live layout first, else the persisted record.
  /// Walks tasks, not the roster, so several tasks on one directory and tasks
  /// whose directory is no known worktree are all found.
  static func surfaceIndex(state: State) -> [UUID: SurfaceEntry] {
    surfaceIndex(tasks: taskEntries(state: state))
  }

  static func surfaceIndex(tasks: [TaskEntry]) -> [UUID: SurfaceEntry] {
    var index: [UUID: SurfaceEntry] = [:]
    for task in tasks {
      for pane in task.layout.panes {
        for tab in pane.tabs {
          let surfaceID = tab.content.id.rawValue
          guard index[surfaceID] == nil else { continue }
          var cwd = task.directoryPath
          if case .terminal(let terminal) = tab.content.state,
            let recorded = terminal.workingDirectory, !recorded.isEmpty
          {
            cwd = recorded
          }
          index[surfaceID] = SurfaceEntry(
            layoutID: task.layoutID, tabID: tab.id, directoryID: task.directoryID,
            directoryPath: task.directoryPath, cwd: cwd)
        }
      }
    }
    return index
  }

  struct TaskEntry {
    var layoutID: LayoutID
    var layout: PaneLayout
    var directoryID: Worktree.ID
    var directoryPath: String
    var createdAt: Date?
  }

  /// Every task: live layouts first, then persisted records with no live layout, in key order.
  static func taskEntries(state: State) -> [TaskEntry] {
    func path(_ directoryID: Worktree.ID) -> String {
      state.repositories.worktree(for: directoryID)?.workingDirectory.path(percentEncoded: false)
        ?? RepositoryLocation.parse(persistedID: directoryID.rawValue)?.path
        ?? directoryID.rawValue
    }
    let persisted = state.repositories.persistedLayouts.tasks
    var entries: [TaskEntry] = []
    for live in state.terminals.layouts {
      // A layout attached without a directory (none yet names one) is found through the seam.
      guard
        let directoryID = state.terminals.directories[live.id]?.worktreeID
          ?? state.worktree(forLayout: live.id)?.id
      else { continue }
      entries.append(
        TaskEntry(
          layoutID: live.id, layout: live.layout, directoryID: directoryID, directoryPath: path(directoryID),
          createdAt: persisted[live.id.persistenceKey]?.createdAt))
    }
    let dormant = storedTasks(state: state)
      .filter { state.terminals.layouts[id: $0.id] == nil }
      .sorted { $0.id.persistenceKey < $1.id.persistenceKey }
    for record in dormant {
      let directoryID = record.directory.worktreeID
      entries.append(
        TaskEntry(
          layoutID: record.id, layout: record.layout, directoryID: directoryID, directoryPath: path(directoryID),
          createdAt: record.createdAt))
    }
    return entries
  }

  /// A candidate row for every task that holds tabs. The reconcile pass keeps
  /// one only where no session row leads to the task: two tasks reporting one
  /// session share a single session row, so "has a live agent" is not enough.
  static func taskSnapshots(tasks: [TaskEntry]) -> [TaskLiveSnapshot] {
    return tasks.compactMap { task in
      guard let tab = task.layout.panes.lazy.compactMap(\.tabs.first).first else { return nil }
      let name = URL(fileURLWithPath: task.directoryPath).lastPathComponent
      return TaskLiveSnapshot(
        title: name.isEmpty ? task.directoryPath : name, cwd: task.directoryPath, createdAt: task.createdAt,
        location: SessionLocation(
          layoutID: task.layoutID, directoryID: task.directoryID, tabID: tab.id,
          surfaceID: tab.content.id.rawValue))
    }
  }

  // MARK: - Snapshot helper

  static func hasUnresolvedLivePresence(state: State, index: [UUID: SurfaceEntry]) -> Bool {
    state.agentPresence.records.contains { key, record in
      record.sessionRef == nil && index[key.surfaceID] == nil
    }
  }

  static func liveSessionKeys(state: State) -> Set<SessionKey> {
    Set(
      state.agentPresence.records.compactMap { key, record in
        record.sessionRef.map { SessionKey(harness: key.agent, sessionID: $0) }
      })
  }

  static func sessionSnapshots(state: State) -> [SessionLiveSnapshot] {
    sessionSnapshots(state: state, index: surfaceIndex(state: state))
  }

  static func sessionSnapshots(state: State, index: [UUID: SurfaceEntry]) -> [SessionLiveSnapshot] {
    return state.agentPresence.records.compactMap { key, record in
      guard let entry = index[key.surfaceID] else { return nil }
      return SessionLiveSnapshot(
        harness: key.agent, sessionRef: record.sessionRef, cwd: entry.directoryPath,
        surfaceCwd: entry.cwd == entry.directoryPath ? nil : entry.cwd,
        location: SessionLocation(
          layoutID: entry.layoutID, directoryID: entry.directoryID, tabID: entry.tabID, surfaceID: key.surfaceID),
        status: sessionStatus(for: record),
        allowsAttentionNavigation: record.activity == .awaitingInput || record.isDoneUnseen)
    }.sorted {
      if $0.location.surfaceID != $1.location.surfaceID {
        return $0.location.surfaceID.uuidString < $1.location.surfaceID.uuidString
      }
      return $0.harness.rawValue < $1.harness.rawValue
    }
  }

  private static func sessionStatus(
    for record: AgentPresenceFeature.PresenceRecord
  ) -> SessionClassification.Status {
    switch record.activity {
    case .awaitingInput, .error:
      return .needsYou
    case .busy, .compacting:
      return .working
    case .idle:
      return record.isDoneUnseen ? .doneUnseen : .idle
    }
  }
}

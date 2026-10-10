import ComposableArchitecture
import Foundation
import SupacodeSettingsShared

extension RepositoriesFeature {
  static func focusSessionNavigation(state: inout State, id: SessionRowID?) -> Effect<Action> {
    guard let id, let location = state.sessionItems[id: id]?.location else { return .none }
    state.selectSessionRow(id)
    return focusEffect(id: id, location: location)
  }

  /// A task row shows its task; a session row also focuses the session's surface.
  static func focusEffect(id: SessionRowID, location: SessionLocation) -> Effect<Action> {
    if case .task(let layoutID) = id {
      return .send(.delegate(.focusTask(layoutID, directory: location.directoryID)))
    }
    return .send(.delegate(.focusSession(location)))
  }

  nonisolated enum SessionsCancelID: Hashable { case refresh, debounce, coarse }

  var sessionsReducer: some Reducer<State, Action> {
    Reduce { state, action in
      @Dependency(\.sessionIndex) var index
      @Dependency(\.continuousClock) var clock
      @Dependency(\.date) var date
      @Shared(.settingsFile) var settingsFile
      switch action {
      case .sessionsRestorationCompleted(let keys, let unresolved):
        state.sessionsRestorationFinished = true
        state.sessionsLiveKeys = keys
        state.sessionsHasUnresolvedLivePresence = unresolved
        state.autoSettleSessions(now: date.now, idleDays: settingsFile.global.sessionIdleDays)
        return .none

      case .sessionsLiveKeysChanged(let keys, let unresolved):
        state.sessionsLiveKeys = keys
        state.sessionsHasUnresolvedLivePresence = unresolved
        return .none

      case .sessionActivityObserved(let key, let activity):
        guard let hold = state.sessions[key]?.manualUnsettledAtActivity, activity > hold else { return .none }
        state.$sessions.withLock { $0[key]?.manualUnsettledAtActivity = nil }
        return .none

      case .sessionsCoarseClockFired:
        return .send(.sessionsRefreshRequested)

      case .sessionsStopped:
        return .merge(
          .cancel(id: SessionsCancelID.coarse), .cancel(id: SessionsCancelID.refresh),
          .cancel(id: SessionsCancelID.debounce))

      case .sessionsStarted:
        guard !state.sessionsStarted else { return .none }
        state.sessionsStarted = true
        state.sessionsRefreshInFlight = true
        return .merge(
          .run { send in
            await send(.sessionsCacheLoaded(await index.cached()))
            await Self.refreshSessions(index: index, send: send)
          }
          .cancellable(id: SessionsCancelID.refresh),
          .run { send in
            while !Task.isCancelled {
              try await clock.sleep(for: .seconds(900))
              await send(.sessionsCoarseClockFired)
            }
          }
          .cancellable(id: SessionsCancelID.coarse, cancelInFlight: true)
        )

      case .sessionsCacheLoaded(let summaries):
        state.sessionSummaries = summaries
        state.reconcileSessionItems(now: date.now)
        return .none

      case .sessionsSidebarShown, .sessionsRefreshRequested:
        guard state.sessionsStarted else { return .send(.sessionsStarted) }
        return .run { send in
          try await clock.sleep(for: .milliseconds(500))
          await send(.sessionsRefreshDebounced)
        }
        .cancellable(id: SessionsCancelID.debounce, cancelInFlight: true)

      case .sessionsRefreshDebounced:
        guard !state.sessionsRefreshInFlight else {
          state.sessionsRefreshPending = true
          return .none
        }
        state.sessionsRefreshInFlight = true
        return .run { send in await Self.refreshSessions(index: index, send: send) }
          .cancellable(id: SessionsCancelID.refresh)

      case .sessionsRefreshCompleted(let summaries):
        state.sessionsRefreshSucceeded = true
        state.sessionsHasCompletedRefresh = true
        let hasEndedPlaceholder = state.sessionItems.contains { $0.isSynthetic && !$0.isLive }
        if state.sessionSummaries != summaries || hasEndedPlaceholder {
          state.sessionSummaries = summaries
          state.reconcileSessionItems(now: date.now, droppingUnindexedEnded: true)
        }
        state.autoSettleSessions(now: date.now, idleDays: settingsFile.global.sessionIdleDays)
        return Self.finishSessionsRefresh(state: &state)

      case .sessionsRefreshFailed:
        state.sessionsRefreshSucceeded = false
        return Self.finishSessionsRefresh(state: &state)

      case .sessionSnapshotsChanged(let snapshots):
        guard state.sessionSnapshots != snapshots else { return .none }
        // A status flip (busy, idle, needs-you) writes nothing the index
        // reads, so only a change in which sessions are live rescans.
        let needsRefresh = state.sessionSnapshots.map(\.withoutStatus) != snapshots.map(\.withoutStatus)
        state.sessionSnapshots = snapshots
        state.reconcileSessionItems(now: date.now)
        return needsRefresh ? .send(.sessionsRefreshRequested) : .none

      case .taskSnapshotsChanged(let snapshots):
        guard state.taskSnapshots != snapshots else { return .none }
        state.taskSnapshots = snapshots
        state.reconcileSessionItems(now: date.now)
        return .none

      case .taskSessionsChanged(let taskSessions):
        guard state.taskSessions != taskSessions else { return .none }
        state.taskSessions = taskSessions
        state.reconcileSessionItems(now: date.now)
        return .none

      case .selectTask(let layoutID, let directoryID):
        guard let worktree = state.worktree(for: directoryID) else {
          // No roster directory to select: the task is shown on its own and
          // the directory features go quiet.
          state.setSingleWorktreeSelection(nil)
          state.selectedTask = SelectedTask(id: layoutID, directoryID: directoryID)
          return .send(.delegate(.selectedWorktreeChanged(nil, layoutID: layoutID)))
        }
        state.setSingleWorktreeSelection(directoryID)
        state.selectedTask = SelectedTask(id: layoutID, directoryID: directoryID)
        var effects: [Effect<Action>] = [
          .send(.delegate(.selectedWorktreeChanged(worktree, layoutID: layoutID)))
        ]
        if state.sidebarItems[id: directoryID] != nil {
          effects.append(.send(.sidebarItems(.element(id: directoryID, action: .focusTerminalRequested))))
        }
        return .merge(effects)

      case .selectedTaskRemoved:
        state.selectedTask = nil
        return .none

      case .sessionSelectionChanged(let id):
        state.selectSessionRow(id.flatMap { state.sessionItems[id: $0] == nil ? nil : $0 })
        return .none

      case .activateSession(let id), .sessionItems(.element(id: let id, action: .activate)):
        guard let row = state.sessionItems[id: id] else { return .none }
        state.selectSessionRow(id)
        if let location = row.location {
          if case .implicit(let key) = id, row.lifecycle == .settled {
            state.applyUnsettle(key: key, summaries: state.sessionSummaries, now: date.now)
          }
          return Self.focusEffect(id: id, location: location)
        }
        // A dormant task reopens on its primary; its tangents resume one by one.
        guard let key = row.sessionKey else { return .none }
        guard case .task(let layoutID) = id else { return .send(.delegate(.resumeSession(key))) }
        return .send(.delegate(.resumeSession(key, task: layoutID)))

      case .activateSessionSubRow(let layoutID, let member):
        let structure = state.sessionsSidebarStructure
        // The list as it is now decides: the click may be older than it.
        guard structure.subRowsTaskID == layoutID,
          let row = structure.subRows.first(where: { $0.id == member })
        else { return .none }
        if let location = row.location { return .send(.delegate(.focusSession(location))) }
        guard let key = member.sessionKey else { return .none }
        // Dormant here but running in another task: shown there, never started twice.
        if let elsewhere = state.sessionSnapshots.first(where: { $0.sessionKey == key })?.location {
          return .send(.delegate(.focusSession(elsewhere)))
        }
        return .send(.delegate(.resumeSession(key, task: layoutID)))

      case .settleSession(let key):
        state.applySettle(key: key, now: date.now)
        state.reconcileSessionItems(now: date.now)
        state.recomputeSessionsSidebarStructureIfChanged()
        return .none

      case .settleSessionRequested(let key):
        return .send(.delegate(.settleAndCloseSession(key)))

      case .settleTaskRequested(let layoutID):
        return .send(.delegate(.settleTask(layoutID)))

      case .mergeTaskRequested(let source, let target):
        return .send(.delegate(.mergeTask(source, into: target)))

      case .detachTabRequested(let source, let tabID):
        return .send(.delegate(.detachTab(source, tabID: tabID)))

      case .unsettleSession(let key):
        state.applyUnsettle(key: key, summaries: state.sessionSummaries, now: date.now)
        return .none

      case .sessionBranchCaptured(let key, let branch):
        guard !branch.isEmpty else { return .none }
        state.$sessions.withLock { sidecar in
          var entry = sidecar[key] ?? SessionSidecarEntry()
          guard !entry.branches.contains(branch) else { return }
          entry.recordBranch(branch)
          sidecar[key] = entry
        }
        state.reconcileSessionItems(now: date.now)
        return .none

      case .registerSessionFolder:
        return .none

      default:
        return .none
      }
    }
    .forEach(\.sessionItems, action: \.sessionItems) { SessionSidebarItemFeature() }
  }

  private static func refreshSessions(index: SessionIndexClient, send: Send<Action>) async {
    do {
      let summaries = try await index.refresh()
      send(.sessionsRefreshCompleted(summaries))
    } catch {
      repositoriesLogger.warning("Session refresh failed: \(error)")
      send(.sessionsRefreshFailed)
    }
  }

  private static func finishSessionsRefresh(state: inout State) -> Effect<Action> {
    state.sessionsRefreshInFlight = false
    guard state.sessionsRefreshPending else { return .none }
    state.sessionsRefreshPending = false
    return .send(.sessionsRefreshDebounced)
  }
}

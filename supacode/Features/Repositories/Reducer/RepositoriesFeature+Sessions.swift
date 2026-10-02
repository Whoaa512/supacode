import ComposableArchitecture
import Foundation
import SupacodeSettingsShared

extension RepositoriesFeature {
  nonisolated enum SessionsCancelID: Hashable { case refresh, debounce }

  var sessionsReducer: some Reducer<State, Action> {
    Reduce { state, action in
      @Dependency(\.sessionIndex) var index
      @Dependency(\.continuousClock) var clock
      @Dependency(\.date.now) var now
      switch action {
      case .sessionsStarted:
        guard !state.sessionsStarted else { return .none }
        state.sessionsStarted = true
        state.sessionsRefreshInFlight = true
        return .run { send in
          await send(.sessionsCacheLoaded(await index.cached()))
          await Self.refreshSessions(index: index, send: send)
        }
        .cancellable(id: SessionsCancelID.refresh)

      case .sessionsCacheLoaded(let summaries):
        state.sessionSummaries = summaries
        state.reconcileSessionItems(now: now)
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
        state.sessionSummaries = summaries
        state.reconcileSessionItems(now: now)
        return Self.finishSessionsRefresh(state: &state)

      case .sessionsRefreshFailed:
        return Self.finishSessionsRefresh(state: &state)

      case .sessionSnapshotsChanged(let snapshots):
        guard state.sessionSnapshots != snapshots else { return .none }
        state.sessionSnapshots = snapshots
        state.reconcileSessionItems(now: now)
        return .send(.sessionsRefreshRequested)

      case .sessionSelectionChanged(let id):
        state.sessionSelection = id.flatMap { state.sessionItems[id: $0] == nil ? nil : $0 }
        return .none

      case .activateSession(let id), .sessionItems(.element(id: let id, action: .activate)):
        guard let row = state.sessionItems[id: id] else { return .none }
        state.sessionSelection = id
        if let location = row.location {
          return .send(.delegate(.focusSession(location)))
        }
        // Dormant row: delegate resume to App which owns cwd validation and
        // createTabWithInput orchestration.
        if case .session(let key) = id {
          return .send(.delegate(.resumeSession(key)))
        }
        return .none

      case .sessionBranchCaptured(let key, let branch):
        guard !branch.isEmpty else { return .none }
        state.$sessions.withLock { sidecar in
          var entry = sidecar[key] ?? SessionSidecarEntry()
          guard !entry.branches.contains(branch) else { return }
          entry.recordBranch(branch)
          sidecar[key] = entry
        }
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

import ComposableArchitecture
import Foundation
import SupacodeSettingsShared

extension AppFeature {
  var sessionsLinkReducer: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .agentPresence(.delegate(.surfacesChanged)), .terminals,
        .repositories(.delegate(.repositoriesChanged)):
        let snapshots = Self.sessionSnapshots(state: state)
        guard snapshots != state.repositories.sessionSnapshots else { return .none }
        return .send(.repositories(.sessionSnapshotsChanged(snapshots)))
      default:
        return .none
      }
    }
  }

  static func sessionSnapshots(state: State) -> [SessionLiveSnapshot] {
    var locations: [UUID: (SessionLocation, String)] = [:]
    for repository in state.repositories.repositories {
      for worktree in repository.worktrees {
        guard
          let layout = state.terminals.layouts[id: worktree.id]?.layout
            ?? state.repositories.persistedLayouts.worktrees[worktree.id.rawValue]?.layout
        else { continue }
        for pane in layout.panes {
          for tab in pane.tabs {
            let id = tab.content.id.rawValue
            locations[id] = (
              SessionLocation(worktreeID: worktree.id, tabID: tab.id, surfaceID: id),
              worktree.workingDirectory.path
            )
          }
        }
      }
    }
    return state.agentPresence.records.compactMap { key, record in
      guard let (location, cwd) = locations[key.surfaceID] else { return nil }
      return SessionLiveSnapshot(
        harness: key.agent, sessionRef: record.sessionRef, cwd: cwd, location: location)
    }.sorted {
      if $0.location.surfaceID != $1.location.surfaceID {
        return $0.location.surfaceID.uuidString < $1.location.surfaceID.uuidString
      }
      return $0.harness.rawValue < $1.harness.rawValue
    }
  }
}

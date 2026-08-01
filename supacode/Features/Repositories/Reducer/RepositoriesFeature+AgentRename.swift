import ComposableArchitecture
import Foundation
import SupacodeSettingsShared

extension RepositoriesFeature {
  /// Agents-tab rename flow. Its own reducer for the same reason the worktree
  /// customization flow has one: the main `body` switch is at the Swift
  /// type-checker's complexity limit.
  static var agentRenameReducer: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .requestRenameAgent(let entryID):
        guard let entry = state.agentDashboardStructure.entries.first(where: { $0.id == entryID }) else {
          repositoriesLogger.warning(
            "requestRenameAgent dropped: no dashboard entry for wt=\(entryID.worktreeID) agent=\(entryID.agent.rawValue)"
          )
          return .none
        }
        // Names are unique across live agents, so the sheet needs every other
        // row's name to reject a duplicate before it reaches presence state.
        let takenNames = Set(
          state.agentDashboardStructure.entries.lazy
            .filter { $0.id != entryID }
            .compactMap(\.name)
        )
        state.agentRename = AgentRenameFeature.State(
          worktreeID: entry.worktreeID,
          agent: entry.agent,
          subject: "\(entry.agent.displayName) in \(entry.title)",
          takenNames: takenNames,
          name: entry.name ?? ""
        )
        return .none

      case .agentRename(.presented(.delegate(.cancel))), .agentRename(.dismiss):
        state.agentRename = nil
        return .none

      case .agentRename(.presented(.delegate(.save(let worktreeID, let agent, let name)))):
        state.agentRename = nil
        return .send(.delegate(.renameAgent(worktreeID: worktreeID, agent: agent, name: name)))

      default:
        return .none
      }
    }
  }
}

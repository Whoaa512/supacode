import ComposableArchitecture
import Foundation
import SupacodeSettingsShared

extension AppFeature {
  /// Resolves the presence record behind a (worktree, agent) pair and applies a
  /// rename. The error string is `nil` on success; the deeplink path turns it
  /// into an alert (which is what makes the CLI ack `ok: false`).
  func renameAgentEffect(
    worktreeID: Worktree.ID,
    agent: SkillAgent,
    name: String?,
    state: State
  ) -> (effect: Effect<Action>, error: String?) {
    guard let surfaceIDs = state.repositories.sidebarItems[id: worktreeID]?.surfaceIDs else {
      return (.none, "Worktree not found: \(worktreeID.rawValue)")
    }
    guard let key = state.agentPresence.presenceKey(agent: agent, across: surfaceIDs) else {
      return (.none, "No running \(agent.rawValue) agent in \(worktreeID.rawValue).")
    }
    if let name {
      guard AgentPresenceFeature.validate(name: name) else {
        return (
          .none,
          "Invalid agent name '\(name)'. Use 1–32 characters matching [a-z][a-z0-9_-]*."
        )
      }
      guard !state.agentPresence.isNameTaken(name, excluding: key) else {
        return (.none, "Agent name '\(name)' is already in use.")
      }
    }
    return (.send(.agentPresence(.renameAgent(key: key, name: name))), nil)
  }

  /// `supacode://agent/<worktree-id>/<agent-kind>/rename[?name=...]`.
  func handleAgentDeeplink(
    worktreeID: Worktree.ID,
    agent rawAgent: String,
    action: Deeplink.AgentAction,
    state: inout State
  ) -> Effect<Action> {
    guard let agent = SkillAgent(rawValue: rawAgent) else {
      state.alert = Self.agentCommandAlert("Unknown agent kind: \(rawAgent)")
      return .none
    }
    switch action {
    case .rename(let name):
      let outcome = renameAgentEffect(worktreeID: worktreeID, agent: agent, name: name, state: state)
      guard let error = outcome.error else { return outcome.effect }
      state.alert = Self.agentCommandAlert(error)
      return .none
    }
  }

  /// Alert doubles as the socket-ack failure signal, so the CLI gets ok=false.
  private static func agentCommandAlert(_ message: String) -> AlertState<Alert> {
    AlertState {
      TextState("Agent command failed")
    } actions: {
      ButtonState(role: .cancel, action: .dismiss) {
        TextState("OK")
      }
    } message: {
      TextState(message)
    }
  }
}

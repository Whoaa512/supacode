import ComposableArchitecture
import Foundation
import SupacodeSettingsShared

extension AppFeature {
  /// Resolves the presence record behind a (worktree, agent) pair and applies a
  /// rename. The error string is `nil` on success; the deeplink path turns it
  /// into an alert (which is what makes the CLI ack `ok: false`).
  func renameAgentEffect(
    worktreeID: Worktree.ID,
    task: LayoutID? = nil,
    surface: UUID? = nil,
    agent: SkillAgent,
    name: String?,
    state: State
  ) -> (effect: Effect<Action>, error: String?) {
    let resolved = agentPresenceKey(
      worktreeID: worktreeID, task: task, surface: surface, agent: agent, state: state)
    guard let key = resolved.key else { return (.none, resolved.error) }
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

  /// `supacode://agent/<worktree-id>[/task/<task-id>]/<agent-kind>/<action>[?surface=<id>]`.
  func handleAgentDeeplink(
    worktreeID: Worktree.ID,
    agent rawAgent: String,
    action: Deeplink.AgentAction,
    task: LayoutID? = nil,
    surface: UUID? = nil,
    state: inout State
  ) -> Effect<Action> {
    guard let agent = SkillAgent(rawValue: rawAgent) else {
      state.alert = Self.agentCommandAlert("Unknown agent kind: \(rawAgent)")
      return .none
    }
    switch action {
    case .rename(let name):
      let outcome = renameAgentEffect(
        worktreeID: worktreeID, task: task, surface: surface, agent: agent, name: name, state: state)
      return apply(outcome: outcome, state: &state)
    case .prompt(let text, let submit):
      let error = promptAgent(
        worktreeID: worktreeID, task: task, surface: surface, agent: agent, text: text, submit: submit, state: state)
      return apply(outcome: (.none, error), state: &state)
    case .sendKeys(let keys):
      let error = sendKeysToAgent(
        worktreeID: worktreeID, task: task, surface: surface, agent: agent, keys: keys, state: state)
      return apply(outcome: (.none, error), state: &state)
    case .metadata(let tokens, let clear):
      let outcome = reportAgentMetadata(
        worktreeID: worktreeID, task: task, surface: surface, agent: agent, tokens: tokens, clear: clear,
        state: state)
      return apply(outcome: outcome, state: &state)
    case .resume:
      let outcome = resumeAgent(worktreeID: worktreeID, task: task, surface: surface, agent: agent, state: state)
      return apply(outcome: outcome, state: &state)
    }
  }

  /// Raises the failure as an alert (the socket ack reads it) or returns the
  /// success effect.
  private func apply(
    outcome: (effect: Effect<Action>, error: String?),
    state: inout State
  ) -> Effect<Action> {
    guard let error = outcome.error else { return outcome.effect }
    state.alert = Self.agentCommandAlert(error)
    return .none
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

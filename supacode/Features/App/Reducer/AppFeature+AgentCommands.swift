import ComposableArchitecture
import Foundation
import SupacodeSettingsShared

/// `supacode agent prompt|send-keys|report-metadata`. Each handler returns an
/// error string instead of throwing so `handleAgentDeeplink` can raise it as an
/// alert, which is what makes the socket ack `ok: false` (see
/// `isolateSocketCommandAlert`).
extension AppFeature {
  /// The surfaces an agent command may address, in the row's order. With a
  /// task named, that task's surfaces only, and it has to be a task of this
  /// directory; with none, every surface on the directory, the shown task's
  /// first, so two agents of one kind on one directory resolve to the one on
  /// screen. A `surface` names one agent exactly: it must be among those
  /// surfaces now, or nothing is addressed. The error names why nothing can
  /// be addressed.
  static func agentSurfaceIDs(
    worktreeID: Worktree.ID, task: LayoutID?, surface: UUID? = nil, state: State
  ) -> (ids: [UUID], error: String?) {
    let scoped = taskSurfaceIDs(worktreeID: worktreeID, task: task, state: state)
    guard let surface, scoped.error == nil else { return scoped }
    guard scoped.ids.contains(surface) else { return ([], "Agent not found.") }
    return ([surface], nil)
  }

  private static func taskSurfaceIDs(
    worktreeID: Worktree.ID, task: LayoutID?, state: State
  ) -> (ids: [UUID], error: String?) {
    guard let item = state.repositories.sidebarItems[id: worktreeID] else {
      return ([], "Worktree not found: \(worktreeID.rawValue)")
    }
    let index = surfaceIndex(state: state)
    let all = Array(item.surfaceIDs)
    // A task merged away is the task that took its tabs, as for worktree commands.
    let task = task.map { state.terminals.mergedTasks[$0] ?? $0 }
    guard let task else {
      let shown = state.commandLayoutID(forDirectory: worktreeID)
      return (all.filter { index[$0]?.layoutID == shown } + all.filter { index[$0]?.layoutID != shown }, nil)
    }
    let directory =
      state.terminals.directories[task]?.worktreeID ?? storedTask(task, state: state)?.directory.worktreeID
    guard hasTask(task, state: state), directory == worktreeID else { return ([], "Task not found.") }
    return (all.filter { index[$0]?.layoutID == task }, nil)
  }

  /// The live presence key behind a (worktree, task, agent) triple, or why it
  /// can't be resolved. Shared by every agent-scoped command, including rename.
  func agentPresenceKey(
    worktreeID: Worktree.ID,
    task: LayoutID?,
    surface: UUID? = nil,
    agent: SkillAgent,
    state: State
  ) -> (key: AgentPresenceFeature.PresenceKey?, error: String?) {
    let surfaces = Self.agentSurfaceIDs(worktreeID: worktreeID, task: task, surface: surface, state: state)
    if let error = surfaces.error { return (nil, error) }
    guard let key = state.agentPresence.presenceKey(agent: agent, across: surfaces.ids) else {
      return (nil, "No running \(agent.rawValue) agent in \(worktreeID.rawValue).")
    }
    return (key, nil)
  }

  /// Types a prompt into the agent's surface without focusing it. `submit`
  /// appends the enter sequence, matching what the surface-input deeplink does
  /// for shell commands.
  func promptAgent(
    worktreeID: Worktree.ID,
    task: LayoutID? = nil,
    surface: UUID? = nil,
    agent: SkillAgent,
    text: String,
    submit: Bool,
    state: State
  ) -> String? {
    @Dependency(TerminalClient.self) var terminalClient
    let resolved = agentPresenceKey(
      worktreeID: worktreeID, task: task, surface: surface, agent: agent, state: state)
    guard let key = resolved.key else { return resolved.error }
    let submitSequence = submit ? (AgentKeySequence.sequence(for: "enter") ?? "\r") : ""
    guard let owner = state.layoutID(forDirectory: worktreeID, holding: key.surfaceID),
      terminalClient.sendTextToSurface(owner, key.surfaceID, text + submitSequence)
    else {
      return "Agent surface is not live in \(worktreeID.rawValue)."
    }
    return nil
  }

  /// Sends named keys in order. Validation happens before the first byte, so a
  /// typo in the third key can't leave the agent half-driven.
  func sendKeysToAgent(
    worktreeID: Worktree.ID,
    task: LayoutID?,
    surface: UUID? = nil,
    agent: SkillAgent,
    keys: [String],
    state: State
  ) -> String? {
    @Dependency(TerminalClient.self) var terminalClient
    let mapped = AgentKeySequence.sequences(for: keys)
    if let unknown = mapped.unknownName {
      return "Unknown key '\(unknown)'. Supported: \(AgentKeySequence.names.joined(separator: ", "))."
    }
    let resolved = agentPresenceKey(
      worktreeID: worktreeID, task: task, surface: surface, agent: agent, state: state)
    guard let key = resolved.key else { return resolved.error }
    for sequence in mapped.sequences {
      guard let owner = state.layoutID(forDirectory: worktreeID, holding: key.surfaceID),
        terminalClient.sendTextToSurface(owner, key.surfaceID, sequence)
      else {
        return "Agent surface is not live in \(worktreeID.rawValue)."
      }
    }
    return nil
  }

  /// Types the agent's native resume command into the surface whose session died.
  ///
  /// Supacode never does this on its own. Every guard below exists so a
  /// user-issued resume can't land somewhere unexpected:
  /// - a live presence record means the agent is running, so resuming would fork
  ///   its session;
  /// - no resume candidate means we have no proven-dead session with a ref, so
  ///   there is nothing to resume rather than something to guess;
  /// - `AgentResumeCommand` re-validates the ref before it becomes terminal input.
  /// With a task named, both the running check and the candidate lookup see
  /// that task's surfaces only; the resume never widens to the directory.
  func resumeAgent(
    worktreeID: Worktree.ID,
    task: LayoutID?,
    surface: UUID? = nil,
    agent: SkillAgent,
    state: State
  ) -> (effect: Effect<Action>, error: String?) {
    @Dependency(TerminalClient.self) var terminalClient
    let surfaces = Self.agentSurfaceIDs(worktreeID: worktreeID, task: task, surface: surface, state: state)
    if let error = surfaces.error { return (.none, error) }
    let surfaceIDs = surfaces.ids
    if state.agentPresence.presenceKey(agent: agent, across: surfaceIDs) != nil {
      return (.none, "\(agent.rawValue) is already running in \(worktreeID.rawValue).")
    }
    guard let candidate = state.agentPresence.resumeCandidate(agent: agent, across: surfaceIDs)
    else {
      return (
        .none,
        "No resumable \(agent.rawValue) session in \(worktreeID.rawValue). "
          + "Supacode only offers resume for a session whose process is gone and whose "
          + "hook reported a session id."
      )
    }
    guard
      let command = AgentResumeCommand.command(
        agent: agent, sessionRef: candidate.candidate.sessionRef)
    else {
      return (.none, "\(agent.rawValue) has no resume-by-id command.")
    }
    let submit = AgentKeySequence.sequence(for: "enter") ?? "\r"
    guard let owner = state.layoutID(forDirectory: worktreeID, holding: candidate.key.surfaceID),
      terminalClient.sendTextToSurface(owner, candidate.key.surfaceID, command + submit)
    else {
      return (.none, "Agent surface is not live in \(worktreeID.rawValue).")
    }
    // The offer is spent: the command is typed, and the relaunched agent's
    // `session_start` re-establishes a live record with the same ref.
    return (.send(.agentPresence(.resumeCandidateConsumed(key: candidate.key))), nil)
  }

  /// Stores display-only tokens on a live agent.
  func reportAgentMetadata(
    worktreeID: Worktree.ID,
    task: LayoutID? = nil,
    surface: UUID? = nil,
    agent: SkillAgent,
    tokens: [String: String],
    clear: Bool,
    state: State
  ) -> (effect: Effect<Action>, error: String?) {
    if let error = AgentPresenceFeature.validate(tokens: tokens) {
      return (.none, error)
    }
    let resolved = agentPresenceKey(
      worktreeID: worktreeID, task: task, surface: surface, agent: agent, state: state)
    guard let key = resolved.key else { return (.none, resolved.error) }
    return (.send(.agentPresence(.reportMetadata(key: key, tokens: tokens, clear: clear))), nil)
  }
}

import ComposableArchitecture
import Foundation
import SupacodeSettingsShared

/// One-at-a-time dormant session resume request. Cleared on success or failure.
struct PendingSessionLaunch: Equatable {
  let key: SessionKey
  let cwd: URL
  let command: String
  let requestID: UUID
}

extension AppFeature {
  var sessionsLinkReducer: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .agentPresence(.delegate(.surfacesChanged)), .terminals,
        .repositories(.delegate(.repositoriesChanged)):
        let snapshots = Self.sessionSnapshots(state: state)
        guard snapshots != state.repositories.sessionSnapshots else { return .none }
        var effects: [Effect<Action>] = [.send(.repositories(.sessionSnapshotsChanged(snapshots)))]
        // Pending launch: check whether registration completed and the worktree is now live.
        if let pending = state.pendingSessionLaunch,
          case .repositories(.delegate(.repositoriesChanged)) = action
        {
          if let effect = Self.launchPendingSessionIfReady(pending: pending, state: &state) {
            effects.append(effect)
          }
        }
        return .merge(effects)

      case .repositories(.delegate(.resumeSession(let key))):
        return Self.handleResumeSession(key, state: &state)

      case .terminalEvent(.agentHookEventReceived(let event)):
        let refresh: Effect<Action> =
          event.eventName == .idle || event.eventName == .sessionStart || event.eventName == .sessionEnd
          ? .send(.repositories(.sessionsRefreshRequested)) : .none
        // Branch capture for busy/idle: read BEFORE presence mutation.
        let branchEffect = Self.branchCaptureEffect(for: event, state: state)
        return .merge(.send(.agentPresence(.hookEventReceived(event))), refresh, branchEffect)

      default:
        return .none
      }
    }
  }

  // MARK: - Resume orchestration

  private static func handleResumeSession(_ key: SessionKey, state: inout State) -> Effect<Action> {
    @Dependency(\.uuid) var uuid
    guard let item = state.repositories.sessionItems[id: .session(key)] else { return .none }
    // Duplicate guard: one pending at a time.
    guard state.pendingSessionLaunch == nil else { return .none }
    // Parse harness and session ID from the opaque raw value ("harness:id").
    let rawParts = key.rawValue.split(separator: ":", maxSplits: 1).map(String.init)
    guard rawParts.count == 2,
      let harness = SkillAgent(rawValue: rawParts[0])
    else { return .none }
    let sessionID = rawParts[1]
    guard let command = AgentResumeCommand.command(agent: harness, sessionRef: sessionID)
    else { return .none }
    let standardCwd = URL(fileURLWithPath: item.cwd).standardizedFileURL
    // Validate cwd is a readable directory.
    var isDir: ObjCBool = false
    guard
      FileManager.default.fileExists(
        atPath: standardCwd.path(percentEncoded: false), isDirectory: &isDir),
      isDir.boolValue
    else {
      repositoriesLogger.warning("Session resume: cwd not found or not a directory: \(item.cwd)")
      return .none
    }
    // Find an already-registered worktree for this exact cwd.
    let worktree = worktreeForCwd(standardCwd, state: state)
    if let worktree {
      return launchSessionTab(worktree: worktree, command: command)
    }
    // Register and then launch.
    state.pendingSessionLaunch = PendingSessionLaunch(
      key: key, cwd: standardCwd, command: command, requestID: uuid())
    return .send(.repositories(.registerSessionFolder(standardCwd)))
  }

  /// Checks whether the pending launch's worktree is now registered; if so,
  /// fires `createTabWithInput` and clears the pending value.
  private static func launchPendingSessionIfReady(
    pending: PendingSessionLaunch,
    state: inout State
  ) -> Effect<Action>? {
    guard let worktree = worktreeForCwd(pending.cwd, state: state) else { return nil }
    state.pendingSessionLaunch = nil
    return launchSessionTab(worktree: worktree, command: pending.command)
  }

  private static func worktreeForCwd(_ cwd: URL, state: State) -> Worktree? {
    // Exact synthetic folder-repo worktree first (fastest path).
    let folderID = Repository.folderWorktreeID(for: cwd)
    if let found = state.repositories.worktree(for: folderID) { return found }
    // Fall back: any worktree whose exact workingDirectory matches the cwd.
    return state.repositories.repositories.flatMap(\.worktrees).first {
      $0.workingDirectory.standardizedFileURL == cwd
    }
  }

  private static func launchSessionTab(worktree: Worktree, command: String) -> Effect<Action> {
    @Dependency(TerminalClient.self) var terminalClient
    return .run { _ in
      await terminalClient.send(
        .createTabWithInput(
          worktree,
          input: command,
          runSetupScriptIfNew: false,
          title: nil,
          focusing: true,
          anchor: nil
        )
      )
    }
  }

  // MARK: - Branch capture

  /// Returns an effect that captures the current branch for the surface's
  /// worktree before `hookEventReceived` mutates the presence records.
  /// Git-tracked worktrees use the synchronous sidebarItems cache; folder repos
  /// (may be inside git) use an async `gitClient.branchName` call.
  private static func branchCaptureEffect(for event: AgentHookEvent, state: State) -> Effect<Action> {
    guard event.eventName == .busy || event.eventName == .idle else { return .none }
    // Derive the SessionKey from the event or fall back to the current record.
    let agent: SkillAgent? = SkillAgent(rawValue: event.agent)
    guard let agent else { return .none }
    let presenceKey = AgentPresenceFeature.PresenceKey(agent: agent, surfaceID: event.surfaceID)
    let ref: String? = event.sessionRef ?? state.agentPresence.records[presenceKey]?.sessionRef
    guard let ref, !ref.isEmpty else { return .none }
    let sessionKey = SessionKey(harness: agent, sessionID: ref)
    // Find the worktree for this surface.
    let worktreeID = worktreeIDForSurface(event.surfaceID, state: state)
    guard let worktreeID else { return .none }
    // Try the synchronous sidebar-item cache first (git-tracked worktrees).
    if let branch = state.repositories.sidebarItems[id: worktreeID]?.branchName,
      !branch.isEmpty
    {
      return .send(.repositories(.sessionBranchCaptured(key: sessionKey, branch: branch)))
    }
    // Folder repo: check if it's inside git via async branchName call.
    guard let worktree = state.repositories.worktree(for: worktreeID) else { return .none }
    let cwd = worktree.workingDirectory
    @Dependency(GitClientDependency.self) var gitClient
    return .run { send in
      if let branch = await gitClient.branchName(cwd), !branch.isEmpty {
        await send(.repositories(.sessionBranchCaptured(key: sessionKey, branch: branch)))
      }
    }
  }

  private static func worktreeIDForSurface(_ surfaceID: UUID, state: State) -> Worktree.ID? {
    for repository in state.repositories.repositories {
      for worktree in repository.worktrees {
        let layout =
          state.terminals.layouts[id: worktree.id]?.layout
          ?? state.repositories.persistedLayouts.worktrees[worktree.id.rawValue]?.layout
        guard let layout else { continue }
        for pane in layout.panes {
          for tab in pane.tabs where tab.content.id.rawValue == surfaceID {
            return worktree.id
          }
        }
      }
    }
    return nil
  }

  // MARK: - Snapshot helper

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

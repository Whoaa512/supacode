import ComposableArchitecture
import Foundation
import SupacodeSettingsShared

struct PendingSessionLaunch: Equatable {
  let key: SessionKey
  let cwd: URL
  let command: String
  let requestID: UUID
  var launched: Bool = false
}

struct BranchCaptureRequest: Equatable {
  let key: SessionKey
  let cwd: URL
}

extension AppFeature {
  static func focusedSessionRowID(state: State) -> SessionRowID? {
    guard let selectedWorktreeID = state.terminals.selectedWorktreeID else { return nil }
    guard let layout = state.terminals.layouts[id: selectedWorktreeID] else { return nil }
    guard let focusedPane = layout.layout.panes.first(where: { $0.id == layout.layout.focusedPaneID })
    else { return nil }
    guard let selectedTab = focusedPane.tabs.first(where: { $0.id == focusedPane.selectedTabID })
    else { return nil }
    let surfaceID = selectedTab.content.id.rawValue
    return state.repositories.sessionItems.first(where: { $0.location?.surfaceID == surfaceID })?.id
  }

  var sessionsLinkReducer: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .agentPresence(.delegate(.surfacesChanged)), .terminals,
        .repositories(.delegate(.repositoriesChanged)):
        var effects: [Effect<Action>] = []
        let snapshots = Self.sessionSnapshots(state: state)
        if snapshots != state.repositories.sessionSnapshots {
          effects.append(.send(.repositories(.sessionSnapshotsChanged(snapshots))))
        }
        if let pending = state.pendingSessionLaunch,
          !pending.launched,
          case .repositories(.delegate(.repositoriesChanged)) = action,
          let effect = Self.launchPendingSessionIfReady(pending: pending, state: &state)
        {
          effects.append(effect)
        }
        guard !effects.isEmpty else { return .none }
        return .merge(effects)

      case .repositories(.delegate(.resumeSession(let key))):
        return Self.handleResumeSession(key, state: &state)

      case .launchSessionCompleted(let requestID):
        guard let pending = state.pendingSessionLaunch, pending.requestID == requestID
        else { return .none }
        let key = pending.key
        state.pendingSessionLaunch = nil
        guard state.repositories.sessionItems[id: .session(key)]?.lifecycle == .settled
        else { return .none }
        return .send(.repositories(.unsettleSession(key)))

      case .terminalEvent(.agentHookEventReceived(let event)):
        let refresh: Effect<Action> =
          event.eventName == .idle || event.eventName == .sessionStart || event.eventName == .sessionEnd
          ? .send(.repositories(.sessionsRefreshRequested)) : .none
        let branchEffect = Self.enqueueBranchCapture(for: event, state: &state)
        return .merge(.send(.agentPresence(.hookEventReceived(event))), refresh, branchEffect)

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

  // MARK: - Launch orchestration

  static func newSessionCwdFallback(state: State) -> URL {
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

  static func handleSettleSessionAndAdvance(state: inout State) -> Effect<Action> {
    let currentID = focusedSessionRowID(state: state) ?? state.repositories.sessionSelection
    guard let currentID, case .session(let key) = currentID else { return .none }
    let nextID = state.repositories.sessionRowID(byOffset: 1, focusedRowID: currentID)
    let advanceTarget = nextID != currentID ? nextID : nil
    let settleEffect = Effect<Action>.send(.repositories(.settleSession(key)))
    guard let target = advanceTarget,
      let targetItem = state.repositories.sessionItems[id: target],
      let location = targetItem.location
    else { return settleEffect }
    var effects: [Effect<Action>] = [
      settleEffect,
      .send(.focusTerminalSurface(
        worktreeID: location.worktreeID, tabID: location.tabID, surfaceID: location.surfaceID)),
    ]
    if case .session(let targetKey) = target, targetItem.lifecycle == .settled {
      effects.append(.send(.repositories(.unsettleSession(targetKey))))
    }
    return .merge(effects)
  }

  static func handleUnsettleCurrentSession(state: inout State) -> Effect<Action> {
    let currentID = focusedSessionRowID(state: state) ?? state.repositories.sessionSelection
    guard let currentID, case .session(let key) = currentID else { return .none }
    return .send(.repositories(.unsettleSession(key)))
  }

  static func handleNewSession(directory: URL?, state: inout State) -> Effect<Action> {
    guard state.pendingSessionLaunch == nil else { return .none }
    @Dependency(\.uuid) var uuid
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
      requestID: requestID
    )
    if let worktree = worktreeForCwd(cwd, state: state) {
      pending.launched = true
      state.pendingSessionLaunch = pending
      return launchSessionTab(worktree: worktree, command: pending.command, requestID: requestID)
    }
    state.pendingSessionLaunch = pending
    return .send(.repositories(.registerSessionFolder(cwd)))
  }

  private static func handleResumeSession(_ key: SessionKey, state: inout State) -> Effect<Action> {
    guard let item = state.repositories.sessionItems[id: .session(key)] else { return .none }
    guard state.pendingSessionLaunch == nil else { return .none }
    let rawParts = key.rawValue.split(separator: ":", maxSplits: 1).map(String.init)
    guard rawParts.count == 2,
      let harness = SkillAgent(rawValue: rawParts[0])
    else { return .none }
    let sessionID = rawParts[1]
    guard let command = AgentResumeCommand.command(agent: harness, sessionRef: sessionID)
    else { return .none }
    @Dependency(\.uuid) var uuid
    let standardCwd = URL(fileURLWithPath: item.cwd).standardizedFileURL
    let cwdPath = standardCwd.path(percentEncoded: false)
    var isDir: ObjCBool = false
    guard
      FileManager.default.fileExists(atPath: cwdPath, isDirectory: &isDir),
      isDir.boolValue,
      FileManager.default.isReadableFile(atPath: cwdPath)
    else {
      repositoriesLogger.warning("Session resume: cwd not found or not readable: \(item.cwd)")
      return .none
    }
    let requestID = uuid()
    var pending = PendingSessionLaunch(
      key: key, cwd: standardCwd, command: command, requestID: requestID)
    if let worktree = worktreeForCwd(standardCwd, state: state) {
      pending.launched = true
      state.pendingSessionLaunch = pending
      return launchSessionTab(worktree: worktree, command: pending.command, requestID: requestID)
    }
    state.pendingSessionLaunch = pending
    return .send(.repositories(.registerSessionFolder(standardCwd)))
  }

  private static func launchPendingSessionIfReady(
    pending: PendingSessionLaunch,
    state: inout State
  ) -> Effect<Action>? {
    guard let worktree = worktreeForCwd(pending.cwd, state: state) else { return nil }
    state.pendingSessionLaunch?.launched = true
    return launchSessionTab(worktree: worktree, command: pending.command, requestID: pending.requestID)
  }

  private static func worktreeForCwd(_ cwd: URL, state: State) -> Worktree? {
    let folderID = Repository.folderWorktreeID(for: cwd)
    if let found = state.repositories.worktree(for: folderID) { return found }
    return state.repositories.repositories.flatMap(\.worktrees).first {
      $0.workingDirectory.standardizedFileURL == cwd
    }
  }

  private static func launchSessionTab(
    worktree: Worktree, command: String, requestID: UUID
  ) -> Effect<Action> {
    @Dependency(TerminalClient.self) var terminalClient
    return .run { send in
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
      await send(.launchSessionCompleted(requestID: requestID))
    }
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
    guard let worktreeID = worktreeIDForSurface(event.surfaceID, state: state) else { return .none }
    if let branch = state.repositories.sidebarItems[id: worktreeID]?.branchName, !branch.isEmpty {
      return .send(.repositories(.sessionBranchCaptured(key: sessionKey, branch: branch)))
    }
    guard let worktree = state.repositories.worktree(for: worktreeID) else { return .none }
    let request = BranchCaptureRequest(key: sessionKey, cwd: worktree.workingDirectory)
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

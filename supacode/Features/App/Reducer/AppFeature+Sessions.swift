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
    guard let selectedWorktreeID = state.terminals.selectedWorktreeID,
      let layout = state.terminals.layouts[id: selectedWorktreeID]?.layout,
      let focusedPane = layout.panes.first(where: { $0.id == layout.focusedPaneID }),
      let selectedTab = focusedPane.tabs.first(where: { $0.id == focusedPane.selectedTabID })
    else { return nil }
    return selectedTab.content.id.rawValue
  }

  static func focusedSessionRowID(state: State) -> SessionRowID? {
    guard let surfaceID = focusedSurfaceID(state: state) else { return nil }
    return state.repositories.sessionSnapshots.first { $0.location.surfaceID == surfaceID }?.id
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
        return .concatenate(
          .send(.repositories(.sessionSnapshotsChanged(Self.sessionSnapshots(state: state)))),
          .send(
            .repositories(
              .sessionsRestorationCompleted(
                Self.liveSessionKeys(state: state),
                hasUnresolvedLivePresence: Self.hasUnresolvedLivePresence(state: state)))))

      case .repositories(.sessionSnapshotsChanged):
        Self.syncSessionSelectionToFocus(state: &state)
        return .none

      case .agentPresence(.delegate(.surfacesChanged)), .terminals,
        .repositories(.delegate(.repositoriesChanged)):
        Self.syncSessionSelectionToFocus(state: &state)
        var effects: [Effect<Action>] = []
        let keys = Self.liveSessionKeys(state: state)
        let unresolved = Self.hasUnresolvedLivePresence(state: state)
        if keys != state.repositories.sessionsLiveKeys
          || unresolved != state.repositories.sessionsHasUnresolvedLivePresence
        {
          effects.append(.send(.repositories(.sessionsLiveKeysChanged(keys, hasUnresolvedLivePresence: unresolved))))
        }
        let snapshots = Self.sessionSnapshots(state: state)
        if snapshots != state.repositories.sessionSnapshots {
          effects.append(.send(.repositories(.sessionSnapshotsChanged(snapshots))))
        }
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
          ? Self.settleReplacedOrEndedSession(event: event, state: state) : .none
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

  static func settleReplacedOrEndedSession(event: AgentHookEvent, state: State) -> Effect<Action> {
    guard let agent = SkillAgent(rawValue: event.agent),
      let record = state.agentPresence.records[
        AgentPresenceFeature.PresenceKey(agent: agent, surfaceID: event.surfaceID)],
      let oldRef = record.sessionRef
    else { return .none }
    let key = SessionKey(harness: agent, sessionID: oldRef)
    if event.eventName == .sessionStart || event.eventName == .busy {
      guard let newRef = event.sessionRef, newRef != oldRef else { return .none }
      return .send(.repositories(.settleSession(key)))
    }
    guard event.eventName == .sessionEnd, record.matchesSessionEnd(event) else { return .none }
    if agent == .pi {
      guard event.sessionRef == oldRef, let reason = event.shutdownReason, reason != "reload"
      else { return .none }
    }
    return .send(.repositories(.settleSession(key)))
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

  /// A manual settle means "done with this": close its tabs the way Cmd-W
  /// would, so the close-confirmation setting still guards a busy agent.
  static func settleAndCloseSession(_ key: SessionKey, state: State) -> Effect<Action> {
    let closes = state.repositories.sessionSnapshots.filter { $0.id == .session(key) }.map {
      Effect<Action>.send(
        .terminals(
          .layouts(
            .element(
              id: $0.location.worktreeID,
              action: .contentRequestedClose(
                content: ContentID(rawValue: $0.location.surfaceID), scope: .tab)))))
    }
    return .merge([.send(.repositories(.settleSession(key)))] + closes)
  }

  static func handleSettleSessionAndAdvance(state: inout State) -> Effect<Action> {
    let currentID = focusedSessionRowID(state: state) ?? state.repositories.sessionSelection
    guard let currentID, case .session(let key) = currentID else { return .none }
    let nextID = state.repositories.sessionRowID(byOffset: 1, focusedRowID: currentID)
    let advanceTarget = nextID != currentID ? nextID : nil
    let settleEffect = settleAndCloseSession(key, state: state)
    guard let target = advanceTarget,
      let targetItem = state.repositories.sessionItems[id: target],
      let location = targetItem.location
    else { return settleEffect }
    var effects: [Effect<Action>] = [
      settleEffect,
      .send(
        .focusTerminalSurface(
          worktreeID: location.worktreeID, tabID: location.tabID, surfaceID: location.surfaceID)),
    ]
    if case .session(let targetKey) = target, targetItem.lifecycle == .settled {
      effects.append(.send(.repositories(.unsettleSession(targetKey))))
    }
    return .merge(effects)
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
      return .send(
        .focusTerminalSurface(
          worktreeID: location.worktreeID, tabID: location.tabID, surfaceID: location.surfaceID))
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
      return .send(
        .focusTerminalSurface(
          worktreeID: location.worktreeID, tabID: location.tabID, surfaceID: location.surfaceID))
    }
    @Dependency(\.uuid) var uuid
    let requestID = reservedID ?? uuid()
    var pending = PendingSessionLaunch(
      key: prepared.key, cwd: prepared.cwd, command: prepared.command, requestID: requestID)
    if let worktree = worktreeForCwd(prepared.cwd, state: state) {
      pending.launched = true
      state.pendingSessionLaunch = pending
      return launchSessionTab(worktree: worktree, command: pending.command, requestID: requestID)
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
          worktree.id, DirectoryContext(worktree: worktree),
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

  static func hasUnresolvedLivePresence(state: State) -> Bool {
    var mappedSurfaceIDs: Set<UUID> = []
    for repository in state.repositories.repositories {
      for worktree in repository.worktrees {
        let layout =
          state.terminals.layouts[id: worktree.id]?.layout
          ?? state.repositories.persistedLayouts.worktrees[worktree.id.rawValue]?.layout
        guard let layout else { continue }
        for pane in layout.panes {
          for tab in pane.tabs {
            mappedSurfaceIDs.insert(tab.content.id.rawValue)
          }
        }
      }
    }
    return state.agentPresence.records.contains { key, record in
      record.sessionRef == nil && !mappedSurfaceIDs.contains(key.surfaceID)
    }
  }

  static func liveSessionKeys(state: State) -> Set<SessionKey> {
    Set(
      state.agentPresence.records.compactMap { key, record in
        record.sessionRef.map { SessionKey(harness: key.agent, sessionID: $0) }
      })
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
              worktree.workingDirectory.path(percentEncoded: false)
            )
          }
        }
      }
    }
    return state.agentPresence.records.compactMap { key, record in
      guard let (location, cwd) = locations[key.surfaceID] else { return nil }
      return SessionLiveSnapshot(
        harness: key.agent, sessionRef: record.sessionRef, cwd: cwd, location: location,
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

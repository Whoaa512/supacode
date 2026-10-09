import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import Sharing
import Testing

@testable import SupacodeSettingsFeature
@testable import SupacodeSettingsShared
@testable import supacode

@Suite(.serialized)
@MainActor
struct AppFeatureSessionsTests {
  private let surface = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
  private let shell = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
  private let tab = TabID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!)

  private var worktree: Worktree {
    Worktree(
      id: "/workspace", name: "workspace", detail: "",
      workingDirectory: URL(fileURLWithPath: "/workspace"),
      repositoryRootURL: URL(fileURLWithPath: "/workspace"))
  }

  private var location: SessionLocation {
    SessionLocation(layoutID: worktree.id.layoutID, directoryID: worktree.id, tabID: tab, surfaceID: surface)
  }

  private func state(restored: Bool = false) -> AppFeature.State {
    var repositories = RepositoriesFeature.State()
    repositories.$sessions = Shared(value: [:])
    repositories.$sidebar = Shared(value: SidebarState())
    repositories.repositories = [
      Repository(
        id: "/workspace", rootURL: worktree.workingDirectory, name: "workspace",
        worktrees: [worktree])
    ]
    repositories.selection = .worktree(worktree.id)
    repositories.isInitialLoadComplete = true
    repositories.sessionsStarted = true
    let paneID = PaneID()
    let tabs: IdentifiedArrayOf<TabItem> = [
      TabItem(
        id: tab, title: "Agent",
        content: ContentSnapshot(
          id: ContentID(rawValue: surface),
          state: .terminal(TerminalContentState(workingDirectory: "/workspace")))),
      TabItem(
        id: TabID(rawValue: shell), title: "Shell",
        content: ContentSnapshot(
          id: ContentID(rawValue: shell),
          state: .terminal(TerminalContentState(workingDirectory: "/workspace")))),
    ]
    let layout = PaneLayout(
      tree: SplitTree(view: paneID),
      panes: [Pane(id: paneID, tabs: tabs, selectedTabID: TabID(rawValue: shell))])
    var state = AppFeature.State(repositories: repositories, settings: SettingsFeature.State())
    if restored {
      state.repositories.$persistedLayouts = SharedReader(
        value: TaskLayoutsFile(
          oneTaskPerDirectory: LayoutsFile(worktrees: [
            worktree.id.rawValue: LayoutRecord(layout: layout)
          ])))
    } else {
      state.terminals.layouts = [LayoutFeature.State(id: worktree.id.layoutID, layout: layout)]
    }
    return state
  }

  private func record(ref: String? = "real") -> AgentPresenceFeature.PresenceRecord {
    AgentPresenceFeature.PresenceRecord(pids: [], sessionRef: ref)
  }

  private func temporaryDirectory(named name: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("supacode-tests-\(UUID().uuidString)-\(name)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url.standardizedFileURL
  }

  // MARK: - Live click focuses exact surface; dormant click without location is no-op

  @Test(.dependencies) func liveClickFocusesExactSurfaceIDAndWorktree() async {
    let focused = LockIsolated<[SessionLocation]>([])
    var initial = state()
    let key = SessionRowID.implicit(SessionKey(harness: .pi, sessionID: "real"))
    initial.repositories.sessionItems = [
      SessionSidebarItemFeature.State(
        id: key, title: "Agent", cwd: "/workspace", createdAt: .distantPast, location: location)
    ]
    let store = TestStore(initialState: initial) {
      AppFeature()
    } withDependencies: {
      $0.date.now = .distantPast
      $0.terminalClient.focusSurface = { layoutID, context, tab, surf in
        focused.withValue {
          $0.append(SessionLocation(layoutID: layoutID, directoryID: context.worktreeID, tabID: tab, surfaceID: surf))
        }
      }
    }
    store.exhaustivity = .off
    await store.send(.repositories(.sessionItems(.element(id: key, action: .activate))))
    await store.receive(\.repositories.delegate.focusSession)
    await store.receive(\.repositories.selectTask)
    await store.finish()
    #expect(focused.value.count == 1)
    #expect(focused.value[0] == location)
    #expect(store.state.repositories.selectedWorktreeID == worktree.id)
  }

  @Test(.dependencies) func liveRowStaysFocusableAfterCacheLoad() async {
    let focused = LockIsolated<[SessionLocation]>([])
    var initial = state()
    let presenceKey = AgentPresenceFeature.PresenceKey(agent: .pi, surfaceID: surface)
    initial.agentPresence.records[presenceKey] = record(ref: "real")
    initial.agentPresence.bySurface[surface] = [.pi]
    initial.repositories.sessionSnapshots = AppFeature.sessionSnapshots(state: initial)
    initial.repositories.reconcileSessionItems(now: .distantPast)
    let key = SessionRowID.implicit(SessionKey(harness: .pi, sessionID: "real"))
    let store = TestStore(initialState: initial) {
      AppFeature()
    } withDependencies: {
      $0.date.now = .distantPast
      $0.terminalClient.focusSurface = { layoutID, context, tab, surf in
        focused.withValue {
          $0.append(SessionLocation(layoutID: layoutID, directoryID: context.worktreeID, tabID: tab, surfaceID: surf))
        }
      }
    }
    store.exhaustivity = .off
    await store.send(
      .repositories(
        .sessionsCacheLoaded([
          SessionSummary(
            harness: .pi, sessionID: "real", createdAt: .distantPast, cwd: "/workspace",
            title: "Agent", messageCount: 0, lastActivity: .distantPast)
        ])))
    #expect(store.state.repositories.sessionItems[id: key]?.location == location)
    await store.send(.repositories(.activateSession(key)))
    await store.receive(\.repositories.delegate.focusSession)
    await store.receive(\.repositories.selectTask)
    await store.finish()
    #expect(focused.value.count == 1)
    #expect(focused.value[0] == location)
  }

  // MARK: - Presence links current and restored layouts

  @Test(.dependencies, arguments: [false, true])
  func presenceLinksLayoutsExcludingShells(restored: Bool) {
    var state = state(restored: restored)
    state.settings.agentPresenceBadgesEnabled = false
    let key = AgentPresenceFeature.PresenceKey(agent: .pi, surfaceID: surface)
    state.agentPresence.records[key] = record()
    let snapshots = AppFeature.sessionSnapshots(state: state)
    #expect(snapshots.count == 1)
    #expect(snapshots[0].location == location)
    #expect(snapshots[0].sessionRef == "real")
    #expect(snapshots[0].cwd == "/workspace")
  }

  @Test(.dependencies) func checkedRestoreReleasesAutoSettleGateWithUnmappedLiveIdentity() async {
    let clock = TestClock()
    let store = TestStore(initialState: state()) {
      AppFeature()
    } withDependencies: {
      $0.date.now = .distantPast
      $0.continuousClock = clock
      $0.terminalClient.saveLayoutsWithAgents = { _ in }
    }
    store.exhaustivity = .off
    let key = AgentPresenceFeature.PresenceKey(agent: .pi, surfaceID: UUID())
    await store.send(
      .agentPresence(
        .restoreFromSnapshotChecked(
          records: [
            key: AgentPresenceFeature.RestoredRecord(
              alivePids: [123], activity: .idle, sessionRef: "unmapped")
          ], resumeCandidates: [:])))
    await store.receive(\.repositories.sessionsRestorationCompleted)
    #expect(store.state.repositories.sessionsRestorationFinished)
    #expect(store.state.repositories.sessionsLiveKeys.contains(SessionKey(harness: .pi, sessionID: "unmapped")))
    await clock.advance(by: .seconds(1))
    await store.finish()
  }

  @Test(.dependencies) func unmappedProvisionalRestoreBlocksAutomaticSettlement() async {
    var initial = state()
    initial.repositories.repositories = []
    initial.terminals.layouts = []
    initial.repositories.$persistedLayouts = SharedReader(value: TaskLayoutsFile())
    let summary = SessionSummary(
      harness: .pi, sessionID: "old", createdAt: .distantPast, cwd: "/fixture",
      title: "Old", messageCount: 1, lastActivity: .distantPast)
    initial.repositories.sessionSummaries = [summary]
    initial.repositories.sessionsRefreshSucceeded = true
    let store = TestStore(initialState: initial) {
      AppFeature()
    } withDependencies: {
      $0.date.now = Date(timeIntervalSince1970: 1_000_000)
      $0.continuousClock = TestClock()
      $0.terminalClient.saveLayoutsWithAgents = { _ in }
    }
    store.exhaustivity = .off
    let key = AgentPresenceFeature.PresenceKey(agent: .pi, surfaceID: surface)
    await store.send(
      .agentPresence(
        .restoreFromSnapshotChecked(
          records: [
            key: AgentPresenceFeature.RestoredRecord(
              alivePids: [123], activity: .idle, sessionRef: nil)
          ], resumeCandidates: [:])))
    await store.receive(\.repositories.sessionsRestorationCompleted)
    #expect(store.state.repositories.sessionsRestorationFinished)
    #expect(store.state.repositories.sessionsHasUnresolvedLivePresence)
    #expect(store.state.repositories.sessionSnapshots.isEmpty)
    #expect(store.state.repositories.sessionsLiveKeys.isEmpty)
    await store.send(.repositories(.sessionsRefreshCompleted([summary])))
    #expect(store.state.repositories.sessions[summary.id] == nil)
    await store.finish()
  }

  @Test(.dependencies) func mappedProvisionalInPersistedLayoutDoesNotHoldGlobalGate() async {
    let store = TestStore(initialState: state(restored: true)) {
      AppFeature()
    } withDependencies: {
      $0.date.now = .distantPast
      $0.continuousClock = TestClock()
      $0.terminalClient.saveLayoutsWithAgents = { _ in }
    }
    store.exhaustivity = .off
    let key = AgentPresenceFeature.PresenceKey(agent: .pi, surfaceID: surface)
    await store.send(
      .agentPresence(
        .restoreFromSnapshotChecked(
          records: [
            key: AgentPresenceFeature.RestoredRecord(
              alivePids: [123], activity: .idle, sessionRef: nil)
          ], resumeCandidates: [:])))
    await store.receive(\.repositories.sessionsRestorationCompleted)
    #expect(store.state.repositories.sessionsRestorationFinished)
    #expect(
      !store.state.repositories.sessionsHasUnresolvedLivePresence,
      "surface is in persistedLayouts so presence is mapped; global gate must not fire")
    await store.finish()
  }

  @Test(.dependencies) func checkedRestoreLinksBeforeTurnAndDelayedIndexHydrates() async {
    let clock = TestClock()
    let store = TestStore(initialState: state(restored: true)) {
      AppFeature()
    } withDependencies: {
      $0.date.now = .distantPast
      $0.continuousClock = clock
      $0.terminalClient.saveLayoutsWithAgents = { _ in }
    }
    store.exhaustivity = .off
    let key = AgentPresenceFeature.PresenceKey(agent: .pi, surfaceID: surface)
    await store.send(
      .agentPresence(
        .restoreFromSnapshotChecked(
          records: [
            key: AgentPresenceFeature.RestoredRecord(
              alivePids: [123], activity: .idle, sessionRef: "real")
          ], resumeCandidates: [:])))
    await store.receive(\.agentPresence.delegate)
    await store.receive(\.repositories.sessionSnapshotsChanged)
    await store.receive(\.repositories.sessionsRefreshRequested)
    #expect(store.state.repositories.sessionItems.count == 1)
    #expect(store.state.repositories.sessionItems.first?.location == location)
    let summary = SessionSummary(
      harness: .pi, sessionID: "real", createdAt: .distantPast, cwd: "/workspace",
      title: "Restored title", messageCount: 5, lastActivity: .distantPast)
    await store.send(.repositories(.sessionsCacheLoaded([summary])))
    #expect(store.state.repositories.sessionItems.count == 1)
    #expect(store.state.repositories.sessionItems.first?.title == "Restored title")
    #expect(store.state.repositories.sessionItems.first?.location == location)
    await clock.advance(by: .seconds(1))
    await store.finish()
  }

  @Test(.dependencies) func identityHookMergesProvisionalRowPreservingCreation() async {
    let clock = TestClock()
    var initial = state()
    let key = AgentPresenceFeature.PresenceKey(agent: .pi, surfaceID: surface)
    initial.agentPresence.records[key] = record(ref: nil)
    initial.agentPresence.bySurface[surface] = [.pi]
    initial.repositories.sessionSnapshots = AppFeature.sessionSnapshots(state: initial)
    initial.repositories.taskSnapshots = AppFeature.taskSnapshots(tasks: AppFeature.taskEntries(state: initial))
    initial.repositories.reconcileSessionItems(now: .distantPast)
    #expect(initial.repositories.sessionItems.map(\.id) == [.task(worktree.id.layoutID)])
    #expect(initial.repositories.sessionItems.first?.title == "New session")
    let store = TestStore(initialState: initial) {
      AppFeature()
    } withDependencies: {
      $0.date.now = Date(timeIntervalSince1970: 500)
      $0.continuousClock = clock
      $0.uuid = .incrementing
      $0.terminalClient.saveLayoutsWithAgents = { _ in }
    }
    store.exhaustivity = .off
    let event = AgentHookEvent(
      version: 1, agent: "pi", event: "idle", surfaceID: surface, pid: nil, timestamp: nil,
      sessionRef: "real", data: nil)
    await store.send(.terminalEvent(.agentHookEventReceived(event)))
    await store.receive(\.agentPresence)
    await store.receive(\.repositories.sessionSnapshotsChanged)
    await store.receive(\.repositories.sessionsRefreshRequested)
    await clock.advance(by: .seconds(1))
    await store.finish()
    await store.skipReceivedActions(strict: false)
    // The task's row stays the same row: the session only becomes its primary.
    #expect(store.state.repositories.sessionItems.map(\.id) == [.task(worktree.id.layoutID)])
    #expect(store.state.repositories.sessionItems.first?.primary == SessionKey(harness: .pi, sessionID: "real"))
    #expect(store.state.repositories.sessionItems.first?.createdAt == .distantPast)
  }

  // MARK: - Dormant resume with real temp directory fixtures

  @Test(.dependencies) func dormantResumeWithMissingCwdSendsNoTerminalCommand() async {
    let sent = LockIsolated<[TerminalClient.Command]>([])
    var initial = state()
    let key = SessionKey(harness: .pi, sessionID: "abc123")
    initial.repositories.sessionItems = [
      SessionSidebarItemFeature.State(
        id: .implicit(key), title: "Dormant", cwd: "/tmp/supacode-test-nonexistent-\(UUID())",
        createdAt: .distantPast, location: nil)
    ]
    let store = TestStore(initialState: initial) {
      AppFeature()
    } withDependencies: {
      $0.date.now = .distantPast
      $0.uuid = .incrementing
      $0.continuousClock = ImmediateClock()
      $0.terminalClient.send = { cmd in sent.withValue { $0.append(cmd) } }
    }
    store.exhaustivity = .off
    await store.send(.repositories(.activateSession(.implicit(key))))
    await store.receive(\.repositories.delegate.resumeSession)
    await store.finish()
    #expect(sent.value.isEmpty)
    #expect(store.state.pendingSessionLaunch == nil)
  }

  @Test(.dependencies) func dormantResumeWithExistingWorktreeCreatesExactTab() async throws {
    let tmpDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("supacode-test-\(UUID())")
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    let sent = LockIsolated<[TerminalClient.Command]>([])
    var initial = state()
    let standardTmp = tmpDir.standardizedFileURL
    let tmpPath = standardTmp.path(percentEncoded: false)
    let tmpWorktreeID = WorktreeID(tmpPath)
    let tmpWorktree = Worktree(
      id: tmpWorktreeID,
      name: "test-session", detail: "",
      workingDirectory: standardTmp,
      repositoryRootURL: standardTmp)
    initial.repositories.repositories.append(
      Repository(
        id: RepositoryID(tmpPath), rootURL: standardTmp, name: "test-session",
        worktrees: [tmpWorktree]))
    let key = SessionKey(harness: .pi, sessionID: "piSess1")
    initial.repositories.sessionItems = [
      SessionSidebarItemFeature.State(
        id: .implicit(key), title: "Dormant",
        cwd: standardTmp.path(percentEncoded: false),
        createdAt: .distantPast, location: nil)
    ]
    let store = TestStore(initialState: initial) {
      AppFeature()
    } withDependencies: {
      $0.date.now = .distantPast
      $0.uuid = .incrementing
      $0.continuousClock = ImmediateClock()
      $0.terminalClient.send = { cmd in sent.withValue { $0.append(cmd) } }
    }
    store.exhaustivity = .off
    await store.send(.repositories(.activateSession(.implicit(key))))
    await store.receive(\.repositories.delegate.resumeSession)
    await store.receive(\.launchSessionCompleted)
    await store.finish()

    let createInputs = sent.value.compactMap { cmd -> String? in
      if case .createTabWithInput(_, _, let input, _, _, _, _, _) = cmd { return input }
      return nil
    }
    #expect(createInputs == ["pi --session piSess1"])
    let createFlags = sent.value.compactMap { cmd -> (setup: Bool, focusing: Bool)? in
      if case .createTabWithInput(_, _, _, let setup, _, _, let focusing, _) = cmd {
        return (setup, focusing)
      }
      return nil
    }
    #expect(createFlags.count == 1)
    #expect(createFlags[0].setup == false)
    #expect(createFlags[0].focusing == true)
    #expect(store.state.pendingSessionLaunch == nil)
  }

  @Test(.dependencies) func dormantResumeBranchMismatchConfirmsOnceBeforeLaunch() async throws {
    let tmpDir = try temporaryDirectory(named: "branch-mismatch")
    defer { try? FileManager.default.removeItem(at: tmpDir) }
    let sent = LockIsolated<[TerminalClient.Command]>([])
    var initial = state()
    let worktree = Worktree(
      id: WorktreeID(tmpDir.path), name: "branch-mismatch", detail: "",
      workingDirectory: tmpDir, repositoryRootURL: tmpDir)
    initial.repositories.repositories.append(
      Repository(id: RepositoryID(tmpDir.path), rootURL: tmpDir, name: "branch-mismatch", worktrees: [worktree]))
    let key = SessionKey(harness: .pi, sessionID: "mismatch")
    initial.repositories.sessionItems = [
      SessionSidebarItemFeature.State(
        id: .implicit(key), title: "Dormant", cwd: tmpDir.path, createdAt: .distantPast)
    ]
    initial.repositories.$sessions.withLock { $0[key] = SessionSidecarEntry(branches: ["old-branch"]) }
    let store = TestStore(initialState: initial) {
      AppFeature()
    } withDependencies: {
      $0.date.now = .distantPast
      $0.uuid = .incrementing
      $0[GitClientDependency.self].branchName = { _ in "new-branch" }
      $0.terminalClient.send = { cmd in sent.withValue { $0.append(cmd) } }
    }
    store.exhaustivity = .off
    await store.send(.repositories(.activateSession(.implicit(key))))
    await store.receive(\.repositories.delegate.resumeSession)
    await store.receive(\.resumeBranchProbeCompleted) {
      $0.pendingBranchMismatchResume = PendingBranchMismatchResume(
        key: key, cwd: tmpDir, command: "pi --session mismatch",
        recordedBranch: "old-branch", currentBranch: "new-branch")
      $0.alert = AlertState {
        TextState("Resume on different branch?")
      } actions: {
        ButtonState(role: .cancel, action: .cancelBranchMismatchResume) { TextState("Cancel") }
        ButtonState(action: .confirmBranchMismatchResume) { TextState("Resume Anyway") }
      } message: {
        TextState(
          "This session last worked on old-branch, but this folder is on new-branch. "
            + "Supacode will not checkout branches for you."
        )
      }
    }
    #expect(sent.value.isEmpty)
    await store.send(.alert(.presented(.confirmBranchMismatchResume))) {
      $0.alert = nil
      $0.pendingBranchMismatchResume = nil
      $0.pendingSessionLaunch = PendingSessionLaunch(
        key: key, cwd: tmpDir, command: "pi --session mismatch", requestID: UUID(0), launched: true)
    }
    await store.receive(\.launchSessionCompleted) { $0.pendingSessionLaunch = nil }
    await store.finish()
    #expect(sent.value.count == 1)
  }

  @Test(.dependencies) func resumeProbeReservationRejectsDuplicatesAndCancelledCompletions() async throws {
    let directory = try temporaryDirectory(named: "controlled-probe")
    defer { try? FileManager.default.removeItem(at: directory) }
    let key = SessionKey(harness: .pi, sessionID: "controlled")
    var initial = state()
    initial.repositories.sessionItems = [
      SessionSidebarItemFeature.State(
        id: .implicit(key), title: "Controlled", cwd: directory.path, createdAt: .distantPast)
    ]
    // Index-backed, so the row survives the reconcile a roster change now runs for task rows.
    initial.repositories.sessionSummaries = [
      SessionSummary(
        harness: .pi, sessionID: "controlled", createdAt: .distantPast, cwd: directory.path,
        title: "Controlled", messageCount: 0, lastActivity: .distantPast)
    ]
    initial.repositories.$sessions.withLock { $0[key] = SessionSidecarEntry(branches: ["old"]) }
    let branches = AsyncStream<String>.makeStream()
    let probes = LockIsolated(0)
    let sent = LockIsolated<[TerminalClient.Command]>([])
    let store = TestStore(initialState: initial) {
      AppFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.date.now = .distantPast
      $0[GitClientDependency.self].branchName = { _ in
        probes.withValue { $0 += 1 }
        for await branch in branches.stream { return branch }
        return nil
      }
      $0.terminalClient.send = { command in
        if case .createTabWithInput = command { sent.withValue { $0.append(command) } }
      }
    }
    store.exhaustivity = .off
    await store.send(.repositories(.delegate(.resumeSession(key))))
    #expect(store.state.pendingSessionLaunch?.probing == true)
    await store.send(.repositories(.delegate(.resumeSession(key))))
    await store.send(.repositories(.delegate(.repositoriesChanged(initial.repositories.repositories))))
    #expect(sent.value.isEmpty)
    branches.continuation.yield("different")
    await store.receive(\.resumeBranchProbeCompleted)
    #expect(probes.value == 1)
    #expect(store.state.pendingBranchMismatchResume != nil)
    await store.send(.alert(.presented(.cancelBranchMismatchResume)))
    #expect(store.state.pendingSessionLaunch == nil)
    await store.send(.repositories(.delegate(.resumeSession(key))))
    #expect(store.state.pendingSessionLaunch?.requestID == UUID(1))
    await store.send(.resumeBranchProbeCompleted(requestID: UUID(0), currentBranch: "old"))
    #expect(store.state.pendingSessionLaunch?.probing == true)
    #expect(store.state.pendingBranchMismatchResume == nil)
    branches.continuation.yield("different")
    await store.receive(\.resumeBranchProbeCompleted)
    await store.send(.alert(.presented(.cancelBranchMismatchResume)))
    await store.send(.resumeBranchProbeCompleted(requestID: UUID(1), currentBranch: "old"))
    #expect(store.state.pendingSessionLaunch == nil)
    #expect(store.state.pendingBranchMismatchResume == nil)
    #expect(sent.value.isEmpty)
    branches.continuation.finish()
    await store.finish()
  }

  @Test(.dependencies) func dormantResumeKnownBranchSkipsMismatchAlert() async throws {
    let tmpDir = try temporaryDirectory(named: "known-branch")
    defer { try? FileManager.default.removeItem(at: tmpDir) }
    let sent = LockIsolated<[TerminalClient.Command]>([])
    var initial = state()
    let worktree = Worktree(
      id: WorktreeID(tmpDir.path), name: "known-branch", detail: "",
      workingDirectory: tmpDir, repositoryRootURL: tmpDir)
    initial.repositories.repositories.append(
      Repository(id: RepositoryID(tmpDir.path), rootURL: tmpDir, name: "known-branch", worktrees: [worktree]))
    let key = SessionKey(harness: .pi, sessionID: "known")
    initial.repositories.sessionItems = [
      SessionSidebarItemFeature.State(
        id: .implicit(key), title: "Dormant", cwd: tmpDir.path, createdAt: .distantPast)
    ]
    initial.repositories.$sessions.withLock { $0[key] = SessionSidecarEntry(branches: ["main", "feature"]) }
    let store = TestStore(initialState: initial) {
      AppFeature()
    } withDependencies: {
      $0.date.now = .distantPast
      $0.uuid = .incrementing
      $0[GitClientDependency.self].branchName = { _ in "main" }
      $0.terminalClient.send = { cmd in sent.withValue { $0.append(cmd) } }
    }
    store.exhaustivity = .off
    await store.send(.repositories(.activateSession(.implicit(key))))
    await store.receive(\.repositories.delegate.resumeSession)
    await store.receive(\.resumeBranchProbeCompleted) {
      $0.pendingSessionLaunch = PendingSessionLaunch(
        key: key, cwd: tmpDir, command: "pi --session known", requestID: UUID(0), launched: true)
    }
    await store.receive(\.launchSessionCompleted) { $0.pendingSessionLaunch = nil }
    await store.finish()
    #expect(sent.value.count == 1)
    #expect(store.state.alert == nil)
  }

  // MARK: - Sessions navigation with focused surface precedence

  @Test(.dependencies) func selectNextWorktreeOnSessionsUsesLiveRows() async {
    let focused = LockIsolated<[SessionLocation]>([])
    var initial = state()
    @Shared(.sidebarTab) var tab
    $tab.withLock { $0 = SidebarTab.sessions.rawValue }
    let key1 = SessionKey(harness: .pi, sessionID: "sess1")
    let key2 = SessionKey(harness: .pi, sessionID: "sess2")
    let surface2 = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!
    let tab2 = TabID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000005")!)
    let layout = initial.terminals.layouts[id: worktree.id.layoutID]!.layout
    let newTabs =
      layout.panes[0].tabs + [
        TabItem(
          id: tab2, title: "Agent2",
          content: ContentSnapshot(
            id: ContentID(rawValue: surface2),
            state: .terminal(TerminalContentState(workingDirectory: "/workspace"))))
      ]
    initial.terminals.layouts[id: worktree.id.layoutID]?.layout.panes[0].tabs = IdentifiedArray(uniqueElements: newTabs)
    let presenceKey1 = AgentPresenceFeature.PresenceKey(agent: .pi, surfaceID: surface)
    initial.agentPresence.records[presenceKey1] = record(ref: "sess1")
    initial.agentPresence.bySurface[surface] = [.pi]
    let presenceKey2 = AgentPresenceFeature.PresenceKey(agent: .pi, surfaceID: surface2)
    initial.agentPresence.records[presenceKey2] = record(ref: "sess2")
    initial.agentPresence.bySurface[surface2] = [.pi]
    initial.repositories.sessionSnapshots = AppFeature.sessionSnapshots(state: initial)
    initial.repositories.reconcileSessionItems(now: .distantPast)
    initial.repositories.recomputeSessionsSidebarStructureIfChanged()
    initial.repositories.sessionSelection = .implicit(key1)
    let sent = LockIsolated<[TerminalClient.Command]>([])
    initial.terminals.selectedLayoutID = worktree.id.layoutID
    initial.terminals.layouts[id: worktree.id.layoutID]?.layout.panes[0].selectedTabID = self.tab
    let store = TestStore(initialState: initial) {
      AppFeature()
    } withDependencies: {
      $0.date.now = .distantPast
      $0.terminalClient.send = { cmd in sent.withValue { $0.append(cmd) } }
      $0.terminalClient.focusSurface = { layoutID, context, tab, surf in
        focused.withValue {
          $0.append(SessionLocation(layoutID: layoutID, directoryID: context.worktreeID, tabID: tab, surfaceID: surf))
        }
      }
    }
    store.exhaustivity = .off
    await store.send(.repositories(.selectNextWorktree)) {
      $0.repositories.sessionSelection = .implicit(key2)
    }
    await store.finish()
    #expect(
      !sent.value.contains {
        if case .createTabWithInput = $0 { return true }
        return false
      })
    #expect(focused.value == [initial.repositories.sessionItems[id: .implicit(key2)]!.location!])
  }

  @Test(.dependencies) func selectPreviousWorktreeOnSessionsWrapsLiveRows() async {
    let focused = LockIsolated<[SessionLocation]>([])
    var initial = state()
    @Shared(.sidebarTab) var tab
    $tab.withLock { $0 = SidebarTab.sessions.rawValue }
    let key1 = SessionKey(harness: .pi, sessionID: "sess1")
    let key2 = SessionKey(harness: .pi, sessionID: "sess2")
    let surface2 = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!
    let tab2 = TabID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000005")!)
    let layout = initial.terminals.layouts[id: worktree.id.layoutID]!.layout
    let newTabs =
      layout.panes[0].tabs + [
        TabItem(
          id: tab2, title: "Agent2",
          content: ContentSnapshot(
            id: ContentID(rawValue: surface2),
            state: .terminal(TerminalContentState(workingDirectory: "/workspace"))))
      ]
    initial.terminals.layouts[id: worktree.id.layoutID]?.layout.panes[0].tabs = IdentifiedArray(uniqueElements: newTabs)
    let presenceKey1 = AgentPresenceFeature.PresenceKey(agent: .pi, surfaceID: surface)
    initial.agentPresence.records[presenceKey1] = record(ref: "sess1")
    initial.agentPresence.bySurface[surface] = [.pi]
    let presenceKey2 = AgentPresenceFeature.PresenceKey(agent: .pi, surfaceID: surface2)
    initial.agentPresence.records[presenceKey2] = record(ref: "sess2")
    initial.agentPresence.bySurface[surface2] = [.pi]
    initial.repositories.sessionSnapshots = AppFeature.sessionSnapshots(state: initial)
    initial.repositories.reconcileSessionItems(now: .distantPast)
    initial.repositories.recomputeSessionsSidebarStructureIfChanged()
    initial.repositories.sessionSelection = .implicit(key1)
    let sent = LockIsolated<[TerminalClient.Command]>([])
    initial.terminals.selectedLayoutID = worktree.id.layoutID
    initial.terminals.layouts[id: worktree.id.layoutID]?.layout.panes[0].selectedTabID = self.tab
    let store = TestStore(initialState: initial) {
      AppFeature()
    } withDependencies: {
      $0.date.now = .distantPast
      $0.terminalClient.send = { cmd in sent.withValue { $0.append(cmd) } }
      $0.terminalClient.focusSurface = { layoutID, context, tab, surf in
        focused.withValue {
          $0.append(SessionLocation(layoutID: layoutID, directoryID: context.worktreeID, tabID: tab, surfaceID: surf))
        }
      }
    }
    store.exhaustivity = .off
    await store.send(.repositories(.selectPreviousWorktree)) {
      $0.repositories.sessionSelection = .implicit(key2)
    }
    await store.finish()
    #expect(
      !sent.value.contains {
        if case .createTabWithInput = $0 { return true }
        return false
      })
    #expect(focused.value == [initial.repositories.sessionItems[id: .implicit(key2)]!.location!])
  }

  @Test(.dependencies) func selectWorktreeAtHotkeySlotOnSessionsJumpsToNthLive() async {
    let focused = LockIsolated<[SessionLocation]>([])
    var initial = state()
    @Shared(.sidebarTab) var tab
    $tab.withLock { $0 = SidebarTab.sessions.rawValue }
    let key1 = SessionKey(harness: .pi, sessionID: "sess1")
    let key2 = SessionKey(harness: .pi, sessionID: "sess2")
    let surface2 = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!
    let tab2 = TabID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000005")!)
    let layout = initial.terminals.layouts[id: worktree.id.layoutID]!.layout
    let newTabs =
      layout.panes[0].tabs + [
        TabItem(
          id: tab2, title: "Agent2",
          content: ContentSnapshot(
            id: ContentID(rawValue: surface2),
            state: .terminal(TerminalContentState(workingDirectory: "/workspace"))))
      ]
    initial.terminals.layouts[id: worktree.id.layoutID]?.layout.panes[0].tabs = IdentifiedArray(uniqueElements: newTabs)
    let presenceKey1 = AgentPresenceFeature.PresenceKey(agent: .pi, surfaceID: surface)
    initial.agentPresence.records[presenceKey1] = record(ref: "sess1")
    initial.agentPresence.bySurface[surface] = [.pi]
    let presenceKey2 = AgentPresenceFeature.PresenceKey(agent: .pi, surfaceID: surface2)
    initial.agentPresence.records[presenceKey2] = record(ref: "sess2")
    initial.agentPresence.bySurface[surface2] = [.pi]
    initial.repositories.sessionSnapshots = AppFeature.sessionSnapshots(state: initial)
    initial.repositories.reconcileSessionItems(now: .distantPast)
    initial.repositories.recomputeSessionsSidebarStructureIfChanged()
    let sent = LockIsolated<[TerminalClient.Command]>([])
    initial.terminals.selectedLayoutID = worktree.id.layoutID
    initial.terminals.layouts[id: worktree.id.layoutID]?.layout.panes[0].selectedTabID = self.tab
    let store = TestStore(initialState: initial) {
      AppFeature()
    } withDependencies: {
      $0.date.now = .distantPast
      $0.terminalClient.send = { cmd in sent.withValue { $0.append(cmd) } }
      $0.terminalClient.focusSurface = { layoutID, context, tab, surf in
        focused.withValue {
          $0.append(SessionLocation(layoutID: layoutID, directoryID: context.worktreeID, tabID: tab, surfaceID: surf))
        }
      }
    }
    store.exhaustivity = .off
    await store.send(.repositories(.selectWorktreeAtHotkeySlot(1))) {
      $0.repositories.sessionSelection = .implicit(key2)
    }
    await store.finish()
    #expect(
      !sent.value.contains {
        if case .createTabWithInput = $0 { return true }
        return false
      })
    #expect(focused.value == [initial.repositories.sessionItems[id: .implicit(key2)]!.location!])
  }

  @Test(.dependencies) func focusedSurfaceResolvesToSessionRowID() {
    var state = state()
    state.terminals.selectedLayoutID = worktree.id.layoutID
    state.terminals.layouts[id: worktree.id.layoutID]?.layout.panes[0].selectedTabID = tab
    let key = SessionKey(harness: .pi, sessionID: "real")
    let location = SessionLocation(
      layoutID: worktree.id.layoutID, directoryID: worktree.id, tabID: TabID(rawValue: tab.id), surfaceID: surface)
    let snapshot = SessionLiveSnapshot(
      harness: .pi, sessionRef: "real", cwd: "/workspace", location: location)
    state.repositories.sessionSnapshots = [snapshot]
    state.repositories.reconcileSessionItems(now: .distantPast)
    let resolved = AppFeature.focusedSessionRowID(state: state)
    #expect(resolved == .implicit(key))
  }

  @Test(.dependencies) func sidebarSelectionFollowsFocusedTabOnlyWhenFocusMoves() {
    var state = state()
    state.terminals.selectedLayoutID = worktree.id.layoutID
    state.terminals.layouts[id: worktree.id.layoutID]?.layout.panes[0].selectedTabID = tab
    let key = SessionKey(harness: .pi, sessionID: "real")
    state.repositories.sessionSnapshots = [
      SessionLiveSnapshot(harness: .pi, sessionRef: "real", cwd: "/workspace", location: location)
    ]
    AppFeature.syncSessionSelectionToFocus(state: &state)
    #expect(state.repositories.sessionSelection == nil, "row not reconciled yet; retried later")
    state.repositories.reconcileSessionItems(now: .distantPast)
    AppFeature.syncSessionSelectionToFocus(state: &state)
    #expect(state.repositories.sessionSelection == .implicit(key))

    state.repositories.sessionSelection = nil
    AppFeature.syncSessionSelectionToFocus(state: &state)
    #expect(state.repositories.sessionSelection == nil, "a manual selection survives until focus moves")

    state.terminals.layouts[id: worktree.id.layoutID]?.layout.panes[0].selectedTabID = TabID(rawValue: shell)
    AppFeature.syncSessionSelectionToFocus(state: &state)
    #expect(state.repositories.sessionSelection == nil)
    state.terminals.layouts[id: worktree.id.layoutID]?.layout.panes[0].selectedTabID = tab
    AppFeature.syncSessionSelectionToFocus(state: &state)
    #expect(state.repositories.sessionSelection == .implicit(key))
  }

  @Test(.dependencies) func focusedSurfaceWithNoPresenceReturnsNil() {
    let state = state()
    let resolved = AppFeature.focusedSessionRowID(state: state)
    #expect(resolved == nil)
  }

  @Test(.dependencies) func focusedSurfacePrecedesStoredSelectionInNavigation() async {
    let focused = LockIsolated<[SessionLocation]>([])
    var initial = state()
    @Shared(.sidebarTab) var tab
    $tab.withLock { $0 = SidebarTab.sessions.rawValue }
    let key1 = SessionKey(harness: .pi, sessionID: "sess1")
    let key2 = SessionKey(harness: .pi, sessionID: "sess2")
    let surface2 = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!
    let tab2 = TabID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000005")!)
    let layout = initial.terminals.layouts[id: worktree.id.layoutID]!.layout
    let newTabs =
      layout.panes[0].tabs + [
        TabItem(
          id: tab2, title: "Agent2",
          content: ContentSnapshot(
            id: ContentID(rawValue: surface2),
            state: .terminal(TerminalContentState(workingDirectory: "/workspace"))))
      ]
    initial.terminals.layouts[id: worktree.id.layoutID]?.layout.panes[0].tabs = IdentifiedArray(uniqueElements: newTabs)
    initial.terminals.layouts[id: worktree.id.layoutID]?.layout.panes[0].selectedTabID = tab2
    let presenceKey1 = AgentPresenceFeature.PresenceKey(agent: .pi, surfaceID: surface)
    initial.agentPresence.records[presenceKey1] = record(ref: "sess1")
    initial.agentPresence.bySurface[surface] = [.pi]
    let presenceKey2 = AgentPresenceFeature.PresenceKey(agent: .pi, surfaceID: surface2)
    initial.agentPresence.records[presenceKey2] = record(ref: "sess2")
    initial.agentPresence.bySurface[surface2] = [.pi]
    initial.repositories.sessionSnapshots = AppFeature.sessionSnapshots(state: initial)
    initial.repositories.reconcileSessionItems(now: .distantPast)
    initial.repositories.recomputeSessionsSidebarStructureIfChanged()
    initial.repositories.sessionSelection = .implicit(key1)
    let sent = LockIsolated<[TerminalClient.Command]>([])
    initial.terminals.selectedLayoutID = worktree.id.layoutID
    let store = TestStore(initialState: initial) {
      AppFeature()
    } withDependencies: {
      $0.date.now = .distantPast
      $0.terminalClient.send = { cmd in sent.withValue { $0.append(cmd) } }
      $0.terminalClient.focusSurface = { layoutID, context, tab, surf in
        focused.withValue {
          $0.append(SessionLocation(layoutID: layoutID, directoryID: context.worktreeID, tabID: tab, surfaceID: surf))
        }
      }
    }
    store.exhaustivity = .off
    await store.send(.repositories(.selectNextWorktree)) {
      $0.repositories.sessionSelection = .implicit(key1)
    }
    await store.finish()
    #expect(
      !sent.value.contains {
        if case .createTabWithInput = $0 { return true }
        return false
      })
    #expect(focused.value == [initial.repositories.sessionItems[id: .implicit(key1)]!.location!])
  }

  @Test(.dependencies) func selectTerminalTabAtIndexUnchangedWhenSessionsActive() async {
    var initial = state()
    @Shared(.sidebarTab) var tab
    $tab.withLock { $0 = SidebarTab.sessions.rawValue }
    let sent = LockIsolated<[TerminalClient.Command]>([])
    let store = TestStore(initialState: initial) {
      AppFeature()
    } withDependencies: {
      $0.date.now = .distantPast
      $0.terminalClient.send = { cmd in sent.withValue { $0.append(cmd) } }
    }
    store.exhaustivity = .off
    await store.send(.selectTerminalTabAtIndex(1))
    await store.finish()
    let selectTabs = sent.value.compactMap { cmd -> Int? in
      if case .selectTabAtIndex(_, let index) = cmd { return index }
      return nil
    }
    #expect(selectTabs == [1])
    #expect(store.state.pendingSessionLaunch == nil)
  }

  // MARK: - Existing worktree resume creates exactly one tab per click

  @Test(.dependencies) func existingWorktreeResumeProducesExactlyOneTab() async throws {
    let tmpDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("supacode-test-dedup-\(UUID())")
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    let sent = LockIsolated<[TerminalClient.Command]>([])
    var initial = state()
    let standardTmp = tmpDir.standardizedFileURL
    let tmpPath = standardTmp.path(percentEncoded: false)
    let tmpWorktree = Worktree(
      id: WorktreeID(tmpPath), name: "dedup", detail: "",
      workingDirectory: standardTmp, repositoryRootURL: standardTmp)
    initial.repositories.repositories.append(
      Repository(
        id: RepositoryID(tmpPath), rootURL: standardTmp, name: "dedup",
        worktrees: [tmpWorktree]))
    let key = SessionKey(harness: .pi, sessionID: "piSess2")
    initial.repositories.sessionItems = [
      SessionSidebarItemFeature.State(
        id: .implicit(key), title: "Dormant",
        cwd: tmpPath, createdAt: .distantPast, location: nil)
    ]
    let store = TestStore(initialState: initial) {
      AppFeature()
    } withDependencies: {
      $0.date.now = .distantPast
      $0.uuid = .incrementing
      $0.continuousClock = ImmediateClock()
      $0.terminalClient.send = { cmd in sent.withValue { $0.append(cmd) } }
    }
    store.exhaustivity = .off

    await store.send(.repositories(.activateSession(.implicit(key))))
    await store.receive(\.repositories.delegate.resumeSession)
    await store.receive(\.launchSessionCompleted)
    await store.finish()

    let tabInputs = sent.value.compactMap { cmd -> String? in
      if case .createTabWithInput(_, _, let input, _, _, _, _, _) = cmd { return input }
      return nil
    }
    #expect(tabInputs == ["pi --session piSess2"])
    #expect(store.state.pendingSessionLaunch == nil)
  }

  // MARK: - Folder registration completes pending launch even with unchanged snapshots

  @Test(.dependencies) func pendingLaunchFiresOnRepositoriesChangedEvenWithUnchangedSnapshots() async throws {
    let tmpDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("supacode-test-pending-\(UUID())")
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    let sent = LockIsolated<[TerminalClient.Command]>([])
    var initial = state()
    let standardTmp = tmpDir.standardizedFileURL
    let key = SessionKey(harness: .pi, sessionID: "piSess3")
    initial.repositories.sessionItems = [
      SessionSidebarItemFeature.State(
        id: .implicit(key), title: "Dormant",
        cwd: standardTmp.path(percentEncoded: false),
        createdAt: .distantPast, location: nil)
    ]
    let store = TestStore(initialState: initial) {
      AppFeature()
    } withDependencies: {
      $0.date.now = .distantPast
      $0.uuid = .incrementing
      $0.continuousClock = ImmediateClock()
      $0.terminalClient.send = { cmd in sent.withValue { $0.append(cmd) } }
    }
    store.exhaustivity = .off

    await store.send(.repositories(.activateSession(.implicit(key))))
    await store.receive(\.repositories.delegate.resumeSession)
    #expect(store.state.pendingSessionLaunch != nil)

    await store.receive(\.repositories.delegate.repositoriesChanged)
    await store.receive(\.launchSessionCompleted)
    await store.finish()

    let created = sent.value.compactMap { cmd -> String? in
      if case .createTabWithInput(_, _, let input, _, _, _, _, _) = cmd { return input }
      return nil
    }
    #expect(created == ["pi --session piSess3"])
    #expect(store.state.pendingSessionLaunch == nil)
  }

  // MARK: - Branch capture writes to sidecar on busy/idle sequence

  @Test(.dependencies) func busyThenIdleCapturesBranchInSidecar() async {
    let clock = TestClock()
    var initial = state()
    let presenceKey = AgentPresenceFeature.PresenceKey(agent: .pi, surfaceID: surface)
    initial.agentPresence.records[presenceKey] = record(ref: "branchSess")
    initial.agentPresence.bySurface[surface] = [.pi]
    initial.repositories.sessionSnapshots = AppFeature.sessionSnapshots(state: initial)
    initial.repositories.reconcileSessionItems(now: .distantPast)
    let branchCalls = LockIsolated<[URL]>([])
    let store = TestStore(initialState: initial) {
      AppFeature()
    } withDependencies: {
      $0.date.now = .distantPast
      $0.uuid = .incrementing
      $0.continuousClock = clock
      $0.terminalClient.saveLayoutsWithAgents = { _ in }
      $0[GitClientDependency.self].branchName = { url in
        branchCalls.withValue { $0.append(url) }
        return "feature/test"
      }
    }
    store.exhaustivity = .off

    let busyEvent = AgentHookEvent(
      version: 1, agent: "pi", event: "busy", surfaceID: surface, pid: nil, timestamp: nil,
      sessionRef: "branchSess", data: nil)
    await store.send(.terminalEvent(.agentHookEventReceived(busyEvent)))
    await store.receive(\.agentPresence)
    await store.receive(\.repositories)
    await clock.advance(by: .milliseconds(600))
    await store.finish()

    let sessionKey = SessionKey(harness: .pi, sessionID: "branchSess")
    let entry = store.state.repositories.sessions[sessionKey]
    #expect(entry?.branches == ["feature/test"])

    let idleEvent = AgentHookEvent(
      version: 1, agent: "pi", event: "idle", surfaceID: surface, pid: nil, timestamp: nil,
      sessionRef: "branchSess", data: nil)
    await store.send(.terminalEvent(.agentHookEventReceived(idleEvent)))
    await store.receive(\.agentPresence)
    await store.receive(\.repositories)
    await clock.advance(by: .milliseconds(600))
    await store.finish()

    let updatedEntry = store.state.repositories.sessions[sessionKey]
    #expect(updatedEntry?.branches == ["feature/test"])
    #expect(branchCalls.value.count >= 1)
  }

  // MARK: - Pending guard: second activation while launched=true is a no-op

  @Test(.dependencies) func secondActivationWhileLaunchedTrueProducesNoEffect() async throws {
    let tmpDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("supacode-test-nodup-\(UUID())")
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    let sent = LockIsolated<[TerminalClient.Command]>([])
    let standardTmp = tmpDir.standardizedFileURL
    let tmpPath = standardTmp.path(percentEncoded: false)
    let key = SessionKey(harness: .pi, sessionID: "piNodup")
    var initial = state()
    let reqID = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!
    initial.pendingSessionLaunch = PendingSessionLaunch(
      key: key, cwd: standardTmp,
      command: "pi --session piNodup", requestID: reqID, launched: true)
    initial.repositories.sessionItems = [
      SessionSidebarItemFeature.State(
        id: .implicit(key), title: "Dormant", cwd: tmpPath,
        createdAt: .distantPast, location: nil)
    ]
    let store = TestStore(initialState: initial) {
      AppFeature()
    } withDependencies: {
      $0.date.now = .distantPast
      $0.uuid = .incrementing
      $0.continuousClock = ImmediateClock()
      $0.terminalClient.send = { cmd in sent.withValue { $0.append(cmd) } }
    }
    store.exhaustivity = .off

    await store.send(.repositories(.activateSession(.implicit(key))))
    await store.receive(\.repositories.delegate.resumeSession)
    await store.finish()

    #expect(sent.value.isEmpty)
    #expect(store.state.pendingSessionLaunch?.requestID == reqID)
  }

  @Test(.dependencies) func launchCompletedClearsPendingByRequestID() async {
    let reqID = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000001")!
    let otherID = UUID(uuidString: "CCCCCCCC-0000-0000-0000-000000000001")!
    let key = SessionKey(harness: .pi, sessionID: "piClear")
    var initial = state()
    initial.pendingSessionLaunch = PendingSessionLaunch(
      key: key, cwd: URL(fileURLWithPath: "/workspace"),
      command: "pi --session piClear", requestID: reqID, launched: true)
    let store = TestStore(initialState: initial) {
      AppFeature()
    } withDependencies: {
      $0.date.now = .distantPast
    }
    store.exhaustivity = .off

    await store.send(.launchSessionCompleted(requestID: otherID))
    await store.finish()
    #expect(store.state.pendingSessionLaunch?.requestID == reqID)

    await store.send(.launchSessionCompleted(requestID: reqID))
    await store.finish()
    #expect(store.state.pendingSessionLaunch == nil)
  }

  // MARK: - Branch capture: two surfaces queued, FIFO ordered, no cross-cancellation

  @Test(.dependencies) func branchCaptureQueuesTwoSurfacesInOrder() async throws {
    let surface2 = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!
    let tab2 = TabID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000005")!)
    let paneID2 = PaneID()
    let tabs2: IdentifiedArrayOf<TabItem> = [
      TabItem(
        id: tab2, title: "Agent2",
        content: ContentSnapshot(
          id: ContentID(rawValue: surface2),
          state: .terminal(TerminalContentState(workingDirectory: "/workspace2"))))
    ]
    let layout2 = PaneLayout(
      tree: SplitTree(view: paneID2),
      panes: [Pane(id: paneID2, tabs: tabs2, selectedTabID: tab2)])
    let worktree2 = Worktree(
      id: WorktreeID("/workspace2"), name: "workspace2", detail: "",
      workingDirectory: URL(fileURLWithPath: "/workspace2"),
      repositoryRootURL: URL(fileURLWithPath: "/workspace2"))

    var initial = state()
    initial.repositories.repositories.append(
      Repository(
        id: RepositoryID("/workspace2"), rootURL: worktree2.workingDirectory, name: "workspace2",
        worktrees: [worktree2]))
    initial.terminals.layouts.append(LayoutFeature.State(id: worktree2.id.layoutID, layout: layout2))

    let presenceKey1 = AgentPresenceFeature.PresenceKey(agent: .pi, surfaceID: surface)
    let presenceKey2 = AgentPresenceFeature.PresenceKey(agent: .pi, surfaceID: surface2)
    initial.agentPresence.records[presenceKey1] = record(ref: "sess1")
    initial.agentPresence.records[presenceKey2] = record(ref: "sess2")
    initial.agentPresence.bySurface[surface] = [.pi]
    initial.agentPresence.bySurface[surface2] = [.pi]
    initial.repositories.sessionSnapshots = AppFeature.sessionSnapshots(state: initial)
    initial.repositories.reconcileSessionItems(now: .distantPast)

    let branchResults = LockIsolated<[(URL, String)]>([
      (URL(fileURLWithPath: "/workspace"), "main"),
      (URL(fileURLWithPath: "/workspace2"), "feat/two"),
    ])
    let probeOrder = LockIsolated<[URL]>([])
    let store = TestStore(initialState: initial) {
      AppFeature()
    } withDependencies: {
      $0.date.now = .distantPast
      $0.uuid = .incrementing
      $0.continuousClock = ImmediateClock()
      $0.terminalClient.saveLayoutsWithAgents = { _ in }
      $0[GitClientDependency.self].branchName = { url in
        probeOrder.withValue { $0.append(url) }
        return branchResults.withValue { pairs in
          pairs.first { $0.0.path == url.path }.map { $0.1 }
        }
      }
    }
    store.exhaustivity = .off

    let busy1 = AgentHookEvent(
      version: 1, agent: "pi", event: "busy", surfaceID: surface, pid: nil, timestamp: nil,
      sessionRef: "sess1", data: nil)
    let busy2 = AgentHookEvent(
      version: 1, agent: "pi", event: "busy", surfaceID: surface2, pid: nil, timestamp: nil,
      sessionRef: "sess2", data: nil)

    await store.send(.terminalEvent(.agentHookEventReceived(busy1)))
    await store.send(.terminalEvent(.agentHookEventReceived(busy2)))
    await store.finish()

    let key1 = SessionKey(harness: .pi, sessionID: "sess1")
    let key2 = SessionKey(harness: .pi, sessionID: "sess2")
    #expect(store.state.repositories.sessions[key1]?.branches == ["main"])
    #expect(store.state.repositories.sessions[key2]?.branches == ["feat/two"])
    #expect(probeOrder.value.count == 2)
    #expect(store.state.branchCaptureQueue.isEmpty)
  }

  @Test(.dependencies) func newSessionFallsBackToSelectedWorktreeWhenNoSessionCwd() async throws {
    let cwd = try temporaryDirectory(named: "selected-worktree-new-session")
    let selectedWorktree = Worktree(
      id: Worktree.ID(cwd.path(percentEncoded: false)), name: "selected", detail: "",
      workingDirectory: cwd, repositoryRootURL: cwd)
    let sent = LockIsolated<[TerminalClient.Command]>([])
    var initial = state()
    initial.repositories.repositories = [
      Repository(
        id: RepositoryID(cwd.path(percentEncoded: false)), rootURL: cwd,
        name: "selected", worktrees: [selectedWorktree])
    ]
    initial.repositories.selection = .worktree(selectedWorktree.id)
    let store = TestStore(initialState: initial) {
      AppFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.date.now = .distantPast
      $0.continuousClock = ImmediateClock()
      $0.terminalClient.send = { command in sent.withValue { $0.append(command) } }
    }
    store.exhaustivity = .off

    await store.send(.newSession)
    await store.receive(\.launchSessionCompleted)
    await store.finish()

    let input = sent.value.compactMap { command -> String? in
      if case .createTabWithInput(_, _, let input, _, _, _, _, _) = command { return input }
      return nil
    }
    #expect(input == ["pi"])
  }
  @Test(.dependencies) func nativeSessionPickerRetainsPurposeUntilCompletion() async throws {
    let cwd = try temporaryDirectory(named: "native-picker")
    defer { try? FileManager.default.removeItem(at: cwd) }
    let pickedWorktree = Worktree(
      id: Worktree.ID(cwd.path(percentEncoded: false)), name: "picked", detail: "",
      workingDirectory: cwd, repositoryRootURL: cwd)
    var initial = state()
    initial.repositories.repositories = [
      Repository(
        id: RepositoryID(cwd.path(percentEncoded: false)), rootURL: cwd,
        name: "picked", worktrees: [pickedWorktree])
    ]
    let sent = LockIsolated<[TerminalClient.Command]>([])
    let store = TestStore(initialState: initial) {
      AppFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.date.now = .distantPast
      $0.terminalClient.send = { command in sent.withValue { $0.append(command) } }
    }
    await store.send(.repositories(.presentOpenPanel(.newSession))) {
      $0.repositories.isOpenPanelPresented = true
      $0.repositories.openPanelPurpose = .newSession
    }
    await store.send(.repositories(.setOpenPanelPresented(false))) {
      $0.repositories.isOpenPanelPresented = false
    }
    #expect(store.state.repositories.openPanelPurpose == .newSession)
    store.exhaustivity = .off
    await store.send(.repositories(.openPanelCompleted([cwd])))
    await store.receive(\.repositories.delegate.newSessionDirectorySelected)
    await store.receive(\.newSessionDirectorySelected)
    await store.receive(\.launchSessionCompleted)
    await store.finish()
    #expect(store.state.repositories.openPanelPurpose == .openRepository)
    #expect(sent.value.count == 1)
    guard case .createTabWithInput(_, let context, let input, _, _, _, _, _) = sent.value[0]
    else {
      Issue.record("Expected exactly one session launch")
      return
    }
    #expect(context.workingDirectory == cwd)
    #expect(input == "pi")
  }

  @Test(.dependencies) func nativeSessionPickerCancellationConsumesPurpose() async {
    let store = TestStore(initialState: state()) { AppFeature() }
    await store.send(.repositories(.presentOpenPanel(.newSession))) {
      $0.repositories.isOpenPanelPresented = true
      $0.repositories.openPanelPurpose = .newSession
    }
    await store.send(.repositories(.setOpenPanelPresented(false))) {
      $0.repositories.isOpenPanelPresented = false
    }
    await store.send(.repositories(.openPanelCompleted(nil))) {
      $0.repositories.openPanelPurpose = .openRepository
    }
    await store.finish()
  }

  // MARK: - Settle and advance

  @Test(.dependencies) func settleSessionAndAdvanceSettlesCurrentAndFocusesNext() async throws {
    var initial = state()
    let key = SessionKey(harness: .pi, sessionID: "real")
    let key2 = SessionKey(harness: .pi, sessionID: "next")
    let surface2 = UUID(uuidString: "00000000-0000-0000-0000-000000000099")!
    let location2 = SessionLocation(
      layoutID: worktree.id.layoutID,
      directoryID: worktree.id,
      tabID: TabID(rawValue: surface2),
      surfaceID: surface2
    )
    initial.repositories.sessionsStarted = true
    initial.repositories.sessionItems = [
      SessionSidebarItemFeature.State(
        id: .implicit(key), title: "Session 1", cwd: "/workspace",
        createdAt: Date(timeIntervalSince1970: 20),
        location: location
      ),
      SessionSidebarItemFeature.State(
        id: .implicit(key2), title: "Session 2", cwd: "/workspace",
        createdAt: Date(timeIntervalSince1970: 10),
        location: location2
      ),
    ]
    initial.repositories.recomputeSessionsSidebarStructureIfChanged()
    initial.repositories.sessionSelection = .implicit(key)
    initial.agentPresence.records[
      AgentPresenceFeature.PresenceKey(agent: .pi, surfaceID: surface)
    ] = AgentPresenceFeature.PresenceRecord(pids: [], sessionRef: "real")
    let store = TestStore(initialState: initial) {
      AppFeature()
    } withDependencies: {
      $0.date.now = Date(timeIntervalSince1970: 100)
      $0.continuousClock = ImmediateClock()
      $0.terminalClient.focusSurface = { _, _, _, _ in }
    }
    store.exhaustivity = .off
    await store.send(.settleSessionAndAdvance) { appState in
      #expect(appState.repositories.sessions[key]?.settledAt != nil)
    }
    await store.receive(\.repositories.delegate.focusSession)
    await store.receive(\.repositories.selectTask)
  }

  @Test(.dependencies) func manualSettleAlsoRequestsClosingTheSessionsTab() async {
    var initial = state()
    let key = SessionKey(harness: .pi, sessionID: "real")
    // A surface outside the fixture layout: this covers the wiring, and the
    // close itself is the Cmd-W path with its own coverage.
    let detached = UUID(uuidString: "00000000-0000-0000-0000-0000000000D1")!
    initial.repositories.sessionSnapshots = [
      SessionLiveSnapshot(
        harness: .pi, sessionRef: "real", cwd: "/workspace",
        location: SessionLocation(
          layoutID: worktree.id.layoutID, directoryID: worktree.id, tabID: TabID(rawValue: detached),
          surfaceID: detached))
    ]
    initial.repositories.reconcileSessionItems(now: .distantPast)
    let store = TestStore(initialState: initial) {
      AppFeature()
    } withDependencies: {
      $0.date.now = Date(timeIntervalSince1970: 100)
      $0.continuousClock = ImmediateClock()
    }
    store.exhaustivity = .off
    await store.send(.repositories(.settleSessionRequested(key)))
    await store.receive(\.repositories.settleSession)
    await store.receive(\.terminals.layouts[id: worktree.layoutID].contentRequestedClose) {
      #expect($0.repositories.sessions[key]?.settledAt != nil)
    }
  }

  @Test(.dependencies) func settleSessionAndAdvanceUnsettlesSettledDestination() async throws {
    var initial = state()
    let key = SessionKey(harness: .pi, sessionID: "real")
    let key2 = SessionKey(harness: .pi, sessionID: "next")
    let surface2 = UUID(uuidString: "00000000-0000-0000-0000-000000000099")!
    let location2 = SessionLocation(
      layoutID: worktree.id.layoutID,
      directoryID: worktree.id,
      tabID: TabID(rawValue: surface2),
      surfaceID: surface2
    )
    initial.repositories.sessionsStarted = true
    initial.repositories.sessionItems = [
      SessionSidebarItemFeature.State(
        id: .implicit(key), title: "Session 1", cwd: "/workspace",
        createdAt: Date(timeIntervalSince1970: 20),
        location: location
      ),
      SessionSidebarItemFeature.State(
        id: .implicit(key2), title: "Session 2", cwd: "/workspace",
        createdAt: Date(timeIntervalSince1970: 10),
        lifecycle: .settled, location: location2
      ),
    ]
    initial.repositories.recomputeSessionsSidebarStructureIfChanged()
    initial.repositories.sessionSelection = .implicit(key)
    initial.agentPresence.records[
      AgentPresenceFeature.PresenceKey(agent: .pi, surfaceID: surface)
    ] = AgentPresenceFeature.PresenceRecord(pids: [], sessionRef: "real")
    let store = TestStore(initialState: initial) {
      AppFeature()
    } withDependencies: {
      $0.date.now = Date(timeIntervalSince1970: 100)
      $0.continuousClock = ImmediateClock()
      $0.terminalClient.focusSurface = { _, _, _, _ in }
    }
    store.exhaustivity = .off
    await store.send(.settleSessionAndAdvance) { appState in
      #expect(appState.repositories.sessions[key]?.settledAt != nil)
    }
    await store.receive(\.repositories.unsettleSession) { appState in
      #expect(appState.repositories.sessions[key2]?.settledAt == nil)
    }
  }

  @Test(.dependencies) func settleSessionAndAdvanceWithNoNextIsNoOp() async {
    var initial = state()
    let key = SessionKey(harness: .pi, sessionID: "real")
    initial.repositories.sessionsStarted = true
    initial.repositories.sessionItems = [
      SessionSidebarItemFeature.State(
        id: .implicit(key), title: "Session", cwd: "/workspace",
        createdAt: Date(timeIntervalSince1970: 10),
        location: location
      )
    ]
    initial.repositories.recomputeSessionsSidebarStructureIfChanged()
    initial.repositories.sessionSelection = .implicit(key)
    initial.agentPresence.records[
      AgentPresenceFeature.PresenceKey(agent: .pi, surfaceID: surface)
    ] = AgentPresenceFeature.PresenceRecord(pids: [], sessionRef: "real")
    let store = TestStore(initialState: initial) {
      AppFeature()
    } withDependencies: {
      $0.date.now = Date(timeIntervalSince1970: 100)
      $0.continuousClock = ImmediateClock()
    }
    store.exhaustivity = .off
    await store.send(.settleSessionAndAdvance) { appState in
      #expect(appState.repositories.sessions[key]?.settledAt != nil)
    }
    await store.finish()
  }

  @Test(.dependencies) func unsettleCurrentSessionClearsSettledAt() async {
    var initial = state()
    let key = SessionKey(harness: .pi, sessionID: "real")
    initial.repositories.sessionsStarted = true
    initial.repositories.sessionItems = [
      SessionSidebarItemFeature.State(
        id: .implicit(key), title: "Session", cwd: "/workspace",
        createdAt: Date(timeIntervalSince1970: 10),
        lifecycle: .settled, location: location
      )
    ]
    initial.repositories.$sessions = Shared(value: [key: SessionSidecarEntry(settledAt: Date())])
    initial.repositories.recomputeSessionsSidebarStructureIfChanged()
    initial.repositories.sessionSelection = .implicit(key)
    initial.agentPresence.records[
      AgentPresenceFeature.PresenceKey(agent: .pi, surfaceID: surface)
    ] = AgentPresenceFeature.PresenceRecord(pids: [], sessionRef: "real")
    let store = TestStore(initialState: initial) {
      AppFeature()
    } withDependencies: {
      $0.date.now = Date(timeIntervalSince1970: 100)
      $0.continuousClock = ImmediateClock()
    }
    store.exhaustivity = .off
    await store.send(.unsettleCurrentSession) { appState in
      #expect(appState.repositories.sessions[key]?.settledAt == nil)
    }
    await store.finish()
  }

  @Test(.dependencies) func userClosedSurfaceSettlesBeforePresenceRemoval() async {
    var initial = state()
    let key = SessionKey(harness: .pi, sessionID: "real")
    initial.agentPresence.records[
      AgentPresenceFeature.PresenceKey(agent: .pi, surfaceID: surface)
    ] = record(ref: "real")
    initial.repositories.sessionItems = [
      SessionSidebarItemFeature.State(
        id: .implicit(key), title: "Session", cwd: "/workspace",
        createdAt: .distantPast, location: location
      )
    ]
    let store = TestStore(initialState: initial) {
      AppFeature()
    } withDependencies: {
      $0.date.now = Date(timeIntervalSince1970: 100)
      $0.continuousClock = ImmediateClock()
      $0.terminalClient.saveLayoutsWithAgents = { _ in }
    }
    store.exhaustivity = .off

    await store.send(.terminalEvent(.userClosedSurfaces(layoutID: worktree.id.layoutID, [surface])))
    await store.receive(\.repositories.settleSession) { appState in
      #expect(appState.repositories.sessions[key]?.settledAt == Date(timeIntervalSince1970: 100))
    }
    await store.send(.terminalEvent(.surfacesClosed(layoutID: worktree.id.layoutID, [surface])))
    await store.receive(\.agentPresence.surfaceClosed)
    await store.finish()
  }

  @Test(.dependencies) func userClosedSurfacesSettlesDistinctSessionsBeforePresenceRemoval() async {
    var initial = state()
    let first = SessionKey(harness: .pi, sessionID: "one")
    let second = SessionKey(harness: .pi, sessionID: "two")
    initial.agentPresence.records[
      AgentPresenceFeature.PresenceKey(agent: .pi, surfaceID: surface)
    ] = record(ref: "one")
    initial.agentPresence.records[
      AgentPresenceFeature.PresenceKey(agent: .pi, surfaceID: shell)
    ] = record(ref: "two")
    initial.repositories.sessionItems = [
      SessionSidebarItemFeature.State(
        id: .implicit(first), title: "One", cwd: "/workspace",
        createdAt: .distantPast, location: location
      ),
      SessionSidebarItemFeature.State(
        id: .implicit(second), title: "Two", cwd: "/workspace",
        createdAt: .distantPast,
        location: SessionLocation(
          layoutID: worktree.id.layoutID, directoryID: worktree.id, tabID: TabID(rawValue: shell), surfaceID: shell)
      ),
    ]
    let store = TestStore(initialState: initial) {
      AppFeature()
    } withDependencies: {
      $0.date.now = Date(timeIntervalSince1970: 100)
      $0.continuousClock = ImmediateClock()
      $0.terminalClient.saveLayoutsWithAgents = { _ in }
    }
    store.exhaustivity = .off

    await store.send(.terminalEvent(.userClosedSurfaces(layoutID: worktree.id.layoutID, [surface, shell])))
    await store.receive(\.repositories.settleSession)
    await store.receive(\.repositories.settleSession)
    #expect(store.state.repositories.sessions[first]?.settledAt == Date(timeIntervalSince1970: 100))
    #expect(store.state.repositories.sessions[second]?.settledAt == Date(timeIntervalSince1970: 100))
    await store.send(.terminalEvent(.surfacesClosed(layoutID: worktree.id.layoutID, [surface, shell])))
    await store.receive(\.agentPresence.surfacesClosed)
    await store.finish()
  }

  @Test(.dependencies) func directContentRequestedCloseMarksUserIntentSynchronously() async {
    let marked = LockIsolated<[Set<UUID>]>([])
    let initial = state()
    let store = TestStore(initialState: initial) {
      AppFeature()
    } withDependencies: {
      $0.date.now = .distantPast
      $0.terminalClient.markUserCloseIntent = { _, ids in marked.withValue { $0.append(ids) } }
    }
    store.exhaustivity = .off

    await store.send(
      .terminals(
        .layouts(
          .element(
            id: worktree.id.layoutID,
            action: .contentRequestedClose(content: ContentID(rawValue: surface), scope: .allTabs)
          )
        )
      )
    )
    #expect(marked.value == [[surface, shell]])
  }

  @Test(.dependencies) func hookIsForwardedAndRefreshRequestedExactlyOnce() async {
    let clock = TestClock()
    let store = TestStore(initialState: state()) {
      AppFeature()
    } withDependencies: {
      $0.continuousClock = clock
    }
    await store.send(
      .terminalEvent(
        .agentHookEventReceived(
          AgentHookEvent(
            agent: "pi", event: "session_end", surfaceID: surface, sessionRef: "unknown"))))
    await store.receive(\.agentPresence.hookEventReceived)
    await store.receive(\.repositories.sessionsRefreshRequested)
    await store.send(.repositories(.sessionsStopped))
    await store.finish()
  }

  @Test(.dependencies) func suppressedSessionEndSkipsRefreshButNonEndEventsStillRefresh() async {
    let store = TestStore(initialState: state()) {
      AppFeature()
    } withDependencies: {
      $0.date.now = Date(timeIntervalSince1970: 100)
      $0.continuousClock = ImmediateClock()
      $0.terminalClient.saveLayoutsWithAgents = { _ in }
      $0.terminalClient.isHarnessEndSuppressed = { $0 == surface }
    }
    store.exhaustivity = .off
    let end = AgentHookEvent(
      version: 1, agent: "pi", event: "session_end", surfaceID: surface, pid: nil,
      timestamp: nil, sessionRef: "real", data: nil)
    let start = AgentHookEvent(
      version: 1, agent: "pi", event: "session_start", surfaceID: surface, pid: nil,
      timestamp: nil, sessionRef: "real", data: nil)

    await store.send(.terminalEvent(.agentHookEventReceived(end)))
    await store.receive(\.agentPresence.hookEventReceived)
    await store.send(.terminalEvent(.agentHookEventReceived(start)))
    await store.receive(\.agentPresence.hookEventReceived)
    await store.receive(\.repositories.sessionsRefreshRequested)
    await store.finish()
  }

  @Test(.dependencies, arguments: ["quit", "new", "resume", "fork"])
  func piShutdownSettlesOldSessionBeforePresenceRemoval(reason: String) async {
    var initial = state()
    let key = SessionKey(harness: .pi, sessionID: "real")
    let presenceKey = AgentPresenceFeature.PresenceKey(agent: .pi, surfaceID: surface)
    initial.agentPresence.records[presenceKey] = record()
    let store = TestStore(initialState: initial) {
      AppFeature()
    } withDependencies: {
      $0.date.now = Date(timeIntervalSince1970: 100)
      $0.continuousClock = ImmediateClock()
      $0.terminalClient.saveLayoutsWithAgents = { _ in }
    }
    store.exhaustivity = .off
    await store.send(
      .terminalEvent(
        .agentHookEventReceived(
          AgentHookEvent(
            agent: "pi", event: "session_end", surfaceID: surface,
            sessionRef: "real", shutdownReason: reason))))
    await store.receive(\.repositories.settleSession)
    await store.finish()
    #expect(store.state.repositories.sessions[key]?.settledAt == Date(timeIntervalSince1970: 100))
    #expect(store.state.agentPresence.records[presenceKey] == nil)
  }

  @Test(
    .dependencies,
    arguments: ["reload", "unknown", "missing", "suppressed", "quitting", "staleSid", "stalePid", "missingSid"]
  )
  func piShutdownDoesNotSettleUnattributedOrAppOwnedEnd(scenario: String) async {
    var initial = state()
    let key = SessionKey(harness: .pi, sessionID: "real")
    let presenceKey = AgentPresenceFeature.PresenceKey(agent: .pi, surfaceID: surface)
    initial.agentPresence.records[presenceKey] = AgentPresenceFeature.PresenceRecord(
      pids: [11, 22], sessionRef: "real", currentSessionPID: 22)
    initial.isQuitting = scenario == "quitting"
    let store = TestStore(initialState: initial) {
      AppFeature()
    } withDependencies: {
      $0.date.now = Date(timeIntervalSince1970: 100)
      $0.continuousClock = ImmediateClock()
      $0.terminalClient.saveLayoutsWithAgents = { _ in }
      $0.terminalClient.isHarnessEndSuppressed = { _ in scenario == "suppressed" }
    }
    store.exhaustivity = .off
    let reason =
      scenario == "missing"
      ? nil
      : scenario == "reload"
        ? "reload"
        : scenario == "unknown" ? "unknown" : "quit"
    await store.send(
      .terminalEvent(
        .agentHookEventReceived(
          AgentHookEvent(
            agent: "pi", event: "session_end", surfaceID: surface,
            pid: scenario == "stalePid" ? 11 : 22,
            sessionRef: scenario == "missingSid" ? nil : scenario == "staleSid" ? "previous" : "real",
            shutdownReason: reason))))
    await store.receive(\.agentPresence.hookEventReceived)
    await store.finish()
    #expect(store.state.repositories.sessions[key]?.settledAt == nil)
    #expect(store.state.agentPresence.records[presenceKey]?.sessionRef == "real")
    if scenario == "missingSid" {
      #expect(store.state.agentPresence.records[presenceKey]?.pids == [11])
    }
    if scenario == "staleSid" || scenario == "stalePid" {
      #expect(store.state.agentPresence.records[presenceKey]?.pids == [11, 22])
      #expect(store.state.agentPresence.records[presenceKey]?.lastEventName == nil)
    }
  }

  @Test(.dependencies) func barePiEndRemovesPresenceWithoutSettling() async {
    var initial = state()
    let presenceKey = AgentPresenceFeature.PresenceKey(agent: .pi, surfaceID: surface)
    initial.agentPresence.records[presenceKey] = AgentPresenceFeature.PresenceRecord(
      pids: [22], sessionRef: "real", currentSessionPID: 22)
    let store = TestStore(initialState: initial) {
      AppFeature()
    } withDependencies: {
      $0.date.now = Date(timeIntervalSince1970: 100)
      $0.continuousClock = ImmediateClock()
      $0.terminalClient.saveLayoutsWithAgents = { _ in }
    }
    store.exhaustivity = .off
    await store.send(
      .terminalEvent(
        .agentHookEventReceived(
          AgentHookEvent(
            agent: "pi", event: "session_end", surfaceID: surface, pid: 22, shutdownReason: "quit"))))
    await store.receive(\.agentPresence.hookEventReceived)
    await store.finish()
    #expect(store.state.agentPresence.records[presenceKey] == nil)
    #expect(store.state.repositories.sessions.isEmpty)
  }

  @Test(.dependencies)
  func piReloadEndThenTwoMessageRecentRefreshRemainsUnsettled() async {
    let now = Date(timeIntervalSince1970: 100)
    var initial = state()
    let key = SessionKey(harness: .pi, sessionID: "real")
    let presenceKey = AgentPresenceFeature.PresenceKey(agent: .pi, surfaceID: surface)
    initial.agentPresence.records[presenceKey] = AgentPresenceFeature.PresenceRecord(
      pids: [42], sessionRef: "real", currentSessionPID: 42)
    initial.repositories.sessionsRestorationFinished = true
    initial.repositories.sessionsRefreshSucceeded = true
    let store = TestStore(initialState: initial) {
      AppFeature()
    } withDependencies: {
      $0.date.now = now
      $0.continuousClock = ImmediateClock()
      $0.terminalClient.saveLayoutsWithAgents = { _ in }
    }
    store.exhaustivity = .off
    await store.send(
      .terminalEvent(
        .agentHookEventReceived(
          AgentHookEvent(
            agent: "pi", event: "session_end", surfaceID: surface,
            pid: 42, sessionRef: "real", shutdownReason: "reload"))))
    await store.receive(\.agentPresence.hookEventReceived)
    await store.finish()
    #expect(store.state.repositories.sessions[key]?.settledAt == nil)
    let summary = SessionSummary(
      harness: .pi, sessionID: "real",
      createdAt: now.addingTimeInterval(-86_400), cwd: "/workspace",
      title: "real", messageCount: 2,
      lastActivity: now.addingTimeInterval(-1_800))
    await store.send(.repositories(.sessionsRefreshCompleted([summary])))
    await store.finish()
    #expect(store.state.repositories.sessions[key]?.settledAt == nil)
  }

  @Test(.dependencies, arguments: ["session_start", "busy"])
  func changedSidSettlesPreviousSessionButSameSidDoesNot(event: String) async {
    var initial = state()
    let presenceKey = AgentPresenceFeature.PresenceKey(agent: .pi, surfaceID: surface)
    initial.agentPresence.records[presenceKey] = record()
    let store = TestStore(initialState: initial) {
      AppFeature()
    } withDependencies: {
      $0.date.now = Date(timeIntervalSince1970: 100)
      $0.continuousClock = ImmediateClock()
      $0.terminalClient.saveLayoutsWithAgents = { _ in }
    }
    store.exhaustivity = .off
    await store.send(
      .terminalEvent(
        .agentHookEventReceived(
          AgentHookEvent(
            agent: "pi", event: event, surfaceID: surface, sessionRef: "real"))))
    await store.receive(\.agentPresence.hookEventReceived)
    await store.finish()
    #expect(store.state.repositories.sessions[SessionKey(harness: .pi, sessionID: "real")] == nil)
    await store.send(
      .terminalEvent(
        .agentHookEventReceived(
          AgentHookEvent(
            agent: "pi", event: event, surfaceID: surface, sessionRef: "replacement"))))
    await store.receive(\.repositories.settleSession)
    await store.finish()
    #expect(store.state.repositories.sessions[SessionKey(harness: .pi, sessionID: "real")]?.settledAt != nil)
    #expect(store.state.repositories.sessions[SessionKey(harness: .pi, sessionID: "replacement")] == nil)
    #expect(store.state.agentPresence.records[presenceKey]?.sessionRef == "replacement")
    await store.send(
      .terminalEvent(
        .agentHookEventReceived(
          AgentHookEvent(
            agent: "pi", event: "session_end", surfaceID: surface,
            sessionRef: "real", shutdownReason: "quit"))))
    await store.receive(\.agentPresence.hookEventReceived)
    await store.finish()
    #expect(store.state.agentPresence.records[presenceKey]?.sessionRef == "replacement")
    #expect(store.state.repositories.sessions[SessionKey(harness: .pi, sessionID: "replacement")] == nil)
  }

  @Test(.dependencies) func newProcessIdentityRejectsLateEndThenAcceptsCurrentEnd() async {
    var initial = state()
    let presenceKey = AgentPresenceFeature.PresenceKey(agent: .pi, surfaceID: surface)
    initial.agentPresence.records[presenceKey] = AgentPresenceFeature.PresenceRecord(
      pids: [11], sessionRef: "real")
    let store = TestStore(initialState: initial) {
      AppFeature()
    } withDependencies: {
      $0.date.now = Date(timeIntervalSince1970: 100)
      $0.continuousClock = ImmediateClock()
      $0.terminalClient.saveLayoutsWithAgents = { _ in }
    }
    store.exhaustivity = .off
    await store.send(
      .terminalEvent(
        .agentHookEventReceived(
          AgentHookEvent(
            agent: "pi", event: "session_start", surfaceID: surface, pid: 22, sessionRef: "replacement"))))
    await store.receive(\.agentPresence.hookEventReceived)
    await store.finish()
    #expect(store.state.agentPresence.records[presenceKey]?.currentSessionPID == 22)
    for ref in ["real", "replacement"] {
      await store.send(
        .terminalEvent(
          .agentHookEventReceived(
            AgentHookEvent(
              agent: "pi", event: "session_end", surfaceID: surface, pid: 11,
              sessionRef: ref, shutdownReason: "quit"))))
      await store.receive(\.agentPresence.hookEventReceived)
      await store.finish()
      #expect(store.state.agentPresence.records[presenceKey]?.sessionRef == "replacement")
      #expect(store.state.repositories.sessions[SessionKey(harness: .pi, sessionID: "replacement")] == nil)
    }
    await store.send(
      .terminalEvent(
        .agentHookEventReceived(
          AgentHookEvent(
            agent: "pi", event: "session_end", surfaceID: surface, pid: 22,
            sessionRef: "replacement", shutdownReason: "quit"))))
    await store.receive(\.repositories.settleSession)
    await store.finish()
    #expect(store.state.repositories.sessions[SessionKey(harness: .pi, sessionID: "replacement")]?.settledAt != nil)
  }

  @Test(.dependencies) func legacyOtherHarnessEndStillSettlesWhenAttributed() async {
    var initial = state()
    let key = SessionKey(harness: .claude, sessionID: "real")
    initial.agentPresence.records[
      AgentPresenceFeature.PresenceKey(agent: .claude, surfaceID: surface)] = record()
    let store = TestStore(initialState: initial) {
      AppFeature()
    } withDependencies: {
      $0.date.now = Date(timeIntervalSince1970: 100)
      $0.continuousClock = ImmediateClock()
      $0.terminalClient.saveLayoutsWithAgents = { _ in }
    }
    store.exhaustivity = .off
    await store.send(
      .terminalEvent(
        .agentHookEventReceived(
          AgentHookEvent(
            agent: "claude", event: "session_end", surfaceID: surface))))
    await store.receive(\.repositories.settleSession)
    await store.finish()
    #expect(store.state.repositories.sessions[key]?.settledAt != nil)
  }

  @Test(.dependencies) func terminateSessionsRequestIsGatedByTerminalSurfacePresence() async {
    var withoutSurface = state()
    withoutSurface.hasAnyTerminalSurface = false
    let noSurfaceStore = TestStore(initialState: withoutSurface) { AppFeature() }
    noSurfaceStore.exhaustivity = .off

    await noSurfaceStore.send(.requestTerminateAllTerminalSessions)
    #expect(noSurfaceStore.state.alert == nil)
    await noSurfaceStore.finish()

    var withSurface = state()
    withSurface.hasAnyTerminalSurface = true
    let surfaceStore = TestStore(initialState: withSurface) { AppFeature() }
    surfaceStore.exhaustivity = .off

    await surfaceStore.send(.requestTerminateAllTerminalSessions)
    #expect(surfaceStore.state.alert != nil)
    await surfaceStore.finish()
  }

  @Test(.dependencies) func nextSessionNeedsMeFocusesAwaitingInputThenDoneUnseenCircularly() async {
    var initial = state()
    let idle = SessionKey(harness: .pi, sessionID: "idle")
    let needs = SessionKey(harness: .pi, sessionID: "needs")
    let done = SessionKey(harness: .pi, sessionID: "done")
    let surfaceNeeds = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!
    let surfaceDone = UUID(uuidString: "00000000-0000-0000-0000-0000000000A2")!
    let needsLocation = SessionLocation(
      layoutID: worktree.id.layoutID, directoryID: worktree.id, tabID: TabID(rawValue: surfaceNeeds),
      surfaceID: surfaceNeeds)
    let doneLocation = SessionLocation(
      layoutID: worktree.id.layoutID, directoryID: worktree.id, tabID: TabID(rawValue: surfaceDone),
      surfaceID: surfaceDone)
    initial.repositories.sessionItems = [
      SessionSidebarItemFeature.State(
        id: .implicit(idle), title: "Idle", cwd: "/workspace",
        createdAt: Date(timeIntervalSince1970: 30), location: location, status: .idle),
      SessionSidebarItemFeature.State(
        id: .implicit(needs), title: "Needs", cwd: "/workspace",
        createdAt: Date(timeIntervalSince1970: 20), location: needsLocation, status: .needsYou),
      SessionSidebarItemFeature.State(
        id: .implicit(done), title: "Done", cwd: "/workspace",
        createdAt: Date(timeIntervalSince1970: 10), location: doneLocation, status: .doneUnseen),
    ]
    initial.repositories.recomputeSessionsSidebarStructureIfChanged()
    initial.repositories.sessionSelection = .implicit(needs)
    let store = TestStore(initialState: initial) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.focusSurface = { _, _, _, _ in }
    }
    store.exhaustivity = .off

    await store.send(.nextSessionNeedsMe) { appState in
      appState.repositories.sessionSelection = .implicit(done)
    }
    await store.receive(\.repositories.delegate.focusSession)

    await store.send(.nextSessionNeedsMe) { appState in
      appState.repositories.sessionSelection = .implicit(needs)
    }
    await store.receive(\.repositories.delegate.focusSession)
  }

  @Test(.dependencies) func nextSessionNeedsMeStartsAfterFocusedNonAttentionRowAndWraps() async {
    var initial = state()
    let first = SessionKey(harness: .pi, sessionID: "first")
    let idle = SessionKey(harness: .pi, sessionID: "idle")
    let next = SessionKey(harness: .pi, sessionID: "next")
    let working = SessionKey(harness: .pi, sessionID: "working")
    let firstLocation = SessionLocation(
      layoutID: worktree.id.layoutID,
      directoryID: worktree.id,
      tabID: TabID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-0000000000B1")!),
      surfaceID: UUID(uuidString: "00000000-0000-0000-0000-0000000000B1")!)
    let idleLocation = SessionLocation(
      layoutID: worktree.id.layoutID,
      directoryID: worktree.id,
      tabID: TabID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-0000000000B2")!),
      surfaceID: UUID(uuidString: "00000000-0000-0000-0000-0000000000B2")!)
    let nextLocation = SessionLocation(
      layoutID: worktree.id.layoutID,
      directoryID: worktree.id,
      tabID: TabID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-0000000000B3")!),
      surfaceID: UUID(uuidString: "00000000-0000-0000-0000-0000000000B3")!)
    let workingLocation = SessionLocation(
      layoutID: worktree.id.layoutID,
      directoryID: worktree.id,
      tabID: TabID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-0000000000B4")!),
      surfaceID: UUID(uuidString: "00000000-0000-0000-0000-0000000000B4")!)
    initial.repositories.sessionItems = [
      SessionSidebarItemFeature.State(
        id: .implicit(first), title: "First", cwd: "/workspace",
        createdAt: Date(timeIntervalSince1970: 40), location: firstLocation, status: .needsYou),
      SessionSidebarItemFeature.State(
        id: .implicit(idle), title: "Idle", cwd: "/workspace",
        createdAt: Date(timeIntervalSince1970: 30), location: idleLocation, status: .idle),
      SessionSidebarItemFeature.State(
        id: .implicit(next), title: "Next", cwd: "/workspace",
        createdAt: Date(timeIntervalSince1970: 20), location: nextLocation, status: .doneUnseen),
      SessionSidebarItemFeature.State(
        id: .implicit(working), title: "Working", cwd: "/workspace",
        createdAt: Date(timeIntervalSince1970: 10), location: workingLocation, status: .working),
    ]
    initial.repositories.recomputeSessionsSidebarStructureIfChanged()
    initial.repositories.sessionSelection = .implicit(idle)
    let store = TestStore(initialState: initial) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.focusSurface = { _, _, _, _ in }
    }
    store.exhaustivity = .off

    await store.send(.nextSessionNeedsMe) { appState in
      appState.repositories.sessionSelection = .implicit(next)
    }
    await store.receive(\.repositories.delegate.focusSession)

    await store.send(.repositories(.sessionSelectionChanged(.implicit(working)))) { appState in
      appState.repositories.sessionSelection = .implicit(working)
    }
    await store.send(.nextSessionNeedsMe) { appState in
      appState.repositories.sessionSelection = .implicit(first)
    }
    await store.receive(\.repositories.delegate.focusSession)
  }

  @Test(.dependencies) func nextSessionNeedsMeDoesNotFocusAnErrorOnlySurface() async {
    var initial = state()
    initial.agentPresence.records[
      AgentPresenceFeature.PresenceKey(agent: .pi, surfaceID: surface)
    ] = AgentPresenceFeature.PresenceRecord(activity: .error, pids: [], sessionRef: "real")
    initial.repositories.sessionSnapshots = AppFeature.sessionSnapshots(state: initial)
    initial.repositories.reconcileSessionItems(now: .distantPast)
    initial.repositories.recomputeSessionsSidebarStructureIfChanged()
    #expect(initial.repositories.sessionItems.first?.status == .needsYou)
    let focused = LockIsolated<[UUID]>([])
    let store = TestStore(initialState: initial) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.focusSurface = { _, _, _, surfaceID in focused.withValue { $0.append(surfaceID) } }
    }
    await store.send(.nextSessionNeedsMe)
    await store.finish()
    #expect(focused.value.isEmpty)
    #expect(store.state.repositories.sessionSelection == nil)
  }

  @Test(.dependencies) func nextSessionNeedsMeNoopsWhenOnlyDormantBusyOrIdle() async {
    var initial = state()
    let busy = SessionKey(harness: .pi, sessionID: "busy")
    let dormant = SessionKey(harness: .pi, sessionID: "dormant")
    initial.repositories.sessionItems = [
      SessionSidebarItemFeature.State(
        id: .implicit(busy), title: "Busy", cwd: "/workspace",
        createdAt: Date(timeIntervalSince1970: 20), location: location, status: .working),
      SessionSidebarItemFeature.State(
        id: .implicit(dormant), title: "Dormant", cwd: "/workspace",
        createdAt: Date(timeIntervalSince1970: 10), status: .needsYou),
    ]
    initial.repositories.recomputeSessionsSidebarStructureIfChanged()
    initial.repositories.sessionSelection = .implicit(busy)
    let store = TestStore(initialState: initial) { AppFeature() }
    store.exhaustivity = .off

    await store.send(.nextSessionNeedsMe)
    await store.finish()
  }

  @Test(.dependencies) func launchCompletedRecordsCooldownDate() async throws {
    let tmpDir = try temporaryDirectory(named: "cooldown-record")
    defer { try? FileManager.default.removeItem(at: tmpDir) }
    let key = SessionKey(harness: .pi, sessionID: "cool")
    let reqID = UUID(uuidString: "DDDDDDDD-0000-0000-0000-000000000001")!
    let launchTime = Date(timeIntervalSince1970: 1_000)
    var initial = state()
    initial.pendingSessionLaunch = PendingSessionLaunch(
      key: key, cwd: tmpDir, command: "pi --session cool", requestID: reqID, launched: true)
    let store = TestStore(initialState: initial) {
      AppFeature()
    } withDependencies: {
      $0.date.now = launchTime
    }
    store.exhaustivity = .off
    await store.send(.launchSessionCompleted(requestID: reqID)) {
      $0.pendingSessionLaunch = nil
      $0.recentSessionLaunchDate[key] = launchTime
    }
    await store.finish()
  }

  @Test(.dependencies) func resumeBlockedWithinCooldownWindow() async throws {
    let tmpDir = try temporaryDirectory(named: "cooldown-block")
    defer { try? FileManager.default.removeItem(at: tmpDir) }
    let key = SessionKey(harness: .pi, sessionID: "block")
    var initial = state()
    let worktree = Worktree(
      id: WorktreeID(tmpDir.path), name: "cooldown-block", detail: "",
      workingDirectory: tmpDir, repositoryRootURL: tmpDir)
    initial.repositories.repositories.append(
      Repository(id: RepositoryID(tmpDir.path), rootURL: tmpDir, name: "cooldown-block", worktrees: [worktree]))
    initial.repositories.sessionItems = [
      SessionSidebarItemFeature.State(
        id: .implicit(key), title: "Block", cwd: tmpDir.path, createdAt: .distantPast)
    ]
    let launchTime = Date(timeIntervalSince1970: 1_000)
    initial.recentSessionLaunchDate[key] = launchTime
    let sent = LockIsolated<[TerminalClient.Command]>([])
    let store = TestStore(initialState: initial) {
      AppFeature()
    } withDependencies: {
      $0.date.now = Date(timeIntervalSince1970: 1_005)  // 5 s after launch
      $0.terminalClient.send = { cmd in sent.withValue { $0.append(cmd) } }
    }
    store.exhaustivity = .off
    await store.send(.repositories(.activateSession(.implicit(key))))
    await store.receive(\.repositories.delegate.resumeSession)
    await store.finish()
    #expect(sent.value.isEmpty, "should not launch within 10 s cooldown")
    #expect(store.state.pendingSessionLaunch == nil)
  }

  @Test(.dependencies) func resumeAllowedAfterCooldownExpires() async throws {
    let tmpDir = try temporaryDirectory(named: "cooldown-allow")
    defer { try? FileManager.default.removeItem(at: tmpDir) }
    let key = SessionKey(harness: .pi, sessionID: "allow")
    var initial = state()
    let worktree = Worktree(
      id: WorktreeID(tmpDir.path), name: "cooldown-allow", detail: "",
      workingDirectory: tmpDir, repositoryRootURL: tmpDir)
    initial.repositories.repositories.append(
      Repository(id: RepositoryID(tmpDir.path), rootURL: tmpDir, name: "cooldown-allow", worktrees: [worktree]))
    initial.repositories.sessionItems = [
      SessionSidebarItemFeature.State(
        id: .implicit(key), title: "Allow", cwd: tmpDir.path, createdAt: .distantPast)
    ]
    let launchTime = Date(timeIntervalSince1970: 1_000)
    initial.recentSessionLaunchDate[key] = launchTime
    let sent = LockIsolated<[TerminalClient.Command]>([])
    let store = TestStore(initialState: initial) {
      AppFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.date.now = Date(timeIntervalSince1970: 1_015)  // 15 s after — cooldown expired
      $0.terminalClient.send = { cmd in
        if case .createTabWithInput = cmd { sent.withValue { $0.append(cmd) } }
      }
    }
    store.exhaustivity = .off
    await store.send(.repositories(.activateSession(.implicit(key))))
    await store.receive(\.repositories.delegate.resumeSession)
    await store.receive(\.launchSessionCompleted)
    await store.finish()
    #expect(sent.value.count == 1, "should launch after cooldown expires")
  }

  @Test(.dependencies) func resumeDormantMissingCwdShowsAlert() async {
    let key = SessionKey(harness: .pi, sessionID: "missing")
    var initial = state()
    initial.repositories.sessionItems = [
      SessionSidebarItemFeature.State(
        id: .implicit(key), title: "Missing", cwd: "/nonexistent/dir/absent", createdAt: .distantPast)
    ]
    let store = TestStore(initialState: initial) {
      AppFeature()
    } withDependencies: {
      $0.date.now = .distantPast
    }
    store.exhaustivity = .off
    await store.send(.repositories(.activateSession(.implicit(key))))
    await store.receive(\.repositories.delegate.resumeSession) { appState in
      #expect(appState.alert != nil)
      #expect(appState.pendingSessionLaunch == nil)
    }
    await store.finish()
  }

  // MARK: - Provisional conflict: same harness + cwd + nil sessionRef

  @Test(.dependencies) func probeCompletionShowsProvisionalConfirmWhenSameHarnessCwdPresent() async throws {
    let tmpDir = try temporaryDirectory(named: "provisional-confirm")
    defer { try? FileManager.default.removeItem(at: tmpDir) }
    let key = SessionKey(harness: .pi, sessionID: "dormant1")
    var initial = state()
    let worktree = Worktree(
      id: WorktreeID(tmpDir.path), name: "provisional", detail: "",
      workingDirectory: tmpDir, repositoryRootURL: tmpDir)
    initial.repositories.repositories.append(
      Repository(
        id: RepositoryID(tmpDir.path), rootURL: tmpDir, name: "provisional",
        worktrees: [worktree]))
    initial.repositories.sessionItems = [
      SessionSidebarItemFeature.State(
        id: .implicit(key), title: "Dormant", cwd: tmpDir.path(percentEncoded: false),
        createdAt: .distantPast)
    ]
    let surfaceID = UUID()
    initial.repositories.sessionSnapshots = [
      SessionLiveSnapshot(
        harness: .pi, sessionRef: nil,
        cwd: tmpDir.path(percentEncoded: false),
        location: SessionLocation(
          layoutID: worktree.id.layoutID, directoryID: worktree.id, tabID: TabID(), surfaceID: surfaceID))
    ]
    let store = TestStore(initialState: initial) {
      AppFeature()
    } withDependencies: {
      $0.date.now = .distantPast
      $0.uuid = .incrementing
    }
    store.exhaustivity = .off
    await store.send(.repositories(.activateSession(.implicit(key))))
    await store.receive(\.repositories.delegate.resumeSession)
    await store.receive(\.resumeBranchProbeCompleted) { appState in
      #expect(appState.pendingBranchMismatchResume?.isProvisionalConflict == true)
      #expect(appState.pendingBranchMismatchResume?.recordedBranch == "")
      #expect(appState.alert != nil)
      #expect(appState.pendingSessionLaunch?.probing == false)
    }
    await store.finish()
  }

  @Test(.dependencies) func provisionalConfirmCancelClearsReservation() async throws {
    let tmpDir = try temporaryDirectory(named: "provisional-cancel")
    defer { try? FileManager.default.removeItem(at: tmpDir) }
    let key = SessionKey(harness: .pi, sessionID: "dormant2")
    var initial = state()
    initial.repositories.sessionItems = [
      SessionSidebarItemFeature.State(
        id: .implicit(key), title: "Dormant", cwd: tmpDir.path(percentEncoded: false),
        createdAt: .distantPast)
    ]
    let surfaceID = UUID()
    initial.repositories.sessionSnapshots = [
      SessionLiveSnapshot(
        harness: .pi, sessionRef: nil,
        cwd: tmpDir.path(percentEncoded: false),
        location: SessionLocation(
          layoutID: LayoutID(legacyWorktreeKey: tmpDir.path), directoryID: WorktreeID(tmpDir.path), tabID: TabID(),
          surfaceID: surfaceID)
      )
    ]
    let sent = LockIsolated<[TerminalClient.Command]>([])
    let store = TestStore(initialState: initial) {
      AppFeature()
    } withDependencies: {
      $0.date.now = .distantPast
      $0.uuid = .incrementing
      $0.terminalClient.send = { cmd in sent.withValue { $0.append(cmd) } }
    }
    store.exhaustivity = .off
    await store.send(.repositories(.activateSession(.implicit(key))))
    await store.receive(\.repositories.delegate.resumeSession)
    await store.receive(\.resumeBranchProbeCompleted)
    await store.send(.alert(.presented(.cancelBranchMismatchResume))) { appState in
      #expect(appState.pendingSessionLaunch == nil)
      #expect(appState.pendingBranchMismatchResume == nil)
    }
    await store.finish()
    #expect(sent.value.isEmpty)
  }

  @Test(.dependencies) func probeCompletionCombinesProvisionalAndBranchMismatchInOneAlert() async throws {
    let tmpDir = try temporaryDirectory(named: "combined-conflict")
    defer { try? FileManager.default.removeItem(at: tmpDir) }
    let key = SessionKey(harness: .pi, sessionID: "dormant3")
    var initial = state()
    initial.repositories.sessionItems = [
      SessionSidebarItemFeature.State(
        id: .implicit(key), title: "Dormant", cwd: tmpDir.path(percentEncoded: false),
        createdAt: .distantPast)
    ]
    initial.repositories.$sessions.withLock { $0[key] = SessionSidecarEntry(branches: ["old-branch"]) }
    let surfaceID = UUID()
    initial.repositories.sessionSnapshots = [
      SessionLiveSnapshot(
        harness: .pi, sessionRef: nil,
        cwd: tmpDir.path(percentEncoded: false),
        location: SessionLocation(
          layoutID: LayoutID(legacyWorktreeKey: tmpDir.path), directoryID: WorktreeID(tmpDir.path), tabID: TabID(),
          surfaceID: surfaceID)
      )
    ]
    let store = TestStore(initialState: initial) {
      AppFeature()
    } withDependencies: {
      $0.date.now = .distantPast
      $0.uuid = .incrementing
      $0[GitClientDependency.self].branchName = { _ in "new-branch" }
    }
    store.exhaustivity = .off
    await store.send(.repositories(.activateSession(.implicit(key))))
    await store.receive(\.repositories.delegate.resumeSession)
    await store.receive(\.resumeBranchProbeCompleted) { appState in
      #expect(appState.pendingBranchMismatchResume?.isProvisionalConflict == true)
      #expect(appState.pendingBranchMismatchResume?.recordedBranch == "old-branch")
      #expect(appState.pendingBranchMismatchResume?.currentBranch == "new-branch")
      #expect(appState.alert != nil)
    }
    await store.finish()
  }

  // MARK: - A1 correction: nonstandard snap.cwd must match via standardizedFileURL

  @Test(.dependencies) func nonstandardSnapCwdMatchesViaStandardizedURL() async throws {
    let tmpDir = try temporaryDirectory(named: "nonstandard-cwd")
    defer { try? FileManager.default.removeItem(at: tmpDir) }
    let key = SessionKey(harness: .pi, sessionID: "nonstandard1")
    var initial = state()
    let worktree = Worktree(
      id: WorktreeID(tmpDir.path), name: "nonstandard", detail: "",
      workingDirectory: tmpDir, repositoryRootURL: tmpDir)
    initial.repositories.repositories.append(
      Repository(
        id: RepositoryID(tmpDir.path), rootURL: tmpDir, name: "nonstandard",
        worktrees: [worktree]))
    initial.repositories.sessionItems = [
      SessionSidebarItemFeature.State(
        id: .implicit(key), title: "Dormant", cwd: tmpDir.path(percentEncoded: false),
        createdAt: .distantPast)
    ]
    let surfaceID = UUID()
    // snap.cwd uses a non-canonical path with an embedded "child/.."
    let nonstandardCwdPath = tmpDir.path(percentEncoded: false) + "/child/.."
    initial.repositories.sessionSnapshots = [
      SessionLiveSnapshot(
        harness: .pi, sessionRef: nil,
        cwd: nonstandardCwdPath,
        location: SessionLocation(
          layoutID: worktree.id.layoutID, directoryID: worktree.id, tabID: TabID(), surfaceID: surfaceID))
    ]
    let store = TestStore(initialState: initial) {
      AppFeature()
    } withDependencies: {
      $0.date.now = .distantPast
      $0.uuid = .incrementing
    }
    store.exhaustivity = .off
    await store.send(.repositories(.activateSession(.implicit(key))))
    await store.receive(\.repositories.delegate.resumeSession)
    await store.receive(\.resumeBranchProbeCompleted) { appState in
      #expect(appState.pendingBranchMismatchResume?.isProvisionalConflict == true)
      #expect(appState.alert != nil)
      let message = appState.alert.map { String(describing: $0.message) } ?? ""
      #expect(message.contains("already running"))
      #expect(message.contains("not reported"))
      #expect(message.contains("may be this session"))
    }
    await store.finish()
  }

  // MARK: - A2 regression: nil branch probe with history must alert, not launch

  @Test(.dependencies) func failedBranchProbeWithHistoryAlertsAndClearsReservation() async throws {
    let tmpDir = try temporaryDirectory(named: "probe-fail")
    defer { try? FileManager.default.removeItem(at: tmpDir) }
    let key = SessionKey(harness: .pi, sessionID: "probefail")
    var initial = state()
    initial.repositories.sessionItems = [
      SessionSidebarItemFeature.State(
        id: .implicit(key), title: "Dormant", cwd: tmpDir.path(percentEncoded: false),
        createdAt: .distantPast)
    ]
    initial.repositories.$sessions.withLock { $0[key] = SessionSidecarEntry(branches: ["main"]) }
    let sent = LockIsolated<[TerminalClient.Command]>([])
    let store = TestStore(initialState: initial) {
      AppFeature()
    } withDependencies: {
      $0.date.now = .distantPast
      $0.uuid = .incrementing
      $0[GitClientDependency.self].branchName = { _ in nil }
      $0.terminalClient.send = { cmd in sent.withValue { $0.append(cmd) } }
    }
    store.exhaustivity = .off
    await store.send(.repositories(.activateSession(.implicit(key))))
    await store.receive(\.repositories.delegate.resumeSession)
    await store.receive(\.resumeBranchProbeCompleted) { appState in
      #expect(appState.alert != nil)
      #expect(appState.pendingSessionLaunch == nil)
    }
    await store.finish()
    #expect(sent.value.isEmpty)
  }

  // MARK: - R1/R3: live location check in finishResumeBranchProbe and startPreparedResume

  @Test(.dependencies) func identityArrivesWhileProbeInFlight() async throws {
    let tmpDir = try temporaryDirectory(named: "identity-probe-inflight")
    defer { try? FileManager.default.removeItem(at: tmpDir) }
    let key = SessionKey(harness: .pi, sessionID: "arrives-during-probe")
    var initial = state()
    let worktreeA = Worktree(
      id: WorktreeID(tmpDir.path), name: "arrives-probe", detail: "",
      workingDirectory: tmpDir, repositoryRootURL: tmpDir)
    initial.repositories.repositories.append(
      Repository(
        id: RepositoryID(tmpDir.path), rootURL: tmpDir, name: "arrives-probe",
        worktrees: [worktreeA]))
    initial.repositories.sessionItems = [
      SessionSidebarItemFeature.State(
        id: .implicit(key), title: "Dormant", cwd: tmpDir.path(percentEncoded: false),
        createdAt: .distantPast)
    ]
    let branches = AsyncStream<String?>.makeStream()
    let focused = LockIsolated<[SessionLocation]>([])
    let sent = LockIsolated<[TerminalClient.Command]>([])
    let store = TestStore(initialState: initial) {
      AppFeature()
    } withDependencies: {
      $0.date.now = .distantPast
      $0.uuid = .incrementing
      $0.continuousClock = ImmediateClock()
      $0[GitClientDependency.self].branchName = { _ in
        for await branch in branches.stream { return branch }
        return nil
      }
      $0.terminalClient.send = { cmd in sent.withValue { $0.append(cmd) } }
      $0.terminalClient.focusSurface = { targetLayoutID, context, targetTab, surf in
        let loc = SessionLocation(
          layoutID: targetLayoutID, directoryID: context.worktreeID, tabID: targetTab, surfaceID: surf)
        focused.withValue { $0.append(loc) }
      }
    }
    store.exhaustivity = .off
    await store.send(.repositories(.activateSession(.implicit(key))))
    await store.receive(\.repositories.delegate.resumeSession)
    #expect(store.state.pendingSessionLaunch?.probing == true)
    let surfaceID = UUID()
    let snapshot = SessionLiveSnapshot(
      harness: .pi, sessionRef: "arrives-during-probe",
      cwd: tmpDir.path(percentEncoded: false),
      location: SessionLocation(
        layoutID: worktreeA.id.layoutID, directoryID: worktreeA.id, tabID: TabID(), surfaceID: surfaceID)
    )
    await store.send(.repositories(.sessionSnapshotsChanged([snapshot])))
    #expect(store.state.repositories.sessionItems[id: .implicit(key)]?.location != nil)
    branches.continuation.yield("main")
    await store.receive(\.resumeBranchProbeCompleted) { appState in
      #expect(appState.pendingSessionLaunch == nil)
      #expect(appState.pendingBranchMismatchResume == nil)
      #expect(appState.alert == nil)
    }
    branches.continuation.finish()
    await store.finish()
    #expect(focused.value.count == 1)
    #expect(focused.value.first?.surfaceID == surfaceID)
    #expect(
      !sent.value.contains {
        if case .createTabWithInput = $0 { return true }
        return false
      })
  }

  @Test(.dependencies) func identityArrivesWhileAlertPending() async throws {
    let tmpDir = try temporaryDirectory(named: "identity-alert-pending")
    defer { try? FileManager.default.removeItem(at: tmpDir) }
    let key = SessionKey(harness: .pi, sessionID: "arrives-during-alert")
    var initial = state()
    let worktreeB = Worktree(
      id: WorktreeID(tmpDir.path), name: "arrives-alert", detail: "",
      workingDirectory: tmpDir, repositoryRootURL: tmpDir)
    initial.repositories.repositories.append(
      Repository(
        id: RepositoryID(tmpDir.path), rootURL: tmpDir, name: "arrives-alert",
        worktrees: [worktreeB]))
    initial.repositories.sessionItems = [
      SessionSidebarItemFeature.State(
        id: .implicit(key), title: "Dormant", cwd: tmpDir.path(percentEncoded: false),
        createdAt: .distantPast)
    ]
    initial.repositories.$sessions.withLock { $0[key] = SessionSidecarEntry(branches: ["old-branch"]) }
    let focused = LockIsolated<[SessionLocation]>([])
    let sent = LockIsolated<[TerminalClient.Command]>([])
    let store = TestStore(initialState: initial) {
      AppFeature()
    } withDependencies: {
      $0.date.now = .distantPast
      $0.uuid = .incrementing
      $0.continuousClock = ImmediateClock()
      $0[GitClientDependency.self].branchName = { _ in "new-branch" }
      $0.terminalClient.send = { cmd in sent.withValue { $0.append(cmd) } }
      $0.terminalClient.focusSurface = { targetLayoutID, context, targetTab, surf in
        let loc = SessionLocation(
          layoutID: targetLayoutID, directoryID: context.worktreeID, tabID: targetTab, surfaceID: surf)
        focused.withValue { $0.append(loc) }
      }
    }
    store.exhaustivity = .off
    await store.send(.repositories(.activateSession(.implicit(key))))
    await store.receive(\.repositories.delegate.resumeSession)
    await store.receive(\.resumeBranchProbeCompleted) { appState in
      #expect(appState.alert != nil)
      #expect(appState.pendingBranchMismatchResume != nil)
    }
    let surfaceID = UUID()
    let snapshot = SessionLiveSnapshot(
      harness: .pi, sessionRef: "arrives-during-alert",
      cwd: tmpDir.path(percentEncoded: false),
      location: SessionLocation(
        layoutID: worktreeB.id.layoutID, directoryID: worktreeB.id, tabID: TabID(), surfaceID: surfaceID)
    )
    await store.send(.repositories(.sessionSnapshotsChanged([snapshot])))
    await store.send(.alert(.presented(.confirmBranchMismatchResume))) { appState in
      #expect(appState.pendingSessionLaunch == nil)
      #expect(appState.pendingBranchMismatchResume == nil)
      #expect(appState.alert == nil)
    }
    await store.finish()
    #expect(focused.value.count == 1)
    #expect(focused.value.first?.surfaceID == surfaceID)
    #expect(
      !sent.value.contains {
        if case .createTabWithInput = $0 { return true }
        return false
      })
  }

  // MARK: - Surface discovery walks tasks

  private func agentTask(
    _ id: LayoutID, surface: UUID, cwd: String? = nil
  ) -> LayoutFeature.State {
    let paneID = PaneID()
    let tab = TabItem(
      id: TabID(rawValue: surface), title: "Agent",
      content: ContentSnapshot(
        id: ContentID(rawValue: surface), state: .terminal(TerminalContentState(workingDirectory: cwd))))
    return LayoutFeature.State(
      id: id,
      layout: PaneLayout(tree: SplitTree(view: paneID), panes: [Pane(id: paneID, tabs: [tab], selectedTabID: tab.id)]))
  }

  private let first = LayoutID(task: UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!)
  private let second = LayoutID(task: UUID(uuidString: "00000000-0000-0000-0000-0000000000A2")!)
  private let firstSurface = UUID(uuidString: "00000000-0000-0000-0000-0000000000B1")!
  private let secondSurface = UUID(uuidString: "00000000-0000-0000-0000-0000000000B2")!

  /// Two minted tasks beside the own-key one on the fixture worktree; the seam resolves it to the first.
  private func twoTasksOnOneDirectory() -> AppFeature.State {
    var state = state()
    state.terminals.layouts.append(agentTask(first, surface: firstSurface))
    state.terminals.layouts.append(agentTask(second, surface: secondSurface, cwd: "/elsewhere"))
    let directory = TaskRecord.Directory(worktreeID: worktree.id)
    state.terminals.directories = [worktree.id.layoutID: directory, first: directory, second: directory]
    state.terminals.activeTasks[worktree.id] = first
    state.agentPresence.records[.init(agent: .pi, surfaceID: firstSurface)] = record(ref: "one")
    state.agentPresence.records[.init(agent: .pi, surfaceID: secondSurface)] = record(ref: "two")
    return state
  }

  @Test func twoTasksOnOneDirectoryEachListTheirAgentUnderTheirOwnLayout() {
    let state = twoTasksOnOneDirectory()

    let snapshots = AppFeature.sessionSnapshots(state: state)

    #expect(
      snapshots.map(\.location) == [
        SessionLocation(
          layoutID: first, directoryID: worktree.id, tabID: TabID(rawValue: firstSurface), surfaceID: firstSurface),
        SessionLocation(
          layoutID: second, directoryID: worktree.id, tabID: TabID(rawValue: secondSurface),
          surfaceID: secondSurface),
      ])
    #expect(snapshots.map(\.sessionRef) == ["one", "two"])
    #expect(snapshots.map(\.cwd) == ["/workspace", "/workspace"])
  }

  @Test func surfaceIndexCoversEveryTaskAndReportsTheTabCwd() {
    let state = twoTasksOnOneDirectory()

    let index = AppFeature.surfaceIndex(state: state)

    #expect(index.count == 4)
    #expect(index[surface]?.layoutID == worktree.id.layoutID)
    #expect(index[shell]?.layoutID == worktree.id.layoutID)
    #expect(
      index[firstSurface]
        == AppFeature.SurfaceEntry(
          layoutID: first, tabID: TabID(rawValue: firstSurface), directoryID: worktree.id,
          directoryPath: "/workspace", cwd: "/workspace"))
    #expect(
      index[secondSurface]
        == AppFeature.SurfaceEntry(
          layoutID: second, tabID: TabID(rawValue: secondSurface), directoryID: worktree.id,
          directoryPath: "/workspace", cwd: "/elsewhere"))
  }

  // MARK: - Branch capture follows the surface's cwd

  /// Branch by path: `/elsewhere` (and anything named so) is on `b-branch`, everything else on `a-branch`.
  private func captureStore(
    _ initial: AppFeature.State, probes: LockIsolated<[String]>, elsewhere: String = "/elsewhere"
  ) -> TestStoreOf<AppFeature> {
    let store = TestStore(initialState: initial) {
      AppFeature()
    } withDependencies: {
      $0.date.now = .distantPast
      $0.uuid = .incrementing
      $0.continuousClock = ImmediateClock()
      $0.terminalClient.saveLayoutsWithAgents = { _ in }
      $0.terminalClient.send = { _ in }
      $0[GitClientDependency.self].branchName = { url in
        let path = url.path(percentEncoded: false)
        probes.withValue { $0.append(path) }
        return path == elsewhere ? "b-branch" : "a-branch"
      }
    }
    store.exhaustivity = .off
    return store
  }

  private func busy(_ surfaceID: UUID, ref: String) -> AppFeature.Action {
    .terminalEvent(
      .agentHookEventReceived(
        AgentHookEvent(
          version: 1, agent: "pi", event: "busy", surfaceID: surfaceID, pid: nil, timestamp: nil,
          sessionRef: ref, data: nil)))
  }

  /// The fixture directory's sidebar row, whose branch is what capture caches.
  private func directoryRow(branch: String) -> SidebarItemFeature.State {
    SidebarItemFeature.State(
      id: worktree.id, repositoryID: "/workspace", kind: .gitWorktree, name: "workspace", branchName: branch,
      subtitle: nil, workingDirectory: worktree.workingDirectory, repositoryAccent: nil, isMainWorktree: true,
      isPinned: false, hasMergedBadge: false)
  }

  @Test(.dependencies) func aTangentRunningElsewhereCapturesTheBranchOfItsOwnDirectory() async {
    var initial = twoTasksOnOneDirectory()
    // The task's directory has a cached branch; it does not speak for a tab running elsewhere.
    initial.repositories.sidebarItems = [directoryRow(branch: "a-branch")]
    let probes = LockIsolated<[String]>([])
    let store = captureStore(initial, probes: probes)

    await store.send(busy(secondSurface, ref: "two"))
    await store.finish()

    #expect(store.state.repositories.sessions[SessionKey(harness: .pi, sessionID: "two")]?.branches == ["b-branch"])
    #expect(probes.value == ["/elsewhere"])
  }

  @Test(.dependencies) func aSurfaceInTheTaskDirectoryCapturesTheCachedBranchWithoutProbing() async {
    var initial = twoTasksOnOneDirectory()
    initial.repositories.sidebarItems = [directoryRow(branch: "cached-branch")]
    let probes = LockIsolated<[String]>([])
    let store = captureStore(initial, probes: probes)

    // One tab recorded no cwd, the other recorded the task directory itself.
    await store.send(busy(firstSurface, ref: "one"))
    await store.send(busy(surface, ref: "own"))
    await store.finish()

    #expect(
      store.state.repositories.sessions[SessionKey(harness: .pi, sessionID: "one")]?.branches == ["cached-branch"])
    #expect(
      store.state.repositories.sessions[SessionKey(harness: .pi, sessionID: "own")]?.branches == ["cached-branch"])
    #expect(probes.value.isEmpty)
  }

  @Test(.dependencies) func aSurfaceInTheTaskDirectoryIsProbedThereWhenNoBranchIsCached() async {
    let probes = LockIsolated<[String]>([])
    let store = captureStore(twoTasksOnOneDirectory(), probes: probes)

    await store.send(busy(firstSurface, ref: "one"))
    await store.finish()

    #expect(store.state.repositories.sessions[SessionKey(harness: .pi, sessionID: "one")]?.branches == ["a-branch"])
    #expect(probes.value == ["/workspace"])
  }

  @Test(.dependencies) func aRemoteTasksTabElsewhereIsNeverProbedOnThisMachine() async throws {
    var initial = twoTasksOnOneDirectory()
    let host = try #require(RemoteHost(authority: "me@box"))
    initial.terminals.directories[second] = TaskRecord.Directory(worktreeID: "me@box/srv/app", host: host)
    let probes = LockIsolated<[String]>([])
    let store = captureStore(initial, probes: probes)

    await store.send(busy(secondSurface, ref: "two"))
    await store.finish()

    #expect(store.state.repositories.sessions[SessionKey(harness: .pi, sessionID: "two")] == nil)
    #expect(probes.value.isEmpty)
  }

  /// A new tab records no cwd and can inherit another tab's; a restored one can
  /// `cd` away. The running surface's directory is what capture goes by.
  @Test(.dependencies, arguments: ["no recorded cwd", "recorded in the task directory"])
  func aSurfaceRunningElsewhereThanRecordedCapturesTheBranchOfWhereItRuns(recorded: String) async {
    var initial = twoTasksOnOneDirectory()
    initial.repositories.sidebarItems = [directoryRow(branch: "a-branch")]
    let target = recorded == "no recorded cwd" ? firstSurface : surface
    let layoutID = recorded == "no recorded cwd" ? first : worktree.id.layoutID
    let probes = LockIsolated<[String]>([])
    let asked = LockIsolated<[LayoutID]>([])
    let store = captureStore(initial, probes: probes)
    store.dependencies.terminalClient.surfaceWorkingDirectory = { layout, surfaceID in
      asked.withValue { $0.append(layout) }
      return surfaceID == target ? "/elsewhere" : nil
    }

    await store.send(busy(target, ref: "moved"))
    await store.finish()

    #expect(
      store.state.repositories.sessions[SessionKey(harness: .pi, sessionID: "moved")]?.branches == ["b-branch"])
    #expect(probes.value == ["/elsewhere"])
    #expect(asked.value == [layoutID])
  }

  @Test(.dependencies) func aSurfaceBackInTheTaskDirectoryCapturesTheCachedBranch() async {
    var initial = twoTasksOnOneDirectory()
    initial.repositories.sidebarItems = [directoryRow(branch: "cached-branch")]
    let probes = LockIsolated<[String]>([])
    let store = captureStore(initial, probes: probes)
    store.dependencies.terminalClient.surfaceWorkingDirectory = { _, _ in "/workspace/" }

    // Recorded in /elsewhere, running in the task directory again.
    await store.send(busy(secondSurface, ref: "two"))
    await store.finish()

    #expect(
      store.state.repositories.sessions[SessionKey(harness: .pi, sessionID: "two")]?.branches == ["cached-branch"])
    #expect(probes.value.isEmpty)
  }

  /// A task whose directory is no roster worktree, known from the running
  /// task or only from its persisted record.
  private func orphanTask(_ directory: TaskRecord.Directory, isLive: Bool) -> AppFeature.State {
    var state = state()
    let layout = agentTask(first, surface: firstSurface)
    if isLive {
      state.terminals.layouts.append(layout)
      state.terminals.directories[first] = directory
    } else {
      state.repositories.$persistedLayouts = SharedReader(
        value: TaskLayoutsFile(tasks: [
          first.persistenceKey: TaskRecord(
            id: first, directory: directory, layout: layout.layout, createdAt: .distantPast)
        ]))
    }
    return state
  }

  @Test(.dependencies, arguments: [true, false])
  func anOrphanTasksAgentCapturesTheBranchOfItsDirectory(isLive: Bool) async {
    let initial = orphanTask(TaskRecord.Directory(worktreeID: "/gone/checkout"), isLive: isLive)
    let probes = LockIsolated<[String]>([])
    let store = captureStore(initial, probes: probes)

    await store.send(busy(firstSurface, ref: "orphan"))
    await store.finish()

    #expect(
      store.state.repositories.sessions[SessionKey(harness: .pi, sessionID: "orphan")]?.branches == ["a-branch"])
    #expect(probes.value == ["/gone/checkout"])
  }

  /// `/srv/app` on the host is not `/srv/app` here.
  @Test(.dependencies, arguments: [true, false])
  func aRemoteOrphanTasksDirectoryIsNeverProbedOnThisMachine(isLive: Bool) async throws {
    let host = try #require(RemoteHost(authority: "me@box"))
    let initial = orphanTask(TaskRecord.Directory(worktreeID: "me@box/srv/app", host: host), isLive: isLive)
    #expect(AppFeature.surfaceIndex(state: initial)[firstSurface]?.directoryPath == "/srv/app")
    let probes = LockIsolated<[String]>([])
    let store = captureStore(initial, probes: probes)

    await store.send(busy(firstSurface, ref: "orphan"))
    await store.finish()

    #expect(store.state.repositories.sessions[SessionKey(harness: .pi, sessionID: "orphan")] == nil)
    #expect(probes.value.isEmpty)
  }

  /// A tangent that ran in B inside a task on A recorded B's branch. Resuming
  /// it where it ran compares against B; resuming it in A compares against A.
  @Test(.dependencies, arguments: [true, false])
  func resumingATangentComparesItsBranchWithTheDirectoryItResumesIn(resumesWhereItRan: Bool) async throws {
    let directoryA = try temporaryDirectory(named: "tangent-a")
    let directoryB = try temporaryDirectory(named: "tangent-b")
    defer {
      try? FileManager.default.removeItem(at: directoryA)
      try? FileManager.default.removeItem(at: directoryB)
    }
    var initial = state()
    for directory in [directoryA, directoryB] {
      let worktree = Worktree(
        id: WorktreeID(directory.path), name: directory.lastPathComponent, detail: "",
        workingDirectory: directory, repositoryRootURL: directory)
      initial.repositories.repositories.append(
        Repository(
          id: RepositoryID(directory.path), rootURL: directory, name: directory.lastPathComponent,
          worktrees: [worktree]))
    }
    let key = SessionKey(harness: .pi, sessionID: "tangent")
    let resumeDirectory = resumesWhereItRan ? directoryB : directoryA
    initial.repositories.sessionItems = [
      SessionSidebarItemFeature.State(
        id: .implicit(key), title: "Tangent", cwd: resumeDirectory.path, createdAt: .distantPast)
    ]
    initial.repositories.$sessions.withLock { $0[key] = SessionSidecarEntry(branches: ["b-branch"]) }
    let probes = LockIsolated<[String]>([])
    let store = captureStore(initial, probes: probes, elsewhere: directoryB.path(percentEncoded: false))

    await store.send(.repositories(.activateSession(.implicit(key))))
    await store.receive(\.resumeBranchProbeCompleted)
    await store.finish()

    #expect(probes.value == [resumeDirectory.path(percentEncoded: false)])
    if resumesWhereItRan {
      #expect(store.state.alert == nil)
      #expect(store.state.pendingBranchMismatchResume == nil)
    } else {
      #expect(store.state.pendingBranchMismatchResume?.recordedBranch == "b-branch")
      #expect(store.state.pendingBranchMismatchResume?.currentBranch == "a-branch")
      #expect(store.state.pendingBranchMismatchResume?.cwd == directoryA)
    }
  }

  @Test func provisionalAgentInNonActiveTaskIsNotUnresolved() {
    var state = twoTasksOnOneDirectory()
    state.agentPresence.records[.init(agent: .pi, surfaceID: secondSurface)] = record(ref: nil)

    #expect(!AppFeature.hasUnresolvedLivePresence(state: state, index: AppFeature.surfaceIndex(state: state)))
    #expect(AppFeature.sessionSnapshots(state: state).map(\.id).contains(.provisional(.pi, secondSurface)))

    let stray = UUID(uuidString: "00000000-0000-0000-0000-0000000000B9")!
    state.agentPresence.records[.init(agent: .pi, surfaceID: stray)] = record(ref: nil)
    #expect(AppFeature.hasUnresolvedLivePresence(state: state, index: AppFeature.surfaceIndex(state: state)))
  }

  @Test func orphanTaskAgentIsListed() {
    let orphan = LayoutID(task: UUID(uuidString: "00000000-0000-0000-0000-0000000000A3")!)
    let orphanSurface = UUID(uuidString: "00000000-0000-0000-0000-0000000000B3")!
    let gone: Worktree.ID = "/gone/checkout"
    var state = state()
    state.terminals.layouts.append(agentTask(orphan, surface: orphanSurface))
    state.terminals.directories[orphan] = TaskRecord.Directory(worktreeID: gone)
    state.agentPresence.records[.init(agent: .pi, surfaceID: orphanSurface)] = record(ref: "orphan")

    let snapshots = AppFeature.sessionSnapshots(state: state)

    #expect(snapshots.count == 1)
    #expect(
      snapshots.first?.location
        == SessionLocation(
          layoutID: orphan, directoryID: gone, tabID: TabID(rawValue: orphanSurface), surfaceID: orphanSurface))
    #expect(snapshots.first?.cwd == "/gone/checkout")
  }

  @Test func neverOpenedOrphanTaskAgentIsListedFromItsRecord() {
    let orphan = LayoutID(task: UUID(uuidString: "00000000-0000-0000-0000-0000000000A4")!)
    let orphanSurface = UUID(uuidString: "00000000-0000-0000-0000-0000000000B4")!
    let gone: Worktree.ID = "/gone/checkout"
    var state = state()
    state.repositories.$persistedLayouts = SharedReader(
      value: TaskLayoutsFile(tasks: [
        orphan.persistenceKey: TaskRecord(
          id: orphan, directory: TaskRecord.Directory(worktreeID: gone),
          layout: agentTask(orphan, surface: orphanSurface).layout, createdAt: .distantPast)
      ]))
    state.agentPresence.records[.init(agent: .pi, surfaceID: orphanSurface)] = record(ref: nil)

    let index = AppFeature.surfaceIndex(state: state)

    #expect(index[orphanSurface]?.layoutID == orphan)
    #expect(index[orphanSurface]?.directoryID == gone)
    #expect(!AppFeature.hasUnresolvedLivePresence(state: state, index: index))
    #expect(AppFeature.sessionSnapshots(state: state, index: index).map(\.location.layoutID) == [orphan])
  }

  // MARK: - Task rows, selection and cycling

  private let third = LayoutID(task: UUID(uuidString: "00000000-0000-0000-0000-0000000000A5")!)
  private let fourth = LayoutID(task: UUID(uuidString: "00000000-0000-0000-0000-0000000000A6")!)
  private let fifth = LayoutID(task: UUID(uuidString: "00000000-0000-0000-0000-0000000000A7")!)
  private let thirdSurface = UUID(uuidString: "00000000-0000-0000-0000-0000000000B5")!
  private let fourthSurface = UUID(uuidString: "00000000-0000-0000-0000-0000000000B6")!
  private let fifthSurface = UUID(uuidString: "00000000-0000-0000-0000-0000000000B7")!

  private var otherWorktree: Worktree {
    Worktree(
      id: "/other", name: "other", detail: "",
      workingDirectory: URL(fileURLWithPath: "/other"),
      repositoryRootURL: URL(fileURLWithPath: "/other"))
  }

  /// Six tasks on two directories. `/workspace`: the own-key task (two shell
  /// tabs), two agent tasks and a shell-only one. `/other`: a shell-only task
  /// that was never opened this run (record only) and an agent task.
  private func sixTasksOnTwoDirectories() -> AppFeature.State {
    var state = twoTasksOnOneDirectory()
    state.repositories.repositories.append(
      Repository(id: "/other", rootURL: otherWorktree.workingDirectory, name: "other", worktrees: [otherWorktree]))
    state.terminals.layouts.append(agentTask(third, surface: thirdSurface))
    state.terminals.layouts.append(agentTask(fifth, surface: fifthSurface))
    state.terminals.directories[third] = TaskRecord.Directory(worktreeID: worktree.id)
    state.terminals.directories[fifth] = TaskRecord.Directory(worktreeID: otherWorktree.id)
    state.repositories.$persistedLayouts = SharedReader(
      value: TaskLayoutsFile(tasks: [
        fourth.persistenceKey: TaskRecord(
          id: fourth, directory: TaskRecord.Directory(worktreeID: otherWorktree.id),
          layout: agentTask(fourth, surface: fourthSurface).layout, createdAt: Date(timeIntervalSince1970: 7))
      ]))
    state.agentPresence.records[.init(agent: .pi, surfaceID: fifthSurface)] = record(ref: "five")
    // No focused surface: cycling then walks from the stored row selection.
    state.terminals.selectedLayoutID = nil
    return state
  }

  private var allSixLayouts: Set<LayoutID> { [worktree.id.layoutID, first, second, third, fourth, fifth] }

  private func withRows(_ state: AppFeature.State) -> AppFeature.State {
    var state = state
    let snapshots = AppFeature.sessionSnapshots(state: state)
    state.repositories.sessionSnapshots = snapshots
    state.repositories.taskSnapshots = AppFeature.taskSnapshots(tasks: AppFeature.taskEntries(state: state))
    state.repositories.reconcileSessionItems(now: .distantPast)
    state.repositories.recomputeSessionsSidebarStructureIfChanged()
    return state
  }

  private struct Recorded {
    let commands = LockIsolated<[TerminalClient.Command]>([])
    let focused = LockIsolated<[SessionLocation]>([])
    let watcher = LockIsolated<[WorktreeInfoWatcherClient.Command]>([])
    let resumes = LockIsolated(0)

    /// Anything but showing a task: the chord may only select and focus.
    var nonFocusCommands: [TerminalClient.Command] {
      commands.value.filter {
        switch $0 {
        case .setSelectedLayoutID: false
        case .ensureInitialTab(_, _, runSetupScriptIfNew: false, focusing: _): false
        default: true
        }
      }
    }

    var selectedLayouts: [LayoutID] {
      commands.value.compactMap {
        if case .setSelectedLayoutID(let id?) = $0 { return id }
        return nil
      }
    }

    var mintedOrResumed: Bool {
      commands.value.contains {
        switch $0 {
        case .createTab, .createTabWithInput: true
        default: false
        }
      }
    }
  }

  /// `hostingContent` is for tests that move the terminal's own selection,
  /// which re-diffs tab visibility and so builds tab content.
  private func taskStore(
    _ initial: AppFeature.State, recorded: Recorded, hostingContent: Bool = false
  ) -> TestStoreOf<AppFeature> {
    let store = TestStore(initialState: initial) {
      CombineReducers {
        AppFeature()
        Reduce<AppFeature.State, AppFeature.Action> { _, action in
          if case .repositories(.delegate(.resumeSession)) = action { recorded.resumes.withValue { $0 += 1 } }
          return .none
        }
      }
    } withDependencies: {
      $0.date.now = .distantPast
      $0.terminalClient.send = { command in recorded.commands.withValue { $0.append(command) } }
      $0.terminalClient.focusSurface = { layoutID, context, tab, surface in
        recorded.focused.withValue {
          $0.append(
            SessionLocation(layoutID: layoutID, directoryID: context.worktreeID, tabID: tab, surfaceID: surface))
        }
      }
      $0.worktreeInfoWatcher.send = { command in recorded.watcher.withValue { $0.append(command) } }
      $0.continuousClock = ImmediateClock()
      $0.terminalClient.saveLayoutsWithAgents = { _ in }
      guard hostingContent else { return }
      $0.contentRuntime = ContentRuntime()
      $0[LayoutContentFactory.self] = LayoutContentFactory { request in
        InertTabContent(id: request.contentID, state: request.content)
      }
      $0[ContentSessionKiller.self] = ContentSessionKiller(kill: { _, _ in })
    }
    store.exhaustivity = .off
    return store
  }

  @Test(.dependencies) func taskWithoutALiveAgentGetsATaskRowTitledByItsDirectory() {
    let state = withRows(sixTasksOnTwoDirectories())

    let tasks = [worktree.id.layoutID, third, fourth].compactMap { state.repositories.sessionItems[id: .task($0)] }
    let taskRowIDs = state.repositories.sessionItems.ids.filter {
      if case .task = $0 { return true }
      return false
    }

    #expect(Set(taskRowIDs) == Set(allSixLayouts.map(SessionRowID.task)), "every row is a task's")
    #expect(tasks.map(\.title) == ["workspace", "workspace", "other"])
    #expect(tasks.allSatisfy { $0.status == nil && $0.primary == nil })
    #expect(tasks.map(\.cwd) == ["/workspace", "/workspace", "/other"])
    #expect(tasks.map(\.location?.directoryID) == [worktree.id, worktree.id, otherWorktree.id])
    #expect(tasks.map(\.createdAt) == [.distantPast, .distantPast, Date(timeIntervalSince1970: 7)])
    #expect(tasks[0].location?.surfaceID == surface, "anchored on the task's first tab, whatever is focused")
    #expect(tasks[2].location?.surfaceID == fourthSurface)
  }

  /// Two tasks reporting one session identity: each is its own row.
  private func twoTasksReportingTheSameSession() -> AppFeature.State {
    var state = sixTasksOnTwoDirectories()
    state.agentPresence.records[.init(agent: .pi, surfaceID: fifthSurface)] = record(ref: "one")
    return state
  }

  @Test(.dependencies) func tasksSharingASessionIdentityAreBothTheTargetOfARow() {
    let state = withRows(twoTasksReportingTheSameSession())
    let rows = state.repositories.sessionItems

    #expect(Set(rows.compactMap(\.location?.layoutID)) == allSixLayouts)
    #expect(rows.count == 6, "one row per task: no task is listed twice")
    #expect(rows[id: .implicit(SessionKey(harness: .pi, sessionID: "one"))] == nil)
    #expect(rows[id: .task(first)]?.location?.surfaceID == firstSurface)
    #expect(rows[id: .task(fifth)]?.location?.surfaceID == fifthSurface)
  }

  @Test(.dependencies, arguments: [1, -1])
  func cyclingVisitsBothTasksSharingASessionIdentity(offset: Int) async {
    let initial = withRows(twoTasksReportingTheSameSession())
    @Shared(.sidebarTab) var tab
    $tab.withLock { $0 = SidebarTab.sessions.rawValue }
    let rowIDs = initial.repositories.sessionsSidebarStructure.liveIDs
    #expect(rowIDs.count == 6)
    let recorded = Recorded()
    let store = taskStore(initial, recorded: recorded)

    for _ in rowIDs {
      await store.send(.repositories(offset > 0 ? .selectNextWorktree : .selectPreviousWorktree))
      await store.finish()
      await store.skipReceivedActions(strict: false)
      await store.skipReceivedActions(strict: false)
    }

    #expect(Set(recorded.selectedLayouts) == allSixLayouts)
    #expect(!recorded.mintedOrResumed)
    #expect(store.state.pendingSessionLaunch == nil)
  }

  @Test(.dependencies) func focusInEitherTaskSharingASessionHighlightsItsOwnRow() {
    var state = withRows(twoTasksReportingTheSameSession())

    state.terminals.selectedLayoutID = fifth
    #expect(AppFeature.focusedSessionRowID(state: state) == .task(fifth))
    state.terminals.selectedLayoutID = first
    #expect(AppFeature.focusedSessionRowID(state: state) == .task(first))
  }

  @Test func emptyTaskGetsNoRow() {
    var state = state()
    state.terminals.layouts[id: worktree.id.layoutID]?.layout.panes[0].tabs = []

    #expect(AppFeature.taskSnapshots(tasks: AppFeature.taskEntries(state: state)).isEmpty)
  }

  @Test func orphanTaskIsListedAsATaskRow() {
    let orphan = LayoutID(task: UUID(uuidString: "00000000-0000-0000-0000-0000000000A3")!)
    let orphanSurface = UUID(uuidString: "00000000-0000-0000-0000-0000000000B3")!
    var state = state()
    state.terminals.layouts.append(agentTask(orphan, surface: orphanSurface))
    state.terminals.directories[orphan] = TaskRecord.Directory(worktreeID: "/gone/checkout")

    let row = withRows(state).repositories.sessionItems[id: .task(orphan)]

    #expect(row?.title == "checkout")
    #expect(row?.cwd == "/gone/checkout")
    #expect(row?.location?.layoutID == orphan)
  }

  @Test(.dependencies) func everyTaskIsTheTargetOfARow() {
    let state = withRows(sixTasksOnTwoDirectories())
    let rows = state.repositories.sessionItems

    #expect(Set(rows.compactMap(\.location?.layoutID)) == allSixLayouts)
    #expect(rows.count == 6, "one row per task: no task is listed twice")
    #expect(Set(rows.ids) == Set(allSixLayouts.map(SessionRowID.task)), "each layout id is a row's target")
    #expect(allSixLayouts.allSatisfy { rows[id: .task($0)]?.location?.layoutID == $0 })
    #expect(rows[id: .task(first)]?.primary == SessionKey(harness: .pi, sessionID: "one"))
    #expect(rows[id: .task(second)]?.primary == SessionKey(harness: .pi, sessionID: "two"))
    #expect(rows[id: .task(fifth)]?.primary == SessionKey(harness: .pi, sessionID: "five"))
    #expect(Set(state.repositories.sessionsSidebarStructure.liveIDs) == Set(rows.ids))
  }

  @Test(.dependencies, arguments: [1, -1])
  func cyclingFromAnyRowVisitsEveryTaskWithoutMintingOrResuming(offset: Int) async {
    let initial = withRows(sixTasksOnTwoDirectories())
    @Shared(.sidebarTab) var tab
    $tab.withLock { $0 = SidebarTab.sessions.rawValue }
    let rowIDs = initial.repositories.sessionsSidebarStructure.liveIDs
    #expect(rowIDs.count == 6)

    for start in rowIDs {
      var from = initial
      from.repositories.sessionSelection = start
      let recorded = Recorded()
      let store = taskStore(from, recorded: recorded)
      for _ in 1..<rowIDs.count {
        await store.send(.repositories(offset > 0 ? .selectNextWorktree : .selectPreviousWorktree))
        await store.finish()
        await store.skipReceivedActions(strict: false)
        await store.skipReceivedActions(strict: false)
      }
      let startLayout = initial.repositories.sessionItems[id: start]?.location?.layoutID
      #expect(Set(recorded.selectedLayouts).union([startLayout].compactMap { $0 }) == allSixLayouts)
      #expect(Set(recorded.selectedLayouts).count == 5, "no task is shown twice in one lap")
      #expect(!recorded.mintedOrResumed)
      #expect(store.state.pendingSessionLaunch == nil)
    }
  }

  @Test(.dependencies) func hotkeySlotsReachEveryTask() async {
    let initial = withRows(sixTasksOnTwoDirectories())
    @Shared(.sidebarTab) var tab
    $tab.withLock { $0 = SidebarTab.sessions.rawValue }
    let recorded = Recorded()
    let store = taskStore(initial, recorded: recorded)

    for slot in 0..<6 {
      await store.send(.repositories(.selectWorktreeAtHotkeySlot(slot)))
      await store.finish()
      await store.skipReceivedActions(strict: false)
    }

    #expect(Set(recorded.selectedLayouts) == allSixLayouts)
    #expect(!recorded.mintedOrResumed)
  }

  @Test(.dependencies) func activatingATaskRowShowsItsOwnTaskNotTheDirectorysActiveOne() async {
    var initial = withRows(twoTasksOnOneDirectory())
    let key = RepositorySettingsKey(rootURL: worktree.repositoryRootURL, host: worktree.host)
    let scripts = LoadedRepositoryScripts(source: key.id, scripts: [])
    initial.loadedRepoScripts = scripts
    #expect(initial.layoutID(forDirectory: worktree.id) == first)
    let recorded = Recorded()
    let store = taskStore(initial, recorded: recorded)
    let row = SessionRowID.task(second)

    await store.send(.repositories(.activateSession(row)))
    await store.receive(\.repositories.selectTask) {
      #expect($0.repositories.selectedTaskID == self.second)
      #expect($0.repositories.selectedWorktreeID == self.worktree.id)
    }
    await store.receive(\.repositories.delegate, .selectedWorktreeChanged(worktree, layoutID: second)) {
      #expect($0.loadedRepoScripts == scripts, "same directory: its scripts are not dropped")
    }
    await store.finish()
    await store.skipReceivedActions(strict: false)

    #expect(recorded.selectedLayouts == [second])
    #expect(recorded.focused.value.isEmpty, "the task keeps the focus it had")
    #expect(
      recorded.commands.value.contains(
        .ensureInitialTab(second, DirectoryContext(worktree: worktree), runSetupScriptIfNew: false, focusing: true)))
    // The directory half reruns with the directory it already had, which the
    // watcher ignores; it is never pointed at another one.
    #expect(recorded.watcher.value.allSatisfy { $0 == .setSelectedWorktreeID(self.worktree.id) })
    #expect(store.state.loadedRepoScripts?.source == key.id)
    #expect(!recorded.mintedOrResumed)
  }

  @Test(.dependencies) func selectedWorktreeFollowsTheSelectedTasksDirectory() async {
    let initial = withRows(sixTasksOnTwoDirectories())
    #expect(initial.repositories.selectedWorktreeID == worktree.id)
    let recorded = Recorded()
    let store = taskStore(initial, recorded: recorded)

    await store.send(.repositories(.activateSession(.task(fifth))))
    await store.receive(\.repositories.selectTask) {
      #expect($0.repositories.selectedTaskID == self.fifth)
    }
    await store.finish()
    await store.skipReceivedActions(strict: false)

    #expect(store.state.repositories.selectedTaskID == fifth)
    #expect(store.state.repositories.selectedWorktreeID == otherWorktree.id)
    #expect(recorded.selectedLayouts == [fifth])
    #expect(recorded.watcher.value.contains(.setSelectedWorktreeID(otherWorktree.id)))
  }

  @Test(.dependencies) func activatingATaskRowShowsTheTaskWithItsOwnFocus() async {
    let initial = withRows(sixTasksOnTwoDirectories())
    let recorded = Recorded()
    let store = taskStore(initial, recorded: recorded)

    await store.send(.repositories(.activateSession(.task(fourth)))) {
      $0.repositories.sessionSelection = .task(self.fourth)
    }
    await store.receive(\.repositories.delegate.focusTask)
    await store.receive(\.repositories.selectTask) {
      #expect($0.repositories.selectedTaskID == self.fourth)
    }
    await store.finish()
    await store.skipReceivedActions(strict: false)

    #expect(store.state.repositories.selectedTaskID == fourth)
    #expect(store.state.repositories.selectedWorktreeID == otherWorktree.id)
    #expect(recorded.selectedLayouts == [fourth])
    #expect(recorded.focused.value.isEmpty, "the anchor tab is not forced into focus")
    #expect(
      recorded.commands.value.contains(
        .ensureInitialTab(
          fourth, DirectoryContext(worktree: otherWorktree), runSetupScriptIfNew: false, focusing: true)))
    #expect(!recorded.mintedOrResumed)
  }

  private let orphanShell = LayoutID(task: UUID(uuidString: "00000000-0000-0000-0000-0000000000A3")!)
  private let orphanAgent = LayoutID(task: UUID(uuidString: "00000000-0000-0000-0000-0000000000A4")!)
  private let orphanShellSurface = UUID(uuidString: "00000000-0000-0000-0000-0000000000B3")!
  private let orphanAgentSurface = UUID(uuidString: "00000000-0000-0000-0000-0000000000B4")!
  private let goneDirectory = TaskRecord.Directory(worktreeID: "/gone/checkout")

  /// A live shell-only task and a never-opened agent task (record only), both
  /// on a directory the roster does not list.
  private func withOrphans(_ initial: AppFeature.State) -> AppFeature.State {
    var state = initial
    state.terminals.layouts.append(agentTask(orphanShell, surface: orphanShellSurface))
    state.terminals.directories[orphanShell] = goneDirectory
    var tasks = state.repositories.persistedLayouts.tasks
    tasks[orphanAgent.persistenceKey] = TaskRecord(
      id: orphanAgent, directory: goneDirectory,
      layout: agentTask(orphanAgent, surface: orphanAgentSurface).layout, createdAt: Date(timeIntervalSince1970: 9))
    state.repositories.$persistedLayouts = SharedReader(value: TaskLayoutsFile(tasks: tasks))
    state.agentPresence.records[.init(agent: .pi, surfaceID: orphanAgentSurface)] = record(ref: "orphan")
    return state
  }

  @Test(.dependencies) func activatingAnOrphanTaskRowShowsAndFocusesIt() async {
    let recorded = Recorded()
    let store = taskStore(withRows(withOrphans(state())), recorded: recorded)

    await store.send(.repositories(.activateSession(.task(orphanShell))))
    await store.finish()
    await store.skipReceivedActions(strict: false)

    #expect(store.state.repositories.selectedTaskID == orphanShell)
    #expect(store.state.repositories.orphanTaskID == orphanShell)
    #expect(store.state.repositories.selectedWorktreeID == nil, "no roster directory stands in for it")
    #expect(recorded.selectedLayouts == [orphanShell])
    #expect(
      recorded.commands.value.contains(
        .ensureInitialTab(
          orphanShell, DirectoryContext(orphan: goneDirectory), runSetupScriptIfNew: false, focusing: true)))
    #expect(recorded.watcher.value == [.setSelectedWorktreeID(nil)])
    #expect(!recorded.mintedOrResumed)
  }

  @Test(.dependencies) func activatingAnOrphanAgentTaskRowShowsIt() async {
    let recorded = Recorded()
    let initial = withRows(withOrphans(state()))
    #expect(initial.repositories.sessionItems[id: .task(orphanAgent)]?.status == .idle)
    let store = taskStore(initial, recorded: recorded)

    await store.send(.repositories(.activateSession(.task(orphanAgent))))
    await store.finish()
    await store.skipReceivedActions(strict: false)

    #expect(store.state.repositories.selectedTaskID == orphanAgent)
    #expect(recorded.selectedLayouts == [orphanAgent])
    #expect(
      recorded.commands.value.contains(
        .ensureInitialTab(
          orphanAgent, DirectoryContext(orphan: goneDirectory), runSetupScriptIfNew: false, focusing: true)))
    #expect(!recorded.mintedOrResumed)
  }

  @Test func orphanContextComesFromTheRecordedDirectory() {
    let local = DirectoryContext(orphan: goneDirectory)
    #expect(local.worktreeID == "/gone/checkout")
    #expect(local.name == "checkout")
    #expect(local.workingDirectory.path(percentEncoded: false) == "/gone/checkout")
    #expect(local.repositoryRootURL == local.workingDirectory)
    #expect(local.host == nil)

    let host = RemoteHost(authority: "me@box")!
    let remote = DirectoryContext(orphan: TaskRecord.Directory(worktreeID: "me@box/srv/app", host: host))
    #expect(remote.host == host)
    #expect(remote.workingDirectory.path(percentEncoded: false) == "/srv/app")
    #expect(remote.name == "app")
  }

  // MARK: - A store split by the task migration is fully reachable

  private func splitTab(_ number: Int, agent: Bool) -> TabItem {
    let id = UUID(uuidString: String(format: "00000000-0000-0000-0000-0000000000%02d", number))!
    let agents = [
      TerminalLayoutSnapshot.SurfaceAgentRecord(
        agent: "pi", pids: [], activity: "idle", doneUnseen: nil, sessionRef: "split-\(number)",
        resumeCandidate: true)
    ]
    return TabItem(
      id: TabID(rawValue: id), title: "Tab \(number)",
      content: ContentSnapshot(
        id: ContentID(rawValue: id),
        state: .terminal(TerminalContentState(workingDirectory: nil, agents: agent ? agents : nil))))
  }

  private func splitRecord(_ tabs: [TabItem]) -> LayoutRecord {
    let paneID = PaneID()
    return LayoutRecord(
      layout: PaneLayout(
        tree: SplitTree(view: paneID),
        panes: [Pane(id: paneID, tabs: IdentifiedArray(uniqueElements: tabs), selectedTabID: tabs.last?.id)],
        focusedPaneID: paneID))
  }

  /// A v2 store run through the split: a mixed directory, an all-agent one and
  /// one that is no longer a known worktree. Nothing is open yet.
  private func migratedStore(
    activeTasks: [String: String] = [:]
  ) -> (state: AppFeature.State, file: TaskLayoutsFile) {
    var unsplit = TaskLayoutsFile(
      oneTaskPerDirectory: LayoutsFile(worktrees: [
        "/workspace": splitRecord([splitTab(11, agent: false), splitTab(12, agent: true), splitTab(13, agent: true)]),
        "/other": splitRecord([splitTab(21, agent: true), splitTab(22, agent: true)]),
        "/gone/orphan": splitRecord([splitTab(31, agent: true), splitTab(32, agent: false)]),
      ]))
    unsplit.activeTasks = activeTasks
    let file = LayoutsTaskSplitter.split(unsplit, now: Date(timeIntervalSince1970: 9))
    var state = state()
    state.repositories.repositories.append(
      Repository(id: "/other", rootURL: otherWorktree.workingDirectory, name: "other", worktrees: [otherWorktree]))
    state.terminals.layouts = []
    state.terminals.directories = [:]
    state.terminals.selectedLayoutID = nil
    state.repositories.$persistedLayouts = SharedReader(value: file)
    return (state, file)
  }

  /// A hint naming a task that no longer exists must not strand the directory
  /// on the own-key layout the split just removed.
  @Test(.dependencies)
  func allAgentDirectoryWithAStaleHintResolvesToAMigratedTask() async {
    let (unhydrated, file) = migratedStore(activeTasks: ["/other": "no-such-task"])
    let onOther = Set(file.tasks.values.filter { $0.directory.worktreeID == "/other" }.map(\.id))
    #expect(onOther.count == 2)
    #expect(file.tasks["/other"] == nil)
    let store = taskStore(unhydrated, recorded: Recorded())
    await store.send(.terminals(.layoutsHydrated(file)))
    await store.finish()
    await store.skipReceivedActions(strict: false)
    let resolved = store.state.layoutID(forDirectory: "/other")
    #expect(onOther.contains(resolved))
    #expect(store.state.terminals.layouts[id: resolved] != nil)
  }

  /// A hint naming a surviving task on another directory is one hydration
  /// ignores, so the split must not let it stand in for the directory's own.
  @Test(.dependencies)
  func allAgentDirectoryWithACrossDirectoryHintResolvesToItsOwnMigratedTask() async throws {
    let (unhydrated, split) = migratedStore(activeTasks: ["/other": "/workspace"])
    // Through the codec, as the launch migration writes it and hydration reads it.
    let file = try JSONDecoder().decode(TaskLayoutsFile.self, from: JSONEncoder().encode(split))
    let onOther = Set(file.tasks.values.filter { $0.directory.worktreeID == "/other" }.map(\.id))
    #expect(onOther.count == 2)
    #expect(file.tasks["/other"] == nil)
    #expect(file.tasks["/workspace"] != nil, "the hinted task survives the split")
    let store = taskStore(unhydrated, recorded: Recorded())
    await store.send(.terminals(.layoutsHydrated(file)))
    await store.finish()
    await store.skipReceivedActions(strict: false)
    let resolved = store.state.layoutID(forDirectory: "/other")
    #expect(onOther.contains(resolved))
    #expect(store.state.terminals.layouts[id: resolved] != nil)
  }

  @Test(.dependencies, arguments: [1, -1])
  func everyMigratedTaskHasARowAndIsInTheCycle(offset: Int) async {
    let (unhydrated, file) = migratedStore()
    let everyLayout = Set(file.tasks.values.map(\.id))
    #expect(everyLayout.count == 7)
    let hydrating = taskStore(unhydrated, recorded: Recorded())
    await hydrating.send(.terminals(.layoutsHydrated(file)))
    await hydrating.finish()
    await hydrating.skipReceivedActions(strict: false)
    #expect(Set(hydrating.state.terminals.layouts.ids) == everyLayout)
    // A directory left with no task under its own key resolves to a real one.
    #expect(everyLayout.contains(hydrating.state.layoutID(forDirectory: "/other")))
    #expect(everyLayout.contains(hydrating.state.layoutID(forDirectory: "/workspace")))

    let initial = withRows(hydrating.state)
    @Shared(.sidebarTab) var tab
    $tab.withLock { $0 = SidebarTab.sessions.rawValue }
    let rows = initial.repositories.sessionItems
    let rowIDs = initial.repositories.sessionsSidebarStructure.liveIDs
    #expect(Set(rows.compactMap(\.location?.layoutID)) == everyLayout)
    #expect(rows.count == 7, "one row per migrated task")
    #expect(Set(rowIDs) == Set(rows.ids))

    for start in rowIDs {
      var from = initial
      from.repositories.sessionSelection = start
      let recorded = Recorded()
      let store = taskStore(from, recorded: recorded)
      for _ in 1..<rowIDs.count {
        await store.send(.repositories(offset > 0 ? .selectNextWorktree : .selectPreviousWorktree))
        await store.finish()
        await store.skipReceivedActions(strict: false)
        await store.skipReceivedActions(strict: false)
      }
      let startLayout = rows[id: start]?.location?.layoutID
      #expect(Set(recorded.selectedLayouts).union([startLayout].compactMap { $0 }) == everyLayout)
      #expect(Set(recorded.selectedLayouts).count == rowIDs.count - 1, "no task is shown twice in one lap")
      #expect(!recorded.mintedOrResumed)
      #expect(store.state.pendingSessionLaunch == nil)
    }
  }

  @Test(.dependencies, arguments: [1, -1])
  func cyclingVisitsOrphanTasksToo(offset: Int) async {
    let initial = withRows(withOrphans(sixTasksOnTwoDirectories()))
    @Shared(.sidebarTab) var tab
    $tab.withLock { $0 = SidebarTab.sessions.rawValue }
    let rowIDs = initial.repositories.sessionsSidebarStructure.liveIDs
    let everyLayout = allSixLayouts.union([orphanShell, orphanAgent])
    #expect(Set(rowIDs.compactMap { initial.repositories.sessionItems[id: $0]?.location?.layoutID }) == everyLayout)

    for start in rowIDs {
      var from = initial
      from.repositories.sessionSelection = start
      let recorded = Recorded()
      let store = taskStore(from, recorded: recorded)
      for _ in 1..<rowIDs.count {
        await store.send(.repositories(offset > 0 ? .selectNextWorktree : .selectPreviousWorktree))
        await store.finish()
        await store.skipReceivedActions(strict: false)
        await store.skipReceivedActions(strict: false)
      }
      let startLayout = initial.repositories.sessionItems[id: start]?.location?.layoutID
      #expect(Set(recorded.selectedLayouts).union([startLayout].compactMap { $0 }) == everyLayout)
      #expect(Set(recorded.selectedLayouts).count == rowIDs.count - 1, "no task is shown twice in one lap")
      #expect(!recorded.mintedOrResumed)
      #expect(store.state.pendingSessionLaunch == nil)
    }
  }

  @Test(.dependencies) func leavingAnOrphanTaskDropsIt() async {
    var initial = withRows(withOrphans(sixTasksOnTwoDirectories()))
    initial.repositories.selection = nil
    initial.repositories.selectedTask = SelectedTask(id: orphanShell, directoryID: goneDirectory.worktreeID)
    #expect(initial.repositories.orphanTaskID == orphanShell)

    let deselected = taskStore(initial, recorded: Recorded())
    await deselected.send(.repositories(.delegate(.selectedWorktreeChanged(nil))))
    await deselected.finish()
    #expect(deselected.state.repositories.selectedTask == nil)

    let recorded = Recorded()
    let moved = taskStore(initial, recorded: recorded)
    await moved.send(.repositories(.activateSession(.task(fourth))))
    await moved.finish()
    await moved.skipReceivedActions(strict: false)
    #expect(moved.state.repositories.orphanTaskID == nil)
    #expect(moved.state.repositories.selectedTaskID == fourth)
    #expect(moved.state.repositories.selectedWorktreeID == otherWorktree.id)
  }

  /// `/other` is still a roster worktree but its directory is gone from disk;
  /// its two tasks (one live, one record only) survive.
  private func otherDirectoryMissing() -> AppFeature.State {
    var state = sixTasksOnTwoDirectories()
    let missing = Worktree(
      id: otherWorktree.id, name: otherWorktree.name, detail: "",
      workingDirectory: otherWorktree.workingDirectory, repositoryRootURL: otherWorktree.repositoryRootURL,
      isMissing: true)
    state.repositories.repositories[id: "/other"] = Repository(
      id: "/other", rootURL: missing.workingDirectory, name: "other", worktrees: [missing])
    return state
  }

  @Test(.dependencies, arguments: [true, false])
  func activatingATaskOnAMissingDirectoryShowsTheTaskNotThePlaceholder(live: Bool) async {
    let task = live ? fifth : fourth
    let rowID = SessionRowID.task(task)
    let recorded = Recorded()
    let store = taskStore(withRows(otherDirectoryMissing()), recorded: recorded)
    #expect(store.state.repositories.worktree(for: otherWorktree.id)?.isMissing == true)

    await store.send(.repositories(.activateSession(rowID)))
    await store.finish()
    await store.skipReceivedActions(strict: false)

    #expect(store.state.repositories.selectedWorktreeID == otherWorktree.id)
    #expect(store.state.taskOnMissingDirectory == task)
    #expect(recorded.selectedLayouts == [task])
    #expect(!recorded.mintedOrResumed)
  }

  @Test(.dependencies) func selectingAMissingDirectoryAloneKeepsThePlaceholder() async {
    var initial = withRows(otherDirectoryMissing())
    #expect(initial.taskOnMissingDirectory == nil, "nothing on the missing directory is selected")

    initial.repositories.selection = .worktree(otherWorktree.id)
    #expect(initial.taskOnMissingDirectory == nil, "the directory by itself is the placeholder")

    initial.repositories.selectedTask = SelectedTask(id: fifth, directoryID: otherWorktree.id)
    #expect(initial.taskOnMissingDirectory == fifth)

    // Leaving for another directory lets go of the task, so the directory's
    // own row leads back to the placeholder and its delete action.
    let store = taskStore(initial, recorded: Recorded())
    await store.send(.repositories(.selectWorktree(worktree.id)))
    await store.finish()
    await store.skipReceivedActions(strict: false)
    #expect(store.state.repositories.selectedTask == nil)
    await store.send(.repositories(.selectWorktree(otherWorktree.id)))
    await store.finish()
    await store.skipReceivedActions(strict: false)
    #expect(store.state.repositories.selectedWorktreeID == otherWorktree.id)
    #expect(store.state.taskOnMissingDirectory == nil)
  }

  /// `fifth` was picked on the missing directory, then lost its last tab but
  /// still lists a session; `sibling` puts `fourth`, with a tab, beside it.
  private func emptiedSelectedTaskOnMissingDirectory(sibling: Bool) -> AppFeature.State {
    var state = otherDirectoryMissing()
    state.terminals.layouts[id: fifth]?.layout = PaneLayout()
    state.terminals.members[fifth] = [.session(SessionKey(harness: .pi, sessionID: "five"))]
    state.terminals.activeTasks[otherWorktree.id] = fifth
    if sibling {
      state.terminals.layouts.append(agentTask(fourth, surface: fourthSurface))
      state.terminals.directories[fourth] = TaskRecord.Directory(worktreeID: otherWorktree.id)
    }
    state = withRows(state)
    state.repositories.selection = .worktree(otherWorktree.id)
    state.repositories.selectedTask = SelectedTask(id: fifth, directoryID: otherWorktree.id)
    return state
  }

  @Test(.dependencies)
  func selectingAMissingDirectoryWhoseSelectedTaskEmptiedShowsWhatTheTerminalIsSentTo() async {
    let initial = emptiedSelectedTaskOnMissingDirectory(sibling: true)
    #expect(initial.taskOnMissingDirectory == fifth, "the explicit pick is shown until the directory is selected")
    let sibling = fourth
    #expect(initial.terminals.task(forDirectory: otherWorktree.id) == sibling)
    let recorded = Recorded()
    let store = taskStore(initial, recorded: recorded)
    store.exhaustivity = .off

    await store.send(.repositories(.delegate(.selectedWorktreeChanged(otherWorktree))))
    await store.finish()

    #expect(recorded.selectedLayouts == [sibling])
    #expect(store.state.repositories.selectedTask == nil)
    #expect(store.state.taskOnMissingDirectory == nil, "the directory by itself is the placeholder")

    // The terminal's echo of the sibling changes nothing about that.
    var echoed = store.state
    echoed.terminals.selectedLayoutID = sibling
    echoed.terminals.selectionOrder.append(sibling)
    echoed.terminals.activeTasks[otherWorktree.id] = sibling
    #expect(echoed.taskOnMissingDirectory == nil)
    #expect(echoed.detailLayoutID(forDirectory: otherWorktree.id) == sibling)
  }

  @Test(.dependencies) func anEmptiedSelectedTaskWithNoSiblingStaysWhereTheTerminalIsSent() async {
    let recorded = Recorded()
    let store = taskStore(emptiedSelectedTaskOnMissingDirectory(sibling: false), recorded: recorded)
    store.exhaustivity = .off

    await store.send(.repositories(.delegate(.selectedWorktreeChanged(otherWorktree))))
    await store.finish()

    #expect(recorded.selectedLayouts == [fifth])
    #expect(store.state.taskOnMissingDirectory == fifth)
    #expect(store.state.detailLayoutID(forDirectory: otherWorktree.id) == fifth)
  }

  @Test(.dependencies) func aTaskThatIsGoneDoesNotHideThePlaceholder() {
    var state = withRows(otherDirectoryMissing())
    state.repositories.selection = .worktree(otherWorktree.id)
    state.repositories.selectedTask = SelectedTask(
      id: LayoutID(task: UUID(uuidString: "00000000-0000-0000-0000-0000000000A9")!), directoryID: otherWorktree.id)

    #expect(state.taskOnMissingDirectory == nil)
  }

  @Test(.dependencies) func aTaskOnAPresentDirectoryIsNotTreatedAsMissing() {
    var state = withRows(sixTasksOnTwoDirectories())
    state.repositories.selection = .worktree(otherWorktree.id)
    state.repositories.selectedTask = SelectedTask(id: fifth, directoryID: otherWorktree.id)

    #expect(state.taskOnMissingDirectory == nil)
  }

  @Test(.dependencies) func focusedShellOnlyTaskResolvesToItsTaskRow() {
    var state = withRows(sixTasksOnTwoDirectories())
    state.terminals.selectedLayoutID = third

    #expect(AppFeature.focusedSessionRowID(state: state) == .task(third))

    state.terminals.selectedLayoutID = first
    #expect(AppFeature.focusedSessionRowID(state: state) == .task(first))
  }

  @Test(.dependencies) func taskRowsFollowTerminalChanges() async {
    var initial = sixTasksOnTwoDirectories()
    initial.repositories.sessionSnapshots = AppFeature.sessionSnapshots(state: initial)
    let store = taskStore(initial, recorded: Recorded())

    await store.send(.agentPresence(.delegate(.surfacesChanged([]))))
    await store.receive(\.repositories.taskSnapshotsChanged)
    await store.finish()
    await store.skipReceivedActions(strict: false)

    #expect(
      Set(store.state.repositories.sessionItems.ids)
        .isSuperset(of: [.task(worktree.id.layoutID), .task(third), .task(fourth)]))
  }

  @Test(.dependencies) func selectedTaskIsForgottenOnceTheTaskIsGone() async {
    var initial = state()
    let gone = LayoutID(task: UUID(uuidString: "00000000-0000-0000-0000-0000000000A8")!)
    initial.repositories.selectedTask = SelectedTask(id: gone, directoryID: worktree.id)
    #expect(initial.repositories.selectedTaskID == gone)
    let store = taskStore(initial, recorded: Recorded())

    await store.send(.agentPresence(.delegate(.surfacesChanged([]))))
    await store.receive(\.repositories.selectedTaskRemoved)
    await store.finish()
    await store.skipReceivedActions(strict: false)

    #expect(store.state.repositories.selectedTaskID == nil)
    #expect(store.state.repositories.selectedWorktreeID == worktree.id)
  }

  @Test(.dependencies) func selectedTaskSurvivesWhileItsTaskExists() async {
    var initial = twoTasksOnOneDirectory()
    initial.repositories.selectedTask = SelectedTask(id: second, directoryID: worktree.id)
    let store = taskStore(initial, recorded: Recorded())

    await store.send(.agentPresence(.delegate(.surfacesChanged([]))))
    await store.finish()
    await store.skipReceivedActions(strict: false)

    #expect(store.state.repositories.selectedTaskID == second)
  }

  // MARK: - A provisional agent protects the directory its tab runs in

  private func oldSummary(_ id: String, cwd: String) -> SessionSummary {
    SessionSummary(
      harness: .pi, sessionID: id, createdAt: .distantPast, cwd: cwd,
      title: id, messageCount: 1, lastActivity: .distantPast)
  }

  /// Restores one provisional agent on `surface`, refreshes, and returns the sidecar.
  private func sidecarAfterProvisionalRestore(
    _ initial: AppFeature.State, surface: UUID, summaries: [SessionSummary]
  ) async -> [SessionKey: SessionSidecarEntry] {
    var initial = initial
    initial.repositories.sessionSummaries = summaries
    initial.repositories.sessionsRefreshSucceeded = true
    let store = TestStore(initialState: initial) {
      AppFeature()
    } withDependencies: {
      $0.date.now = Date(timeIntervalSince1970: 1_000_000)
      $0.continuousClock = TestClock()
      $0.terminalClient.saveLayoutsWithAgents = { _ in }
    }
    store.exhaustivity = .off
    await store.send(
      .agentPresence(
        .restoreFromSnapshotChecked(
          records: [
            .init(agent: .pi, surfaceID: surface): AgentPresenceFeature.RestoredRecord(
              alivePids: [123], activity: .idle, sessionRef: nil)
          ], resumeCandidates: [:])))
    await store.receive(\.repositories.sessionsRestorationCompleted)
    #expect(!store.state.repositories.sessionsHasUnresolvedLivePresence)
    await store.send(.repositories(.sessionsRefreshCompleted(summaries)))
    await store.finish()
    return store.state.repositories.sessions
  }

  @Test(.dependencies) func provisionalInNonActiveTaskProtectsItsTabCwdFromAutoSettle() async {
    var initial = state()
    initial.terminals.layouts.append(agentTask(first, surface: firstSurface))
    initial.terminals.layouts.append(agentTask(second, surface: secondSurface, cwd: "/elsewhere"))
    let directory = TaskRecord.Directory(worktreeID: worktree.id)
    initial.terminals.directories = [worktree.id.layoutID: directory, first: directory, second: directory]
    initial.terminals.activeTasks[worktree.id] = first
    let inTabCwd = oldSummary("in-tab-cwd", cwd: "/elsewhere")
    let inTaskDirectory = oldSummary("in-task-directory", cwd: "/workspace")
    let unrelated = oldSummary("unrelated", cwd: "/third")

    let sidecar = await sidecarAfterProvisionalRestore(
      initial, surface: secondSurface, summaries: [inTabCwd, inTaskDirectory, unrelated])

    #expect(sidecar[inTabCwd.id] == nil, "the provisional agent may be this session")
    #expect(sidecar[inTaskDirectory.id] == nil)
    #expect(sidecar[unrelated.id]?.settledAt != nil, "settlement ran and is only blocked per directory")
  }

  @Test(.dependencies) func provisionalInPersistedOrphanTaskProtectsItsTabCwdFromAutoSettle() async {
    let orphan = LayoutID(task: UUID(uuidString: "00000000-0000-0000-0000-0000000000A5")!)
    let orphanSurface = UUID(uuidString: "00000000-0000-0000-0000-0000000000B5")!
    var initial = state()
    initial.repositories.$persistedLayouts = SharedReader(
      value: TaskLayoutsFile(tasks: [
        orphan.persistenceKey: TaskRecord(
          id: orphan, directory: TaskRecord.Directory(worktreeID: "/gone/checkout"),
          layout: agentTask(orphan, surface: orphanSurface, cwd: "/elsewhere").layout, createdAt: .distantPast)
      ]))
    let inTabCwd = oldSummary("in-tab-cwd", cwd: "/elsewhere")
    let inTaskDirectory = oldSummary("in-task-directory", cwd: "/gone/checkout")
    let unrelated = oldSummary("unrelated", cwd: "/third")

    let sidecar = await sidecarAfterProvisionalRestore(
      initial, surface: orphanSurface, summaries: [inTabCwd, inTaskDirectory, unrelated])

    #expect(sidecar[inTabCwd.id] == nil, "the provisional agent may be this session")
    #expect(sidecar[inTaskDirectory.id] == nil)
    #expect(sidecar[unrelated.id]?.settledAt != nil, "settlement ran and is only blocked per directory")
  }

  // MARK: - Minting and membership

  private struct Launch {
    let layoutID: LayoutID
    let directory: Worktree.ID
    let input: String
  }

  private func launches(_ recorded: Recorded) -> [Launch] {
    recorded.commands.value.compactMap { command in
      guard case .createTabWithInput(let layoutID, let context, let input, _, _, _, _, _) = command else { return nil }
      return Launch(layoutID: layoutID, directory: context.worktreeID, input: input)
    }
  }

  /// The fixture worktree moved onto a real directory, since a launch checks the cwd exists.
  private func stateOnDisk(_ directory: URL) -> (AppFeature.State, Worktree) {
    let path = directory.path(percentEncoded: false)
    let onDisk = Worktree(
      id: Worktree.ID(path), name: "disk", detail: "", workingDirectory: directory, repositoryRootURL: directory)
    var state = state()
    state.repositories.repositories = [
      Repository(id: RepositoryID(path), rootURL: directory, name: "disk", worktrees: [onDisk])
    ]
    state.repositories.selection = .worktree(onDisk.id)
    state.terminals.layouts = []
    return (state, onDisk)
  }

  private func dormantRow(_ key: SessionKey, cwd: URL) -> SessionSidebarItemFeature.State {
    SessionSidebarItemFeature.State(
      id: .implicit(key), title: "Dormant", cwd: cwd.path(percentEncoded: false), createdAt: .distantPast,
      location: nil)
  }

  private func mintingStore(_ initial: AppFeature.State, recorded: Recorded) -> TestStoreOf<AppFeature> {
    let store = TestStore(initialState: initial) {
      AppFeature()
    } withDependencies: {
      $0.date.now = .distantPast
      $0.uuid = .incrementing
      $0.continuousClock = ImmediateClock()
      $0.terminalClient.send = { command in recorded.commands.withValue { $0.append(command) } }
      $0.worktreeInfoWatcher.send = { _ in }
      $0.terminalClient.saveLayoutsWithAgents = { _ in }
    }
    store.exhaustivity = .off
    return store
  }

  @Test(.dependencies) func newSessionMintsATaskInTheCurrentDirectoryWithTheDefaultAgentAndNoPrompt() async throws {
    let directory = try temporaryDirectory(named: "mint-new")
    let (initial, onDisk) = stateOnDisk(directory)
    let recorded = Recorded()
    let store = mintingStore(initial, recorded: recorded)

    await store.send(.newSession)
    await store.receive(\.launchSessionCompleted)
    await store.finish()

    let launch = try #require(launches(recorded).first)
    #expect(launches(recorded).count == 1)
    #expect(launch.layoutID == LayoutID(task: UUID(1)), "a fresh task, not the directory's own layout")
    #expect(launch.layoutID != onDisk.id.layoutID)
    #expect(launch.directory == onDisk.id)
    #expect(launch.input == "pi")
    #expect(store.state.alert == nil)
    #expect(store.state.pendingTaskLaunches == [PendingTaskLaunch(layoutID: launch.layoutID, directoryID: onDisk.id)])
  }

  /// The shown task sits on `directory`; `elsewhere` is a registered directory too, so a launch there would be instant.
  private func shownTaskOnDisk(_ directory: URL, elsewhere: URL) -> (AppFeature.State, Worktree) {
    var (state, onDisk) = stateOnDisk(directory)
    let path = elsewhere.path(percentEncoded: false)
    let other = Worktree(
      id: Worktree.ID(path), name: "elsewhere", detail: "", workingDirectory: elsewhere, repositoryRootURL: elsewhere)
    state.repositories.repositories.append(
      Repository(id: RepositoryID(path), rootURL: elsewhere, name: "elsewhere", worktrees: [other]))
    state.terminals.layouts = [agentTask(first, surface: firstSurface, cwd: path)]
    state.terminals.directories[first] = TaskRecord.Directory(worktreeID: onDisk.id)
    state.terminals.selectedLayoutID = first
    state.repositories.selectedTask = .init(id: first, directoryID: onDisk.id)
    return (state, onDisk)
  }

  @Test(.dependencies) func newSessionStartsInTheCurrentTasksDirectoryNotItsFocusedTangents() async throws {
    let directory = try temporaryDirectory(named: "mint-task-directory")
    let tangentCwd = try temporaryDirectory(named: "mint-tangent")
    var (initial, onDisk) = shownTaskOnDisk(directory, elsewhere: tangentCwd)
    // The focused tab of the task runs an agent in another directory.
    let location = SessionLocation(
      layoutID: first, directoryID: onDisk.id, tabID: TabID(rawValue: firstSurface), surfaceID: firstSurface)
    let tangentPath = tangentCwd.path(percentEncoded: false)
    initial.repositories.sessionItems = [
      SessionSidebarItemFeature.State(
        id: .implicit(piKey("tangent")), title: "Tangent", cwd: tangentPath, createdAt: .distantPast,
        location: location)
    ]
    initial.repositories.sessionSnapshots = [
      SessionLiveSnapshot(harness: .pi, sessionRef: "tangent", cwd: tangentPath, location: location)
    ]
    #expect(AppFeature.focusedSessionRowID(state: initial) == .implicit(piKey("tangent")))
    let recorded = Recorded()
    let store = mintingStore(initial, recorded: recorded)

    await store.send(.newSession)
    await store.receive(\.launchSessionCompleted)
    await store.finish()

    #expect(launches(recorded).map(\.directory) == [onDisk.id])
    #expect(launches(recorded).first?.layoutID != first)
  }

  @Test(.dependencies) func newSessionStartsInTheCurrentTasksDirectoryNotTheSelectedHistoryRows() async throws {
    let directory = try temporaryDirectory(named: "mint-task-directory")
    let historyCwd = try temporaryDirectory(named: "mint-history")
    var (initial, onDisk) = shownTaskOnDisk(directory, elsewhere: historyCwd)
    // A dormant row of another directory is highlighted while the task stays on screen.
    initial.repositories.sessionItems = [dormantRow(piKey("history"), cwd: historyCwd)]
    initial.repositories.sessionSelection = .implicit(piKey("history"))
    let recorded = Recorded()
    let store = mintingStore(initial, recorded: recorded)

    await store.send(.newSession)
    await store.receive(\.launchSessionCompleted)
    await store.finish()

    #expect(launches(recorded).map(\.directory) == [onDisk.id])
  }

  @Test(.dependencies) func newSessionWithNoTaskOnScreenStillFollowsTheSelectedHistoryRow() async throws {
    let directory = try temporaryDirectory(named: "mint-no-task")
    let historyCwd = try temporaryDirectory(named: "mint-history")
    var (initial, _) = shownTaskOnDisk(directory, elsewhere: historyCwd)
    initial.terminals.layouts = []
    initial.terminals.directories = [:]
    initial.terminals.selectedLayoutID = nil
    initial.repositories.selectedTask = nil
    initial.repositories.sessionItems = [dormantRow(piKey("history"), cwd: historyCwd)]
    initial.repositories.sessionSelection = .implicit(piKey("history"))
    let recorded = Recorded()
    let store = mintingStore(initial, recorded: recorded)

    await store.send(.newSession)
    await store.receive(\.launchSessionCompleted)
    await store.finish()

    #expect(launches(recorded).map(\.directory) == [Worktree.ID(historyCwd.path(percentEncoded: false))])
  }

  @Test(.dependencies) func aSecondNewSessionMintsAnotherTaskOnTheSameDirectory() async throws {
    let directory = try temporaryDirectory(named: "mint-twice")
    let (initial, _) = stateOnDisk(directory)
    let recorded = Recorded()
    let store = mintingStore(initial, recorded: recorded)

    await store.send(.newSession)
    await store.receive(\.launchSessionCompleted)
    await store.send(.newSession)
    await store.receive(\.launchSessionCompleted)
    await store.finish()

    #expect(Set(launches(recorded).map(\.layoutID)).count == 2)
  }

  @Test(.dependencies) func aLaunchWhoseTabIsNeverCreatedLeavesNoTask() async throws {
    let directory = try temporaryDirectory(named: "mint-empty")
    let (initial, _) = stateOnDisk(directory)
    let recorded = Recorded()
    let store = mintingStore(initial, recorded: recorded)

    await store.send(.newSession)
    await store.receive(\.launchSessionCompleted)
    await store.finish()
    await store.skipReceivedActions(strict: false)

    // The task exists only through its first tab: nothing is attached, listed, selected or stored for it.
    #expect(store.state.terminals.layouts.isEmpty)
    #expect(store.state.terminals.members.isEmpty)
    #expect(store.state.repositories.selectedTask == nil)
    #expect(!recorded.commands.value.contains { if case .ensureInitialTab = $0 { true } else { false } })
  }

  @Test(.dependencies) func aLaunchedTaskIsShownOnlyOnceItHoldsATab() async {
    var initial = state()
    let minted = LayoutID(task: UUID(7))
    initial.pendingTaskLaunches = [PendingTaskLaunch(layoutID: minted, directoryID: worktree.id)]
    initial.terminals.layouts.append(LayoutFeature.State(id: minted, layout: PaneLayout()))
    initial.terminals.directories[minted] = TaskRecord.Directory(worktreeID: worktree.id)
    let recorded = Recorded()
    let store = taskStore(initial, recorded: recorded)

    await store.send(.terminals(.hibernationPolicyChanged))
    await store.finish()
    #expect(!store.state.pendingTaskLaunches.isEmpty)
    #expect(recorded.selectedLayouts.isEmpty, "an empty task is not selected: that would bootstrap a shell tab")

    let filled = agentTask(minted, surface: thirdSurface).layout
    await store.send(.terminals(.replaceRestoredLayout(worktreeID: minted, layout: filled)))
    await store.receive(\.repositories.selectTask)
    await store.finish()
    await store.skipReceivedActions(strict: false)

    #expect(store.state.pendingTaskLaunches.isEmpty)
    #expect(store.state.repositories.selectedTask?.id == minted)
    #expect(recorded.selectedLayouts == [minted])
    #expect(!recorded.mintedOrResumed)
  }

  @Test(.dependencies) func resumingASessionNoTaskListsMintsATaskWithItAsPrimary() async throws {
    let directory = try temporaryDirectory(named: "mint-resume")
    var (initial, onDisk) = stateOnDisk(directory)
    let key = SessionKey(harness: .pi, sessionID: "history")
    initial.repositories.sessionItems = [dormantRow(key, cwd: directory)]
    let recorded = Recorded()
    let store = mintingStore(initial, recorded: recorded)

    await store.send(.repositories(.activateSession(.implicit(key))))
    await store.receive(\.launchSessionCompleted)
    await store.finish()

    let launch = try #require(launches(recorded).first)
    #expect(launches(recorded).count == 1)
    #expect(launch.layoutID != onDisk.id.layoutID)
    #expect(launch.directory == onDisk.id)
    #expect(launch.input == "pi --session history")
    #expect(
      store.state.pendingTaskLaunches
        == [PendingTaskLaunch(layoutID: launch.layoutID, directoryID: onDisk.id, primary: key)])

    // The task comes into being with its first tab, and lists the session then.
    await store.send(
      .terminals(
        .attachLayout(
          worktreeID: launch.layoutID, directory: TaskRecord.Directory(worktreeID: onDisk.id), titlePrefix: "disk")))
    #expect(store.state.terminals.members.isEmpty)
    let filled = agentTask(launch.layoutID, surface: thirdSurface).layout
    await store.send(.terminals(.replaceRestoredLayout(worktreeID: launch.layoutID, layout: filled)))
    await store.receive(\.terminals.membersChanged)
    await store.finish()
    await store.skipReceivedActions(strict: false)

    #expect(store.state.terminals.members == [launch.layoutID: [.session(key)]])
    #expect(store.state.pendingTaskLaunches.isEmpty)
  }

  @Test(.dependencies) func aResumedSessionLeadsTheMintedTaskEvenWhenItsAgentReportedAnotherFirst() async {
    var initial = state()
    let minted = LayoutID(task: UUID(7))
    let key = piKey("history")
    initial.pendingTaskLaunches = [PendingTaskLaunch(layoutID: minted, directoryID: worktree.id, primary: key)]
    initial.terminals.layouts.append(agentTask(minted, surface: thirdSurface))
    initial.terminals.directories[minted] = TaskRecord.Directory(worktreeID: worktree.id)
    initial.agentPresence.records[.init(agent: .pi, surfaceID: thirdSurface)] = record(ref: "forked")

    let (state, written) = await observingMembers(initial)

    #expect(state.terminals.members[minted] == [.session(key), .session(piKey("forked"))])
    #expect(written == [minted])
  }

  @Test(.dependencies) func aResumeWhoseTabIsNeverCreatedLeavesNoTaskAndNoMember() async throws {
    let directory = try temporaryDirectory(named: "mint-resume-empty")
    var (initial, _) = stateOnDisk(directory)
    let key = piKey("history")
    initial.repositories.sessionItems = [dormantRow(key, cwd: directory)]
    let recorded = Recorded()
    let store = mintingStore(initial, recorded: recorded)

    await store.send(.repositories(.activateSession(.implicit(key))))
    await store.receive(\.launchSessionCompleted)
    await store.finish()
    await store.skipReceivedActions(strict: false)
    #expect(launches(recorded).count == 1)
    #expect(store.state.terminals.layouts.isEmpty)
    #expect(store.state.terminals.members.isEmpty, "no member for a task that does not exist")
    #expect(store.state.repositories.selectedTask == nil)

    // The next launch is the one shown; the failed one's session is listed nowhere.
    await store.send(.newSession)
    await store.receive(\.launchSessionCompleted)
    await store.finish()
    #expect(store.state.pendingTaskLaunches.map(\.isShown) == [false, true])
    #expect(store.state.terminals.members.isEmpty)
  }

  /// A launch is free to start once the previous one's command is sent, which is before its tab exists.
  @Test(.dependencies, arguments: [false, true])
  func twoResumesLaunchedBeforeEitherTabAppearsEachLeadTheirOwnTask(latestTabFirst: Bool) async throws {
    let directory = try temporaryDirectory(named: "mint-two-resumes")
    var (initial, onDisk) = stateOnDisk(directory)
    let keys = [piKey("one"), piKey("two")]
    initial.repositories.sessionItems = [dormantRow(keys[0], cwd: directory), dormantRow(keys[1], cwd: directory)]
    let recorded = Recorded()
    let store = mintingStore(initial, recorded: recorded)

    for key in keys {
      await store.send(.repositories(.activateSession(.implicit(key))))
      await store.receive(\.launchSessionCompleted)
    }
    await store.finish()
    let minted = launches(recorded).map(\.layoutID)
    try #require(minted.count == 2 && minted[0] != minted[1])
    #expect(store.state.terminals.members.isEmpty)

    let surfaces = [thirdSurface, fourthSurface]
    for index in latestTabFirst ? [1, 0] : [0, 1] {
      await store.send(
        .terminals(
          .attachLayout(
            worktreeID: minted[index], directory: TaskRecord.Directory(worktreeID: onDisk.id), titlePrefix: "disk")))
      let filled = agentTask(minted[index], surface: surfaces[index]).layout
      await store.send(.terminals(.replaceRestoredLayout(worktreeID: minted[index], layout: filled)))
      await store.finish()
      await store.skipReceivedActions(strict: false)
    }

    #expect(store.state.terminals.members == [minted[0]: [.session(keys[0])], minted[1]: [.session(keys[1])]])
    #expect(store.state.repositories.selectedTask?.id == minted[1], "the latest launch is the one shown")
    #expect(store.state.pendingTaskLaunches.isEmpty)
  }

  @Test(.dependencies) func newSessionOnARemoteTaskStartsOnItsHostNotInALocalDirectory() async throws {
    let historyCwd = try temporaryDirectory(named: "mint-remote-history")
    var (initial, _) = stateOnDisk(historyCwd)
    let host = try #require(RemoteHost(authority: "me@box"))
    let remoteID: Worktree.ID = "me@box/srv/app"
    initial.terminals.layouts = [agentTask(first, surface: firstSurface)]
    initial.terminals.directories[first] = TaskRecord.Directory(worktreeID: remoteID, host: host)
    initial.terminals.selectedLayoutID = first
    initial.repositories.selectedTask = .init(id: first, directoryID: remoteID)
    // A local directory is highlighted in history and selected in the roster; neither is the task's.
    initial.repositories.sessionItems = [dormantRow(piKey("history"), cwd: historyCwd)]
    initial.repositories.sessionSelection = .implicit(piKey("history"))
    let recorded = Recorded()
    let store = mintingStore(initial, recorded: recorded)

    await store.send(.newSession)
    await store.receive(\.launchSessionCompleted)
    await store.finish()

    let contexts = recorded.commands.value.compactMap { command -> DirectoryContext? in
      guard case .createTabWithInput(_, let context, _, _, _, _, _, _) = command else { return nil }
      return context
    }
    #expect(launches(recorded).map(\.input) == ["pi"])
    #expect(launches(recorded).first?.layoutID != first)
    #expect(contexts.map(\.worktreeID) == [remoteID])
    #expect(contexts.map(\.host) == [host])
    #expect(contexts.map { $0.workingDirectory.path(percentEncoded: false) } == ["/srv/app"])
    #expect(store.state.pendingSessionLaunch == nil)
  }

  @Test(.dependencies) func resumingASessionReusesTheTaskThatListsIt() async throws {
    let directory = try temporaryDirectory(named: "mint-reuse")
    var (initial, onDisk) = stateOnDisk(directory)
    let key = SessionKey(harness: .pi, sessionID: "member")
    initial.repositories.sessionItems = [dormantRow(key, cwd: directory)]
    // Its task kept its record when the last tab closed; nothing is live.
    initial.repositories.$persistedLayouts = SharedReader(
      value: TaskLayoutsFile(tasks: [
        first.persistenceKey: TaskRecord(
          id: first, directory: TaskRecord.Directory(worktreeID: onDisk.id), sessions: [key], createdAt: .distantPast)
      ]))
    let recorded = Recorded()
    let store = mintingStore(initial, recorded: recorded)

    await store.send(.repositories(.activateSession(.implicit(key))))
    await store.receive(\.launchSessionCompleted)
    await store.finish()

    #expect(launches(recorded).map(\.layoutID) == [first])
    #expect(store.state.pendingTaskLaunches == [PendingTaskLaunch(layoutID: first, directoryID: onDisk.id)])
  }

  @Test(.dependencies) func resumingASessionListedByATaskOnAnotherDirectoryMintsATask() async throws {
    let directory = try temporaryDirectory(named: "mint-elsewhere")
    var (initial, onDisk) = stateOnDisk(directory)
    let key = SessionKey(harness: .pi, sessionID: "tangent")
    initial.repositories.sessionItems = [dormantRow(key, cwd: directory)]
    initial.terminals.members[first] = [.session(key)]
    initial.terminals.directories[first] = TaskRecord.Directory(worktreeID: "/somewhere/else")
    let recorded = Recorded()
    let store = mintingStore(initial, recorded: recorded)

    await store.send(.repositories(.activateSession(.implicit(key))))
    await store.receive(\.launchSessionCompleted)
    await store.finish()

    let launch = try #require(launches(recorded).first)
    #expect(launch.layoutID != first, "the other task's tabs start in its own directory")
    #expect(launch.directory == onDisk.id)
    #expect(store.state.terminals.members[first] == [.session(key)], "the other task keeps its member")
  }

  // MARK: - Resume into a task (A23)

  /// `first` closed on `directory` (no tabs), listing `primary` then
  /// `tangent`; the tangent ran in `tangentCwd`.
  private func closedTaskWithATangent(on directory: URL, tangentCwd: URL) -> (AppFeature.State, Worktree) {
    var (state, onDisk) = stateOnDisk(directory)
    state.terminals.layouts = [LayoutFeature.State(id: first, layout: PaneLayout())]
    state.terminals.directories[first] = TaskRecord.Directory(worktreeID: onDisk.id)
    state.terminals.members[first] = [.session(piKey("primary")), .session(piKey("tangent"))]
    state.repositories.sessionSummaries = [("primary", directory), ("tangent", tangentCwd)].map {
      SessionSummary(
        harness: .pi, sessionID: $0.0, createdAt: .distantPast, cwd: $0.1.path(percentEncoded: false),
        title: $0.0, messageCount: 4, lastActivity: .distantPast)
    }
    return (state, onDisk)
  }

  @Test(.dependencies) func aTangentThatRanElsewhereResumesInItsTaskFromItsOwnDirectory() async throws {
    let directory = try temporaryDirectory(named: "tangent-task")
    let elsewhere = try temporaryDirectory(named: "tangent-elsewhere")
    defer { for url in [directory, elsewhere] { try? FileManager.default.removeItem(at: url) } }
    var (initial, onDisk) = closedTaskWithATangent(on: directory, tangentCwd: elsewhere)
    initial.repositories.$sessions.withLock {
      $0[piKey("primary")] = SessionSidecarEntry(settledAt: .distantPast)
      $0[piKey("tangent")] = SessionSidecarEntry(settledAt: .distantPast)
    }
    let recorded = Recorded()
    let store = mintingStore(initial, recorded: recorded)

    await store.send(.repositories(.delegate(.resumeSession(piKey("tangent"), task: first))))
    await store.receive(\.launchSessionCompleted)
    await store.finish()

    #expect(launches(recorded).map(\.layoutID) == [first], "the task that was clicked, not one minted elsewhere")
    #expect(launches(recorded).map(\.directory) == [onDisk.id])
    let quoted = ZmxAttach.shellQuote(elsewhere.path)
    #expect(launches(recorded).map(\.input) == ["cd \(quoted) && pi --session tangent"])
    #expect(store.state.repositories.repositories.count == 1, "its directory is not registered for it")
    // No primary is seeded: the task keeps the one it has.
    #expect(store.state.pendingTaskLaunches == [PendingTaskLaunch(layoutID: first, directoryID: onDisk.id)])
    #expect(store.state.terminals.members[first] == [.session(piKey("primary")), .session(piKey("tangent"))])
    let sidecar = store.state.repositories.sessions
    #expect(sidecar[piKey("tangent")]?.settledAt == nil)
    #expect(sidecar[piKey("primary")]?.settledAt != nil, "a tangent resuming leaves the primary's mark")
  }

  /// The task is only what the store holds: nothing of it is live this run.
  /// Its sessions are read at launch ahead of the layouts, so a resume can
  /// come either side of that read.
  @Test(.dependencies, arguments: [true, false])
  func aTangentOfAStoredOnlyTaskResumesInItAndTheTaskIsShown(sessionsLoadedFirst: Bool) async throws {
    let directory = try temporaryDirectory(named: "tangent-stored")
    let elsewhere = try temporaryDirectory(named: "tangent-stored-elsewhere")
    defer { for url in [directory, elsewhere] { try? FileManager.default.removeItem(at: url) } }
    var (initial, onDisk) = stateOnDisk(directory)
    let members = [piKey("primary"), piKey("tangent")]
    let stored = TaskLayoutsFile(tasks: [
      first.persistenceKey: TaskRecord(
        id: first, directory: TaskRecord.Directory(worktreeID: onDisk.id), sessions: members, createdAt: .distantPast)
    ])
    initial.repositories.$persistedLayouts = SharedReader(value: stored)
    initial.repositories.sessionSummaries = [("primary", directory), ("tangent", elsewhere)].map {
      SessionSummary(
        harness: .pi, sessionID: $0.0, createdAt: .distantPast, cwd: $0.1.path(percentEncoded: false),
        title: $0.0, messageCount: 4, lastActivity: .distantPast)
    }
    initial.repositories.$sessions.withLock {
      for key in members { $0[key] = SessionSidecarEntry(settledAt: .distantPast) }
    }
    // The resumed agent's report, counted once its surface is in a task.
    initial.agentPresence.records[.init(agent: .pi, surfaceID: thirdSurface)] = record(ref: "tangent")
    let recorded = Recorded()
    let store = mintingStore(initial, recorded: recorded)
    if sessionsLoadedFirst { await store.send(.terminals(.storedSessionsLoaded(stored))) }
    #expect(store.state.terminals.layouts.isEmpty && store.state.terminals.directories.isEmpty)
    let roster = store.state.repositories.repositories

    await store.send(.repositories(.delegate(.resumeSession(piKey("tangent"), task: first))))
    await store.receive(\.launchSessionCompleted)
    await store.finish()

    #expect(launches(recorded).map(\.layoutID) == [first], "the stored task, not one minted for the session")
    #expect(launches(recorded).map(\.directory) == [onDisk.id])
    #expect(launches(recorded).map(\.input) == ["cd \(ZmxAttach.shellQuote(elsewhere.path)) && pi --session tangent"])
    #expect(store.state.pendingTaskLaunches == [PendingTaskLaunch(layoutID: first, directoryID: onDisk.id)])
    #expect(store.state.repositories.repositories == roster, "no folder is registered for the session")
    #expect(store.state.repositories.selectedTask == nil, "not shown before it holds a tab")

    await store.send(
      .terminals(
        .attachLayout(worktreeID: first, directory: TaskRecord.Directory(worktreeID: onDisk.id), titlePrefix: "disk")))
    let filled = agentTask(first, surface: thirdSurface).layout
    await store.send(.terminals(.replaceRestoredLayout(worktreeID: first, layout: filled)))
    await store.receive(\.repositories.selectTask)
    await store.finish()
    await store.skipReceivedActions(strict: false)
    if !sessionsLoadedFirst {
      await store.send(.terminals(.storedSessionsLoaded(stored)))
      await store.finish()
      await store.skipReceivedActions(strict: false)
    }

    #expect(store.state.repositories.selectedTask?.id == first)
    #expect(store.state.pendingTaskLaunches.isEmpty)
    #expect(store.state.terminals.members[first] == members.map(TaskMember.session))
    #expect(AppFeature.primarySession(of: first, state: store.state) == piKey("primary"))
    #expect(launches(recorded).count == 1, "the primary is not launched")
    let sidecar = store.state.repositories.sessions
    #expect(sidecar[piKey("tangent")]?.settledAt == nil)
    #expect(sidecar[piKey("primary")]?.settledAt != nil, "a tangent resuming leaves the primary's mark")
  }

  @Test(.dependencies) func aTangentInItsTasksDirectoryIsResumedWithTheBareCommand() async throws {
    let directory = try temporaryDirectory(named: "tangent-home")
    defer { try? FileManager.default.removeItem(at: directory) }
    let (initial, _) = closedTaskWithATangent(on: directory, tangentCwd: directory)
    let recorded = Recorded()
    let store = mintingStore(initial, recorded: recorded)

    await store.send(.repositories(.delegate(.resumeSession(piKey("tangent"), task: first))))
    await store.receive(\.launchSessionCompleted)
    await store.finish()

    #expect(launches(recorded).map(\.layoutID) == [first])
    #expect(launches(recorded).map(\.input) == ["pi --session tangent"])
  }

  @Test(.dependencies) func theResumeDirectoryIsQuoted() async throws {
    let directory = try temporaryDirectory(named: "tangent-quote")
    let elsewhere = directory.appendingPathComponent("it's here", isDirectory: true).standardizedFileURL
    try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let (initial, _) = closedTaskWithATangent(on: directory, tangentCwd: elsewhere)
    let recorded = Recorded()
    let store = mintingStore(initial, recorded: recorded)

    await store.send(.repositories(.delegate(.resumeSession(piKey("tangent"), task: first))))
    await store.receive(\.launchSessionCompleted)
    await store.finish()

    let input = try #require(launches(recorded).first?.input)
    #expect(input.hasPrefix("cd '") && input.hasSuffix("/it'\\''s here' && pi --session tangent"))
  }

  @Test(.dependencies) func aResumedTangentDoesNotChangeTheMemberOrder() async {
    // The state once the resumed tangent reports on its new tab.
    var initial = state()
    initial.terminals.layouts.append(agentTask(first, surface: firstSurface))
    initial.terminals.directories = [
      worktree.id.layoutID: TaskRecord.Directory(worktreeID: worktree.id),
      first: TaskRecord.Directory(worktreeID: worktree.id),
    ]
    initial.terminals.members[first] = [.session(piKey("primary")), .session(piKey("tangent"))]
    initial.agentPresence.records[.init(agent: .pi, surfaceID: firstSurface)] = record(ref: "tangent")

    let (state, _) = await observingMembers(initial)

    #expect(state.terminals.members[first] == [.session(piKey("primary")), .session(piKey("tangent"))])
    #expect(AppFeature.primarySession(of: first, state: state) == piKey("primary"))
  }

  @Test(.dependencies) func aTaskRemovedWhileTheProbeRunsIsNotLaunchedInto() async throws {
    let directory = try temporaryDirectory(named: "tangent-removed")
    defer { try? FileManager.default.removeItem(at: directory) }
    let (initial, onDisk) = closedTaskWithATangent(on: directory, tangentCwd: directory)
    let recorded = Recorded()
    let store = mintingStore(initial, recorded: recorded)
    let branches = AsyncStream<String>.makeStream()
    store.dependencies[GitClientDependency.self].branchName = { _ in
      for await branch in branches.stream { return branch }
      return nil
    }

    await store.send(.repositories(.delegate(.resumeSession(piKey("tangent"), task: first))))
    #expect(store.state.pendingSessionLaunch?.probing == true)
    await store.send(.terminals(.detachLayout(worktreeID: first)))
    branches.continuation.yield("main")
    await store.receive(\.launchSessionCompleted)
    await store.finish()

    #expect(launches(recorded).count == 1)
    #expect(launches(recorded).first?.layoutID != first, "a tab on a removed task's id would bring it back")
    #expect(launches(recorded).first?.directory == onDisk.id)
    #expect(!AppFeature.hasTask(first, state: store.state))
  }

  @Test(.dependencies) func aBranchMismatchConfirmedStillResumesInTheClickedTask() async throws {
    let directory = try temporaryDirectory(named: "tangent-mismatch")
    let elsewhere = try temporaryDirectory(named: "tangent-mismatch-elsewhere")
    defer { for url in [directory, elsewhere] { try? FileManager.default.removeItem(at: url) } }
    var (initial, _) = closedTaskWithATangent(on: directory, tangentCwd: elsewhere)
    initial.repositories.$sessions.withLock { $0[piKey("tangent")] = SessionSidecarEntry(branches: ["feature"]) }
    let recorded = Recorded()
    let store = mintingStore(initial, recorded: recorded)
    store.dependencies[GitClientDependency.self].branchName = { _ in "main" }

    await store.send(.repositories(.delegate(.resumeSession(piKey("tangent"), task: first))))
    await store.receive(\.resumeBranchProbeCompleted)
    #expect(store.state.pendingBranchMismatchResume != nil)
    #expect(launches(recorded).isEmpty)
    await store.send(.alert(.presented(.confirmBranchMismatchResume)))
    await store.receive(\.launchSessionCompleted)
    await store.finish()

    #expect(launches(recorded).map(\.layoutID) == [first])
    #expect(launches(recorded).first?.input.hasPrefix("cd ") == true)
  }

  @Test(.dependencies) func aSessionThatWentLiveInTheTargetTaskIsFocusedNotRelaunched() async throws {
    let directory = try temporaryDirectory(named: "tangent-live")
    defer { try? FileManager.default.removeItem(at: directory) }
    var (initial, onDisk) = closedTaskWithATangent(on: directory, tangentCwd: directory)
    initial.terminals.layouts.append(LayoutFeature.State(id: second, layout: PaneLayout()))
    initial.terminals.directories[second] = TaskRecord.Directory(worktreeID: onDisk.id)
    initial.terminals.members[second] = [.session(piKey("tangent"))]
    let recorded = Recorded()
    let store = mintingStore(initial, recorded: recorded)
    store.dependencies.terminalClient.focusSurface = { layoutID, context, tab, surface in
      recorded.focused.withValue {
        $0.append(SessionLocation(layoutID: layoutID, directoryID: context.worktreeID, tabID: tab, surfaceID: surface))
      }
    }
    let branches = AsyncStream<String>.makeStream()
    store.dependencies[GitClientDependency.self].branchName = { _ in
      for await branch in branches.stream { return branch }
      return nil
    }
    func running(in task: LayoutID, on surface: UUID) -> SessionLiveSnapshot {
      SessionLiveSnapshot(
        harness: .pi, sessionRef: "tangent", cwd: directory.path(percentEncoded: false),
        location: SessionLocation(
          layoutID: task, directoryID: onDisk.id, tabID: TabID(rawValue: surface), surfaceID: surface))
    }

    await store.send(.repositories(.delegate(.resumeSession(piKey("tangent"), task: second))))
    // It starts in both tasks while the probe runs.
    await store.send(
      .repositories(
        .sessionSnapshotsChanged([running(in: first, on: firstSurface), running(in: second, on: secondSurface)])))
    branches.continuation.yield("main")
    await store.receive(\.resumeBranchProbeCompleted)
    await store.finish()
    await store.skipReceivedActions(strict: false)

    #expect(launches(recorded).isEmpty)
    #expect(recorded.focused.value.map(\.layoutID) == [second], "the surface of the task that was clicked")
    #expect(store.state.pendingSessionLaunch == nil)
  }

  @Test(.dependencies) func anOrphanTasksTangentResumesInIt() async throws {
    let cwd = try temporaryDirectory(named: "tangent-orphan")
    defer { try? FileManager.default.removeItem(at: cwd) }
    var initial = orphanTask(TaskRecord.Directory(worktreeID: "/gone/checkout"), isLive: true)
    initial.terminals.members[first] = [.session(piKey("primary")), .session(piKey("tangent"))]
    initial.repositories.sessionSummaries = [
      SessionSummary(
        harness: .pi, sessionID: "tangent", createdAt: .distantPast, cwd: cwd.path(percentEncoded: false),
        title: "tangent", messageCount: 4, lastActivity: .distantPast)
    ]
    let roster = initial.repositories.repositories
    let recorded = Recorded()
    let store = mintingStore(initial, recorded: recorded)

    await store.send(.repositories(.delegate(.resumeSession(piKey("tangent"), task: first))))
    await store.receive(\.launchSessionCompleted)
    await store.finish()

    #expect(launches(recorded).map(\.layoutID) == [first])
    #expect(launches(recorded).map(\.directory) == ["/gone/checkout"])
    #expect(launches(recorded).first?.input.hasPrefix("cd ") == true)
    #expect(store.state.repositories.repositories == roster, "no folder is registered for the session")
  }

  @Test(.dependencies) func aRemovedTaskIsGoneEvenThoughTheLaunchTimeFileStillListsIt() async {
    var initial = twoTasksOnOneDirectory()
    // `first` was restored from the file, which is read once and never again.
    initial.repositories.$persistedLayouts = SharedReader(
      value: TaskLayoutsFile(tasks: [
        first.persistenceKey: TaskRecord(
          id: first, directory: TaskRecord.Directory(worktreeID: worktree.id),
          layout: agentTask(first, surface: firstSurface).layout, sessions: [piKey("one")], createdAt: .distantPast)
      ]))
    initial.repositories.selectedTask = .init(id: first, directoryID: worktree.id)
    initial.agentPresence.records = [:]
    let recorded = Recorded()
    let store = taskStore(initial, recorded: recorded)

    await store.send(.terminals(.detachLayout(worktreeID: first)))
    await store.receive(\.repositories.selectedTaskRemoved)
    await store.finish()
    await store.skipReceivedActions(strict: false)

    #expect(store.state.repositories.selectedTask == nil)
    #expect(!AppFeature.hasTask(first, state: store.state))
    #expect(!AppFeature.taskEntries(state: store.state).contains { $0.layoutID == first })
    #expect(!store.state.repositories.sessionItems.contains { $0.location?.layoutID == first })
    #expect(AppFeature.task(listing: piKey("one"), onDirectory: worktree.id, state: store.state) == nil)
    #expect(!recorded.mintedOrResumed)

    // The same id attached again is a task again.
    await store.send(
      .terminals(
        .attachLayout(worktreeID: first, directory: TaskRecord.Directory(worktreeID: worktree.id), titlePrefix: "w")))
    #expect(AppFeature.hasTask(first, state: store.state))
  }

  private func piKey(_ ref: String) -> SessionKey { SessionKey(harness: .pi, sessionID: ref) }

  /// One task holding two agent tabs, beside the fixture's own-key layout.
  private func oneTaskWithTwoAgents(firstRef: String?, secondRef: String?) -> AppFeature.State {
    var state = state()
    var task = agentTask(first, surface: firstSurface)
    let extra = agentTask(first, surface: secondSurface).layout.panes[0].tabs[0]
    task.layout.panes[0].tabs.append(extra)
    state.terminals.layouts.append(task)
    state.terminals.directories = [
      worktree.id.layoutID: TaskRecord.Directory(worktreeID: worktree.id),
      first: TaskRecord.Directory(worktreeID: worktree.id),
    ]
    state.agentPresence.records[.init(agent: .pi, surfaceID: firstSurface)] = record(ref: firstRef)
    state.agentPresence.records[.init(agent: .pi, surfaceID: secondSurface)] = record(ref: secondRef)
    return state
  }

  private func observingMembers(_ initial: AppFeature.State) async -> (AppFeature.State, [LayoutID]) {
    let written = LockIsolated<[LayoutID]>([])
    let store = TestStore(initialState: initial) {
      AppFeature()
    } withDependencies: {
      $0.date.now = .distantPast
      $0.continuousClock = ImmediateClock()
      $0.terminalClient.send = { _ in }
      $0.worktreeInfoWatcher.send = { _ in }
      $0[LayoutChangeObserver.self].sessionsChanged = { id in written.withValue { $0.append(id) } }
      $0.terminalClient.saveLayoutsWithAgents = { _ in }
    }
    store.exhaustivity = .off
    await store.send(.agentPresence(.delegate(.surfacesChanged([]))))
    await store.finish()
    await store.skipReceivedActions(strict: false)
    return (store.state, written.value)
  }

  @Test(.dependencies) func agentsStartingInATaskJoinItAndTheFirstIsPrimary() async {
    let (state, written) = await observingMembers(twoTasksOnOneDirectory())

    #expect(state.terminals.members == [first: [.session(piKey("one"))], second: [.session(piKey("two"))]])
    #expect(written == [first, second], "each task's stored sessions are written once")
  }

  @Test(.dependencies) func theFirstAgentInAShellOnlyTaskBecomesItsPrimaryOnTheSameRow() async throws {
    let agent = AgentPresenceFeature.PresenceKey(agent: .pi, surfaceID: secondSurface)
    var initial = twoTasksOnOneDirectory()
    initial.agentPresence.records[agent] = nil
    initial.terminals.selectedLayoutID = second
    initial.repositories.selectedTask = .init(id: second, directoryID: worktree.id)
    initial = withRows(initial)
    initial.repositories.selectSessionRow(.task(second))

    func expectSameRowSelected(_ state: AppFeature.State, _ step: String) {
      #expect(state.repositories.sessionSelection == .task(second), "\(step)")
      #expect(state.repositories.selectedTaskID == second, "\(step)")
      let rows = state.repositories.sessionItems.filter { $0.location?.layoutID == second }
      #expect(rows.map(\.id) == [.task(second)], "\(step): one row for the task, none for its agent")
    }

    let shellOnly = initial.repositories.sessionItems[id: .task(second)]
    #expect(shellOnly?.title == worktree.workingDirectory.lastPathComponent)
    #expect(shellOnly?.primary == nil)
    #expect(AppFeature.primarySession(of: second, state: initial) == nil)
    expectSameRowSelected(initial, "shell-only")

    // An agent starts in the task's tab and has not said which session it is.
    initial.agentPresence.records[agent] = record(ref: nil)
    let (unreported, writtenUnreported) = await observingMembers(initial)
    #expect(unreported.terminals.members[second] == [.provisional(harness: .pi, surfaceID: secondSurface)])
    #expect(!writtenUnreported.contains(second), "an unreported agent is never stored")
    #expect(unreported.repositories.sessionItems[id: .task(second)]?.title == "New session")
    #expect(unreported.repositories.sessionItems[id: .task(second)]?.primary == nil)
    expectSameRowSelected(unreported, "unreported")

    var reporting = unreported
    reporting.agentPresence.records[agent] = record(ref: "two")
    let (reported, writtenReported) = await observingMembers(reporting)
    #expect(reported.terminals.members[second] == [.session(piKey("two"))])
    #expect(writtenReported == [second], "the task's first session is stored once")
    #expect(reported.repositories.sessionItems[id: .task(second)]?.primary == piKey("two"))
    #expect(AppFeature.primarySession(of: second, state: reported) == piKey("two"))
    #expect(reported.repositories.taskSessions[second] == [piKey("two")])
    expectSameRowSelected(reported, "reported")

    var indexed = reported
    indexed.repositories.sessionSummaries = [
      SessionSummary(
        harness: .pi, sessionID: "two", createdAt: Date(timeIntervalSince1970: 900), cwd: "/workspace",
        title: "Fix the build", messageCount: 3, lastActivity: Date(timeIntervalSince1970: 900))
    ]
    indexed = withRows(indexed)
    #expect(indexed.repositories.sessionItems[id: .task(second)]?.title == "Fix the build")
    expectSameRowSelected(indexed, "indexed")

    // The other task on the directory never noticed.
    #expect(indexed.terminals.members[first] == [.session(piKey("one"))])
    #expect(indexed.repositories.sessionItems[id: .task(first)]?.primary == piKey("one"))

    // The new primary survives the stored form and a relaunch.
    let stored = TaskLayoutsFile(tasks: [
      second.persistenceKey: TaskRecord(
        id: second, directory: TaskRecord.Directory(worktreeID: worktree.id),
        layout: try #require(indexed.terminals.layouts[id: second]).layout,
        sessions: (indexed.terminals.members[second] ?? []).compactMap(\.sessionKey), createdAt: .distantPast)
    ])
    let decoded = try JSONDecoder().decode(TaskLayoutsFile.self, from: JSONEncoder().encode(stored))
    #expect(decoded.undecodedEntryCount == 0)
    let relaunched = TestStore(initialState: TerminalsFeature.State()) { TerminalsFeature() }
    relaunched.exhaustivity = .off
    await relaunched.send(.layoutsHydrated(decoded))
    #expect(relaunched.state.members == [second: [.session(piKey("two"))]])
  }

  @Test(.dependencies) func twoAgentsInOneTaskAreBothMembersOfOneRow() async throws {
    let (state, _) = await observingMembers(oneTaskWithTwoAgents(firstRef: "one", secondRef: "two"))

    #expect(state.terminals.members == [first: [.session(piKey("one")), .session(piKey("two"))]])
    let rows = state.repositories.sessionItems.filter { $0.location?.layoutID == first }
    #expect(rows.map(\.id) == [.task(first)])
    #expect(rows.first?.primary == piKey("one"))
    // Both stay visible: as the sub-rows of their task, once it is selected.
    var selected = state.repositories
    selected.selectSessionRow(.task(first))
    #expect(selected.sessionsSidebarStructure.subRows.map(\.id) == [.session(piKey("one")), .session(piKey("two"))])

    // Membership survives the stored form and a relaunch.
    let stored = TaskLayoutsFile(tasks: [
      first.persistenceKey: TaskRecord(
        id: first, directory: TaskRecord.Directory(worktreeID: worktree.id),
        layout: try #require(state.terminals.layouts[id: first]).layout,
        sessions: (state.terminals.members[first] ?? []).compactMap(\.sessionKey), createdAt: .distantPast)
    ])
    let decoded = try JSONDecoder().decode(TaskLayoutsFile.self, from: JSONEncoder().encode(stored))
    #expect(decoded.undecodedEntryCount == 0)
    #expect(decoded.tasks[first.persistenceKey]?.sessions == [piKey("one"), piKey("two")])
    let relaunched = TestStore(initialState: TerminalsFeature.State()) { TerminalsFeature() }
    relaunched.exhaustivity = .off
    await relaunched.send(.layoutsHydrated(decoded))
    #expect(relaunched.state.members == [first: [.session(piKey("one")), .session(piKey("two"))]])
  }

  @Test(.dependencies) func nextSessionNeedsMeOnATaskRowFocusesTheAgentThatNeedsYou() async {
    var initial = oneTaskWithTwoAgents(firstRef: "one", secondRef: "two")
    initial.agentPresence.records[.init(agent: .pi, surfaceID: secondSurface)]?.activity = .awaitingInput
    initial = withRows(initial)
    #expect(initial.repositories.sessionItems[id: .task(first)]?.status == .needsYou)
    let recorded = Recorded()
    let store = taskStore(initial, recorded: recorded)

    await store.send(.nextSessionNeedsMe)
    await store.finish()
    await store.skipReceivedActions(strict: false)

    #expect(store.state.repositories.sessionSelection == .task(first))
    #expect(
      recorded.focused.value == [
        SessionLocation(
          layoutID: first, directoryID: worktree.id, tabID: TabID(rawValue: secondSurface), surfaceID: secondSurface)
      ], "the tangent's own surface, not whatever the task had focused")
    #expect(!recorded.mintedOrResumed)
  }

  private func location(_ task: LayoutID, _ surface: UUID) -> SessionLocation {
    SessionLocation(layoutID: task, directoryID: worktree.id, tabID: TabID(rawValue: surface), surfaceID: surface)
  }

  private func focusing(_ surface: UUID, of task: LayoutID, in state: AppFeature.State) -> AppFeature.State {
    var state = state
    state.terminals.selectedLayoutID = task
    let paneID = state.terminals.layouts[id: task]?.layout.panes[0].id
    state.terminals.layouts[id: task]?.layout.focusedPaneID = paneID
    state.terminals.layouts[id: task]?.layout.panes[0].selectedTabID = TabID(rawValue: surface)
    return state
  }

  /// The first task is on screen; the second, not shown, has a working
  /// primary and a tangent that finished unseen, which its row does not show.
  private func twoTasksWithATangentInTheSecond() -> AppFeature.State {
    var state = twoTasksOnOneDirectory()
    let extra = agentTask(second, surface: thirdSurface).layout.panes[0].tabs[0]
    state.terminals.layouts[id: second]?.layout.panes[0].tabs.append(extra)
    state.agentPresence.records[.init(agent: .pi, surfaceID: secondSurface)]?.activity = .busy
    state.agentPresence.records[.init(agent: .pi, surfaceID: thirdSurface)] = record(ref: "three")
    state.agentPresence.records[.init(agent: .pi, surfaceID: thirdSurface)]?.isDoneUnseen = true
    state.repositories.$persistedLayouts = SharedReader(value: TaskLayoutsFile())
    return withRows(focusing(firstSurface, of: first, in: state))
  }

  @Test(.dependencies) func nextSessionNeedsMeReachesATangentInATaskThatIsNotShown() async {
    let initial = twoTasksWithATangentInTheSecond()
    #expect(AppFeature.focusedSurfaceID(state: initial) == firstSurface)
    #expect(initial.repositories.sessionItems[id: .task(second)]?.status == .working)
    let recorded = Recorded()
    let store = taskStore(initial, recorded: recorded)

    await store.send(.nextSessionNeedsMe)
    await store.finish()
    await store.skipReceivedActions(strict: false)

    #expect(store.state.repositories.sessionSelection == .task(second))
    #expect(recorded.focused.value == [location(second, thirdSurface)])
    #expect(store.state.repositories.selectedTask?.id == second)
    #expect(!recorded.mintedOrResumed)
    #expect(recorded.resumes.value == 0)
    #expect(recorded.nonFocusCommands.isEmpty, "\(recorded.nonFocusCommands)")
  }

  @Test(.dependencies) func nextSessionNeedsMeStepsToTheNextAgentOfTheFocusedTask() async {
    for (focused, expected) in [(firstSurface, secondSurface), (secondSurface, firstSurface)] {
      var initial = oneTaskWithTwoAgents(firstRef: "one", secondRef: "two")
      initial.agentPresence.records[.init(agent: .pi, surfaceID: firstSurface)]?.activity = .awaitingInput
      initial.agentPresence.records[.init(agent: .pi, surfaceID: secondSurface)]?.activity = .awaitingInput
      initial = withRows(focusing(focused, of: first, in: initial))
      #expect(AppFeature.focusedSurfaceID(state: initial) == focused)
      let recorded = Recorded()
      let store = taskStore(initial, recorded: recorded)

      await store.send(.nextSessionNeedsMe)
      await store.finish()
      await store.skipReceivedActions(strict: false)

      #expect(recorded.focused.value == [location(first, expected)])
      #expect(!recorded.mintedOrResumed)
    }
  }

  @Test(.dependencies) func nextSessionNeedsMePressedTwiceBeforeFocusLandsTargetsTheSameSurface() async {
    let recorded = Recorded()
    let store = taskStore(twoTasksWithATangentInTheSecond(), recorded: recorded)

    for _ in 0..<2 {
      await store.send(.nextSessionNeedsMe)
      await store.finish()
      await store.skipReceivedActions(strict: false)
    }

    #expect(AppFeature.focusedSurfaceID(state: store.state) == firstSurface, "the terminal has not moved")
    #expect(recorded.focused.value == [location(second, thirdSurface), location(second, thirdSurface)])
    #expect(!recorded.mintedOrResumed)
    #expect(recorded.resumes.value == 0)
  }

  @Test(.dependencies) func nextSessionNeedsMeIgnoresATargetWhoseTaskIsGone() async {
    var initial = twoTasksWithATangentInTheSecond()
    initial.terminals.layouts.remove(id: second)
    let selection = initial.repositories.sessionSelection
    let selectedTask = initial.repositories.selectedTask
    let recorded = Recorded()
    let store = taskStore(initial, recorded: recorded)

    await store.send(.nextSessionNeedsMe)
    await store.finish()
    await store.skipReceivedActions(strict: false)

    #expect(recorded.focused.value.isEmpty)
    #expect(recorded.commands.value.isEmpty)
    #expect(store.state.repositories.sessionSelection == selection)
    #expect(store.state.repositories.selectedTask == selectedTask)
  }

  @Test(.dependencies) func anAgentAlreadyListedWritesNothing() async {
    var initial = twoTasksOnOneDirectory()
    initial.terminals.members = [first: [.session(piKey("one"))], second: [.session(piKey("two"))]]

    let (state, written) = await observingMembers(initial)

    #expect(state.terminals.members == initial.terminals.members)
    #expect(written.isEmpty)
  }

  @Test(.dependencies) func provisionalMemberUpgradesInPlaceWhenItsSessionArrives() async {
    // The second surface's agent started first and has not reported; the first surface's has.
    var initial = oneTaskWithTwoAgents(firstRef: "one", secondRef: nil)
    initial.terminals.members[first] = [.provisional(harness: .pi, surfaceID: secondSurface)]
    let (waiting, writtenWhileWaiting) = await observingMembers(initial)
    #expect(
      waiting.terminals.members[first] == [
        .provisional(harness: .pi, surfaceID: secondSurface), .session(piKey("one")),
      ])
    #expect(writtenWhileWaiting == [first])

    var arrived = waiting
    arrived.agentPresence.records[.init(agent: .pi, surfaceID: secondSurface)] = record(ref: "two")
    let (state, _) = await observingMembers(arrived)

    #expect(state.terminals.members[first] == [.session(piKey("two")), .session(piKey("one"))])
    let rows = state.repositories.sessionItems.filter { $0.location?.layoutID == first }
    #expect(rows.map(\.id) == [.task(first)], "one row for the task")
    var selected = state.repositories
    selected.selectSessionRow(.task(first))
    #expect(
      selected.sessionsSidebarStructure.subRows.map(\.id) == [.session(piKey("two")), .session(piKey("one"))],
      "no second sub-row for the upgraded member")
  }

  @Test(.dependencies) func aProvisionalMemberWhoseAgentLeftIsDroppedAndASessionIsKept() async {
    var initial = oneTaskWithTwoAgents(firstRef: "one", secondRef: nil)
    initial.terminals.members[first] = [
      .session(piKey("one")), .provisional(harness: .pi, surfaceID: secondSurface),
    ]
    initial.agentPresence.records = [:]

    let (state, written) = await observingMembers(initial)

    #expect(state.terminals.members[first] == [.session(piKey("one"))])
    #expect(written.isEmpty, "a provisional member is never stored")
  }

  @Test(.dependencies) func aRosterReloadKeepsTheSelectedTaskBeforeTheTerminalEchoesIt() async {
    var initial = twoTasksOnOneDirectory()
    // `second` was just selected; the directory's active task still says `first`.
    initial.repositories.selectedTask = .init(id: second, directoryID: worktree.id)
    let recorded = Recorded()
    let store = taskStore(initial, recorded: recorded)

    await store.send(.repositories(.delegate(.selectedWorktreeChanged(worktree, layoutID: nil))))
    await store.finish()

    #expect(recorded.selectedLayouts == [second])
  }

  // MARK: - A directory row shows its most recent task

  /// The fixture directory with only minted tasks on it: no own-key layout and
  /// no recorded active task, as after the active one was removed.
  private func mintedTasksOnly(_ ids: [(LayoutID, UUID)]) -> AppFeature.State {
    var state = state()
    state.terminals.layouts = []
    for (id, surface) in ids {
      state.terminals.layouts.append(agentTask(id, surface: surface))
      state.terminals.directories[id] = TaskRecord.Directory(worktreeID: worktree.id)
    }
    state.terminals.selectedLayoutID = nil
    return state
  }

  private func isBootstrap(_ command: TerminalClient.Command) -> Bool {
    if case .ensureInitialTab = command { return true }
    return false
  }

  @Test(.dependencies) func selectingADirectoryWithNoTaskMintsNothing() async {
    let initial = mintedTasksOnly([])
    #expect(initial.terminals.task(forDirectory: worktree.id) == nil)
    let recorded = Recorded()
    let store = taskStore(initial, recorded: recorded)

    await store.send(.repositories(.delegate(.selectedWorktreeChanged(worktree))))
    await store.finish()

    #expect(!recorded.mintedOrResumed)
    #expect(!recorded.commands.value.contains(where: isBootstrap), "no shell tab is bootstrapped by a selection")
    #expect(recorded.selectedLayouts == [worktree.id.layoutID], "where the directory's first tab would land")
    #expect(recorded.watcher.value == [.setSelectedWorktreeID(worktree.id)])
    #expect(store.state.terminals.layouts.isEmpty)
    #expect(store.state.repositories.selectedWorktreeID == worktree.id)
  }

  @Test(.dependencies) func selectingADirectoryWithOneTaskShowsItEvenWithNoRecordedActiveTask() async {
    let initial = mintedTasksOnly([(first, firstSurface)])
    let recorded = Recorded()
    let store = taskStore(initial, recorded: recorded)

    await store.send(.repositories(.delegate(.selectedWorktreeChanged(worktree))))
    await store.finish()

    #expect(recorded.selectedLayouts == [first], "not the own-key layout, which does not exist")
    #expect(
      recorded.commands.value.filter(isBootstrap) == [
        .ensureInitialTab(first, DirectoryContext(worktree: worktree), runSetupScriptIfNew: false, focusing: false)
      ])
    #expect(!recorded.mintedOrResumed)
    #expect(store.state.repositories.selectedWorktreeID == worktree.id)
  }

  @Test(.dependencies) func selectingADirectoryWithTwoTasksShowsTheMostRecentOne() async {
    var initial = mintedTasksOnly([(first, firstSurface), (second, secondSurface)])
    #expect(initial.terminals.task(forDirectory: worktree.id) == first, "never selected: the first by key")

    initial.terminals.selectionOrder = [first, second]
    #expect(initial.terminals.task(forDirectory: worktree.id) == second, "the one selected last this run")

    initial.terminals.activeTasks[worktree.id] = first
    #expect(initial.terminals.task(forDirectory: worktree.id) == first, "the recorded one while it is a task here")

    let recorded = Recorded()
    let store = taskStore(initial, recorded: recorded)
    await store.send(.repositories(.delegate(.selectedWorktreeChanged(worktree))))
    await store.finish()

    #expect(recorded.selectedLayouts == [first])
    #expect(!recorded.mintedOrResumed)
  }

  @Test(.dependencies) func removingTheActiveTaskLeavesTheDirectoryOnItsOtherTask() async {
    var initial = mintedTasksOnly([(first, firstSurface), (second, secondSurface), (third, thirdSurface)])
    initial.terminals.selectionOrder = [third, second, first]
    initial.terminals.activeTasks[worktree.id] = first
    let store = taskStore(initial, recorded: Recorded())

    await store.send(.terminals(.detachLayout(worktreeID: first)))
    await store.finish()

    #expect(store.state.terminals.activeTasks[worktree.id] == nil)
    #expect(store.state.terminals.task(forDirectory: worktree.id) == second)
    #expect(store.state.layoutID(forDirectory: worktree.id) == second, "commands follow the task the row shows")
  }

  /// A populated layout under the directory's own key beside minted tasks.
  private func ownKeyTaskBeside(_ ids: [(LayoutID, UUID)]) -> AppFeature.State {
    mintedTasksOnly([(worktree.id.layoutID, surface)] + ids)
  }

  @Test(.dependencies) func removingTheActiveTaskPrefersTheLastSelectedTaskOverTheOwnKeyOne() async {
    let ownKey = worktree.id.layoutID
    // The own-key task, then `first`, then `second` were selected, as the
    // terminal records it: an own-key selection clears the directory's entry.
    var initial = ownKeyTaskBeside([(first, firstSurface), (second, secondSurface)])
    initial.terminals.selectionOrder = [ownKey, first, second]
    initial.terminals.activeTasks[worktree.id] = second
    let store = taskStore(initial, recorded: Recorded())

    await store.send(.terminals(.detachLayout(worktreeID: second)))
    await store.finish()

    #expect(store.state.terminals.activeTasks[worktree.id] == nil)
    #expect(store.state.terminals.task(forDirectory: worktree.id) == first, "selected after the own-key task")
    #expect(store.state.layoutID(forDirectory: worktree.id) == first)

    // The own-key task is the answer when it was selected last, or when
    // nothing on the directory was selected this run.
    var ownKeyLast = store.state.terminals
    ownKeyLast.selectionOrder = [first, ownKey]
    #expect(ownKeyLast.task(forDirectory: worktree.id) == ownKey)
    ownKeyLast.selectionOrder = []
    #expect(ownKeyLast.task(forDirectory: worktree.id) == ownKey)
    // One no record names yet is still the directory's own.
    ownKeyLast.directories[ownKey] = nil
    ownKeyLast.selectionOrder = [first, ownKey]
    #expect(ownKeyLast.task(forDirectory: worktree.id) == ownKey)
  }

  /// `first` lists a session and is the selected task, but its last tab closed.
  private func selectedTaskWithNoTab(sibling: Bool) -> AppFeature.State {
    var state = mintedTasksOnly(sibling ? [(second, secondSurface)] : [])
    state.terminals.layouts.append(LayoutFeature.State(id: first, layout: PaneLayout()))
    state.terminals.directories[first] = TaskRecord.Directory(worktreeID: worktree.id)
    state.terminals.members[first] = [.session(piKey("closed"))]
    state.terminals.activeTasks[worktree.id] = first
    state.terminals.selectionOrder = sibling ? [second, first] : [first]
    state.repositories.selectedTask = .init(id: first, directoryID: worktree.id)
    return state
  }

  @Test(.dependencies, arguments: [true, false])
  func selectingTheDirectoryOfASelectedTaskWithNoTabBootstrapsNothingInIt(sibling: Bool) async {
    let recorded = Recorded()
    let store = taskStore(selectedTaskWithNoTab(sibling: sibling), recorded: recorded)

    await store.send(.repositories(.delegate(.selectedWorktreeChanged(worktree))))
    await store.finish()

    let bootstraps = recorded.commands.value.filter(isBootstrap)
    #expect(!recorded.mintedOrResumed)
    if sibling {
      #expect(recorded.selectedLayouts == [second], "the task the detail view shows")
      #expect(store.state.repositories.selectedTask == nil, "the pick ends once the directory shows another task")
      #expect(
        bootstraps == [
          .ensureInitialTab(second, DirectoryContext(worktree: worktree), runSetupScriptIfNew: false, focusing: false)
        ])
    } else {
      #expect(bootstraps.isEmpty, "an empty task gets no shell tab from a selection")
      #expect(recorded.selectedLayouts == [first], "the empty task stays where the directory's first tab lands")
      #expect(store.state.repositories.selectedTask?.id == first)
    }
  }

  @Test func aTaskWithNoTabOrOnAnotherDirectoryIsNotTheDirectorysTask() {
    var state = mintedTasksOnly([(first, firstSurface)])
    // Recorded as active, but it holds no tab: showing it would bootstrap one.
    state.terminals.layouts.append(LayoutFeature.State(id: second, layout: PaneLayout()))
    state.terminals.directories[second] = TaskRecord.Directory(worktreeID: worktree.id)
    state.terminals.activeTasks[worktree.id] = second
    #expect(state.terminals.task(forDirectory: worktree.id) == first)

    // A task elsewhere is never this directory's, whatever the entry says.
    state.terminals.layouts.append(agentTask(third, surface: thirdSurface))
    state.terminals.directories[third] = TaskRecord.Directory(worktreeID: otherWorktree.id)
    state.terminals.activeTasks[worktree.id] = third
    #expect(state.terminals.task(forDirectory: worktree.id) == first)
    #expect(state.terminals.task(forDirectory: otherWorktree.id) == third)

    // With no task to show, the seam still says where a first tab lands.
    state.terminals.layouts.remove(id: first)
    state.terminals.activeTasks[worktree.id] = nil
    #expect(state.terminals.task(forDirectory: worktree.id) == nil)
    #expect(state.layoutID(forDirectory: worktree.id) == worktree.id.layoutID)
  }

  @Test(.dependencies) func aTasklessDirectoryNeverSelectsAnotherDirectorysLayout() async {
    var initial = mintedTasksOnly([])
    // The directory's own key is in use by a task recorded on another directory.
    initial.terminals.layouts.append(agentTask(worktree.id.layoutID, surface: firstSurface))
    initial.terminals.directories[worktree.id.layoutID] = TaskRecord.Directory(worktreeID: otherWorktree.id)
    let recorded = Recorded()
    let store = taskStore(initial, recorded: recorded)

    await store.send(.repositories(.delegate(.selectedWorktreeChanged(worktree))))
    await store.finish()

    #expect(recorded.commands.value.contains(.setSelectedLayoutID(nil)))
    #expect(recorded.selectedLayouts.isEmpty)
    #expect(!recorded.commands.value.contains(where: isBootstrap))
    #expect(!recorded.mintedOrResumed)
    // The detail view mounts nothing of the other directory's task either.
    #expect(store.state.detailLayoutID(forDirectory: worktree.id) == nil)
    #expect(store.state.detailLayoutID(forDirectory: otherWorktree.id) == worktree.id.layoutID)
  }

  @Test func theDetailViewMountsWhatADirectorySelectionSelects() {
    // No task: the empty layout a first tab lands in, so the tab shows up.
    var state = mintedTasksOnly([])
    #expect(state.detailLayoutID(forDirectory: worktree.id) == worktree.id.layoutID)

    state = mintedTasksOnly([(first, firstSurface), (second, secondSurface)])
    state.terminals.selectionOrder = [first, second]
    #expect(state.detailLayoutID(forDirectory: worktree.id) == second)

    // A recorded entry naming another directory's task mounts nothing of it.
    state = mintedTasksOnly([(first, firstSurface)])
    state.terminals.directories[first] = TaskRecord.Directory(worktreeID: otherWorktree.id)
    state.terminals.activeTasks[worktree.id] = first
    #expect(state.detailLayoutID(forDirectory: worktree.id) == nil)
  }

  @Test(.dependencies) func newTaskHereMintsAnAgentTaskOnThatDirectory() async throws {
    var initial = mintedTasksOnly([])
    // A session row elsewhere is selected: the task still starts on the row's directory.
    initial.repositories.repositories.append(
      Repository(id: "/other", rootURL: otherWorktree.workingDirectory, name: "other", worktrees: [otherWorktree]))
    let recorded = Recorded()
    let store = mintingStore(initial, recorded: recorded)

    await store.send(.newTask(inDirectory: otherWorktree.id))
    await store.receive(\.launchSessionCompleted)
    await store.finish()

    let launch = try #require(launches(recorded).first)
    #expect(launches(recorded).count == 1)
    #expect(launch.layoutID == LayoutID(task: UUID(1)), "a fresh task, not the directory's own layout")
    #expect(launch.directory == otherWorktree.id)
    #expect(launch.input == "pi")
    #expect(
      store.state.pendingTaskLaunches == [PendingTaskLaunch(layoutID: launch.layoutID, directoryID: otherWorktree.id)],
      "shown once its first tab exists")
  }

  @Test(.dependencies) func newTaskHereDoesNothingForADirectoryGoneFromDisk() async {
    let recorded = Recorded()
    let store = mintingStore(otherDirectoryMissing(), recorded: recorded)
    #expect(store.state.repositories.worktree(for: otherWorktree.id)?.isMissing == true)

    await store.send(.newTask(inDirectory: otherWorktree.id))
    await store.finish()

    #expect(recorded.commands.value.isEmpty)
    #expect(store.state.pendingSessionLaunch == nil)
    #expect(store.state.pendingTaskLaunches.isEmpty)
  }

  @Test(.dependencies) func newTaskHereOnARemoteDirectoryStartsOnItsHostWhileAnotherTaskIsSelected() async throws {
    let host = try #require(RemoteHost(authority: "me@box"))
    let remote = Worktree(
      id: "me@box/srv/app", name: "app", detail: "",
      workingDirectory: URL(fileURLWithPath: "/srv/app"), repositoryRootURL: URL(fileURLWithPath: "/srv/app"),
      host: host)
    var initial = mintedTasksOnly([(first, firstSurface)])
    initial.repositories.repositories.append(
      Repository(
        id: "me@box/srv/app", rootURL: remote.repositoryRootURL, name: "app", worktrees: [remote], host: host))
    // A local task is the one on screen: the launch still goes to the row's host.
    initial.terminals.selectedLayoutID = first
    initial.repositories.selectedTask = .init(id: first, directoryID: worktree.id)
    let recorded = Recorded()
    let store = mintingStore(initial, recorded: recorded)

    await store.send(.newTask(inDirectory: remote.id))
    await store.receive(\.launchSessionCompleted)
    await store.finish()

    let contexts = recorded.commands.value.compactMap { command -> DirectoryContext? in
      guard case .createTabWithInput(_, let context, _, _, _, _, _, _) = command else { return nil }
      return context
    }
    #expect(launches(recorded).map(\.input) == ["pi"])
    #expect(launches(recorded).map(\.layoutID) == [LayoutID(task: UUID(1))], "a fresh task, not the selected one")
    #expect(contexts == [DirectoryContext(worktree: remote)])
    #expect(contexts.map(\.host) == [host])
    #expect(contexts.map(\.worktreeID) == [remote.id])
    #expect(contexts.map { $0.workingDirectory.path(percentEncoded: false) } == ["/srv/app"])
    #expect(
      store.state.pendingTaskLaunches == [PendingTaskLaunch(layoutID: LayoutID(task: UUID(1)), directoryID: remote.id)])
  }

  @Test(.dependencies) func newTaskHereLeavesALaunchAlreadyPendingAlone() async {
    var initial = mintedTasksOnly([])
    let pending = PendingSessionLaunch(
      key: piKey("pending"), cwd: URL(fileURLWithPath: "/elsewhere"), command: "pi --session pending",
      requestID: UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!, launched: true)
    initial.pendingSessionLaunch = pending
    let recorded = Recorded()
    let store = mintingStore(initial, recorded: recorded)

    await store.send(.newTask(inDirectory: worktree.id))
    await store.finish()

    #expect(recorded.commands.value.isEmpty)
    #expect(store.state.pendingSessionLaunch == pending)
    #expect(store.state.pendingTaskLaunches.isEmpty)
  }

  @Test(.dependencies) func newTaskHereDoesNothingForADirectoryTheRosterDoesNotList() async {
    let recorded = Recorded()
    let store = mintingStore(mintedTasksOnly([]), recorded: recorded)

    await store.send(.newTask(inDirectory: "/gone/checkout"))
    await store.finish()

    #expect(recorded.commands.value.isEmpty)
    #expect(store.state.pendingSessionLaunch == nil)
    #expect(store.state.pendingTaskLaunches.isEmpty)
  }

  // MARK: - Task chord and tab chord (A25)

  private func press(_ store: TestStoreOf<AppFeature>, offset: Int) async {
    await store.send(.repositories(offset > 0 ? .selectNextWorktree : .selectPreviousWorktree))
    await store.finish()
    await store.skipReceivedActions(strict: false)
    await store.skipReceivedActions(strict: false)
  }

  private func onSessionsTab() {
    @Shared(.sidebarTab) var tab
    $tab.withLock { $0 = SidebarTab.sessions.rawValue }
  }

  @Test(.dependencies, arguments: [1, -1])
  func heldChordAdvancesBeforeTheTerminalEchoes(offset: Int) async {
    var initial = withRows(sixTasksOnTwoDirectories())
    onSessionsTab()
    initial.terminals.selectedLayoutID = first
    #expect(AppFeature.focusedSessionRowID(state: initial) == .task(first))
    let recorded = Recorded()
    let store = taskStore(initial, recorded: recorded)

    // The terminal never echoes a selection here: every press lands inside the window.
    for _ in initial.repositories.sessionsSidebarStructure.liveIDs { await press(store, offset: offset) }

    let shown = recorded.selectedLayouts
    #expect(zip(shown, shown.dropFirst()).allSatisfy { $0 != $1 }, "no press re-shows the task it left from")
    #expect(Set(shown) == allSixLayouts)
    #expect(store.state.terminals.selectedLayoutID == first)
  }

  @Test(.dependencies) func anEchoForATaskAlreadyLeftDoesNotMoveTheHighlight() async {
    var initial = withRows(twoTasksOnOneDirectory())
    onSessionsTab()
    initial.terminals.selectedLayoutID = first
    #expect(initial.repositories.sessionsSidebarStructure.liveIDs.count == 3)
    let recorded = Recorded()
    let store = taskStore(initial, recorded: recorded, hostingContent: true)

    await press(store, offset: 1)
    await press(store, offset: 1)
    let shown = recorded.selectedLayouts
    #expect(shown.count == 2)
    guard shown.count == 2 else { return }
    let recordedFocus = store.state.lastFocusedSessionRowID
    #expect(store.state.repositories.sessionSelection == .task(shown[1]))

    await store.send(.terminals(.selectedLayoutChanged(shown[0])))
    #expect(store.state.repositories.sessionSelection == .task(shown[1]), "the echo is for the task being left")
    #expect(store.state.lastFocusedSessionRowID == recordedFocus)

    await store.send(.terminals(.selectedLayoutChanged(shown[1])))
    await store.finish()
    #expect(store.state.repositories.sessionSelection == .task(shown[1]))
    #expect(store.state.lastFocusedSessionRowID == .task(shown[1]))
  }

  @Test(.dependencies) func theHoldReleasesWhenTheAskedTaskIsGone() async {
    var initial = withRows(twoTasksOnOneDirectory())
    onSessionsTab()
    initial.terminals.selectedLayoutID = first
    let recorded = Recorded()
    let store = taskStore(initial, recorded: recorded, hostingContent: true)

    await press(store, offset: 1)
    guard let asked = recorded.selectedLayouts.first else {
      Issue.record("the press showed no task")
      return
    }
    #expect(store.state.repositories.selectedTaskID == asked)

    // The terminal still shows `first`, which has a focused surface.
    await store.send(.terminals(.detachLayout(worktreeID: asked)))
    await store.finish()
    await store.skipReceivedActions(strict: false)

    #expect(store.state.repositories.sessionSelection == .task(first), "the highlight follows the focus again")
    #expect(store.state.repositories.selectedTask == nil)
  }

  @Test(.dependencies) func aStaleLiveRowIsNotBootstrapped() async {
    var initial = withRows(twoTasksOnOneDirectory())
    onSessionsTab()
    // The row outlives the task by one snapshot.
    initial.terminals.layouts.remove(id: second)
    #expect(initial.repositories.sessionItems[id: .task(second)]?.location != nil)
    let liveIDs = initial.repositories.sessionsSidebarStructure.liveIDs
    let recorded = Recorded()
    let store = taskStore(initial, recorded: recorded)

    for _ in liveIDs where store.state.repositories.sessionSelection != .task(second) {
      await press(store, offset: 1)
    }

    #expect(store.state.repositories.sessionSelection == .task(second))
    #expect(!recorded.selectedLayouts.contains(second))
    #expect(
      !recorded.commands.value.contains {
        if case .ensureInitialTab(self.second, _, _, _) = $0 { true } else { false }
      })
    #expect(store.state.repositories.selectedTask?.id != second)
    #expect(!recorded.mintedOrResumed)
  }

  @Test(.dependencies) func aNeverOpenedTaskIsStillShownByTheChord() async {
    var initial = withRows(sixTasksOnTwoDirectories())
    onSessionsTab()
    let liveIDs = initial.repositories.sessionsSidebarStructure.liveIDs
    guard let index = liveIDs.firstIndex(of: .task(fourth)) else {
      Issue.record("the never-opened task has no live row")
      return
    }
    #expect(initial.terminals.layouts[id: fourth] == nil)
    initial.repositories.sessionSelection = liveIDs[(index - 1 + liveIDs.count) % liveIDs.count]
    let recorded = Recorded()
    let store = taskStore(initial, recorded: recorded)

    await press(store, offset: 1)

    #expect(recorded.selectedLayouts == [fourth])
    #expect(store.state.repositories.selectedTaskID == fourth)
  }

  @Test(.dependencies, arguments: [1, -1])
  func cyclingSendsNothingButSelectAndFocus(offset: Int) async {
    let initial = withRows(sixTasksOnTwoDirectories())
    onSessionsTab()
    let liveIDs = initial.repositories.sessionsSidebarStructure.liveIDs
    let recorded = Recorded()
    let store = taskStore(initial, recorded: recorded)

    for _ in 0..<(liveIDs.count * 2) { await press(store, offset: offset) }

    #expect(recorded.selectedLayouts.count >= liveIDs.count * 2)
    #expect(recorded.nonFocusCommands.isEmpty)
    #expect(!recorded.mintedOrResumed)
    #expect(recorded.resumes.value == 0)
    #expect(store.state.pendingSessionLaunch == nil)
  }

  @Test(.dependencies) func aTaskWithTwoAgentsIsOneStopPerLap() async {
    var initial = twoTasksOnOneDirectory()
    let tangent = agentTask(first, surface: thirdSurface).layout.panes[0].tabs[0]
    initial.terminals.layouts[id: first]?.layout.panes[0].tabs.append(tangent)
    initial.agentPresence.records[.init(agent: .pi, surfaceID: thirdSurface)] = record(ref: "three")
    initial.terminals.members[first] = [.session(piKey("one")), .session(piKey("three"))]
    initial = withRows(initial)
    onSessionsTab()
    let liveIDs = initial.repositories.sessionsSidebarStructure.liveIDs
    #expect(Set(liveIDs) == [.task(worktree.id.layoutID), .task(first), .task(second)])
    #expect(AppFeature.sessionSnapshots(state: initial).filter { $0.location.layoutID == first }.count == 2)
    let recorded = Recorded()
    let store = taskStore(initial, recorded: recorded)

    for _ in liveIDs { await press(store, offset: 1) }

    #expect(recorded.selectedLayouts.count == 3)
    #expect(Set(recorded.selectedLayouts) == [worktree.id.layoutID, first, second])
    #expect(recorded.focused.value.isEmpty, "the task is shown with its own focus, not a member's surface")
  }

  @Test(.dependencies) func theChordSkipsDormantAndSettledTasks() async {
    var initial = sixTasksOnTwoDirectories()
    let closed = LayoutID(task: UUID(uuidString: "00000000-0000-0000-0000-0000000000A8")!)
    initial.terminals.layouts.append(LayoutFeature.State(id: closed, layout: PaneLayout()))
    initial.terminals.directories[closed] = TaskRecord.Directory(worktreeID: worktree.id)
    initial.terminals.members[closed] = [.session(piKey("closed"))]
    initial.repositories.taskSessions = AppFeature.taskSessions(initial.terminals.members)
    initial.repositories.sessionSummaries = ["closed", "loose"].map {
      SessionSummary(
        harness: .pi, sessionID: $0, createdAt: .distantPast, cwd: "/workspace", title: $0, messageCount: 4,
        lastActivity: .distantPast)
    }
    initial = withRows(initial)
    onSessionsTab()
    let dormant: Set<SessionRowID> = [.task(closed), .implicit(piKey("loose"))]
    let rows = initial.repositories.sessionItems
    #expect(dormant.allSatisfy { rows[id: $0] != nil && rows[id: $0]?.location == nil })
    let liveIDs = initial.repositories.sessionsSidebarStructure.liveIDs
    #expect(liveIDs.count == 6)
    let recorded = Recorded()
    let store = taskStore(initial, recorded: recorded)

    for _ in 0..<(liveIDs.count * 2) {
      await press(store, offset: 1)
      #expect(store.state.repositories.sessionSelection.map(dormant.contains) == false)
    }

    #expect(Set(recorded.selectedLayouts) == allSixLayouts)
    #expect(recorded.resumes.value == 0)
    #expect(!recorded.mintedOrResumed)
    #expect(store.state.pendingSessionLaunch == nil)
  }

  private func tabChord(forward: Bool) -> AppFeature.Action {
    forward ? .selectNextTerminalTab : .selectPreviousTerminalTab
  }

  /// `second` was just picked on a directory whose recorded task is `first`;
  /// the terminal has not echoed it.
  private func secondJustSelected() -> AppFeature.State {
    var state = withRows(twoTasksOnOneDirectory())
    state.repositories.selectedTask = SelectedTask(id: second, directoryID: worktree.id)
    return state
  }

  @Test(.dependencies, arguments: [true, false])
  func tabChordActsOnTheTaskJustSelected(forward: Bool) async {
    let initial = secondJustSelected()
    #expect(initial.layoutID(forDirectory: worktree.id) == first)
    let recorded = Recorded()
    let store = taskStore(initial, recorded: recorded)

    await store.send(tabChord(forward: forward))
    await store.finish()

    #expect(recorded.commands.value == [.selectRelativeTab(second, forward: forward)])
  }

  @Test(.dependencies, arguments: [true, false])
  func tabChordReachesAnOrphanTask(forward: Bool) async {
    var initial = withRows(withOrphans(state()))
    initial.repositories.selection = nil
    initial.repositories.selectedTask = SelectedTask(id: orphanShell, directoryID: goneDirectory.worktreeID)
    #expect(initial.repositories.orphanTaskID == orphanShell)
    let recorded = Recorded()
    let store = taskStore(initial, recorded: recorded)

    await store.send(tabChord(forward: forward))
    await store.finish()

    #expect(recorded.commands.value == [.selectRelativeTab(orphanShell, forward: forward)])
  }

  @Test(.dependencies, arguments: [true, false])
  func tabChordReachesATaskOnAMissingDirectory(forward: Bool) async {
    var initial = secondJustSelected()
    let missing = Worktree(
      id: "/workspace", name: "workspace", detail: "",
      workingDirectory: URL(fileURLWithPath: "/workspace"),
      repositoryRootURL: URL(fileURLWithPath: "/workspace"), isMissing: true)
    initial.repositories.repositories = [
      Repository(id: "/workspace", rootURL: missing.workingDirectory, name: "workspace", worktrees: [missing])
    ]
    #expect(initial.taskOnMissingDirectory == second)
    let recorded = Recorded()
    let store = taskStore(initial, recorded: recorded)

    await store.send(tabChord(forward: forward))
    await store.finish()

    #expect(recorded.commands.value == [.selectRelativeTab(second, forward: forward)])
  }

  @Test(.dependencies, arguments: [true, false])
  func tabChordWithNoTaskOnScreenSendsNothing(forward: Bool) async {
    var initial = withRows(withOrphans(state()))
    initial.repositories.selection = nil
    let recorded = Recorded()
    let store = taskStore(initial, recorded: recorded)

    await store.send(tabChord(forward: forward))
    await store.send(.selectTerminalTabAtIndex(2))
    await store.finish()

    #expect(recorded.commands.value.isEmpty)
  }

  @Test(.dependencies) func tabIndexChordUsesTheSameTarget() async {
    let recorded = Recorded()
    let store = taskStore(secondJustSelected(), recorded: recorded)

    await store.send(.selectTerminalTabAtIndex(2))
    await store.finish()

    #expect(recorded.commands.value == [.selectTabAtIndex(second, index: 2)])
  }

  @Test(.dependencies, arguments: [true, false])
  func tabChordNeverChangesTheSelectedTask(forward: Bool) async {
    var initial = secondJustSelected()
    initial.repositories.sessionSelection = .task(second)
    let recorded = Recorded()
    let store = taskStore(initial, recorded: recorded)

    for _ in 0..<5 { await store.send(tabChord(forward: forward)) }
    await store.finish()

    #expect(store.state.repositories.selectedTask == initial.repositories.selectedTask)
    #expect(store.state.repositories.sessionSelection == .task(second))
    #expect(store.state.repositories.selectedWorktreeID == worktree.id)
    #expect(recorded.selectedLayouts.isEmpty)
    #expect(recorded.commands.value == Array(repeating: .selectRelativeTab(second, forward: forward), count: 5))
  }
}

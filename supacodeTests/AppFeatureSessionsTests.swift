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
    SessionLocation(worktreeID: worktree.id, tabID: tab, surfaceID: surface)
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
        value: LayoutsFile(worktrees: [
          worktree.id.rawValue: LayoutRecord(layout: layout)
        ]))
    } else {
      state.terminals.layouts = [LayoutFeature.State(id: worktree.id, layout: layout)]
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
    let key = SessionRowID.session(SessionKey(harness: .pi, sessionID: "real"))
    initial.repositories.sessionItems = [
      SessionSidebarItemFeature.State(
        id: key, title: "Agent", cwd: "/workspace", createdAt: .distantPast, location: location)
    ]
    let store = TestStore(initialState: initial) {
      AppFeature()
    } withDependencies: {
      $0.date.now = .distantPast
      $0.terminalClient.focusSurface = { worktree, tab, surf in
        focused.withValue {
          $0.append(SessionLocation(worktreeID: worktree.id, tabID: tab, surfaceID: surf))
        }
      }
    }
    store.exhaustivity = .off
    await store.send(.repositories(.sessionItems(.element(id: key, action: .activate))))
    await store.receive(\.repositories.delegate.focusSession)
    await store.receive(\.focusTerminalSurface)
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
    let key = SessionRowID.session(SessionKey(harness: .pi, sessionID: "real"))
    let store = TestStore(initialState: initial) {
      AppFeature()
    } withDependencies: {
      $0.date.now = .distantPast
      $0.terminalClient.focusSurface = { worktree, tab, surf in
        focused.withValue {
          $0.append(SessionLocation(worktreeID: worktree.id, tabID: tab, surfaceID: surf))
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
    await store.receive(\.focusTerminalSurface)
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
    let store = TestStore(initialState: state()) { AppFeature() } withDependencies: {
      $0.date.now = .distantPast
      $0.continuousClock = clock
      $0.terminalClient.saveLayoutsWithAgents = { _ in }
    }
    store.exhaustivity = .off
    let key = AgentPresenceFeature.PresenceKey(agent: .pi, surfaceID: UUID())
    await store.send(.agentPresence(.restoreFromSnapshotChecked(
      records: [key: AgentPresenceFeature.RestoredRecord(
        alivePids: [123], activity: .idle, sessionRef: "unmapped")], resumeCandidates: [:])))
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
    initial.repositories.$persistedLayouts = SharedReader(value: LayoutsFile(worktrees: [:]))
    let summary = SessionSummary(
      harness: .pi, sessionID: "old", createdAt: .distantPast, cwd: "/fixture",
      title: "Old", messageCount: 1, lastActivity: .distantPast)
    initial.repositories.sessionSummaries = [summary]
    initial.repositories.sessionsRefreshSucceeded = true
    let store = TestStore(initialState: initial) { AppFeature() } withDependencies: {
      $0.date.now = Date(timeIntervalSince1970: 1_000_000)
      $0.continuousClock = TestClock()
      $0.terminalClient.saveLayoutsWithAgents = { _ in }
    }
    store.exhaustivity = .off
    let key = AgentPresenceFeature.PresenceKey(agent: .pi, surfaceID: surface)
    await store.send(.agentPresence(.restoreFromSnapshotChecked(
      records: [key: AgentPresenceFeature.RestoredRecord(
        alivePids: [123], activity: .idle, sessionRef: nil)], resumeCandidates: [:])))
    await store.receive(\.repositories.sessionsRestorationCompleted)
    #expect(store.state.repositories.sessionsRestorationFinished)
    #expect(store.state.repositories.sessionsHasUnresolvedLivePresence)
    #expect(store.state.repositories.sessionSnapshots.isEmpty)
    #expect(store.state.repositories.sessionsLiveKeys.isEmpty)
    await store.send(.repositories(.sessionsRefreshCompleted([summary])))
    #expect(store.state.repositories.sessions[summary.id] == nil)
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
    initial.repositories.reconcileSessionItems(now: .distantPast)
    let store = TestStore(initialState: initial) {
      AppFeature()
    } withDependencies: {
      $0.date.now = .distantPast
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
    #expect(store.state.repositories.sessionItems.count == 1)
    let rowID = store.state.repositories.sessionItems.first?.id
    #expect(rowID == .session(SessionKey(harness: .pi, sessionID: "real")))
    #expect(store.state.repositories.sessionItems.first?.createdAt == .distantPast)
    await clock.advance(by: .seconds(1))
    await store.finish()
  }

  // MARK: - Dormant resume with real temp directory fixtures

  @Test(.dependencies) func dormantResumeWithMissingCwdSendsNoTerminalCommand() async {
    let sent = LockIsolated<[TerminalClient.Command]>([])
    var initial = state()
    let key = SessionKey(harness: .pi, sessionID: "abc123")
    initial.repositories.sessionItems = [
      SessionSidebarItemFeature.State(
        id: .session(key), title: "Dormant", cwd: "/tmp/supacode-test-nonexistent-\(UUID())",
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
    await store.send(.repositories(.activateSession(.session(key))))
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
        id: .session(key), title: "Dormant",
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
    await store.send(.repositories(.activateSession(.session(key))))
    await store.receive(\.repositories.delegate.resumeSession)
    await store.receive(\.launchSessionCompleted)
    await store.finish()

    let createInputs = sent.value.compactMap { cmd -> String? in
      if case .createTabWithInput(_, let input, _, _, _, _, _) = cmd { return input }
      return nil
    }
    #expect(createInputs == ["pi --session piSess1"])
    let createFlags = sent.value.compactMap { cmd -> (setup: Bool, focusing: Bool)? in
      if case .createTabWithInput(_, _, let setup, _, _, let focusing, _) = cmd {
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
        id: .session(key), title: "Dormant", cwd: tmpDir.path, createdAt: .distantPast)
    ]
    initial.repositories.$sessions.withLock { $0[key] = SessionSidecarEntry(branches: ["old-branch"]) }
    let store = TestStore(initialState: initial) { AppFeature() } withDependencies: {
      $0.date.now = .distantPast
      $0.uuid = .incrementing
      $0[GitClientDependency.self].branchName = { _ in "new-branch" }
      $0.terminalClient.send = { cmd in sent.withValue { $0.append(cmd) } }
    }
    store.exhaustivity = .off
    await store.send(.repositories(.activateSession(.session(key))))
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
        id: .session(key), title: "Controlled", cwd: directory.path, createdAt: .distantPast)
    ]
    initial.repositories.$sessions.withLock { $0[key] = SessionSidecarEntry(branches: ["old"]) }
    let branches = AsyncStream<String>.makeStream()
    let probes = LockIsolated(0)
    let sent = LockIsolated<[TerminalClient.Command]>([])
    let store = TestStore(initialState: initial) { AppFeature() } withDependencies: {
      $0.uuid = .incrementing
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
        id: .session(key), title: "Dormant", cwd: tmpDir.path, createdAt: .distantPast)
    ]
    initial.repositories.$sessions.withLock { $0[key] = SessionSidecarEntry(branches: ["main", "feature"]) }
    let store = TestStore(initialState: initial) { AppFeature() } withDependencies: {
      $0.date.now = .distantPast
      $0.uuid = .incrementing
      $0[GitClientDependency.self].branchName = { _ in "main" }
      $0.terminalClient.send = { cmd in sent.withValue { $0.append(cmd) } }
    }
    store.exhaustivity = .off
    await store.send(.repositories(.activateSession(.session(key))))
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
    let layout = initial.terminals.layouts[id: worktree.id]!.layout
    let newTabs = layout.panes[0].tabs + [
      TabItem(
        id: tab2, title: "Agent2",
        content: ContentSnapshot(
          id: ContentID(rawValue: surface2),
          state: .terminal(TerminalContentState(workingDirectory: "/workspace"))))
    ]
    initial.terminals.layouts[id: worktree.id]?.layout.panes[0].tabs = IdentifiedArray(uniqueElements: newTabs)
    let presenceKey1 = AgentPresenceFeature.PresenceKey(agent: .pi, surfaceID: surface)
    initial.agentPresence.records[presenceKey1] = record(ref: "sess1")
    initial.agentPresence.bySurface[surface] = [.pi]
    let presenceKey2 = AgentPresenceFeature.PresenceKey(agent: .pi, surfaceID: surface2)
    initial.agentPresence.records[presenceKey2] = record(ref: "sess2")
    initial.agentPresence.bySurface[surface2] = [.pi]
    initial.repositories.sessionSnapshots = AppFeature.sessionSnapshots(state: initial)
    initial.repositories.reconcileSessionItems(now: .distantPast)
    initial.repositories.recomputeSessionsSidebarStructureIfChanged()
    initial.repositories.sessionSelection = .session(key1)
    let sent = LockIsolated<[TerminalClient.Command]>([])
    initial.terminals.selectedWorktreeID = worktree.id
    initial.terminals.layouts[id: worktree.id]?.layout.panes[0].selectedTabID = self.tab
    let store = TestStore(initialState: initial) {
      AppFeature()
    } withDependencies: {
      $0.date.now = .distantPast
      $0.terminalClient.send = { cmd in sent.withValue { $0.append(cmd) } }
      $0.terminalClient.focusSurface = { worktree, tab, surf in
        focused.withValue {
          $0.append(SessionLocation(worktreeID: worktree.id, tabID: tab, surfaceID: surf))
        }
      }
    }
    store.exhaustivity = .off
    await store.send(.repositories(.selectNextWorktree)) {
      $0.repositories.sessionSelection = .session(key2)
    }
    await store.finish()
    #expect(!sent.value.contains { if case .createTabWithInput = $0 { return true }; return false })
    #expect(focused.value == [initial.repositories.sessionItems[id: .session(key2)]!.location!])
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
    let layout = initial.terminals.layouts[id: worktree.id]!.layout
    let newTabs = layout.panes[0].tabs + [
      TabItem(
        id: tab2, title: "Agent2",
        content: ContentSnapshot(
          id: ContentID(rawValue: surface2),
          state: .terminal(TerminalContentState(workingDirectory: "/workspace"))))
    ]
    initial.terminals.layouts[id: worktree.id]?.layout.panes[0].tabs = IdentifiedArray(uniqueElements: newTabs)
    let presenceKey1 = AgentPresenceFeature.PresenceKey(agent: .pi, surfaceID: surface)
    initial.agentPresence.records[presenceKey1] = record(ref: "sess1")
    initial.agentPresence.bySurface[surface] = [.pi]
    let presenceKey2 = AgentPresenceFeature.PresenceKey(agent: .pi, surfaceID: surface2)
    initial.agentPresence.records[presenceKey2] = record(ref: "sess2")
    initial.agentPresence.bySurface[surface2] = [.pi]
    initial.repositories.sessionSnapshots = AppFeature.sessionSnapshots(state: initial)
    initial.repositories.reconcileSessionItems(now: .distantPast)
    initial.repositories.recomputeSessionsSidebarStructureIfChanged()
    initial.repositories.sessionSelection = .session(key1)
    let sent = LockIsolated<[TerminalClient.Command]>([])
    initial.terminals.selectedWorktreeID = worktree.id
    initial.terminals.layouts[id: worktree.id]?.layout.panes[0].selectedTabID = self.tab
    let store = TestStore(initialState: initial) {
      AppFeature()
    } withDependencies: {
      $0.date.now = .distantPast
      $0.terminalClient.send = { cmd in sent.withValue { $0.append(cmd) } }
      $0.terminalClient.focusSurface = { worktree, tab, surf in
        focused.withValue {
          $0.append(SessionLocation(worktreeID: worktree.id, tabID: tab, surfaceID: surf))
        }
      }
    }
    store.exhaustivity = .off
    await store.send(.repositories(.selectPreviousWorktree)) {
      $0.repositories.sessionSelection = .session(key2)
    }
    await store.finish()
    #expect(!sent.value.contains { if case .createTabWithInput = $0 { return true }; return false })
    #expect(focused.value == [initial.repositories.sessionItems[id: .session(key2)]!.location!])
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
    let layout = initial.terminals.layouts[id: worktree.id]!.layout
    let newTabs = layout.panes[0].tabs + [
      TabItem(
        id: tab2, title: "Agent2",
        content: ContentSnapshot(
          id: ContentID(rawValue: surface2),
          state: .terminal(TerminalContentState(workingDirectory: "/workspace"))))
    ]
    initial.terminals.layouts[id: worktree.id]?.layout.panes[0].tabs = IdentifiedArray(uniqueElements: newTabs)
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
    initial.terminals.selectedWorktreeID = worktree.id
    initial.terminals.layouts[id: worktree.id]?.layout.panes[0].selectedTabID = self.tab
    let store = TestStore(initialState: initial) {
      AppFeature()
    } withDependencies: {
      $0.date.now = .distantPast
      $0.terminalClient.send = { cmd in sent.withValue { $0.append(cmd) } }
      $0.terminalClient.focusSurface = { worktree, tab, surf in
        focused.withValue {
          $0.append(SessionLocation(worktreeID: worktree.id, tabID: tab, surfaceID: surf))
        }
      }
    }
    store.exhaustivity = .off
    await store.send(.repositories(.selectWorktreeAtHotkeySlot(1))) {
      $0.repositories.sessionSelection = .session(key2)
    }
    await store.finish()
    #expect(!sent.value.contains { if case .createTabWithInput = $0 { return true }; return false })
    #expect(focused.value == [initial.repositories.sessionItems[id: .session(key2)]!.location!])
  }

  @Test(.dependencies) func focusedSurfaceResolvesToSessionRowID() {
    var state = state()
    state.terminals.selectedWorktreeID = worktree.id
    state.terminals.layouts[id: worktree.id]?.layout.panes[0].selectedTabID = tab
    let key = SessionKey(harness: .pi, sessionID: "real")
    let location = SessionLocation(worktreeID: worktree.id, tabID: TabID(rawValue: tab.id), surfaceID: surface)
    let snapshot = SessionLiveSnapshot(
      harness: .pi, sessionRef: "real", cwd: "/workspace", location: location)
    state.repositories.sessionSnapshots = [snapshot]
    state.repositories.reconcileSessionItems(now: .distantPast)
    let resolved = AppFeature.focusedSessionRowID(state: state)
    #expect(resolved == .session(key))
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
    let layout = initial.terminals.layouts[id: worktree.id]!.layout
    let newTabs = layout.panes[0].tabs + [
      TabItem(
        id: tab2, title: "Agent2",
        content: ContentSnapshot(
          id: ContentID(rawValue: surface2),
          state: .terminal(TerminalContentState(workingDirectory: "/workspace"))))
    ]
    initial.terminals.layouts[id: worktree.id]?.layout.panes[0].tabs = IdentifiedArray(uniqueElements: newTabs)
    initial.terminals.layouts[id: worktree.id]?.layout.panes[0].selectedTabID = tab2
    let presenceKey1 = AgentPresenceFeature.PresenceKey(agent: .pi, surfaceID: surface)
    initial.agentPresence.records[presenceKey1] = record(ref: "sess1")
    initial.agentPresence.bySurface[surface] = [.pi]
    let presenceKey2 = AgentPresenceFeature.PresenceKey(agent: .pi, surfaceID: surface2)
    initial.agentPresence.records[presenceKey2] = record(ref: "sess2")
    initial.agentPresence.bySurface[surface2] = [.pi]
    initial.repositories.sessionSnapshots = AppFeature.sessionSnapshots(state: initial)
    initial.repositories.reconcileSessionItems(now: .distantPast)
    initial.repositories.recomputeSessionsSidebarStructureIfChanged()
    initial.repositories.sessionSelection = .session(key1)
    let sent = LockIsolated<[TerminalClient.Command]>([])
    initial.terminals.selectedWorktreeID = worktree.id
    let store = TestStore(initialState: initial) {
      AppFeature()
    } withDependencies: {
      $0.date.now = .distantPast
      $0.terminalClient.send = { cmd in sent.withValue { $0.append(cmd) } }
      $0.terminalClient.focusSurface = { worktree, tab, surf in
        focused.withValue {
          $0.append(SessionLocation(worktreeID: worktree.id, tabID: tab, surfaceID: surf))
        }
      }
    }
    store.exhaustivity = .off
    await store.send(.repositories(.selectNextWorktree)) {
      $0.repositories.sessionSelection = .session(key1)
    }
    await store.finish()
    #expect(!sent.value.contains { if case .createTabWithInput = $0 { return true }; return false })
    #expect(focused.value == [initial.repositories.sessionItems[id: .session(key1)]!.location!])
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
        id: .session(key), title: "Dormant",
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

    await store.send(.repositories(.activateSession(.session(key))))
    await store.receive(\.repositories.delegate.resumeSession)
    await store.receive(\.launchSessionCompleted)
    await store.finish()

    let tabInputs = sent.value.compactMap { cmd -> String? in
      if case .createTabWithInput(_, let input, _, _, _, _, _) = cmd { return input }
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
        id: .session(key), title: "Dormant",
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

    await store.send(.repositories(.activateSession(.session(key))))
    await store.receive(\.repositories.delegate.resumeSession)
    #expect(store.state.pendingSessionLaunch != nil)

    await store.receive(\.repositories.delegate.repositoriesChanged)
    await store.receive(\.launchSessionCompleted)
    await store.finish()

    let created = sent.value.compactMap { cmd -> String? in
      if case .createTabWithInput(_, let input, _, _, _, _, _) = cmd { return input }
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
        id: .session(key), title: "Dormant", cwd: tmpPath,
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

    await store.send(.repositories(.activateSession(.session(key))))
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
    initial.terminals.layouts.append(LayoutFeature.State(id: worktree2.id, layout: layout2))

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

  @Test(.dependencies) func newSessionUsesFocusedSessionCwdBeforeSelection() async throws {
    let focusedCwd = try temporaryDirectory(named: "focused-new-session")
    let selectedCwd = try temporaryDirectory(named: "selected-new-session")
    let focusedWorktree = Worktree(
      id: Worktree.ID(focusedCwd.path(percentEncoded: false)), name: "focused", detail: "",
      workingDirectory: focusedCwd, repositoryRootURL: focusedCwd)
    var initial = state()
    initial.terminals.selectedWorktreeID = worktree.id
    initial.terminals.layouts[id: worktree.id]?.layout.panes[0].selectedTabID = tab
    initial.repositories.repositories.append(
      Repository(
        id: RepositoryID(focusedCwd.path(percentEncoded: false)), rootURL: focusedCwd,
        name: "focused", worktrees: [focusedWorktree])
    )
    let focusedKey = SessionKey(harness: .pi, sessionID: "focused")
    let selectedKey = SessionKey(harness: .pi, sessionID: "selected")
    initial.repositories.sessionItems = [
      SessionSidebarItemFeature.State(
        id: .session(focusedKey), title: "Focused", cwd: focusedCwd.path(percentEncoded: false),
        createdAt: .distantPast, location: location),
      SessionSidebarItemFeature.State(
        id: .session(selectedKey), title: "Selected", cwd: selectedCwd.path(percentEncoded: false),
        createdAt: .distantPast, location: nil),
    ]
    initial.repositories.sessionSelection = .session(selectedKey)
    let sent = LockIsolated<[TerminalClient.Command]>([])
    let store = TestStore(initialState: initial) { AppFeature() } withDependencies: {
      $0.uuid = .incrementing
      $0.date.now = .distantPast
      $0.continuousClock = ImmediateClock()
      $0.terminalClient.send = { command in sent.withValue { $0.append(command) } }
    }
    store.exhaustivity = .off

    await store.send(.newSession)
    await store.receive(\.launchSessionCompleted)
    await store.finish()

    let launches = sent.value.compactMap { command -> (String, String)? in
      guard case .createTabWithInput(let worktree, let input, _, _, _, _, _) = command else { return nil }
      return (worktree.workingDirectory.path(percentEncoded: false), input)
    }
    #expect(launches.count == 1)
    #expect(launches.first?.0 == focusedCwd.path(percentEncoded: false))
    #expect(launches.first?.1 == "pi")
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
    let store = TestStore(initialState: initial) { AppFeature() } withDependencies: {
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
      if case .createTabWithInput(_, let input, _, _, _, _, _) = command { return input }
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
      Repository(id: RepositoryID(cwd.path(percentEncoded: false)), rootURL: cwd,
        name: "picked", worktrees: [pickedWorktree])
    ]
    let sent = LockIsolated<[TerminalClient.Command]>([])
    let store = TestStore(initialState: initial) { AppFeature() } withDependencies: {
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
    guard case .createTabWithInput(let worktree, let input, _, _, _, _, _) = sent.value[0]
    else { Issue.record("Expected exactly one session launch"); return }
    #expect(worktree.workingDirectory == cwd)
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
      worktreeID: worktree.id,
      tabID: TabID(rawValue: surface2),
      surfaceID: surface2
    )
    initial.repositories.sessionsStarted = true
    initial.repositories.sessionItems = [
      SessionSidebarItemFeature.State(
        id: .session(key), title: "Session 1", cwd: "/workspace",
        createdAt: Date(timeIntervalSince1970: 20),
        location: location
      ),
      SessionSidebarItemFeature.State(
        id: .session(key2), title: "Session 2", cwd: "/workspace",
        createdAt: Date(timeIntervalSince1970: 10),
        location: location2
      ),
    ]
    initial.repositories.recomputeSessionsSidebarStructureIfChanged()
    initial.repositories.sessionSelection = .session(key)
    initial.agentPresence.records[
      AgentPresenceFeature.PresenceKey(agent: .pi, surfaceID: surface)
    ] = AgentPresenceFeature.PresenceRecord(pids: [], sessionRef: "real")
    let store = TestStore(initialState: initial) { AppFeature() } withDependencies: {
      $0.date.now = Date(timeIntervalSince1970: 100)
      $0.continuousClock = ImmediateClock()
      $0.terminalClient.focusSurface = { _, _, _ in }
    }
    store.exhaustivity = .off
    await store.send(.settleSessionAndAdvance) { appState in
      #expect(appState.repositories.sessions[key]?.settledAt != nil)
    }
    await store.receive(\..focusTerminalSurface)
  }

  @Test(.dependencies) func settleSessionAndAdvanceUnsettlesSettledDestination() async throws {
    var initial = state()
    let key = SessionKey(harness: .pi, sessionID: "real")
    let key2 = SessionKey(harness: .pi, sessionID: "next")
    let surface2 = UUID(uuidString: "00000000-0000-0000-0000-000000000099")!
    let location2 = SessionLocation(
      worktreeID: worktree.id,
      tabID: TabID(rawValue: surface2),
      surfaceID: surface2
    )
    initial.repositories.sessionsStarted = true
    initial.repositories.sessionItems = [
      SessionSidebarItemFeature.State(
        id: .session(key), title: "Session 1", cwd: "/workspace",
        createdAt: Date(timeIntervalSince1970: 20),
        location: location
      ),
      SessionSidebarItemFeature.State(
        id: .session(key2), title: "Session 2", cwd: "/workspace",
        createdAt: Date(timeIntervalSince1970: 10),
        lifecycle: .settled, location: location2
      ),
    ]
    initial.repositories.recomputeSessionsSidebarStructureIfChanged()
    initial.repositories.sessionSelection = .session(key)
    initial.agentPresence.records[
      AgentPresenceFeature.PresenceKey(agent: .pi, surfaceID: surface)
    ] = AgentPresenceFeature.PresenceRecord(pids: [], sessionRef: "real")
    let store = TestStore(initialState: initial) { AppFeature() } withDependencies: {
      $0.date.now = Date(timeIntervalSince1970: 100)
      $0.continuousClock = ImmediateClock()
      $0.terminalClient.focusSurface = { _, _, _ in }
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
        id: .session(key), title: "Session", cwd: "/workspace",
        createdAt: Date(timeIntervalSince1970: 10),
        location: location
      )
    ]
    initial.repositories.recomputeSessionsSidebarStructureIfChanged()
    initial.repositories.sessionSelection = .session(key)
    initial.agentPresence.records[
      AgentPresenceFeature.PresenceKey(agent: .pi, surfaceID: surface)
    ] = AgentPresenceFeature.PresenceRecord(pids: [], sessionRef: "real")
    let store = TestStore(initialState: initial) { AppFeature() } withDependencies: {
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
        id: .session(key), title: "Session", cwd: "/workspace",
        createdAt: Date(timeIntervalSince1970: 10),
        lifecycle: .settled, location: location
      )
    ]
    initial.repositories.$sessions = Shared(value: [key: SessionSidecarEntry(settledAt: Date())])
    initial.repositories.recomputeSessionsSidebarStructureIfChanged()
    initial.repositories.sessionSelection = .session(key)
    initial.agentPresence.records[
      AgentPresenceFeature.PresenceKey(agent: .pi, surfaceID: surface)
    ] = AgentPresenceFeature.PresenceRecord(pids: [], sessionRef: "real")
    let store = TestStore(initialState: initial) { AppFeature() } withDependencies: {
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
        id: .session(key), title: "Session", cwd: "/workspace",
        createdAt: .distantPast, location: location
      )
    ]
    let store = TestStore(initialState: initial) { AppFeature() } withDependencies: {
      $0.date.now = Date(timeIntervalSince1970: 100)
      $0.continuousClock = ImmediateClock()
      $0.terminalClient.saveLayoutsWithAgents = { _ in }
    }
    store.exhaustivity = .off

    await store.send(.terminalEvent(.userClosedSurfaces(worktreeID: worktree.id, [surface])))
    await store.receive(\.repositories.settleSession) { appState in
      #expect(appState.repositories.sessions[key]?.settledAt == Date(timeIntervalSince1970: 100))
    }
    await store.send(.terminalEvent(.surfacesClosed(worktreeID: worktree.id, [surface])))
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
        id: .session(first), title: "One", cwd: "/workspace",
        createdAt: .distantPast, location: location
      ),
      SessionSidebarItemFeature.State(
        id: .session(second), title: "Two", cwd: "/workspace",
        createdAt: .distantPast,
        location: SessionLocation(worktreeID: worktree.id, tabID: TabID(rawValue: shell), surfaceID: shell)
      ),
    ]
    let store = TestStore(initialState: initial) { AppFeature() } withDependencies: {
      $0.date.now = Date(timeIntervalSince1970: 100)
      $0.continuousClock = ImmediateClock()
      $0.terminalClient.saveLayoutsWithAgents = { _ in }
    }
    store.exhaustivity = .off

    await store.send(.terminalEvent(.userClosedSurfaces(worktreeID: worktree.id, [surface, shell])))
    await store.receive(\.repositories.settleSession)
    await store.receive(\.repositories.settleSession)
    #expect(store.state.repositories.sessions[first]?.settledAt == Date(timeIntervalSince1970: 100))
    #expect(store.state.repositories.sessions[second]?.settledAt == Date(timeIntervalSince1970: 100))
    await store.send(.terminalEvent(.surfacesClosed(worktreeID: worktree.id, [surface, shell])))
    await store.receive(\.agentPresence.surfacesClosed)
    await store.finish()
  }

  @Test(.dependencies) func directContentRequestedCloseMarksUserIntentSynchronously() async {
    let marked = LockIsolated<[Set<UUID>]>([])
    let initial = state()
    let store = TestStore(initialState: initial) { AppFeature() } withDependencies: {
      $0.terminalClient.markUserCloseIntent = { _, ids in marked.withValue { $0.append(ids) } }
    }
    store.exhaustivity = .off

    await store.send(
      .terminals(
        .layouts(
          .element(
            id: worktree.id,
            action: .contentRequestedClose(content: ContentID(rawValue: surface), scope: .allTabs)
          )
        )
      )
    )
    #expect(marked.value == [[surface, shell]])
  }

  @Test(.dependencies) func suppressedSessionEndSkipsRefreshButNonEndEventsStillRefresh() async {
    let store = TestStore(initialState: state()) { AppFeature() } withDependencies: {
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
    let store = TestStore(initialState: initial) { AppFeature() } withDependencies: {
      $0.date.now = Date(timeIntervalSince1970: 100)
      $0.continuousClock = ImmediateClock()
      $0.terminalClient.saveLayoutsWithAgents = { _ in }
    }
    store.exhaustivity = .off
    await store.send(.terminalEvent(.agentHookEventReceived(AgentHookEvent(
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
    let store = TestStore(initialState: initial) { AppFeature() } withDependencies: {
      $0.date.now = Date(timeIntervalSince1970: 100)
      $0.continuousClock = ImmediateClock()
      $0.terminalClient.saveLayoutsWithAgents = { _ in }
      $0.terminalClient.isHarnessEndSuppressed = { _ in scenario == "suppressed" }
    }
    store.exhaustivity = .off
    let reason = scenario == "missing" ? nil : scenario == "reload" ? "reload"
      : scenario == "unknown" ? "unknown" : "quit"
    await store.send(.terminalEvent(.agentHookEventReceived(AgentHookEvent(
      agent: "pi", event: "session_end", surfaceID: surface,
      pid: scenario == "stalePid" ? 11 : 22,
      sessionRef: scenario == "missingSid" ? nil : scenario == "staleSid" ? "previous" : "real",
      shutdownReason: reason))))
    await store.receive(\.agentPresence.hookEventReceived)
    await store.finish()
    #expect(store.state.repositories.sessions[key]?.settledAt == nil)
    #expect(store.state.agentPresence.records[presenceKey]?.sessionRef == "real")
    if scenario == "staleSid" || scenario == "stalePid" || scenario == "missingSid" {
      #expect(store.state.agentPresence.records[presenceKey]?.pids == [11, 22])
      #expect(store.state.agentPresence.records[presenceKey]?.lastEventName == nil)
    }
  }

  @Test(.dependencies, arguments: ["session_start", "busy"])
  func changedSidSettlesPreviousSessionButSameSidDoesNot(event: String) async {
    var initial = state()
    let presenceKey = AgentPresenceFeature.PresenceKey(agent: .pi, surfaceID: surface)
    initial.agentPresence.records[presenceKey] = record()
    let store = TestStore(initialState: initial) { AppFeature() } withDependencies: {
      $0.date.now = Date(timeIntervalSince1970: 100)
      $0.continuousClock = ImmediateClock()
      $0.terminalClient.saveLayoutsWithAgents = { _ in }
    }
    store.exhaustivity = .off
    await store.send(.terminalEvent(.agentHookEventReceived(AgentHookEvent(
      agent: "pi", event: event, surfaceID: surface, sessionRef: "real"))))
    await store.receive(\.agentPresence.hookEventReceived)
    await store.finish()
    #expect(store.state.repositories.sessions[SessionKey(harness: .pi, sessionID: "real")] == nil)
    await store.send(.terminalEvent(.agentHookEventReceived(AgentHookEvent(
      agent: "pi", event: event, surfaceID: surface, sessionRef: "replacement"))))
    await store.receive(\.repositories.settleSession)
    await store.finish()
    #expect(store.state.repositories.sessions[SessionKey(harness: .pi, sessionID: "real")]?.settledAt != nil)
    #expect(store.state.repositories.sessions[SessionKey(harness: .pi, sessionID: "replacement")] == nil)
    #expect(store.state.agentPresence.records[presenceKey]?.sessionRef == "replacement")
    await store.send(.terminalEvent(.agentHookEventReceived(AgentHookEvent(
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
    let store = TestStore(initialState: initial) { AppFeature() } withDependencies: {
      $0.date.now = Date(timeIntervalSince1970: 100)
      $0.continuousClock = ImmediateClock()
      $0.terminalClient.saveLayoutsWithAgents = { _ in }
    }
    store.exhaustivity = .off
    await store.send(.terminalEvent(.agentHookEventReceived(AgentHookEvent(
      agent: "pi", event: "session_start", surfaceID: surface, pid: 22, sessionRef: "replacement"))))
    await store.receive(\.agentPresence.hookEventReceived)
    await store.finish()
    #expect(store.state.agentPresence.records[presenceKey]?.currentSessionPID == 22)
    for ref in ["real", "replacement"] {
      await store.send(.terminalEvent(.agentHookEventReceived(AgentHookEvent(
        agent: "pi", event: "session_end", surfaceID: surface, pid: 11,
        sessionRef: ref, shutdownReason: "quit"))))
      await store.receive(\.agentPresence.hookEventReceived)
      await store.finish()
      #expect(store.state.agentPresence.records[presenceKey]?.sessionRef == "replacement")
      #expect(store.state.repositories.sessions[SessionKey(harness: .pi, sessionID: "replacement")] == nil)
    }
    await store.send(.terminalEvent(.agentHookEventReceived(AgentHookEvent(
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
    let store = TestStore(initialState: initial) { AppFeature() } withDependencies: {
      $0.date.now = Date(timeIntervalSince1970: 100)
      $0.continuousClock = ImmediateClock()
      $0.terminalClient.saveLayoutsWithAgents = { _ in }
    }
    store.exhaustivity = .off
    await store.send(.terminalEvent(.agentHookEventReceived(AgentHookEvent(
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
      worktreeID: worktree.id, tabID: TabID(rawValue: surfaceNeeds), surfaceID: surfaceNeeds)
    let doneLocation = SessionLocation(
      worktreeID: worktree.id, tabID: TabID(rawValue: surfaceDone), surfaceID: surfaceDone)
    initial.repositories.sessionItems = [
      SessionSidebarItemFeature.State(
        id: .session(idle), title: "Idle", cwd: "/workspace",
        createdAt: Date(timeIntervalSince1970: 30), location: location, status: .idle),
      SessionSidebarItemFeature.State(
        id: .session(needs), title: "Needs", cwd: "/workspace",
        createdAt: Date(timeIntervalSince1970: 20), location: needsLocation, status: .needsYou),
      SessionSidebarItemFeature.State(
        id: .session(done), title: "Done", cwd: "/workspace",
        createdAt: Date(timeIntervalSince1970: 10), location: doneLocation, status: .doneUnseen),
    ]
    initial.repositories.recomputeSessionsSidebarStructureIfChanged()
    initial.repositories.sessionSelection = .session(needs)
    let store = TestStore(initialState: initial) { AppFeature() } withDependencies: {
      $0.terminalClient.focusSurface = { _, _, _ in }
    }
    store.exhaustivity = .off

    await store.send(.nextSessionNeedsMe) { appState in
      appState.repositories.sessionSelection = .session(done)
    }
    await store.receive(\.repositories.delegate.focusSession)

    await store.send(.nextSessionNeedsMe) { appState in
      appState.repositories.sessionSelection = .session(needs)
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
      worktreeID: worktree.id,
      tabID: TabID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-0000000000B1")!),
      surfaceID: UUID(uuidString: "00000000-0000-0000-0000-0000000000B1")!)
    let idleLocation = SessionLocation(
      worktreeID: worktree.id,
      tabID: TabID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-0000000000B2")!),
      surfaceID: UUID(uuidString: "00000000-0000-0000-0000-0000000000B2")!)
    let nextLocation = SessionLocation(
      worktreeID: worktree.id,
      tabID: TabID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-0000000000B3")!),
      surfaceID: UUID(uuidString: "00000000-0000-0000-0000-0000000000B3")!)
    let workingLocation = SessionLocation(
      worktreeID: worktree.id,
      tabID: TabID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-0000000000B4")!),
      surfaceID: UUID(uuidString: "00000000-0000-0000-0000-0000000000B4")!)
    initial.repositories.sessionItems = [
      SessionSidebarItemFeature.State(
        id: .session(first), title: "First", cwd: "/workspace",
        createdAt: Date(timeIntervalSince1970: 40), location: firstLocation, status: .needsYou),
      SessionSidebarItemFeature.State(
        id: .session(idle), title: "Idle", cwd: "/workspace",
        createdAt: Date(timeIntervalSince1970: 30), location: idleLocation, status: .idle),
      SessionSidebarItemFeature.State(
        id: .session(next), title: "Next", cwd: "/workspace",
        createdAt: Date(timeIntervalSince1970: 20), location: nextLocation, status: .doneUnseen),
      SessionSidebarItemFeature.State(
        id: .session(working), title: "Working", cwd: "/workspace",
        createdAt: Date(timeIntervalSince1970: 10), location: workingLocation, status: .working),
    ]
    initial.repositories.recomputeSessionsSidebarStructureIfChanged()
    initial.repositories.sessionSelection = .session(idle)
    let store = TestStore(initialState: initial) { AppFeature() } withDependencies: {
      $0.terminalClient.focusSurface = { _, _, _ in }
    }
    store.exhaustivity = .off

    await store.send(.nextSessionNeedsMe) { appState in
      appState.repositories.sessionSelection = .session(next)
    }
    await store.receive(\.repositories.delegate.focusSession)

    await store.send(.repositories(.sessionSelectionChanged(.session(working)))) { appState in
      appState.repositories.sessionSelection = .session(working)
    }
    await store.send(.nextSessionNeedsMe) { appState in
      appState.repositories.sessionSelection = .session(first)
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
    let store = TestStore(initialState: initial) { AppFeature() } withDependencies: {
      $0.terminalClient.focusSurface = { _, _, surfaceID in focused.withValue { $0.append(surfaceID) } }
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
        id: .session(busy), title: "Busy", cwd: "/workspace",
        createdAt: Date(timeIntervalSince1970: 20), location: location, status: .working),
      SessionSidebarItemFeature.State(
        id: .session(dormant), title: "Dormant", cwd: "/workspace",
        createdAt: Date(timeIntervalSince1970: 10), status: .needsYou),
    ]
    initial.repositories.recomputeSessionsSidebarStructureIfChanged()
    initial.repositories.sessionSelection = .session(busy)
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
    let store = TestStore(initialState: initial) { AppFeature() } withDependencies: {
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
        id: .session(key), title: "Block", cwd: tmpDir.path, createdAt: .distantPast)
    ]
    let launchTime = Date(timeIntervalSince1970: 1_000)
    initial.recentSessionLaunchDate[key] = launchTime
    let sent = LockIsolated<[TerminalClient.Command]>([])
    let store = TestStore(initialState: initial) { AppFeature() } withDependencies: {
      $0.date.now = Date(timeIntervalSince1970: 1_005)  // 5 s after launch
      $0.terminalClient.send = { cmd in sent.withValue { $0.append(cmd) } }
    }
    store.exhaustivity = .off
    await store.send(.repositories(.activateSession(.session(key))))
    await store.receive(\..repositories.delegate.resumeSession)
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
        id: .session(key), title: "Allow", cwd: tmpDir.path, createdAt: .distantPast)
    ]
    let launchTime = Date(timeIntervalSince1970: 1_000)
    initial.recentSessionLaunchDate[key] = launchTime
    let sent = LockIsolated<[TerminalClient.Command]>([])
    let store = TestStore(initialState: initial) { AppFeature() } withDependencies: {
      $0.uuid = .incrementing
      $0.date.now = Date(timeIntervalSince1970: 1_015)  // 15 s after — cooldown expired
      $0.terminalClient.send = { cmd in
        if case .createTabWithInput = cmd { sent.withValue { $0.append(cmd) } }
      }
    }
    store.exhaustivity = .off
    await store.send(.repositories(.activateSession(.session(key))))
    await store.receive(\..repositories.delegate.resumeSession)
    await store.receive(\.launchSessionCompleted)
    await store.finish()
    #expect(sent.value.count == 1, "should launch after cooldown expires")
  }

  @Test(.dependencies) func resumeDormantMissingCwdShowsAlert() async {
    let key = SessionKey(harness: .pi, sessionID: "missing")
    var initial = state()
    initial.repositories.sessionItems = [
      SessionSidebarItemFeature.State(
        id: .session(key), title: "Missing", cwd: "/nonexistent/dir/absent", createdAt: .distantPast)
    ]
    let store = TestStore(initialState: initial) { AppFeature() } withDependencies: {
      $0.date.now = .distantPast
    }
    store.exhaustivity = .off
    await store.send(.repositories(.activateSession(.session(key))))
    await store.receive(\..repositories.delegate.resumeSession) { appState in
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
      Repository(id: RepositoryID(tmpDir.path), rootURL: tmpDir, name: "provisional",
        worktrees: [worktree]))
    initial.repositories.sessionItems = [
      SessionSidebarItemFeature.State(
        id: .session(key), title: "Dormant", cwd: tmpDir.path(percentEncoded: false),
        createdAt: .distantPast)
    ]
    let surfaceID = UUID()
    initial.repositories.sessionSnapshots = [
      SessionLiveSnapshot(
        harness: .pi, sessionRef: nil,
        cwd: tmpDir.path(percentEncoded: false),
        location: SessionLocation(
          worktreeID: worktree.id, tabID: TabID(), surfaceID: surfaceID))
    ]
    let store = TestStore(initialState: initial) { AppFeature() } withDependencies: {
      $0.date.now = .distantPast
      $0.uuid = .incrementing
    }
    store.exhaustivity = .off
    await store.send(.repositories(.activateSession(.session(key))))
    await store.receive(\..repositories.delegate.resumeSession)
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
        id: .session(key), title: "Dormant", cwd: tmpDir.path(percentEncoded: false),
        createdAt: .distantPast)
    ]
    let surfaceID = UUID()
    initial.repositories.sessionSnapshots = [
      SessionLiveSnapshot(
        harness: .pi, sessionRef: nil,
        cwd: tmpDir.path(percentEncoded: false),
        location: SessionLocation(
          worktreeID: WorktreeID(tmpDir.path), tabID: TabID(), surfaceID: surfaceID))
    ]
    let sent = LockIsolated<[TerminalClient.Command]>([])
    let store = TestStore(initialState: initial) { AppFeature() } withDependencies: {
      $0.date.now = .distantPast
      $0.uuid = .incrementing
      $0.terminalClient.send = { cmd in sent.withValue { $0.append(cmd) } }
    }
    store.exhaustivity = .off
    await store.send(.repositories(.activateSession(.session(key))))
    await store.receive(\..repositories.delegate.resumeSession)
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
        id: .session(key), title: "Dormant", cwd: tmpDir.path(percentEncoded: false),
        createdAt: .distantPast)
    ]
    initial.repositories.$sessions.withLock { $0[key] = SessionSidecarEntry(branches: ["old-branch"]) }
    let surfaceID = UUID()
    initial.repositories.sessionSnapshots = [
      SessionLiveSnapshot(
        harness: .pi, sessionRef: nil,
        cwd: tmpDir.path(percentEncoded: false),
        location: SessionLocation(
          worktreeID: WorktreeID(tmpDir.path), tabID: TabID(), surfaceID: surfaceID))
    ]
    let store = TestStore(initialState: initial) { AppFeature() } withDependencies: {
      $0.date.now = .distantPast
      $0.uuid = .incrementing
      $0[GitClientDependency.self].branchName = { _ in "new-branch" }
    }
    store.exhaustivity = .off
    await store.send(.repositories(.activateSession(.session(key))))
    await store.receive(\..repositories.delegate.resumeSession)
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
      Repository(id: RepositoryID(tmpDir.path), rootURL: tmpDir, name: "nonstandard",
        worktrees: [worktree]))
    initial.repositories.sessionItems = [
      SessionSidebarItemFeature.State(
        id: .session(key), title: "Dormant", cwd: tmpDir.path(percentEncoded: false),
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
          worktreeID: worktree.id, tabID: TabID(), surfaceID: surfaceID))
    ]
    let store = TestStore(initialState: initial) { AppFeature() } withDependencies: {
      $0.date.now = .distantPast
      $0.uuid = .incrementing
    }
    store.exhaustivity = .off
    await store.send(.repositories(.activateSession(.session(key))))
    await store.receive(\..repositories.delegate.resumeSession)
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
        id: .session(key), title: "Dormant", cwd: tmpDir.path(percentEncoded: false),
        createdAt: .distantPast)
    ]
    initial.repositories.$sessions.withLock { $0[key] = SessionSidecarEntry(branches: ["main"]) }
    let sent = LockIsolated<[TerminalClient.Command]>([])
    let store = TestStore(initialState: initial) { AppFeature() } withDependencies: {
      $0.date.now = .distantPast
      $0.uuid = .incrementing
      $0[GitClientDependency.self].branchName = { _ in nil }
      $0.terminalClient.send = { cmd in sent.withValue { $0.append(cmd) } }
    }
    store.exhaustivity = .off
    await store.send(.repositories(.activateSession(.session(key))))
    await store.receive(\..repositories.delegate.resumeSession)
    await store.receive(\.resumeBranchProbeCompleted) { appState in
      #expect(appState.alert != nil)
      #expect(appState.pendingSessionLaunch == nil)
    }
    await store.finish()
    #expect(sent.value.isEmpty)
  }

}

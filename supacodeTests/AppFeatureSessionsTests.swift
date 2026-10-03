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
}

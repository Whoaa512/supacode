import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import Sharing
import Testing

@testable import SupacodeSettingsShared
@testable import supacode

@MainActor
struct RepositoriesFeatureTaskSelectionTests {
  private let repoRoot = "/tmp/repo"
  private let taskA = LayoutID(task: UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!)
  private let taskB = LayoutID(task: UUID(uuidString: "00000000-0000-0000-0000-0000000000A2")!)

  private func worktree(_ name: String) -> Worktree {
    Worktree(
      id: WorktreeID("/tmp/repo/\(name)"), name: name, detail: "",
      workingDirectory: URL(fileURLWithPath: "/tmp/repo/\(name)"),
      repositoryRootURL: URL(fileURLWithPath: repoRoot))
  }

  private func state(worktrees: [Worktree]) -> RepositoriesFeature.State {
    var state = RepositoriesFeature.State()
    state.$sessions = Shared(value: [:])
    state.$sidebar = Shared(value: SidebarState())
    state.$persistedLayouts = SharedReader(value: TaskLayoutsFile())
    state.repositories = [
      Repository(
        id: RepositoryID(repoRoot), rootURL: URL(fileURLWithPath: repoRoot), name: "repo",
        worktrees: IdentifiedArray(uniqueElements: worktrees))
    ]
    state.repositoryRoots = [URL(fileURLWithPath: repoRoot)]
    state.reconcileSidebarForTesting()
    return state
  }

  private func summary(_ id: String, created: TimeInterval) -> SessionSummary {
    SessionSummary(
      harness: .pi, sessionID: id, createdAt: Date(timeIntervalSince1970: created),
      cwd: "/tmp/repo/main", title: id, messageCount: 5, lastActivity: Date(timeIntervalSince1970: created))
  }

  private func taskSnapshot(_ id: LayoutID, directory: Worktree.ID, created: TimeInterval? = nil) -> TaskLiveSnapshot {
    let path = directory.rawValue
    return TaskLiveSnapshot(
      title: URL(fileURLWithPath: path).lastPathComponent, cwd: path,
      createdAt: created.map(Date.init(timeIntervalSince1970:)),
      location: SessionLocation(layoutID: id, directoryID: directory, tabID: TabID(), surfaceID: UUID()))
  }

  // MARK: - Selection (A18)

  @Test(.dependencies) func selectTaskSelectsItsDirectoryAndNamesTheTaskInTheDelegate() async {
    let main = worktree("main")
    let feature = worktree("feature")
    var initial = state(worktrees: [main, feature])
    initial.selection = .worktree(main.id)
    let store = TestStore(initialState: initial) { RepositoriesFeature() }
    store.exhaustivity = .off

    await store.send(.selectTask(taskA, directory: feature.id))
    await store.receive(\.delegate.selectedWorktreeChanged) {
      #expect($0.selectedTaskID == taskA)
      #expect($0.selectedWorktreeID == feature.id)
    }
    await store.receive(\.sidebarItems[id: feature.id].focusTerminalRequested)
    await store.finish()

    #expect(store.state.selection == .worktree(feature.id))
    #expect(store.state.sidebarItems[id: feature.id]?.shouldFocusTerminal == true)
  }

  @Test(.dependencies) func selectTaskDelegateCarriesTheWorktreeAndTheLayout() async {
    let main = worktree("main")
    var initial = state(worktrees: [main])
    initial.selection = .worktree(main.id)
    let store = TestStore(initialState: initial) { RepositoriesFeature() }
    store.exhaustivity = .off

    await store.send(.selectTask(taskB, directory: main.id))
    await store.receive(\.delegate, .selectedWorktreeChanged(main, layoutID: taskB))
    await store.finish()

    #expect(store.state.selectedTaskID == taskB)
    #expect(store.state.selectedWorktreeID == main.id, "same directory: the selected worktree does not move")
  }

  @Test(.dependencies) func selectTaskOnAnUnknownDirectorySelectsTheTaskAlone() async {
    let main = worktree("main")
    var initial = state(worktrees: [main])
    initial.selection = .worktree(main.id)
    let store = TestStore(initialState: initial) { RepositoriesFeature() }
    store.exhaustivity = .off

    await store.send(.selectTask(taskA, directory: "/gone/checkout"))
    await store.receive(\.delegate, .selectedWorktreeChanged(nil, layoutID: taskA))
    await store.finish()

    #expect(store.state.selectedTaskID == taskA)
    #expect(store.state.orphanTaskID == taskA)
    #expect(store.state.selectedWorktreeID == nil)

    await store.send(.selectTask(taskB, directory: main.id))
    await store.finish()
    #expect(store.state.orphanTaskID == nil)
    #expect(store.state.selectedTaskID == taskB)
    #expect(store.state.selectedWorktreeID == main.id)
  }

  @Test(.dependencies) func selectingAnotherDirectoryDropsTheSelectedTask() async {
    let main = worktree("main")
    let feature = worktree("feature")
    var initial = state(worktrees: [main, feature])
    initial.selection = .worktree(feature.id)
    initial.selectedTask = SelectedTask(id: taskA, directoryID: feature.id)
    #expect(initial.selectedTaskID == taskA)
    let store = TestStore(initialState: initial) { RepositoriesFeature() }
    store.exhaustivity = .off

    await store.send(.selectWorktree(main.id, focusTerminal: false))
    await store.finish()

    #expect(store.state.selectedTaskID == nil)
    #expect(store.state.selectedWorktreeID == main.id)
  }

  @Test(.dependencies) func deletingTheDirectoryClearsTheSelectedTask() async {
    let main = worktree("main")
    let feature = worktree("feature")
    var initial = state(worktrees: [main, feature])
    initial.selection = .worktree(feature.id)
    initial.selectedTask = SelectedTask(id: taskA, directoryID: feature.id)
    initial.sidebarItems[id: feature.id]?.lifecycle = .deleting
    let store = TestStore(initialState: initial) {
      RepositoriesFeature()
    } withDependencies: {
      $0.gitClient.worktrees = { _ in [main] }
    }
    store.exhaustivity = .off

    await store.send(
      .worktreeDeleted(feature.id, repositoryID: RepositoryID(repoRoot), selectionWasRemoved: false, nextSelection: nil)
    )
    await store.receive(\.delegate.selectedWorktreeChanged)

    #expect(store.state.selection == .worktree(main.id))
    #expect(store.state.selectedTaskID == nil)
    #expect(store.state.selectedWorktreeID == main.id)
  }

  @Test(.dependencies) func selectedTaskRemovedForgetsTheTask() async {
    let main = worktree("main")
    var initial = state(worktrees: [main])
    initial.selection = .worktree(main.id)
    initial.selectedTask = SelectedTask(id: taskA, directoryID: main.id)
    let store = TestStore(initialState: initial) { RepositoriesFeature() }
    store.exhaustivity = .off

    await store.send(.selectedTaskRemoved) { $0.selectedTask = nil }
    #expect(store.state.selectedWorktreeID == main.id)
  }

  // MARK: - Rows (A16)

  @Test(.dependencies) func everyIndexedSessionKeepsItsOwnRowBesideTaskRows() {
    let main = worktree("main")
    var state = state(worktrees: [main])
    state.sessionSummaries = [summary("one", created: 30), summary("two", created: 20), summary("three", created: 10)]
    state.reconcileSessionItems(now: .distantPast)
    let sessionRowCount = state.sessionItems.count

    state.taskSnapshots = [taskSnapshot(taskA, directory: main.id, created: 5)]
    state.reconcileSessionItems(now: .distantPast)
    state.applyCacheRecomputes(.sessionsStructure)

    #expect(sessionRowCount == 3)
    #expect(state.sessionItems.count == 4)
    for id in ["one", "two", "three"] {
      let row = state.sessionItems[id: .implicit(SessionKey(harness: .pi, sessionID: id))]
      #expect(row != nil)
      #expect(row?.location == nil, "an indexed session in no task stays an implicit, dormant row")
    }
    let taskRow = state.sessionItems[id: .task(taskA)]
    #expect(taskRow?.title == "main")
    #expect(taskRow?.cwd == "/tmp/repo/main")
    #expect(taskRow?.lifecycle == .active)
    #expect(taskRow?.location?.layoutID == taskA)
    #expect(state.sessionsSidebarStructure.liveIDs == [.task(taskA)])
    #expect(state.sessionsSidebarStructure.allIDs.count == 4)
  }

  @Test(.dependencies) func taskRowWithoutARecordKeepsItsFirstSeenDate() {
    let main = worktree("main")
    var state = state(worktrees: [main])
    state.taskSnapshots = [taskSnapshot(taskA, directory: main.id)]
    state.reconcileSessionItems(now: Date(timeIntervalSince1970: 100))
    state.reconcileSessionItems(now: Date(timeIntervalSince1970: 200))

    #expect(state.sessionItems[id: .task(taskA)]?.createdAt == Date(timeIntervalSince1970: 100))
  }

  @Test(.dependencies) func taskRowGoesAwayWithItsSnapshot() async {
    let main = worktree("main")
    var initial = state(worktrees: [main])
    initial.taskSnapshots = [taskSnapshot(taskA, directory: main.id, created: 5)]
    initial.reconcileSessionItems(now: .distantPast)
    initial.sessionSelection = .task(taskA)
    let store = TestStore(initialState: initial) {
      RepositoriesFeature()
    } withDependencies: {
      $0.date.now = .distantPast
    }
    store.exhaustivity = .off

    await store.send(.taskSnapshotsChanged([]))

    #expect(store.state.sessionItems.isEmpty)
    #expect(store.state.sessionSelection == nil)
    #expect(store.state.sessionsSidebarStructure.liveIDs.isEmpty)
  }

  // MARK: - Keyboard (A36)

  @Test(.dependencies) func nextAndPreviousWalkTaskRowsWithoutResuming() async {
    let main = worktree("main")
    var initial = state(worktrees: [main])
    initial.sessionSummaries = [summary("dormant", created: 50)]
    initial.taskSnapshots = [
      taskSnapshot(taskA, directory: main.id, created: 30),
      taskSnapshot(taskB, directory: main.id, created: 20),
    ]
    initial.reconcileSessionItems(now: .distantPast)
    initial.applyCacheRecomputes(.sessionsStructure)
    @Shared(.sidebarTab) var tab
    $tab.withLock { $0 = SidebarTab.sessions.rawValue }
    let store = TestStore(initialState: initial) { RepositoriesFeature() }
    store.exhaustivity = .off

    await store.send(.selectNextWorktree) { $0.sessionSelection = .task(self.taskA) }
    await store.receive(\.delegate, .focusTask(taskA, directory: main.id))
    await store.send(.selectNextWorktree) { $0.sessionSelection = .task(self.taskB) }
    await store.receive(\.delegate, .focusTask(taskB, directory: main.id))
    await store.send(.selectNextWorktree) { $0.sessionSelection = .task(self.taskA) }
    await store.receive(\.delegate, .focusTask(taskA, directory: main.id))
    await store.send(.selectPreviousWorktree) { $0.sessionSelection = .task(self.taskB) }
    await store.receive(\.delegate, .focusTask(taskB, directory: main.id))
    await store.send(.selectWorktreeAtHotkeySlot(0)) { $0.sessionSelection = .task(self.taskA) }
    await store.receive(\.delegate, .focusTask(taskA, directory: main.id))
    await store.finish()
  }

  /// The liveness the task chord walks: a task is live through a tab or an
  /// agent, whatever its sessions are marked; one with neither is never live.
  @Test(.dependencies) func aLiveTaskRowIsNeverInSettledAndADormantOneIsNeverLive() {
    let main = worktree("main")
    let taskC = LayoutID(task: UUID(uuidString: "00000000-0000-0000-0000-0000000000A3")!)
    func key(_ id: String) -> SessionKey { SessionKey(harness: .pi, sessionID: id) }
    let settled = SessionSidecarEntry(settledAt: Date(timeIntervalSince1970: 60))
    var state = state(worktrees: [main])
    state.$sessions = Shared(value: [key("open"): settled, key("closed"): settled])
    state.sessionSummaries = [
      summary("open", created: 30), summary("closed", created: 20), summary("idle", created: 10),
    ]
    state.taskSessions = [taskA: [key("open")], taskB: [key("closed")], taskC: [key("idle")]]
    state.taskSnapshots = [taskSnapshot(taskA, directory: main.id, created: 5)]
    state.reconcileSessionItems(now: .distantPast)
    state.applyCacheRecomputes(.sessionsStructure)

    let sections = state.sessionsSidebarStructure.sections
    #expect(state.sessionsSidebarStructure.liveIDs == [.task(taskA)])
    #expect(sections.first { $0.id == .active }?.rowIDs.contains(.task(taskA)) == true)
    #expect(sections.first { $0.id == .settled }?.rowIDs == [.task(taskB)])
    #expect(state.sessionItems[id: .task(taskB)]?.location == nil)
    #expect(state.sessionItems[id: .task(taskC)]?.location == nil)
    #expect(state.sessionItems[id: .task(taskC)] != nil, "a dormant task keeps its row; the chord just skips it")
  }

  @Test(.dependencies) func activatingATaskRowAsksForTheTask() async {
    let main = worktree("main")
    var initial = state(worktrees: [main])
    initial.taskSnapshots = [taskSnapshot(taskA, directory: main.id, created: 30)]
    initial.reconcileSessionItems(now: .distantPast)
    let store = TestStore(initialState: initial) {
      RepositoriesFeature()
    } withDependencies: {
      $0.date.now = .distantPast
    }
    store.exhaustivity = .off

    await store.send(.activateSession(.task(taskA))) { $0.sessionSelection = .task(self.taskA) }
    await store.receive(\.delegate, .focusTask(taskA, directory: main.id))
    await store.finish()
  }
}

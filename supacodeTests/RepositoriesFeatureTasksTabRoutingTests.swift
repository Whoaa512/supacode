import ComposableArchitecture
import Foundation
import IdentifiedCollections
import Sharing
import Testing

@testable import supacode

/// Assertion A9: adding the Tasks panel must not leak into worktree navigation.
/// With Tasks on screen the arrow / ⌃digit chords are inert (they beep instead of
/// moving the worktree selection), the ⌘⇧A toggle has an explicit Tasks arm, an
/// unknown persisted tab value still falls back to Worktrees, and a `.task`
/// selection carries no worktree ID so every worktree-only flow goes inert by
/// construction.
@MainActor
struct RepositoriesFeatureTasksTabRoutingTests {
  private let repoRoot = URL(fileURLWithPath: "/tmp/tasks-nav-repo")

  private func makeWorktree(id: String, name: String) -> Worktree {
    Worktree(
      id: WorktreeID(id),
      name: name,
      detail: "",
      workingDirectory: URL(fileURLWithPath: id),
      repositoryRootURL: repoRoot
    )
  }

  private func makeState() -> (RepositoriesFeature.State, Worktree) {
    let alpha = makeWorktree(id: "/tmp/tasks-nav-repo/alpha", name: "alpha")
    let bravo = makeWorktree(id: "/tmp/tasks-nav-repo/bravo", name: "bravo")
    let repository = Repository(
      id: RepositoryID(repoRoot.path(percentEncoded: false)),
      rootURL: repoRoot,
      name: "tasks-nav-repo",
      worktrees: IdentifiedArray(uniqueElements: [alpha, bravo])
    )
    var state = RepositoriesFeature.State(reconciledRepositories: [repository])
    state.isInitialLoadComplete = true
    state.setSingleWorktreeSelection(alpha.id)
    state.applyPostReduceCacheRecomputes(.all)
    return (state, alpha)
  }

  private func withTab<T>(_ tab: SidebarTab, _ body: () async throws -> T) async rethrows -> T {
    try await withDependencies {
      $0.defaultAppStorage = .inMemory
    } operation: {
      @Shared(.sidebarTab) var sidebarTabRawValue
      $sidebarTabRawValue.withLock { $0 = tab.rawValue }
      return try await body()
    }
  }

  // MARK: - Persisted tab decoding

  @Test func knownStoredValuesResolveToTheirTab() {
    for tab in SidebarTab.allCases {
      #expect(SidebarTab.resolved(fromStoredValue: tab.rawValue) == tab)
    }
  }

  @Test func unknownStoredValueFallsBackToWorktrees() {
    #expect(SidebarTab.resolved(fromStoredValue: "not-a-tab") == .worktrees)
    #expect(SidebarTab.resolved(fromStoredValue: "") == .worktrees)
  }

  @Test func tasksTabIsSelectableInThePicker() {
    #expect(SidebarTab.allCases.contains(.tasks))
    #expect(!SidebarTab.tasks.help.isEmpty)
    #expect(!SidebarTab.tasks.systemImage.isEmpty)
  }

  // MARK: - ⌘⇧A toggle

  /// The chord means "show me the agents", so from Tasks it jumps to Agents
  /// rather than flipping into the Worktrees tree.
  @Test func togglingFromTasksSelectsAgents() async {
    await withTab(.tasks) {
      @Shared(.sidebarTab) var tab
      let store = TestStore(initialState: RepositoriesFeature.State()) { RepositoriesFeature() }

      await store.send(.toggleAgentsSidebarTab)

      #expect(tab == SidebarTab.agents.rawValue)
    }
  }

  // MARK: - Navigation chords are inert on Tasks

  @Test func selectNextWorktreeDoesNotMoveSelectionWhileTasksIsActive() async {
    let (state, alpha) = makeState()
    await withTab(.tasks) {
      let store = TestStore(initialState: state) { RepositoriesFeature() }

      await store.send(.selectNextWorktree)

      #expect(store.state.selectedWorktreeID == alpha.id)
    }
  }

  @Test func selectPreviousWorktreeDoesNotMoveSelectionWhileTasksIsActive() async {
    let (state, alpha) = makeState()
    await withTab(.tasks) {
      let store = TestStore(initialState: state) { RepositoriesFeature() }

      await store.send(.selectPreviousWorktree)

      #expect(store.state.selectedWorktreeID == alpha.id)
    }
  }

  @Test func hotkeySlotDoesNotMoveSelectionWhileTasksIsActive() async {
    let (state, alpha) = makeState()
    await withTab(.tasks) {
      let store = TestStore(initialState: state) { RepositoriesFeature() }

      await store.send(.selectWorktreeAtHotkeySlot(1))

      #expect(store.state.selectedWorktreeID == alpha.id)
    }
  }

  @Test func worktreeHistoryBackDoesNotMoveSelectionWhileTasksIsActive() async {
    var (state, _) = makeState()
    let taskID = TaskID("task-1")
    state.selection = .task(taskID)
    state.worktreeHistoryBackStack = [WorktreeID("/tmp/tasks-nav-repo/bravo")]
    await withTab(.tasks) {
      let store = TestStore(initialState: state) { RepositoriesFeature() }
      // Seeding `.task` after the cache recompute leaves derived slices stale;
      // only the selection / history stacks matter here.
      store.exhaustivity = .off

      await store.send(.worktreeHistoryBack)
      await store.finish()

      #expect(store.state.selection == .task(taskID))
      #expect(store.state.worktreeHistoryBackStack == [WorktreeID("/tmp/tasks-nav-repo/bravo")])
    }
  }

  @Test func worktreeHistoryForwardDoesNotMoveSelectionWhileTasksIsActive() async {
    var (state, _) = makeState()
    let taskID = TaskID("task-1")
    state.selection = .task(taskID)
    state.worktreeHistoryForwardStack = [WorktreeID("/tmp/tasks-nav-repo/bravo")]
    await withTab(.tasks) {
      let store = TestStore(initialState: state) { RepositoriesFeature() }
      store.exhaustivity = .off

      await store.send(.worktreeHistoryForward)
      await store.finish()

      #expect(store.state.selection == .task(taskID))
      #expect(store.state.worktreeHistoryForwardStack == [WorktreeID("/tmp/tasks-nav-repo/bravo")])
    }
  }

  @Test func taskSelectionPreservesFocusedWorktreeFlag() {
    #expect(SidebarSelection.task(TaskID("task-1")).preservesFocusedWorktree)
    #expect(SidebarSelection.archivedWorktrees.preservesFocusedWorktree)
    #expect(!SidebarSelection.worktree(WorktreeID("/tmp/x")).preservesFocusedWorktree)
    #expect(!SidebarSelection.failedRepository(RepositoryID("/tmp/x")).preservesFocusedWorktree)
  }

  /// The Worktrees panel keeps moving on the same chord — Tasks must not have
  /// made the guard swallow everything.
  @Test func selectNextWorktreeStillMovesWhileWorktreesIsActive() async {
    let (state, alpha) = makeState()
    await withTab(.worktrees) {
      let store = TestStore(initialState: state) { RepositoriesFeature() }
      store.exhaustivity = .off

      await store.send(.selectNextWorktree)
      await store.receive(\.selectWorktree)

      #expect(store.state.selectedWorktreeID != alpha.id)
    }
  }

  // MARK: - `.task` selection

  @Test func taskSelectionCarriesNoWorktreeOrRepository() {
    let selection = SidebarSelection.task(TaskID("task-1"))

    #expect(selection.worktreeID == nil)
    #expect(selection.failedRepositoryID == nil)
    #expect(selection.taskID == TaskID("task-1"))
  }

  @Test func taskSelectionYieldsNilSelectedWorktreeID() {
    var (state, _) = makeState()
    state.selection = .task(TaskID("task-1"))

    #expect(state.selectedWorktreeID == nil)
    #expect(!state.isShowingArchivedWorktrees)
  }

  /// Selecting a task is exclusive: the previous worktree selection is dropped
  /// and the detail pane is told there is no worktree.
  @Test func selectingATaskClearsWorktreeSelection() async {
    let (state, _) = makeState()
    let taskID = TaskID("task-1")
    await withTab(.tasks) {
      let store = TestStore(initialState: state) { RepositoriesFeature() }
      store.exhaustivity = .off

      await store.send(.selectionChanged([.task(taskID)]))

      #expect(store.state.selection == .task(taskID))
      #expect(store.state.selectedWorktreeID == nil)
      #expect(store.state.sidebarSelectedWorktreeIDs.isEmpty)
    }
  }

  @Test func taskSelectionIsExemptFromTheWorktreeValidationSweep() {
    #expect(SidebarSelection.task(TaskID("task-1")).isClearedByWorktreeValidation == false)
    #expect(SidebarSelection.archivedWorktrees.isClearedByWorktreeValidation == false)
    #expect(SidebarSelection.worktree(WorktreeID("/tmp/x")).isClearedByWorktreeValidation)
  }

  @Test func taskSelectionSurfacesItselfInSidebarSelections() {
    var (state, _) = makeState()
    let taskID = TaskID("task-1")
    state.selection = .task(taskID)

    #expect(state.sidebarSelections == [.task(taskID)])
  }
}

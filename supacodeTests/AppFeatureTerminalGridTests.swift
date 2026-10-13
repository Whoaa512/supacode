import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import IdentifiedCollections
import Testing

@testable import SupacodeSettingsFeature
@testable import supacode

@MainActor
struct AppFeatureTerminalGridTests {
  @Test(.dependencies) func presentingBuildsModelAndResetsFilter() async {
    let worktree = makeWorktree()
    let session = makeSession(worktree: worktree)
    let store = makeStore(worktree: worktree) {
      $0.terminalClient.listSurfaces = { [session] }
    }

    await store.send(.setTerminalGridFilter(.activity(.busy)))
    await store.send(.setTerminalGridPresented(true))

    #expect(store.state.isTerminalGridPresented)
    #expect(store.state.terminalGridOverview.filter == .all)
    #expect(store.state.terminalGridOverview.tiles.map(\.surfaceID) == [session.surfaceID])
    #expect(store.state.terminalGridOverview.counts.total == 1)
  }

  @Test(.dependencies) func refreshPreservesFilterAndReplacesSessions() async {
    let worktree = makeWorktree()
    let first = makeSession(worktree: worktree)
    let second = makeSession(worktree: worktree)
    let sessions = LockIsolated([first])
    let store = makeStore(worktree: worktree) {
      $0.terminalClient.listSurfaces = { sessions.value }
    }

    await store.send(.setTerminalGridPresented(true))
    await store.send(.setTerminalGridFilter(.activity(.none)))
    sessions.setValue([second])
    await store.send(.refreshTerminalGrid)

    #expect(store.state.terminalGridOverview.filter == .activity(.none))
    #expect(store.state.terminalGridOverview.tiles.map(\.surfaceID) == [second.surfaceID])
  }

  @Test(.dependencies) func jumpDismissesAndFocusesSurface() async {
    let worktree = makeWorktree()
    let session = makeSession(worktree: worktree)
    let focused = LockIsolated<UUID?>(nil)
    // The surface is reached through the task that holds it.
    let store = makeStore(
      worktree: worktree,
      seeding: { $0.seedTask(worktree.layoutID, on: worktree.id, tabID: session.tabID, surfaceID: session.surfaceID) },
      configure: {
        $0.terminalClient.listSurfaces = { [session] }
        $0.terminalClient.focusSurface = { _, _, _, surfaceID in focused.setValue(surfaceID) }
      })

    await store.send(.setTerminalGridPresented(true))
    await store.send(
      .terminalGridJumpToSurface(
        worktreeID: worktree.id,
        tabID: session.tabID,
        surfaceID: session.surfaceID
      )
    )
    await store.finish()

    #expect(!store.state.isTerminalGridPresented)
    #expect(focused.value == session.surfaceID)
  }

  @Test(.dependencies) func closeTabUsesTerminalClientClosePath() async {
    let worktree = makeWorktree()
    let tabID = TabID()
    let closed = LockIsolated<TabID?>(nil)
    let store = makeStore(
      worktree: worktree, seeding: { $0.seedTask(worktree.layoutID, on: worktree.id, tabID: tabID) },
      configure: { $0.terminalClient.closeTab = { _, tabID in closed.setValue(tabID) } })

    await store.send(.closeTerminalTab(worktreeID: worktree.id, tabID: tabID))
    await store.finish()

    #expect(closed.value == tabID)
  }

  @Test(.dependencies) func layoutSeamReadsBackToTheRosterWorktree() throws {
    let worktree = makeWorktree()
    let state = makeStore(worktree: worktree) { _ in }.state

    let layoutID = try #require(state.layoutID(forDirectory: worktree.id))
    #expect(state.worktree(forLayout: layoutID)?.id == worktree.id)
    // A directory with no task resolves to nothing; a layout no record names has no worktree.
    #expect(state.layoutID(forDirectory: "/tmp/repo/unknown") == nil)
    #expect(state.worktree(forLayout: LayoutID(task: UUID())) == nil)
  }

  @Test(.dependencies) func layoutSeamResolvesToTheDirectorysMostRecentlySelectedTask() {
    let worktree = makeWorktree()
    var state = makeStore(worktree: worktree) { _ in }.state
    let taskID = LayoutID(task: UUID())
    state.seedTask(taskID, on: worktree.id)
    #expect(state.layoutID(forDirectory: worktree.id) == worktree.id.layoutID, "the own-key task first")

    state.terminals.activeTasks[worktree.id] = taskID
    #expect(state.layoutID(forDirectory: worktree.id) == taskID)
    #expect(state.worktree(forLayout: taskID)?.id == worktree.id)
  }

  @Test(.dependencies) func hydratedLayoutReadsItsDirectoryFromTheTaskRecord() {
    let worktree = makeWorktree()
    var state = makeStore(worktree: worktree) { _ in }.state
    // A task id says nothing about the directory; the record does.
    let taskID = LayoutID(task: UUID())
    state.terminals.directories[taskID] = TaskRecord.Directory(worktreeID: worktree.id)
    #expect(state.worktree(forLayout: taskID)?.id == worktree.id)

    let orphanID = LayoutID(task: UUID())
    state.terminals.directories[orphanID] = TaskRecord.Directory(worktreeID: "/tmp/repo/unknown")
    #expect(state.worktree(forLayout: orphanID) == nil)
  }

  @Test(.dependencies) func initialTabOfALayoutOutsideTheRosterSettlesNothing() async {
    let worktree = makeWorktree()
    let store = makeStore(worktree: worktree) { _ in }
    store.exhaustivity = .on

    await store.send(.terminalEvent(.tabCreated(layoutID: "/tmp/repo/unknown")))
  }

  private func makeStore(
    worktree: Worktree,
    seeding: (inout AppFeature.State) -> Void = { _ in },
    configure: (inout DependencyValues) -> Void
  ) -> TestStoreOf<AppFeature> {
    var repositories = RepositoriesFeature.State()
    repositories.repositories = [
      Repository(
        id: "/tmp/repo",
        rootURL: URL(fileURLWithPath: "/tmp/repo"),
        name: "repo",
        worktrees: IdentifiedArray(uniqueElements: [worktree])
      )
    ]
    repositories.selection = .worktree(worktree.id)
    repositories.isInitialLoadComplete = true
    var initial = AppFeature.State.seeded(
      repositories: repositories, settings: SettingsFeature.State(), ownKeyTaskOn: worktree)
    seeding(&initial)
    let store = TestStore(initialState: initial) {
      AppFeature()
    } withDependencies: {
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      configure(&$0)
    }
    store.exhaustivity = .off
    return store
  }

  private func makeSession(worktree: Worktree) -> TerminalSession {
    TerminalSession(
      layoutID: worktree.layoutID,
      worktreeID: worktree.id,
      worktreeName: worktree.name,
      directoryName: worktree.workingDirectory.lastPathComponent,
      tabID: TabID(),
      tabTitle: "agent",
      surfaceID: UUID(),
      availability: .live,
      isFocused: false
    )
  }

  private func makeWorktree() -> Worktree {
    Worktree(
      id: "/tmp/repo/wt-1",
      name: "wt-1",
      detail: "detail",
      workingDirectory: URL(fileURLWithPath: "/tmp/repo/wt-1"),
      repositoryRootURL: URL(fileURLWithPath: "/tmp/repo")
    )
  }
}

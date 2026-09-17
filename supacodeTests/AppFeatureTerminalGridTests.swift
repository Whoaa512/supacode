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
    let store = makeStore(worktree: worktree) {
      $0.terminalClient.listSurfaces = { [session] }
      $0.terminalClient.focusSurface = { _, _, surfaceID in focused.setValue(surfaceID) }
    }

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
    let store = makeStore(worktree: worktree) {
      $0.terminalClient.closeTab = { _, tabID in closed.setValue(tabID) }
    }

    await store.send(.closeTerminalTab(worktreeID: worktree.id, tabID: tabID))
    await store.finish()

    #expect(closed.value == tabID)
  }

  private func makeStore(
    worktree: Worktree,
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
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: repositories,
        settings: SettingsFeature.State()
      )
    ) {
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

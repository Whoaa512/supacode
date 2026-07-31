import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import Testing

@testable import SupacodeSettingsFeature
@testable import SupacodeSettingsShared
@testable import supacode

@MainActor
struct AppFeatureTerminalSessionBrowserTests {
  @Test(.dependencies) func focusSelectsWorktreeAndFocusesSurface() async {
    let worktree = makeWorktree()
    let tabID = TerminalTabID(rawValue: UUID())
    let surfaceID = UUID()
    let sent = LockIsolated<[TerminalClient.Command]>([])
    let store = makeStore(worktree: worktree) {
      $0.terminalClient.send = { command in
        sent.withValue { $0.append(command) }
      }
    }

    await store.send(
      .focusTerminalSurface(worktreeID: worktree.id, tabID: tabID, surfaceID: surfaceID))
    await store.receive(\.repositories.selectWorktree)
    await store.finish()

    let focusCommands = sent.value.filter {
      if case .focusSurface = $0 { return true } else { return false }
    }
    #expect(focusCommands == [.focusSurface(worktree, tabID: tabID, surfaceID: surfaceID, input: nil)])
  }

  @Test(.dependencies) func closeSendsDestroySurface() async {
    let worktree = makeWorktree()
    let tabID = TerminalTabID(rawValue: UUID())
    let surfaceID = UUID()
    let sent = LockIsolated<[TerminalClient.Command]>([])
    let store = makeStore(worktree: worktree) {
      $0.terminalClient.send = { command in
        sent.withValue { $0.append(command) }
      }
    }

    await store.send(
      .closeTerminalSurface(worktreeID: worktree.id, tabID: tabID, surfaceID: surfaceID))
    await store.finish()

    #expect(sent.value == [.destroySurface(worktree, tabID: tabID, surfaceID: surfaceID)])
  }

  @Test(.dependencies) func focusAndCloseDropWhenWorktreeMissing() async {
    let worktree = makeWorktree()
    let missingID = WorktreeID("/tmp/repo/does-not-exist")
    let sent = LockIsolated<[TerminalClient.Command]>([])
    let store = makeStore(worktree: worktree) {
      $0.terminalClient.send = { command in
        sent.withValue { $0.append(command) }
      }
    }

    await store.send(
      .focusTerminalSurface(worktreeID: missingID, tabID: TerminalTabID(rawValue: UUID()), surfaceID: UUID()))
    await store.send(
      .closeTerminalSurface(worktreeID: missingID, tabID: TerminalTabID(rawValue: UUID()), surfaceID: UUID()))
    await store.finish()

    #expect(sent.value.isEmpty)
  }

  // MARK: - Helpers.

  private func makeWorktree(
    id: String = "/tmp/repo/wt-1",
    name: String = "wt-1"
  ) -> Worktree {
    Worktree(
      id: WorktreeID(id),
      name: name,
      detail: "detail",
      workingDirectory: URL(fileURLWithPath: id),
      repositoryRootURL: URL(fileURLWithPath: "/tmp/repo"),
    )
  }

  private func makeStore(
    worktree: Worktree,
    withAdditionalDependencies: (inout DependencyValues) -> Void
  ) -> TestStoreOf<AppFeature> {
    var repositoriesState = RepositoriesFeature.State()
    let repository = Repository(
      id: "/tmp/repo",
      rootURL: URL(fileURLWithPath: "/tmp/repo"),
      name: "repo",
      worktrees: [worktree],
    )
    repositoriesState.repositories = [repository]
    repositoriesState.selection = .worktree(worktree.id)
    repositoriesState.isInitialLoadComplete = true

    let store = TestStore(
      initialState: AppFeature.State(
        repositories: repositoriesState,
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    } withDependencies: { values in
      values.terminalClient.tabExists = { _, _ in true }
      values.terminalClient.surfaceExists = { _, _, _ in true }
      withAdditionalDependencies(&values)
    }
    store.exhaustivity = .off
    return store
  }
}

// Serialized: spins real GhosttyRuntime surfaces like the other terminal suites.
@MainActor
@Suite(.serialized)
struct TerminalSessionOverviewTests {
  private func makeWorktree(id: String, name: String) -> Worktree {
    Worktree(
      id: WorktreeID(id),
      name: name,
      detail: "detail",
      workingDirectory: URL(fileURLWithPath: id),
      repositoryRootURL: URL(fileURLWithPath: "/tmp/repo")
    )
  }

  @Test func overviewListsSurfacesGroupedByWorktreeSortedByName() {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let zebra = makeWorktree(id: "/tmp/repo/zebra", name: "zebra")
    let alpha = makeWorktree(id: "/tmp/repo/alpha", name: "alpha")
    let zebraState = manager.state(for: zebra)
    let alphaState = manager.state(for: alpha)
    _ = zebraState.createTab(focusing: false)
    _ = alphaState.createTab(focusing: false)
    _ = alphaState.createTab(focusing: false)

    let overviews = manager.sessionOverviews()

    #expect(overviews.map(\.name) == ["alpha", "zebra"])
    #expect(overviews.first?.tabs.count == 2)
    #expect(overviews.last?.tabs.count == 1)
    #expect(overviews.allSatisfy { $0.tabs.allSatisfy { !$0.surfaces.isEmpty } })

    zebraState.closeAllSurfaces()
    alphaState.closeAllSurfaces()
  }

  @Test func overviewSkipsWorktreesWithoutSurfaces() {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree(id: "/tmp/repo/bare", name: "bare")
    _ = manager.state(for: worktree)

    #expect(manager.sessionOverviews().isEmpty)
  }
}

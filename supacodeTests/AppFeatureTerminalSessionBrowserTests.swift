import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import IdentifiedCollections
import Testing

@testable import SupacodeSettingsFeature
@testable import supacode

@MainActor
struct AppFeatureTerminalSessionBrowserTests {
  private enum Call: Equatable {
    case focus(Worktree, TabID, UUID)
    case close(Worktree, TabID, UUID)
  }

  @Test(.dependencies) func focusSelectsWorktreeAndFocusesSurface() async {
    let worktree = makeWorktree()
    let tabID = TabID()
    let surfaceID = UUID()
    let calls = LockIsolated<[Call]>([])
    let store = makeStore(worktree: worktree) {
      $0.terminalClient.focusSurface = { worktree, tabID, surfaceID in
        calls.withValue { $0.append(.focus(worktree, tabID, surfaceID)) }
      }
    }

    await store.send(
      .focusTerminalSurface(worktreeID: worktree.id, tabID: tabID, surfaceID: surfaceID))
    await store.finish()

    #expect(calls.value == [.focus(worktree, tabID, surfaceID)])
  }

  @Test(.dependencies) func closeUsesTerminalClientClosePath() async {
    let worktree = makeWorktree()
    let tabID = TabID()
    let surfaceID = UUID()
    let calls = LockIsolated<[Call]>([])
    let store = makeStore(worktree: worktree) {
      $0.terminalClient.closeSurface = { worktree, tabID, surfaceID in
        calls.withValue { $0.append(.close(worktree, tabID, surfaceID)) }
      }
    }

    await store.send(
      .closeTerminalSurface(worktreeID: worktree.id, tabID: tabID, surfaceID: surfaceID))
    await store.finish()

    #expect(calls.value == [.close(worktree, tabID, surfaceID)])
  }

  @Test(.dependencies) func missingWorktreeDropsFocusAndClose() async {
    let called = LockIsolated(false)
    let store = makeStore(worktree: makeWorktree()) {
      $0.terminalClient.focusSurface = { _, _, _ in called.setValue(true) }
      $0.terminalClient.closeSurface = { _, _, _ in called.setValue(true) }
    }
    let missingID = WorktreeID("/tmp/repo/missing")

    await store.send(
      .focusTerminalSurface(worktreeID: missingID, tabID: TabID(), surfaceID: UUID()))
    await store.send(
      .closeTerminalSurface(worktreeID: missingID, tabID: TabID(), surfaceID: UUID()))

    #expect(!called.value)
  }

  @Test(.dependencies) func managerEnumeratesHydratedSnapshotSessions() {
    let alpha = makeWorktree(id: "/tmp/repo/alpha", name: "alpha")
    let zebra = makeWorktree(id: "/tmp/repo/zebra", name: "zebra")
    var appState = AppFeature.State(
      repositories: makeRepositoriesState(worktrees: [zebra, alpha]),
      settings: SettingsFeature.State()
    )
    let alphaSurface = UUID()
    appState.terminals.layouts = [
      makeLayoutState(worktree: zebra, surfaceID: UUID()),
      makeLayoutState(worktree: alpha, surfaceID: alphaSurface),
    ]
    let store = Store(initialState: appState) { AppFeature() }
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    manager.appStore = store

    let sessions = manager.terminalSessions()

    #expect(sessions.map(\.worktreeName) == ["alpha", "zebra"])
    #expect(sessions.first?.surfaceID == alphaSurface)
    #expect(sessions.allSatisfy { $0.availability == .snapshot })
    #expect(sessions.allSatisfy { !$0.isFocused })
  }

  private func makeStore(
    worktree: Worktree,
    configure: (inout DependencyValues) -> Void
  ) -> TestStoreOf<AppFeature> {
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: makeRepositoriesState(worktrees: [worktree]),
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

  private func makeRepositoriesState(worktrees: [Worktree]) -> RepositoriesFeature.State {
    let repository = Repository(
      id: "/tmp/repo",
      rootURL: URL(fileURLWithPath: "/tmp/repo"),
      name: "repo",
      worktrees: IdentifiedArray(uniqueElements: worktrees)
    )
    var state = RepositoriesFeature.State()
    state.repositories = [repository]
    state.selection = worktrees.first.map { .worktree($0.id) }
    state.isInitialLoadComplete = true
    return state
  }

  private func makeLayoutState(worktree: Worktree, surfaceID: UUID) -> LayoutFeature.State {
    let tab = TabItem(
      id: TabID(),
      title: "\(worktree.name) tab",
      content: ContentSnapshot(
        id: ContentID(rawValue: surfaceID),
        state: .terminal(TerminalContentState(workingDirectory: nil))
      )
    )
    let pane = Pane(id: PaneID(), tabs: [tab], selectedTabID: tab.id)
    return LayoutFeature.State(
      id: worktree.id,
      layout: PaneLayout(
        tree: SplitTree(view: pane.id),
        panes: [pane],
        focusedPaneID: pane.id
      )
    )
  }

  private func makeWorktree(id: String = "/tmp/repo/wt-1", name: String = "wt-1") -> Worktree {
    Worktree(
      id: WorktreeID(id),
      name: name,
      detail: "detail",
      workingDirectory: URL(fileURLWithPath: id),
      repositoryRootURL: URL(fileURLWithPath: "/tmp/repo")
    )
  }
}

import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import Testing

@testable import SupacodeSettingsFeature
@testable import SupacodeSettingsShared
@testable import supacode

@MainActor
struct AppFeatureCommandCenterTests {
  @Test(.dependencies) func sendInputToExistingTabFocusesSurface() async {
    let worktree = makeWorktree()
    let repositories = makeRepositoriesState(worktree: worktree)
    let tabID = UUID()
    let sent = LockIsolated<[TerminalClient.Command]>([])
    let store = TestStore(
      initialState: AppFeature.State(repositories: repositories, settings: SettingsFeature.State())
    ) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.send = { command in
        sent.withValue { $0.append(command) }
      }
      $0.terminalClient.tabExists = { _, _ in true }
    }
    store.exhaustivity = .off

    await store.send(
      .commandCenter(
        .delegate(.sendInputToTab(worktreeID: worktree.id, tabID: tabID, surfaceID: nil, input: "verify"))
      )
    )
    await store.finish()

    #expect(
      sent.value == [
        .focusSurface(worktree, tabID: TerminalTabID(rawValue: tabID), surfaceID: tabID, input: "verify")
      ]
    )
  }

  @Test(.dependencies) func sendInputToMissingTabCreatesNewTab() async {
    let worktree = makeWorktree()
    let repositories = makeRepositoriesState(worktree: worktree)
    let sent = LockIsolated<[TerminalClient.Command]>([])
    let store = TestStore(
      initialState: AppFeature.State(repositories: repositories, settings: SettingsFeature.State())
    ) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.send = { command in
        sent.withValue { $0.append(command) }
      }
      $0.terminalClient.tabExists = { _, _ in false }
    }
    store.exhaustivity = .off

    await store.send(
      .commandCenter(
        .delegate(.sendInputToTab(worktreeID: worktree.id, tabID: UUID(), surfaceID: nil, input: "verify"))
      )
    )
    await store.finish()

    #expect(
      sent.value == [
        .createTabWithInput(worktree, input: "verify", runSetupScriptIfNew: false)
      ]
    )
  }

  private func makeWorktree() -> Worktree {
    let repositoryRootURL = URL(fileURLWithPath: "/tmp/repo-\(UUID().uuidString)")
    let worktreeURL = repositoryRootURL.appending(path: "wt-1")
    return Worktree(
      id: worktreeURL.path(percentEncoded: false),
      name: "wt-1",
      detail: "detail",
      workingDirectory: worktreeURL,
      repositoryRootURL: repositoryRootURL
    )
  }

  private func makeRepositoriesState(worktree: Worktree) -> RepositoriesFeature.State {
    let repository = Repository(
      id: worktree.repositoryRootURL.path(percentEncoded: false),
      rootURL: worktree.repositoryRootURL,
      name: "repo",
      worktrees: [worktree]
    )
    var repositoriesState = RepositoriesFeature.State()
    repositoriesState.repositories = [repository]
    repositoriesState.selection = .worktree(worktree.id)
    return repositoriesState
  }
}

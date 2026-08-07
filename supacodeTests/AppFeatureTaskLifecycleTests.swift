import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import IdentifiedCollections
import Testing

@testable import SupacodeSettingsFeature
@testable import SupacodeSettingsShared
@testable import supacode

/// The task-inbox half that only exists in `AppFeature`: the surfaces→tabs
/// translation behind assertion A7, and the terminal-selection side effects of
/// opening a task row. `RepositoriesFeatureTasksTests` owns everything the
/// reducer can assert on its own.
@MainActor
struct AppFeatureTaskLifecycleTests {
  private static let rootURL = URL(fileURLWithPath: "/tmp/repo")

  private static func makeWorktree(_ name: String) -> Worktree {
    Worktree(
      id: WorktreeID("/tmp/repo/\(name)"),
      name: name,
      detail: "",
      workingDirectory: URL(fileURLWithPath: "/tmp/repo/\(name)"),
      repositoryRootURL: rootURL
    )
  }

  private static func makeRepositoriesState(_ worktrees: [Worktree]) -> RepositoriesFeature.State {
    let repository = Repository(
      id: RepositoryID(rootURL.path(percentEncoded: false)),
      rootURL: rootURL,
      name: "repo",
      worktrees: IdentifiedArray(uniqueElements: worktrees)
    )
    return RepositoriesFeature.State(reconciledRepositories: [repository])
  }

  private static func makeRecord(
    worktree: Worktree,
    surfaceIDs: Set<UUID>,
    settledAt: Date? = nil
  ) -> TaskRecord {
    TaskRecord(
      title: worktree.name,
      directoryPath: TaskDirectoryPath.normalized(worktree.workingDirectory.path(percentEncoded: false)),
      createdAt: Date(timeIntervalSince1970: 1_700_000_000),
      settledAt: settledAt,
      surfaceIDs: surfaceIDs
    )
  }

  /// A7's adversarial case: two tasks' surfaces are split across panes of ONE
  /// tab. Hibernating that tab would take the other task's session down with it,
  /// so the protected-surface subtraction must empty the target set entirely.
  @Test(.dependencies) func hibernateTargetsAreEmptyWhenOneTabHoldsAnotherTasksSurface() async {
    let worktree = Self.makeWorktree("shared")
    let mySurface = UUID()
    let theirSurface = UUID()
    let sharedTab = TerminalTabID(rawValue: UUID())
    let appState = AppFeature.State(
      repositories: Self.makeRepositoriesState([worktree]),
      settings: SettingsFeature.State()
    )
    let sentCommands = LockIsolated<[TerminalClient.Command]>([])
    let store = TestStore(initialState: appState) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.tabID = { _, surfaceID in
        // Both surfaces live in the same tab (split panes).
        [mySurface, theirSurface].contains(surfaceID) ? sharedTab : nil
      }
      $0.terminalClient.send = { command in
        sentCommands.withValue { $0.append(command) }
      }
      $0.worktreeInfoWatcher.send = { _ in }
    }
    store.exhaustivity = .off

    await store.send(
      .repositories(
        .delegate(
          .hibernateTaskSurfaces(
            worktreeID: worktree.id,
            surfaceIDs: [mySurface],
            protectedSurfaceIDs: [theirSurface]
          )
        )
      )
    )
    await store.finish()

    // Nothing was sent at all: the only candidate tab was protected.
    #expect(sentCommands.value.isEmpty)
  }

  /// The non-adversarial control: a tab holding only this task's surface does
  /// hibernate, so the assertion above is not passing because the whole path is
  /// inert.
  @Test(.dependencies) func hibernateTargetsTheTaskOwnTabWhenNothingIsProtected() async {
    let worktree = Self.makeWorktree("mine")
    let mySurface = UUID()
    let myTab = TerminalTabID(rawValue: UUID())
    let appState = AppFeature.State(
      repositories: Self.makeRepositoriesState([worktree]),
      settings: SettingsFeature.State()
    )
    let sentCommands = LockIsolated<[TerminalClient.Command]>([])
    let store = TestStore(initialState: appState) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.tabID = { _, surfaceID in surfaceID == mySurface ? myTab : nil }
      $0.terminalClient.send = { command in
        sentCommands.withValue { $0.append(command) }
      }
      $0.worktreeInfoWatcher.send = { _ in }
    }
    store.exhaustivity = .off

    await store.send(
      .repositories(
        .delegate(
          .hibernateTaskSurfaces(
            worktreeID: worktree.id,
            surfaceIDs: [mySurface],
            protectedSurfaceIDs: []
          )
        )
      )
    )
    await store.finish()

    #expect(sentCommands.value == [.hibernateTabs(worktree, tabIDs: [myTab])])
  }

  /// M5: a task selection clears the worktree selection, and a nil terminal
  /// selection arms the hibernation grace timer on every tab of the owning
  /// worktree — including the tab the click just focused. The manager must be
  /// pointed at the owning worktree instead. A11 rides along: `sidebar.json`'s
  /// `focusedWorktreeID` stays put (twin of the archived-selection case).
  @Test(.dependencies) func selectingATaskPointsTheTerminalManagerAtItsOwningWorktree() async {
    let worktree = Self.makeWorktree("mine")
    let surfaceID = UUID()
    var repositoriesState = Self.makeRepositoriesState([worktree])
    let record = Self.makeRecord(worktree: worktree, surfaceIDs: [surfaceID])
    repositoriesState.taskRecords = [record]
    repositoriesState.selection = .worktree(worktree.id)
    repositoriesState.$sidebar.withLock { $0.focusedWorktreeID = worktree.id }
    let terminalCommands = LockIsolated<[TerminalClient.Command]>([])
    let watcherCommands = LockIsolated<[WorktreeInfoWatcherClient.Command]>([])
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: repositoriesState,
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.settingsFileStorage = .inMemory()
      $0.date.now = Date(timeIntervalSince1970: 1_800_000_000)
      $0.terminalClient.tabID = { _, _ in nil }
      $0.terminalClient.send = { command in
        terminalCommands.withValue { $0.append(command) }
      }
      $0.worktreeInfoWatcher.send = { command in
        watcherCommands.withValue { $0.append(command) }
      }
    }
    store.exhaustivity = .off

    await store.send(.repositories(.selectionChanged([.task(record.id)])))
    await store.receive(\.repositories.delegate.selectedWorktreeChanged)
    await store.finish()

    #expect(store.state.repositories.selection == .task(record.id))
    #expect(terminalCommands.value.contains(.setSelectedWorktreeID(worktree.id)))
    // The info watcher is not a task concern: a task selection is not a worktree visit.
    #expect(watcherCommands.value == [.setSelectedWorktreeID(nil)])
    // A11 twin: the persisted sidebar focus is untouched.
    #expect(store.state.repositories.sidebar.focusedWorktreeID == worktree.id)
  }

  /// A settled task owns no live sessions worth keeping awake, so browsing the
  /// settled tail must not resurrect a terminal selection.
  @Test(.dependencies) func selectingASettledTaskLeavesTheTerminalSelectionNil() async {
    let worktree = Self.makeWorktree("mine")
    var repositoriesState = Self.makeRepositoriesState([worktree])
    let record = Self.makeRecord(
      worktree: worktree,
      surfaceIDs: [UUID()],
      settledAt: Date(timeIntervalSince1970: 1_700_000_100)
    )
    repositoriesState.taskRecords = [record]
    repositoriesState.selection = .worktree(worktree.id)
    let terminalCommands = LockIsolated<[TerminalClient.Command]>([])
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: repositoriesState,
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.settingsFileStorage = .inMemory()
      $0.date.now = Date(timeIntervalSince1970: 1_800_000_000)
      $0.terminalClient.send = { command in
        terminalCommands.withValue { $0.append(command) }
      }
      $0.worktreeInfoWatcher.send = { _ in }
    }
    store.exhaustivity = .off

    await store.send(.repositories(.selectionChanged([.task(record.id)])))
    await store.receive(\.repositories.delegate.selectedWorktreeChanged)
    await store.finish()

    #expect(terminalCommands.value == [.setSelectedWorktreeID(nil)])
  }
}

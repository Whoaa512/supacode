import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import Sharing
import Testing

@testable import SupacodeSettingsFeature
@testable import SupacodeSettingsShared
@testable import supacode

/// ⌘N is one shortcut with two meanings (A19), so the menu bar has to say which
/// one it currently is and must never grey out task capture with the worktree
/// gate. The label lives on `WorktreeMenuSnapshot`, which only recomputes on
/// actions the gate classifies as snapshot-affecting — so these tests pin both
/// the value and the fact that swapping panels reaches it.
@MainActor
struct AppFeatureTaskMenuTests {
  @Test(.dependencies, .sidebarTab(.tasks))
  func snapshotCarriesTheActivePanel() {
    let state = AppFeature.State()

    #expect(state.computeWorktreeMenuSnapshot().activeSidebarTab == .tasks)
  }

  /// The segmented picker's write. It goes through the reducer precisely so the
  /// snapshot gate can see it; a view-only write to `@Shared(.sidebarTab)` would
  /// leave the menu claiming "New Worktree…" over the open inbox.
  @Test(.dependencies, .sidebarTab(.worktrees))
  func pickerSwitchRefreshesTheMenuSnapshot() async {
    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    }
    store.exhaustivity = .off
    #expect(store.state.worktreeMenuSnapshot.activeSidebarTab == .worktrees)

    await store.send(.repositories(.setSidebarTab(.tasks)))

    #expect(store.state.worktreeMenuSnapshot.activeSidebarTab == .tasks)
  }

  /// ⌘⇧T takes the same path. Both tab writers invalidate no cache, which is
  /// exactly why the gate names them instead of reading `cacheInvalidations`.
  @Test(.dependencies, .sidebarTab(.worktrees))
  func tasksToggleRefreshesTheMenuSnapshot() async {
    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    }
    store.exhaustivity = .off

    await store.send(.repositories(.toggleTasksSidebarTab))

    #expect(store.state.worktreeMenuSnapshot.activeSidebarTab == .tasks)
  }

  /// A no-op pick writes nothing, so the segmented control can re-report the
  /// current tab without churning app storage.
  @Test(.dependencies, .sidebarTab(.tasks))
  func settingTheAlreadyActiveTabIsANoOp() async {
    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    }
    store.exhaustivity = .off

    await store.send(.repositories(.setSidebarTab(.tasks)))

    #expect(store.state.worktreeMenuSnapshot.activeSidebarTab == .tasks)
  }

  /// The one place the label and the reducer's routing agree. A9: the Agents
  /// panel is unchanged, so ⌘N there still means "new worktree".
  @Test func onlyTheInboxTurnsNewIntoCapture() {
    #expect(SidebarTab.tasks.newItemCapturesTask)
    #expect(!SidebarTab.worktrees.newItemCapturesTask)
    #expect(!SidebarTab.agents.newItemCapturesTask)
  }
}

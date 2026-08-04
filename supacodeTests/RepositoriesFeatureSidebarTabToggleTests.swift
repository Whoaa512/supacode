import ComposableArchitecture
import Sharing
import Testing

@testable import supacode

/// Locks the ⌘⇧A sidebar-tab toggle: `.toggleAgentsSidebarTab` jumps to the
/// Agents panel and, when already there, returns to Worktrees. The selection
/// lives in `@Shared(.sidebarTab)` app storage, so each test scopes
/// `defaultAppStorage = .inMemory` to keep writes out of the shared suite.
@MainActor
struct RepositoriesFeatureSidebarTabToggleTests {
  private func makeStore() -> TestStoreOf<RepositoriesFeature> {
    TestStore(initialState: RepositoriesFeature.State()) {
      RepositoriesFeature()
    }
  }

  @Test func togglingFromWorktreesSelectsAgents() async {
    await withDependencies {
      $0.defaultAppStorage = .inMemory
    } operation: {
      @Shared(.sidebarTab) var tab
      $tab.withLock { $0 = SidebarTab.worktrees.rawValue }

      await makeStore().send(.toggleAgentsSidebarTab)

      #expect(tab == SidebarTab.agents.rawValue)
    }
  }

  @Test func togglingFromAgentsReturnsToWorktrees() async {
    await withDependencies {
      $0.defaultAppStorage = .inMemory
    } operation: {
      @Shared(.sidebarTab) var tab
      $tab.withLock { $0 = SidebarTab.agents.rawValue }

      await makeStore().send(.toggleAgentsSidebarTab)

      #expect(tab == SidebarTab.worktrees.rawValue)
    }
  }

  @Test func togglingTwiceRoundTripsBackToWorktrees() async {
    await withDependencies {
      $0.defaultAppStorage = .inMemory
    } operation: {
      @Shared(.sidebarTab) var tab
      $tab.withLock { $0 = SidebarTab.worktrees.rawValue }
      let store = makeStore()

      await store.send(.toggleAgentsSidebarTab)
      await store.send(.toggleAgentsSidebarTab)

      #expect(tab == SidebarTab.worktrees.rawValue)
    }
  }

  /// A garbage persisted value must not strand the toggle: it falls back to
  /// `worktrees`, so the first press still lands on Agents.
  @Test func unknownPersistedTabTogglesToAgents() async {
    await withDependencies {
      $0.defaultAppStorage = .inMemory
    } operation: {
      @Shared(.sidebarTab) var tab
      $tab.withLock { $0 = "not-a-tab" }

      await makeStore().send(.toggleAgentsSidebarTab)

      #expect(tab == SidebarTab.agents.rawValue)
    }
  }
}

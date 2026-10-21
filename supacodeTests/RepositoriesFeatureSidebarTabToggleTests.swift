import ComposableArchitecture
import Sharing
import Testing

@testable import supacode

/// Locks the ⌘⇧A sidebar-panel chord: `.cycleSidebarTab` advances through
/// `SidebarTab.allCases` and wraps, so every panel is reachable from any other.
/// The selection lives in `@Shared(.sidebarTab)` app storage, so each test
/// scopes `defaultAppStorage = .inMemory` to keep writes out of the shared suite.
@MainActor
struct RepositoriesFeatureSidebarTabToggleTests {
  private func makeStore() -> TestStoreOf<RepositoriesFeature> {
    TestStore(initialState: RepositoriesFeature.State()) {
      RepositoriesFeature()
    }
  }

  @Test func cyclingFromSessionsSelectsWorktrees() async {
    await withDependencies {
      $0.defaultAppStorage = .inMemory
    } operation: {
      @Shared(.sidebarTab) var tab
      $tab.withLock { $0 = SidebarTab.sessions.rawValue }

      await makeStore().send(.cycleSidebarTab)

      #expect(tab == SidebarTab.worktrees.rawValue)
    }
  }

  @Test func cyclingFromLastPanelWrapsToFirst() async {
    await withDependencies {
      $0.defaultAppStorage = .inMemory
    } operation: {
      @Shared(.sidebarTab) var tab
      $tab.withLock { $0 = SidebarTab.allCases.last!.rawValue }

      await makeStore().send(.cycleSidebarTab)

      #expect(tab == SidebarTab.allCases.first!.rawValue)
    }
  }

  @Test func cyclingVisitsEveryPanelOnce() async {
    await withDependencies {
      $0.defaultAppStorage = .inMemory
    } operation: {
      @Shared(.sidebarTab) var tab
      $tab.withLock { $0 = SidebarTab.sessions.rawValue }
      let store = makeStore()
      var visited: [String] = [tab]

      for _ in 1..<SidebarTab.allCases.count {
        await store.send(.cycleSidebarTab)
        visited.append(tab)
      }

      #expect(Set(visited).count == SidebarTab.allCases.count)
    }
  }

  /// The retired `agents` panel, or any garbage value, resolves to Sessions
  /// everywhere, so the first press lands on Worktrees.
  @Test func retiredPersistedTabResolvesToSessionsThenCycles() async {
    await withDependencies {
      $0.defaultAppStorage = .inMemory
    } operation: {
      @Shared(.sidebarTab) var tab
      $tab.withLock { $0 = "agents" }
      let store = makeStore()

      #expect(SidebarTab.stored(tab) == .sessions)
      #expect(store.state.isSessionsSidebarTabActive)

      await store.send(.cycleSidebarTab)

      #expect(tab == SidebarTab.worktrees.rawValue)
    }
  }
}

import ComposableArchitecture
import Sharing
import Testing

@testable import SupacodeSettingsShared
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

  // MARK: - ⌘⇧T Tasks toggle

  @Test func togglingTasksFromWorktreesSelectsTasks() async {
    await withDependencies {
      $0.defaultAppStorage = .inMemory
    } operation: {
      @Shared(.sidebarTab) var tab
      $tab.withLock { $0 = SidebarTab.worktrees.rawValue }

      await makeStore().send(.toggleTasksSidebarTab)

      #expect(tab == SidebarTab.tasks.rawValue)
    }
  }

  /// Same chord semantics as ⌘⇧A: from Agents it jumps to Tasks, not back to
  /// Worktrees.
  @Test func togglingTasksFromAgentsSelectsTasks() async {
    await withDependencies {
      $0.defaultAppStorage = .inMemory
    } operation: {
      @Shared(.sidebarTab) var tab
      $tab.withLock { $0 = SidebarTab.agents.rawValue }

      await makeStore().send(.toggleTasksSidebarTab)

      #expect(tab == SidebarTab.tasks.rawValue)
    }
  }

  @Test func togglingTasksFromTasksReturnsToWorktrees() async {
    await withDependencies {
      $0.defaultAppStorage = .inMemory
    } operation: {
      @Shared(.sidebarTab) var tab
      $tab.withLock { $0 = SidebarTab.tasks.rawValue }

      await makeStore().send(.toggleTasksSidebarTab)

      #expect(tab == SidebarTab.worktrees.rawValue)
    }
  }

  /// Tasks is the home panel: with nothing persisted, the sidebar opens on the
  /// inbox.
  @Test func freshInstallDefaultsToTasksTab() async {
    await withDependencies {
      $0.defaultAppStorage = .inMemory
    } operation: {
      @Shared(.sidebarTab) var tab

      #expect(SidebarTab.resolved(fromStoredValue: tab) == .tasks)
    }
  }

  // MARK: - A36: hidden tabs

  /// Tasks is the floor. A36 asks for "≥1 tab always reachable", and making the
  /// inbox structurally un-hideable is a stronger answer than a runtime guard
  /// that has to be remembered at every call site.
  @Test func tasksIsAlwaysVisibleAndOrderIsPreserved() {
    #expect(SidebarTab.visibleCases(.all) == SidebarTab.allCases)
    #expect(SidebarTab.visibleCases(.init(showsWorktrees: false, showsAgents: true)) == [.agents, .tasks])
    #expect(
      SidebarTab.visibleCases(.init(showsWorktrees: true, showsAgents: false)) == [.worktrees, .tasks]
    )
    #expect(SidebarTab.visibleCases(.init(showsWorktrees: false, showsAgents: false)) == [.tasks])
  }

  /// Hiding the tab you are standing on must not leave the sidebar blank — the
  /// unknown-value fallback's rule, applied to a tab that exists but is hidden.
  @Test func aHiddenPersistedTabResolvesToTasks() {
    #expect(
      SidebarTab.resolved(
        fromStoredValue: SidebarTab.agents.rawValue,
        visibility: .init(showsWorktrees: true, showsAgents: false)
      ) == .tasks
    )
    #expect(
      SidebarTab.resolved(
        fromStoredValue: SidebarTab.worktrees.rawValue,
        visibility: .init(showsWorktrees: false, showsAgents: true)
      ) == .tasks
    )
    // A visible tab is left exactly where it is.
    #expect(
      SidebarTab.resolved(fromStoredValue: SidebarTab.agents.rawValue, visibility: .all) == .agents
    )
  }

  /// ⌘⇧A with Agents hidden unhides it and goes there. The alternative — a
  /// chord that silently does nothing — leaves the user pressing a key that the
  /// menu still advertises, with no clue why it is inert.
  @Test func theAgentsChordUnhidesTheTabItAsksFor() async {
    await withDependencies {
      $0.defaultAppStorage = .inMemory
    } operation: {
      @Shared(.sidebarTab) var tab
      @Shared(.sidebarShowsAgentsTab) var showsAgents
      $tab.withLock { $0 = SidebarTab.tasks.rawValue }
      $showsAgents.withLock { $0 = false }

      await makeStore().send(.toggleAgentsSidebarTab)

      #expect(showsAgents)
      #expect(tab == SidebarTab.agents.rawValue)
    }
  }

  /// The return half of the chord can't land on a hidden tab either: with
  /// Worktrees hidden, leaving Agents falls through to the inbox.
  @Test func leavingAgentsSkipsAHiddenWorktreesTab() async {
    await withDependencies {
      $0.defaultAppStorage = .inMemory
    } operation: {
      @Shared(.sidebarTab) var tab
      @Shared(.sidebarShowsWorktreesTab) var showsWorktrees
      $tab.withLock { $0 = SidebarTab.agents.rawValue }
      $showsWorktrees.withLock { $0 = false }

      await makeStore().send(.toggleAgentsSidebarTab)

      // Hiding a tab is a preference, not a request to be taken there.
      #expect(showsWorktrees == false)
      #expect(tab == SidebarTab.tasks.rawValue)
    }
  }

  @Test func leavingTasksSkipsAHiddenWorktreesTab() async {
    await withDependencies {
      $0.defaultAppStorage = .inMemory
    } operation: {
      @Shared(.sidebarTab) var tab
      @Shared(.sidebarShowsWorktreesTab) var showsWorktrees
      $tab.withLock { $0 = SidebarTab.tasks.rawValue }
      $showsWorktrees.withLock { $0 = false }

      await makeStore().send(.toggleTasksSidebarTab)

      #expect(tab == SidebarTab.agents.rawValue)
    }
  }

  /// Both others hidden: ⌘⇧T has nowhere to go, and staying put beats blanking
  /// the sidebar.
  @Test func theTasksChordStaysPutWhenNothingElseIsVisible() async {
    await withDependencies {
      $0.defaultAppStorage = .inMemory
    } operation: {
      @Shared(.sidebarTab) var tab
      @Shared(.sidebarShowsWorktreesTab) var showsWorktrees
      @Shared(.sidebarShowsAgentsTab) var showsAgents
      $tab.withLock { $0 = SidebarTab.tasks.rawValue }
      $showsWorktrees.withLock { $0 = false }
      $showsAgents.withLock { $0 = false }

      await makeStore().send(.toggleTasksSidebarTab)

      #expect(tab == SidebarTab.tasks.rawValue)
    }
  }
}

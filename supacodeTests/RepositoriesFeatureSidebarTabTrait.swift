import ComposableArchitecture
import Sharing
import Testing

@testable import supacode

/// Pins the sidebar tab a suite exercises.
///
/// The active tab lives in `@Shared(.sidebarTab)` app storage, whose default is
/// `.tasks` now that Tasks is the home panel. The worktree-navigation reducer
/// arms (`selectNextWorktree`, `worktreeHistoryBack`, the hotkey slots, …)
/// deliberately beep instead of moving the selection on any tab but Worktrees,
/// so a suite that asserts worktree navigation has to state the tab it is
/// testing rather than inherit whatever the product default happens to be.
///
/// Each test gets a fresh in-memory `UserDefaults` so the pinned tab cannot leak
/// into suites running beside it.
struct SidebarTabTrait: SuiteTrait, TestTrait, TestScoping {
  let tab: SidebarTab

  var isRecursive: Bool { true }

  func provideScope(
    for test: Test,
    testCase: Test.Case?,
    performing function: @concurrent @Sendable () async throws -> Void
  ) async throws {
    try await withDependencies {
      $0.defaultAppStorage = .inMemory
    } operation: {
      @Shared(.sidebarTab) var sidebarTabRawValue
      $sidebarTabRawValue.withLock { $0 = tab.rawValue }
      try await function()
    }
  }
}

extension Trait where Self == SidebarTabTrait {
  static func sidebarTab(_ tab: SidebarTab) -> Self {
    SidebarTabTrait(tab: tab)
  }
}

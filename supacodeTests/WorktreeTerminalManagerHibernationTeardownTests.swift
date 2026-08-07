import Dependencies
import DependenciesTestSupport
import Foundation
import Sharing
import Testing

@testable import supacode

/// Hibernation must not free ghostty surfaces on its own turn: the free joins the
/// surface's io thread, so one wedged pty reader freezes the whole app. Dropping
/// the last strong reference is NOT enough — `GhosttySurfaceView.isolated deinit`
/// frees inline — so hibernation has to hand OWNERSHIP to the teardown queue.
@MainActor
@Suite(.serialized, .dependencies)
struct HibernationTeardownTests {
  private final class WeakSurfaceRef {
    weak var view: GhosttySurfaceView?

    init(_ view: GhosttySurfaceView) {
      self.view = view
    }
  }

  private func makeState(runtime: GhosttyRuntime) -> WorktreeTerminalState {
    HibernationTestSupport.enableHibernation()
    let id = "/tmp/repo/wt-hibernation-teardown"
    return WorktreeTerminalState(
      runtime: runtime,
      worktree: Worktree(
        id: WorktreeID(id),
        name: URL(fileURLWithPath: id).lastPathComponent,
        detail: "detail",
        workingDirectory: URL(fileURLWithPath: id),
        repositoryRootURL: URL(fileURLWithPath: "/tmp/repo")
      ),
      splitPreserveZoomOnNavigation: { false }
    )
  }

  /// Returns only the leaf IDs plus weak references, so the caller holds no strong
  /// reference that would mask an inline free during hibernation.
  private func snapshotLeaves(
    of state: WorktreeTerminalState,
    tab: TerminalTabID
  ) -> (ids: Set<UUID>, refs: [WeakSurfaceRef]) {
    let leaves = state.splitTree(for: tab).root!.leaves()
    return (Set(leaves.map(\.id)), leaves.map(WeakSurfaceRef.init))
  }

  @Test func hibernationTransfersSurfaceOwnershipAndStillCompletes() {
    let runtime = GhosttyRuntime()
    let state = makeState(runtime: runtime)
    var hibernatedSurfaces: Set<UUID>?
    state.onSurfacesHibernated = { hibernatedSurfaces = $0 }
    var dormancyChanged = false
    state.onDormancyChanged = { dormancyChanged = true }

    var leafIDs: Set<UUID> = []
    var refs: [WeakSurfaceRef] = []
    var tab: TerminalTabID!
    // Surface creation autoreleases the views, so create AND hibernate inside one
    // pool: the weak checks below must run after that pool has drained, otherwise
    // an autoreleased reference masks an inline free.
    autoreleasepool {
      tab = state.createTab(focusing: false)!
      (leafIDs, refs) = snapshotLeaves(of: state, tab: tab)
      state.hibernateTabForTesting(tab)
    }

    // Ownership moved to the queue: nothing was freed on hibernation's turn, so
    // every view outlives the call (a dealloc'd view means `deinit` freed inline).
    #expect(refs.allSatisfy { $0.view != nil })
    #expect(runtime.surfaceTeardownQueue.pendingSurfaceIDs == leafIDs)
    // Every leaf handed off exactly once — no surface skipped, none handed twice.
    #expect(runtime.surfaceTeardownQueue.handOffCount == leafIDs.count)

    // ...and hibernation completed despite owning no completed teardown.
    #expect(state.isTabDormant(tab))
    #expect(Set(state.dormantTabLayouts[tab]?.layout.leafSurfaceIDs ?? []) == leafIDs)
    #expect(hibernatedSurfaces == leafIDs)
    #expect(dormancyChanged)
  }
}

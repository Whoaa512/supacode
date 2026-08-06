import Dependencies
import DependenciesTestSupport
import Foundation
import Sharing
import Testing

@testable import supacode

/// Hibernation must not sit on the main actor waiting for ghostty surface
/// teardown: `ghostty_surface_free` joins the surface's io thread, so one wedged
/// pty reader freezes the whole app. Teardown is handed to the `surfaceTeardown`
/// seam; hibernation itself completes regardless of what that teardown does.
@MainActor
@Suite(.serialized, .dependencies)
struct HibernationTeardownTests {
  /// Records every surface handed to teardown and never frees it, standing in
  /// for a surface whose `ghostty_surface_free` wedges forever.
  private final class WedgedTeardown {
    var handedOff: [UUID] = []
  }

  private func makeState() -> WorktreeTerminalState {
    HibernationTestSupport.enableHibernation()
    let id = "/tmp/repo/wt-hibernation-teardown"
    return WorktreeTerminalState(
      runtime: GhosttyRuntime(),
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

  @Test func hibernationCompletesWhenSurfaceTeardownNeverFinishes() {
    let state = makeState()
    let tab = state.createTab(focusing: false)!
    let leafIDs = Set(state.splitTree(for: tab).root!.leaves().map(\.id))

    let teardown = WedgedTeardown()
    state.surfaceTeardown = { view in teardown.handedOff.append(view.id) }
    var hibernatedSurfaces: Set<UUID>?
    state.onSurfacesHibernated = { hibernatedSurfaces = $0 }
    var dormancyChanged = false
    state.onDormancyChanged = { dormancyChanged = true }

    state.hibernateTabForTesting(tab)

    // Teardown was handed off, not performed inline.
    #expect(Set(teardown.handedOff) == leafIDs)
    // ...and hibernation still completed despite that teardown never finishing.
    #expect(state.isTabDormant(tab))
    #expect(Set(state.dormantTabLayouts[tab]?.layout.leafSurfaceIDs ?? []) == leafIDs)
    #expect(hibernatedSurfaces == leafIDs)
    #expect(dormancyChanged)
  }
}

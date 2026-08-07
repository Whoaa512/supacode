import Dependencies
import DependenciesTestSupport
import Foundation
import GhosttyKit
import Testing

@testable import supacode

/// Pins `SurfaceTeardownQueue`'s bookkeeping. Surface UUIDs are REUSED when a
/// dormant tab wakes, so the queue must track view identity, not surface identity:
/// a UUID-keyed queue would treat the woken generation as already pending, skip the
/// hand-off, and let the free run inline again (the deadlock this whole change
/// exists to remove).
@MainActor
@Suite(.serialized, .dependencies)
struct SurfaceTeardownQueueTests {
  private func makeView(id: UUID, runtime: GhosttyRuntime) -> GhosttySurfaceView {
    GhosttySurfaceView(
      id: id,
      runtime: runtime,
      workingDirectory: nil,
      context: GHOSTTY_SURFACE_CONTEXT_TAB
    )
  }

  @Test func handOffTracksEachViewGenerationOfAReusedSurfaceID() {
    let runtime = GhosttyRuntime()
    let queue = runtime.surfaceTeardownQueue
    let surfaceID = UUID()
    let firstGeneration = makeView(id: surfaceID, runtime: runtime)
    let secondGeneration = makeView(id: surfaceID, runtime: runtime)

    queue.handOff(firstGeneration)
    queue.handOff(secondGeneration)

    // Both views own a live ghostty surface, so both must be pending.
    #expect(queue.pendingCount == 2)
    #expect(queue.pendingSurfaceIDs == [surfaceID])
  }

  @Test func handOffIsIdempotentForTheSameView() {
    let runtime = GhosttyRuntime()
    let queue = runtime.surfaceTeardownQueue
    let view = makeView(id: UUID(), runtime: runtime)

    queue.handOff(view)
    queue.handOff(view)

    #expect(queue.pendingCount == 1)
  }

  /// `passwordInput` scopes SecureInput app-wide; a pending surface that keeps it
  /// set would leave secure event input enabled for every other terminal.
  @Test func handOffClearsPasswordInput() {
    let runtime = GhosttyRuntime()
    let view = makeView(id: UUID(), runtime: runtime)
    view.passwordInput = true

    runtime.surfaceTeardownQueue.handOff(view)

    #expect(view.passwordInput == false)
  }

  /// The local monitor sees every key event in the app, so a pending view that
  /// kept one would keep swallowing Cmd-keyUp for the surfaces still in the tree.
  @Test func handOffRemovesTheLocalEventMonitor() {
    let runtime = GhosttyRuntime()
    let view = makeView(id: UUID(), runtime: runtime)
    #expect(view.hasLocalEventMonitor)

    runtime.surfaceTeardownQueue.handOff(view)

    #expect(view.hasLocalEventMonitor == false)
  }
}

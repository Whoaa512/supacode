import Clocks
import ConcurrencyExtras
import Dependencies
import DependenciesTestSupport
import Foundation
import GhosttyKit
import Testing

@testable import SupacodeSettingsShared
@testable import supacode

/// Records every session the teardown queue detaches, so the tests pin that the
/// queue's only zmx side effect is the IPC detach (never a signal by pattern,
/// which also matches the forked daemon and murders the session).
private actor DetachSpy {
  private(set) var sessionIDs: [String] = []

  func detach(_ sessionID: String) {
    sessionIDs.append(sessionID)
  }
}

/// Stands in for `ghostty_surface_process_exited`, so a test decides exactly when
/// the wedged pty child is gone.
@MainActor
private final class ProbeSpy {
  var hasExited = false
  private(set) var callCount = 0

  func probe(_ view: GhosttySurfaceView) -> Bool {
    callCount += 1
    return hasExited
  }
}

/// Counts frees and performs the REAL one, so a test can assert "freed exactly
/// once" without leaking the ghostty surface in the test process.
@MainActor
private final class FreeSpy {
  private(set) var freedSurfaceIDs: [UUID] = []

  func free(_ view: GhosttySurfaceView) {
    freedSurfaceIDs.append(view.id)
    view.performDeferredFree()
  }
}

/// Records analytics events so the teardown path's freed / leaked reporting is
/// observable (the two together are the leak-rate denominator).
@MainActor
private final class AnalyticsSpy {
  private(set) var events: [String] = []
  private(set) var properties: [[String: Any]] = []

  var client: AnalyticsClient {
    AnalyticsClient(
      capture: { [weak self] event, properties in
        MainActor.assumeIsolated {
          self?.events.append(event)
          self?.properties.append(properties ?? [:])
        }
      },
      identify: { _ in }
    )
  }
}

/// Weak handle: the queue must be the LAST strong reference, so a test can only
/// check ownership through a weak box.
@MainActor
private final class WeakSurfaceRef {
  weak var view: GhosttySurfaceView?
}

/// Pins `SurfaceTeardownQueue`'s bookkeeping. Surface UUIDs are REUSED when a
/// dormant tab wakes, so the queue must track view identity, not surface identity:
/// a UUID-keyed queue would treat the woken generation as already pending, skip the
/// hand-off, and let the free run inline again (the deadlock this whole change
/// exists to remove).
@MainActor
@Suite(.serialized, .dependencies)
struct SurfaceTeardownQueueTests {
  private func makeView(
    id: UUID,
    runtime: GhosttyRuntime,
    usesZmx: Bool = true
  ) -> GhosttySurfaceView {
    GhosttySurfaceView(
      id: id,
      runtime: runtime,
      workingDirectory: nil,
      usesZmx: usesZmx,
      context: GHOSTTY_SURFACE_CONTEXT_TAB
    )
  }

  private func makeQueue(
    _ spy: DetachSpy,
    clock: any Clock<Duration> = TestClock(),
    probe: ProbeSpy? = nil,
    free: FreeSpy? = nil,
    analytics: AnalyticsSpy? = nil
  ) -> SurfaceTeardownQueue {
    SurfaceTeardownQueue(
      detachClients: { await spy.detach($0) },
      clock: clock,
      analytics: analytics?.client ?? .testValue,
      hasProcessExited: { probe?.probe($0) ?? true },
      free: { free?.free($0) ?? $0.performDeferredFree() }
    )
  }

  /// Advances the TestClock in poll-interval ticks until `condition` holds. A
  /// freshly spawned teardown Task can register its sleep after an advance, so one
  /// tick isn't guaranteed to be enough; the bound only stops a regression from
  /// spinning forever, so it sits comfortably above the queue's poll bound.
  private func advance(
    _ clock: TestClock<Duration>,
    ticks: Int = 400,
    until condition: () -> Bool
  ) async {
    for _ in 0..<ticks where !condition() {
      await Task.megaYield()
      await clock.advance(by: .milliseconds(50))
    }
  }

  @Test func handOffTracksEachViewGenerationOfAReusedSurfaceID() {
    let runtime = GhosttyRuntime()
    let queue = makeQueue(DetachSpy())
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
    let queue = makeQueue(DetachSpy())
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

    makeQueue(DetachSpy()).handOff(view)

    #expect(view.passwordInput == false)
  }

  /// A leaked surface's shell keeps running (its wedged pty is the whole problem), so
  /// it can still emit the password-input OSC. Honoring it would re-enable app-wide
  /// SecureInput from a view the user can neither see nor focus.
  @Test func passwordInputCannotBeReEnabledAfterHandOff() {
    let runtime = GhosttyRuntime()
    let view = makeView(id: UUID(), runtime: runtime)

    makeQueue(DetachSpy()).handOff(view)
    view.passwordInput = true

    #expect(view.passwordInput == false)
  }

  /// The local monitor sees every key event in the app, so a pending view that
  /// kept one would keep swallowing Cmd-keyUp for the surfaces still in the tree.
  @Test func handOffRemovesTheLocalEventMonitor() {
    let runtime = GhosttyRuntime()
    let view = makeView(id: UUID(), runtime: runtime)
    #expect(view.hasLocalEventMonitor)

    makeQueue(DetachSpy()).handOff(view)

    #expect(view.hasLocalEventMonitor == false)
  }

  /// The wedged pty io thread only gets EOF once its `zmx attach` CLIENT dies, so
  /// the detach must go out at hand-off — over IPC, addressed by session id.
  /// Anything pattern-based is forbidden: the forked daemon shares the client's
  /// argv, and signaling it SIGKILLs the whole terminal process group.
  @Test func handOffDetachesTheSessionsClientsOverIPC() async {
    let runtime = GhosttyRuntime()
    let spy = DetachSpy()
    let queue = makeQueue(spy)
    let surfaceID = UUID()
    let view = makeView(id: surfaceID, runtime: runtime)

    queue.handOff(view)
    await queue.teardownTask(for: view)?.value

    #expect(await spy.sessionIDs == [ZmxSessionID.make(surfaceID: surfaceID)])
  }

  /// A woken surface reuses its UUID, so when IT later tears down, its own
  /// hand-off must detach again. (Exactly one detach per hand-off: never zero,
  /// never a retry that could race a freshly woken replacement client.)
  @Test func eachHandOffOfAReusedSurfaceIDDetachesItsOwnClient() async {
    let runtime = GhosttyRuntime()
    let spy = DetachSpy()
    let queue = makeQueue(spy)
    let surfaceID = UUID()
    let firstGeneration = makeView(id: surfaceID, runtime: runtime)
    let secondGeneration = makeView(id: surfaceID, runtime: runtime)

    queue.handOff(firstGeneration)
    await queue.teardownTask(for: firstGeneration)?.value
    queue.handOff(secondGeneration)
    await queue.teardownTask(for: secondGeneration)?.value

    #expect(await spy.sessionIDs.count == 2)
  }

  /// The reattach path hands off with `detachClients: false`: the old child is
  /// already gone and a replacement client is attaching to the SAME session, so a
  /// session-wide detach would boot the newcomer.
  @Test func handOffWithoutDetachRunsNoDetach() async {
    let runtime = GhosttyRuntime()
    let spy = DetachSpy()
    let queue = makeQueue(spy)
    let view = makeView(id: UUID(), runtime: runtime)

    queue.handOff(view, detachClients: false)
    await queue.teardownTask(for: view)?.value

    #expect(await spy.sessionIDs.isEmpty)
  }

  /// The whole point of the deferred path: the free waits for the pty child to
  /// actually exit (`ghostty_surface_process_exited`), and only then frees — once —
  /// releasing the queue's last strong reference to the view. The free is also
  /// reported, since it is the denominator the leak rate is read against.
  @Test func pollingFreesTheSurfaceOnceTheProcessHasExited() async {
    let runtime = GhosttyRuntime()
    let clock = TestClock()
    let probe = ProbeSpy()
    let free = FreeSpy()
    let analytics = AnalyticsSpy()
    let queue = makeQueue(
      DetachSpy(),
      clock: clock,
      probe: probe,
      free: free,
      analytics: analytics
    )
    let weakRef = WeakSurfaceRef()
    let surfaceID = UUID()
    var task: Task<Void, Never>?
    // Surface creation autoreleases the view; the weak check has to run after this
    // pool drains, else an autoreleased reference masks the ownership question.
    autoreleasepool {
      let view = makeView(id: surfaceID, runtime: runtime)
      weakRef.view = view
      queue.handOff(view)
      task = queue.teardownTask(for: view)
    }

    // Child still running: nothing may be freed no matter how much time passes.
    await advance(clock, ticks: 5, until: { false })
    #expect(free.freedSurfaceIDs.isEmpty)
    #expect(queue.pendingCount == 1)
    #expect(weakRef.view != nil)

    probe.hasExited = true
    await advance(clock, until: { !free.freedSurfaceIDs.isEmpty })
    await task?.value

    #expect(free.freedSurfaceIDs == [surfaceID])
    #expect(queue.pendingCount == 0)
    #expect(weakRef.view == nil)
    #expect(analytics.events == ["surface_teardown_freed"])
    #expect(analytics.properties.first?["used_zmx"] as? Bool == true)
  }

  /// Leak over hang: if the child never exits, the free is SKIPPED —
  /// but the view must stay RETAINED. ghostty holds the bridge pointer
  /// as userdata with no liveness registry, so dropping a view whose surface is
  /// still alive is a use-after-free on the next callback.
  @Test func abandonedTeardownRetainsTheViewInsteadOfFreeingIt() async {
    let runtime = GhosttyRuntime()
    let clock = TestClock()
    let probe = ProbeSpy()
    let free = FreeSpy()
    let analytics = AnalyticsSpy()
    let queue = makeQueue(
      DetachSpy(),
      clock: clock,
      probe: probe,
      free: free,
      analytics: analytics
    )
    let weakRef = WeakSurfaceRef()
    var task: Task<Void, Never>?
    autoreleasepool {
      let view = makeView(id: UUID(), runtime: runtime)
      weakRef.view = view
      queue.handOff(view)
      task = queue.teardownTask(for: view)
    }

    // The child never exits: burn past the poll bound.
    await advance(clock, until: { queue.leakedCount == 1 })
    await task?.value

    #expect(free.freedSurfaceIDs.isEmpty)
    #expect(queue.pendingCount == 0)
    #expect(queue.leakedCount == 1)
    #expect(analytics.events == ["surface_teardown_leaked"])
    // STILL ALIVE — the leak is deliberate and owned, not a dropped reference.
    #expect(weakRef.view != nil)
  }

  /// A surface with no zmx attach client (script tabs / unbundled zmx) has no
  /// detach mechanism at all, so there is nothing to EOF. Leaking it would be
  /// strictly worse than the pre-branch behavior: freeing SIGHUPs the child through
  /// the pty, and only a WEDGED reader can hang the free. So after the poll bound
  /// it is freed anyway.
  @Test func nonZmxSurfaceIsFreedAfterThePollBoundInsteadOfLeaked() async {
    let runtime = GhosttyRuntime()
    let clock = TestClock()
    let probe = ProbeSpy()
    let free = FreeSpy()
    let spy = DetachSpy()
    let queue = makeQueue(spy, clock: clock, probe: probe, free: free)
    let surfaceID = UUID()
    var task: Task<Void, Never>?
    autoreleasepool {
      let view = makeView(id: surfaceID, runtime: runtime, usesZmx: false)
      queue.handOff(view)
      task = queue.teardownTask(for: view)
    }

    // The child never reports an exit: burn past the poll bound.
    await advance(clock, until: { !free.freedSurfaceIDs.isEmpty })
    await task?.value

    #expect(free.freedSurfaceIDs == [surfaceID])
    #expect(queue.leakedCount == 0)
    #expect(queue.pendingCount == 0)
    // No detach mechanism exists for a non-zmx surface, so none may run.
    #expect(await spy.sessionIDs.isEmpty)
  }

  /// A cancelled teardown must not leave the view in limbo: its Task is gone, so
  /// nothing would ever free it, and dropping it is a use-after-free while its
  /// surface lives. It lands in the leak bucket like any other unresolvable teardown.
  @Test func cancelledTeardownLeaksTheViewInsteadOfLeavingItPending() async {
    let runtime = GhosttyRuntime()
    let probe = ProbeSpy()
    let free = FreeSpy()
    let queue = makeQueue(DetachSpy(), probe: probe, free: free)
    let weakRef = WeakSurfaceRef()
    var task: Task<Void, Never>?
    autoreleasepool {
      let view = makeView(id: UUID(), runtime: runtime)
      weakRef.view = view
      queue.handOff(view)
      task = queue.teardownTask(for: view)
    }

    task?.cancel()
    await task?.value

    #expect(free.freedSurfaceIDs.isEmpty)
    #expect(queue.pendingCount == 0)
    #expect(queue.teardownTaskCount == 0)
    #expect(queue.leakedCount == 1)
    #expect(weakRef.view != nil)
  }

  /// A surface still in the tree must never lose its client.
  @Test func noDetachRunsWithoutAHandOff() async {
    let runtime = GhosttyRuntime()
    let spy = DetachSpy()
    let queue = makeQueue(spy)
    _ = makeView(id: UUID(), runtime: runtime)
    _ = queue

    #expect(await spy.sessionIDs.isEmpty)
  }
}

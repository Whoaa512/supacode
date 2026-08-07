import Clocks
import ConcurrencyExtras
import Dependencies
import DependenciesTestSupport
import Foundation
import GhosttyKit
import Testing

@testable import SupacodeSettingsShared
@testable import supacode

/// Records every command the teardown queue runs, and lets a test decide what
/// `pgrep` reports so both the PID path and the no-match fallback are pinned.
private actor ShellSpy {
  private let pgrepStdout: String?
  private(set) var commands: [[String]] = []

  init(pgrepStdout: String? = nil) {
    self.pgrepStdout = pgrepStdout
  }

  func run(_ command: [String]) -> String? {
    commands.append(command)
    guard command.first == "pgrep" else { return "" }
    return pgrepStdout
  }

  var killCommands: [[String]] {
    commands.filter { $0.first == "kill" || $0.first == "pkill" }
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

/// Records analytics events so the leak path's counter is observable.
@MainActor
private final class AnalyticsSpy {
  private(set) var events: [String] = []

  var client: AnalyticsClient {
    AnalyticsClient(
      capture: { [weak self] event, _ in
        MainActor.assumeIsolated { self?.events.append(event) }
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
  private func makeView(id: UUID, runtime: GhosttyRuntime) -> GhosttySurfaceView {
    GhosttySurfaceView(
      id: id,
      runtime: runtime,
      workingDirectory: nil,
      context: GHOSTTY_SURFACE_CONTEXT_TAB
    )
  }

  private func makeQueue(
    _ spy: ShellSpy,
    clock: any Clock<Duration> = TestClock(),
    probe: ProbeSpy? = nil,
    free: FreeSpy? = nil,
    analytics: AnalyticsSpy? = nil
  ) -> SurfaceTeardownQueue {
    SurfaceTeardownQueue(
      shell: SurfaceTeardownShell { executable, arguments in
        await spy.run([executable.lastPathComponent] + arguments)
      },
      clock: clock,
      analytics: analytics?.client ?? .testValue,
      hasProcessExited: { probe?.probe($0) ?? true },
      free: { free?.free($0) ?? $0.performDeferredFree() }
    )
  }

  /// Advances the TestClock in poll-interval ticks until `condition` holds. A
  /// freshly spawned teardown Task can register its sleep after an advance, so one
  /// tick isn't guaranteed to be enough; the bound only stops a regression from
  /// spinning forever.
  private func advance(
    _ clock: TestClock<Duration>,
    ticks: Int = 200,
    until condition: () -> Bool
  ) async {
    for _ in 0..<ticks where !condition() {
      await Task.megaYield()
      await clock.advance(by: .milliseconds(50))
    }
  }

  @Test func handOffTracksEachViewGenerationOfAReusedSurfaceID() {
    let runtime = GhosttyRuntime()
    let queue = makeQueue(ShellSpy())
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
    let queue = makeQueue(ShellSpy())
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

    makeQueue(ShellSpy()).handOff(view)

    #expect(view.passwordInput == false)
  }

  /// The local monitor sees every key event in the app, so a pending view that
  /// kept one would keep swallowing Cmd-keyUp for the surfaces still in the tree.
  @Test func handOffRemovesTheLocalEventMonitor() {
    let runtime = GhosttyRuntime()
    let view = makeView(id: UUID(), runtime: runtime)
    #expect(view.hasLocalEventMonitor)

    makeQueue(ShellSpy()).handOff(view)

    #expect(view.hasLocalEventMonitor == false)
  }

  /// The wedged pty io thread only gets EOF once its `zmx attach` CLIENT dies, so
  /// the kill must happen at hand-off. PID-targeted, because the `-f` pattern also
  /// matches any FUTURE client of the same (surviving) session.
  @Test func handOffKillsTheAttachClientByPID() async {
    let runtime = GhosttyRuntime()
    let spy = ShellSpy(pgrepStdout: "4242\n")
    let queue = makeQueue(spy)
    let surfaceID = UUID()
    let view = makeView(id: surfaceID, runtime: runtime)

    queue.handOff(view)
    await queue.teardownTask(for: view)?.value

    let pattern = "zmx attach \(ZmxSessionID.make(surfaceID: surfaceID))"
    #expect(await spy.commands == [["pgrep", "-f", pattern], ["kill", "-TERM", "4242"]])
  }

  @Test func handOffFallsBackToASinglePkillWhenNoClientIsFound() async {
    let runtime = GhosttyRuntime()
    let spy = ShellSpy(pgrepStdout: nil)
    let queue = makeQueue(spy)
    let surfaceID = UUID()
    let view = makeView(id: surfaceID, runtime: runtime)

    queue.handOff(view)
    await queue.teardownTask(for: view)?.value

    let pattern = "zmx attach \(ZmxSessionID.make(surfaceID: surfaceID))"
    #expect(await spy.killCommands == [["pkill", "-f", pattern]])
  }

  /// A woken surface reuses its UUID, so its NEW attach client is a different
  /// process and must be killed on ITS hand-off. (Re-killing the SAME hand-off
  /// later is what murders a freshly woken terminal — that's binding 8.)
  @Test func eachHandOffOfAReusedSurfaceIDKillsItsOwnClient() async {
    let runtime = GhosttyRuntime()
    let spy = ShellSpy(pgrepStdout: "4242\n")
    let queue = makeQueue(spy)
    let surfaceID = UUID()
    let firstGeneration = makeView(id: surfaceID, runtime: runtime)
    let secondGeneration = makeView(id: surfaceID, runtime: runtime)

    queue.handOff(firstGeneration)
    await queue.teardownTask(for: firstGeneration)?.value
    queue.handOff(secondGeneration)
    await queue.teardownTask(for: secondGeneration)?.value

    #expect(await spy.killCommands.count == 2)
  }

  /// The whole point of the deferred path: the free waits for the pty child to
  /// actually exit (`ghostty_surface_process_exited`), and only then frees — once —
  /// releasing the queue's last strong reference to the view.
  @Test func pollingFreesTheSurfaceOnceTheProcessHasExited() async {
    let runtime = GhosttyRuntime()
    let clock = TestClock()
    let probe = ProbeSpy()
    let free = FreeSpy()
    let queue = makeQueue(ShellSpy(pgrepStdout: "4242\n"), clock: clock, probe: probe, free: free)
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
  }

  /// Leak over hang (decision 1): if the child never exits, the free is SKIPPED —
  /// but the view must stay RETAINED (binding 6). ghostty holds the bridge pointer
  /// as userdata with no liveness registry, so dropping a view whose surface is
  /// still alive is a use-after-free on the next callback.
  @Test func abandonedTeardownRetainsTheViewInsteadOfFreeingIt() async {
    let runtime = GhosttyRuntime()
    let clock = TestClock()
    let probe = ProbeSpy()
    let free = FreeSpy()
    let analytics = AnalyticsSpy()
    let queue = makeQueue(
      ShellSpy(pgrepStdout: "4242\n"),
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

  /// A surface still in the tree must never lose its client.
  @Test func noCommandsRunWithoutAHandOff() async {
    let runtime = GhosttyRuntime()
    let spy = ShellSpy()
    let queue = makeQueue(spy)
    _ = makeView(id: UUID(), runtime: runtime)
    _ = queue

    #expect(await spy.commands.isEmpty)
  }
}

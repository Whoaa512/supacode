import Clocks
import ConcurrencyExtras
import Foundation
import GhosttyKit
import Testing

@testable import SupacodeSettingsShared
@testable import supacode

actor TeardownDetachSpy {
  private(set) var sessionIDs: [String] = []

  func detach(_ sessionID: String) {
    sessionIDs.append(sessionID)
  }
}

@MainActor
final class TeardownProbeSpy {
  var hasExited: Bool

  init(hasExited: Bool = false) {
    self.hasExited = hasExited
  }

  func probe(_ view: GhosttySurfaceView) -> Bool { hasExited }
}

@MainActor
final class TeardownFreeSpy {
  private(set) var surfaceIDs: [UUID] = []

  func free(_ view: GhosttySurfaceView) {
    surfaceIDs.append(view.id)
    view.performDeferredFree()
  }
}

@MainActor
final class TeardownAnalyticsSpy {
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

@MainActor
final class WeakTeardownSurface {
  weak var view: GhosttySurfaceView?
}

@MainActor
enum TeardownTestSupport {
  static func queue(
    detach: TeardownDetachSpy = TeardownDetachSpy(),
    clock: any Clock<Duration> = TestClock(),
    probe: TeardownProbeSpy? = nil,
    free: TeardownFreeSpy? = nil,
    analytics: TeardownAnalyticsSpy? = nil
  ) -> SurfaceTeardownQueue {
    let probe = probe ?? TeardownProbeSpy()
    let free = free ?? TeardownFreeSpy()
    let analytics = analytics ?? TeardownAnalyticsSpy()
    return SurfaceTeardownQueue(
      detachClients: { await detach.detach($0) },
      clock: clock,
      analytics: analytics.client,
      hasProcessExited: { probe.probe($0) },
      free: { free.free($0) }
    )
  }

  static func view(
    id: UUID = UUID(),
    runtime: GhosttyRuntime,
    usesZmx: Bool = true
  ) -> GhosttySurfaceView {
    GhosttySurfaceView(
      id: id,
      runtime: runtime,
      workingDirectory: nil,
      usesZmx: usesZmx,
      initialGeometry: .fallback,
      context: GHOSTTY_SURFACE_CONTEXT_TAB
    )
  }

  static func content(
    id: ContentID = ContentID(),
    runtime: GhosttyRuntime,
    usesZmx: Bool = true,
    onSpawn: ((GhosttySurfaceView) -> Void)? = nil
  ) -> TerminalContent {
    TerminalContent(
      id: id,
      makeSurface: { _, _, _ in
        let view = TeardownTestSupport.view(id: id.rawValue, runtime: runtime, usesZmx: usesZmx)
        onSpawn?(view)
        return TerminalContent.SpawnedSurface(view: view, usesZmx: usesZmx)
      },
      initialState: TerminalContentState(workingDirectory: nil)
    )
  }

  static func advance(
    _ clock: TestClock<Duration>,
    ticks: Int = 400,
    until condition: () -> Bool
  ) async {
    for _ in 0..<ticks where !condition() {
      await Task.megaYield()
      await clock.advance(by: .milliseconds(50))
    }
  }
}

@MainActor
@Suite(.serialized)
struct SurfaceTeardownQueueTests {
  @Test func handOffOwnsEveryViewGenerationAndDropsAppWideState() {
    let probe = TeardownProbeSpy()
    let queue = TeardownTestSupport.queue(probe: probe)
    let runtime = GhosttyRuntime(surfaceTeardownQueue: queue)
    let id = UUID()
    let first = TeardownTestSupport.view(id: id, runtime: runtime)
    let second = TeardownTestSupport.view(id: id, runtime: runtime)
    first.passwordInput = true

    queue.handOff(first)
    queue.handOff(first)
    queue.handOff(second)

    #expect(queue.pendingCount == 2)
    #expect(queue.pendingSurfaceIDs == [id])
    #expect(first.passwordInput == false)
    #expect(!first.hasLocalEventMonitor)
    first.passwordInput = true
    #expect(first.passwordInput == false)
  }

  @Test func handOffDetachesTheZmxClientOverIPCExactlyOnce() async {
    let detach = TeardownDetachSpy()
    let probe = TeardownProbeSpy(hasExited: true)
    let queue = TeardownTestSupport.queue(detach: detach, probe: probe)
    let runtime = GhosttyRuntime(surfaceTeardownQueue: queue)
    let view = TeardownTestSupport.view(runtime: runtime)

    queue.handOff(view)
    await queue.teardownTask(for: view)?.value

    #expect(await detach.sessionIDs == [ZmxSessionID.make(surfaceID: view.id)])
  }

  @Test func handOffCanSkipDetachForAReattach() async {
    let detach = TeardownDetachSpy()
    let queue = TeardownTestSupport.queue(
      detach: detach,
      probe: TeardownProbeSpy(hasExited: true)
    )
    let runtime = GhosttyRuntime(surfaceTeardownQueue: queue)
    let view = TeardownTestSupport.view(runtime: runtime)

    queue.handOff(view, detachClients: false)
    await queue.teardownTask(for: view)?.value

    #expect(await detach.sessionIDs.isEmpty)
  }

  @Test func exitedChildFreesExactlyOnceAndReportsTheOutcome() async {
    let free = TeardownFreeSpy()
    let analytics = TeardownAnalyticsSpy()
    let queue = TeardownTestSupport.queue(
      probe: TeardownProbeSpy(hasExited: true),
      free: free,
      analytics: analytics
    )
    let runtime = GhosttyRuntime(surfaceTeardownQueue: queue)
    let view = TeardownTestSupport.view(runtime: runtime)
    let id = view.id

    queue.handOff(view)
    await queue.teardownTask(for: view)?.value

    #expect(free.surfaceIDs == [id])
    #expect(queue.pendingCount == 0)
    #expect(queue.teardownTaskCount == 0)
    #expect(queue.leakedCount == 0)
    #expect(analytics.events == ["surface_teardown_freed"])
  }

  @Test func zmxTimeoutLeaksAndRetainsTheView() async {
    let clock = TestClock()
    let free = TeardownFreeSpy()
    let analytics = TeardownAnalyticsSpy()
    let queue = TeardownTestSupport.queue(
      clock: clock,
      probe: TeardownProbeSpy(),
      free: free,
      analytics: analytics
    )
    let runtime = GhosttyRuntime(surfaceTeardownQueue: queue)
    let weakView = WeakTeardownSurface()
    var task: Task<Void, Never>?
    autoreleasepool {
      let view = TeardownTestSupport.view(runtime: runtime)
      weakView.view = view
      queue.handOff(view)
      task = queue.teardownTask(for: view)
    }

    await TeardownTestSupport.advance(clock, until: { queue.leakedCount == 1 })
    await task?.value

    #expect(free.surfaceIDs.isEmpty)
    #expect(queue.pendingCount == 0)
    #expect(queue.leakedCount == 1)
    #expect(weakView.view != nil)
    #expect(analytics.events == ["surface_teardown_timed_out", "surface_teardown_leaked"])
  }

  @Test func nonZmxTimeoutFreesInsteadOfLeaking() async {
    let clock = TestClock()
    let detach = TeardownDetachSpy()
    let free = TeardownFreeSpy()
    let analytics = TeardownAnalyticsSpy()
    let queue = TeardownTestSupport.queue(
      detach: detach,
      clock: clock,
      probe: TeardownProbeSpy(),
      free: free,
      analytics: analytics
    )
    let runtime = GhosttyRuntime(surfaceTeardownQueue: queue)
    let view = TeardownTestSupport.view(runtime: runtime, usesZmx: false)
    let id = view.id

    queue.handOff(view)
    let task = queue.teardownTask(for: view)
    await TeardownTestSupport.advance(clock, until: { !free.surfaceIDs.isEmpty })
    await task?.value

    #expect(free.surfaceIDs == [id])
    #expect(queue.leakedCount == 0)
    #expect(await detach.sessionIDs.isEmpty)
    #expect(analytics.events == ["surface_teardown_timed_out", "surface_teardown_freed"])
  }

  @Test func cancelledTeardownLeaksInsteadOfStrandingPendingOwnership() async {
    let queue = TeardownTestSupport.queue(probe: TeardownProbeSpy())
    let runtime = GhosttyRuntime(surfaceTeardownQueue: queue)
    let weakView = WeakTeardownSurface()
    let view = TeardownTestSupport.view(runtime: runtime)
    weakView.view = view

    queue.handOff(view)
    let task = queue.teardownTask(for: view)
    task?.cancel()
    await task?.value

    #expect(queue.pendingCount == 0)
    #expect(queue.teardownTaskCount == 0)
    #expect(queue.leakedCount == 1)
    #expect(weakView.view != nil)
  }
}

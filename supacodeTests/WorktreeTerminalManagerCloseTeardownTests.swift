import Foundation
import Testing

@testable import supacode

@MainActor
@Suite(.serialized)
struct CloseTeardownTests {
  @Test func contentRuntimeRemovalRoutesEverySurfaceThroughTheQueue() {
    let queue = TeardownTestSupport.queue(probe: TeardownProbeSpy())
    let ghosttyRuntime = GhosttyRuntime(surfaceTeardownQueue: queue)
    let contentRuntime = ContentRuntime()
    let first = TeardownTestSupport.content(runtime: ghosttyRuntime)
    let second = TeardownTestSupport.content(runtime: ghosttyRuntime)
    #expect(contentRuntime.provision(first, at: .fallback))
    #expect(contentRuntime.provision(second, at: .fallback))
    let views = [first.renderer, second.renderer].compactMap { $0 as? GhosttySurfaceView }

    contentRuntime.remove(first.id, tombstone: false)
    contentRuntime.remove(second.id, tombstone: false)

    #expect(queue.pendingCount == 2)
    #expect(views.allSatisfy(queue.isPending))
  }

  @Test func hibernateAndCloseShareTheSameQueuePath() throws {
    let queue = TeardownTestSupport.queue(probe: TeardownProbeSpy())
    let runtime = GhosttyRuntime(surfaceTeardownQueue: queue)
    let hibernated = TeardownTestSupport.content(runtime: runtime)
    let closed = TeardownTestSupport.content(runtime: runtime)
    hibernated.startSession(at: .fallback)
    closed.startSession(at: .fallback)
    let hibernatedView = try #require(hibernated.renderer as? GhosttySurfaceView)
    let closedView = try #require(closed.renderer as? GhosttySurfaceView)

    hibernated.hibernate()
    closed.tearDown()

    #expect(queue.isPending(hibernatedView))
    #expect(queue.isPending(closedView))
  }

  @Test func reattachRetirementDoesNotDetachTheReplacementSession() async throws {
    let detach = TeardownDetachSpy()
    let queue = TeardownTestSupport.queue(
      detach: detach,
      probe: TeardownProbeSpy(hasExited: true)
    )
    let runtime = GhosttyRuntime(surfaceTeardownQueue: queue)
    let content = TeardownTestSupport.content(runtime: runtime)
    content.startSession(at: .fallback)
    let view = try #require(content.renderer as? GhosttySurfaceView)

    content.tearDown(detachClients: false)
    await queue.teardownTask(for: view)?.value

    #expect(await detach.sessionIDs.isEmpty)
  }

  @Test func reattachGateRequiresTheChildToBeGone() {
    #expect(
      !LayoutSurfaceConduit.shouldProbeUnexpectedZmxClose(
        isExplicit: false,
        processAlive: true,
        isHibernatable: true
      )
    )
    #expect(
      LayoutSurfaceConduit.shouldProbeUnexpectedZmxClose(
        isExplicit: false,
        processAlive: false,
        isHibernatable: true
      )
    )
  }
}

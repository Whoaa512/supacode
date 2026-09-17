import Clocks
import Testing

@testable import supacode

@MainActor
@Suite(.serialized)
struct HappyPathTeardownTests {
  @Test func closeFreesEverySurfaceExactlyOnceWithoutLeaking() async {
    let free = TeardownFreeSpy()
    let queue = TeardownTestSupport.queue(
      probe: TeardownProbeSpy(hasExited: true),
      free: free
    )
    let ghosttyRuntime = GhosttyRuntime(surfaceTeardownQueue: queue)
    let contentRuntime = ContentRuntime()
    let contents = [
      TeardownTestSupport.content(runtime: ghosttyRuntime),
      TeardownTestSupport.content(runtime: ghosttyRuntime),
    ]
    for content in contents {
      #expect(contentRuntime.provision(content, at: .fallback))
    }
    let views = contents.compactMap { $0.renderer as? GhosttySurfaceView }
    let ids = views.map(\.id)

    for content in contents {
      contentRuntime.remove(content.id, tombstone: false)
    }
    let tasks = views.compactMap(queue.teardownTask)
    for task in tasks { await task.value }

    #expect(free.surfaceIDs.count == ids.count)
    #expect(ids.allSatisfy { id in free.surfaceIDs.count(where: { $0 == id }) == 1 })
    #expect(queue.pendingCount == 0)
    #expect(queue.teardownTaskCount == 0)
    #expect(queue.leakedCount == 0)
  }

  @Test func hibernationFreeCompletesAfterDormancyAlreadyLanded() async throws {
    let probe = TeardownProbeSpy()
    let clock = TestClock()
    let free = TeardownFreeSpy()
    let queue = TeardownTestSupport.queue(clock: clock, probe: probe, free: free)
    let runtime = GhosttyRuntime(surfaceTeardownQueue: queue)
    let content = TeardownTestSupport.content(runtime: runtime)
    content.startSession(at: .fallback)
    let view = try #require(content.renderer as? GhosttySurfaceView)

    content.hibernate()
    #expect(content.renderer == nil)
    #expect(queue.isPending(view))
    #expect(free.surfaceIDs.isEmpty)

    probe.hasExited = true
    await TeardownTestSupport.advance(clock, until: { !free.surfaceIDs.isEmpty })
    await queue.teardownTask(for: view)?.value

    #expect(free.surfaceIDs == [view.id])
    #expect(queue.pendingCount == 0)
  }
}

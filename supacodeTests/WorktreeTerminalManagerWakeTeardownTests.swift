import Testing

@testable import supacode

@MainActor
@Suite(.serialized)
struct WakeWhileTeardownPendingTests {
  @Test func wakeCreatesAFreshViewWhileTheOldGenerationIsPending() throws {
    let queue = TeardownTestSupport.queue(probe: TeardownProbeSpy())
    let runtime = GhosttyRuntime(surfaceTeardownQueue: queue)
    let contentID = ContentID()
    let content = TeardownTestSupport.content(id: contentID, runtime: runtime)
    content.startSession(at: .fallback)
    let oldView = try #require(content.renderer as? GhosttySurfaceView)

    content.hibernate()
    content.startSession(at: .fallback)
    let newView = try #require(content.renderer as? GhosttySurfaceView)

    #expect(newView !== oldView)
    #expect(newView.id == oldView.id)
    #expect(queue.isPending(oldView))
    #expect(!queue.isPending(newView))
  }

  @Test func rehibernationQueuesBothGenerationsOfTheSameSurfaceID() throws {
    let queue = TeardownTestSupport.queue(probe: TeardownProbeSpy())
    let runtime = GhosttyRuntime(surfaceTeardownQueue: queue)
    let content = TeardownTestSupport.content(runtime: runtime)
    content.startSession(at: .fallback)
    let first = try #require(content.renderer as? GhosttySurfaceView)
    content.hibernate()
    content.startSession(at: .fallback)
    let second = try #require(content.renderer as? GhosttySurfaceView)

    content.hibernate()

    #expect(queue.pendingCount == 2)
    #expect(queue.pendingSurfaceIDs == [first.id])
    #expect(queue.isPending(first))
    #expect(queue.isPending(second))
  }
}

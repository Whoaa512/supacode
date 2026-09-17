import Clocks
import Foundation
import Testing

@testable import supacode

@MainActor
@Suite(.serialized)
struct HibernationTeardownTests {
  @Test func hibernationTransfersOwnershipAndCompletesHostBookkeeping() {
    let queue = TeardownTestSupport.queue(probe: TeardownProbeSpy())
    let ghosttyRuntime = GhosttyRuntime(surfaceTeardownQueue: queue)
    let contentRuntime = ContentRuntime()
    let contentID = ContentID()
    let content = TeardownTestSupport.content(id: contentID, runtime: ghosttyRuntime)
    #expect(contentRuntime.provision(content, at: .fallback))
    let oldView = content.renderer as? GhosttySurfaceView
    let weakView = WeakTeardownSurface()
    weakView.view = oldView
    let worktree = Worktree(
      id: WorktreeID("/tmp/hibernation-teardown"),
      name: "hibernation-teardown",
      detail: "detail",
      workingDirectory: URL(filePath: "/tmp/hibernation-teardown"),
      repositoryRootURL: URL(filePath: "/tmp")
    )
    let host = WorktreeContentHost(
      worktree: worktree,
      runtime: contentRuntime,
      clock: TestClock(),
      runSetupScript: false
    )
    var hibernated: Set<UUID>?
    var dormancyChanged = false
    host.onSurfacesHibernated = { hibernated = $0 }
    host.onDormancyChanged = { dormancyChanged = true }

    content.hibernate()
    host.handleSurfacesHibernated([contentID.rawValue])

    #expect(content.renderer == nil)
    #expect(oldView.map(queue.isPending) == true)
    #expect(weakView.view != nil)
    #expect(hibernated == [contentID.rawValue])
    #expect(dormancyChanged)
  }
}

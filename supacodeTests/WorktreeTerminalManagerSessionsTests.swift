import ConcurrencyExtras
import Dependencies
import Foundation
import Testing

@testable import supacode

@MainActor
@Suite(.serialized)
struct WorktreeTerminalManagerSessionsTests {
  @Test func terminalContentSuppressesHarnessEndAcrossTeardownAndStart() throws {
    let runtime = GhosttyRuntime(surfaceTeardownQueue: TeardownTestSupport.queue(probe: TeardownProbeSpy()))
    let content = TeardownTestSupport.content(runtime: runtime)
    var suppressed: [UUID] = []
    var allowed: [UUID] = []
    content.onWillTearDown = { suppressed.append($0) }
    content.onDidStart = { allowed.append($0) }

    content.startSession(at: .fallback)
    content.hibernate()

    #expect(allowed == [content.id.rawValue])
    #expect(suppressed == [content.id.rawValue])
  }

  @Test func unexpectedZmxPathsAreNotExplicitUserCloses() {
    #expect(
      LayoutSurfaceConduit.shouldProbeUnexpectedZmxClose(
        isExplicit: false,
        processAlive: false,
        isHibernatable: true
      )
    )
    #expect(
      !LayoutSurfaceConduit.shouldProbeUnexpectedZmxClose(
        isExplicit: true,
        processAlive: false,
        isHibernatable: true
      )
    )
    #expect(
      !LayoutSurfaceConduit.shouldProbeUnexpectedZmxClose(
        isExplicit: false,
        processAlive: true,
        isHibernatable: true
      )
    )
  }

  @Test func hostEmitsUserClosedOnlyForAcceptedIntent() {
    let worktree = Worktree(
      id: "/tmp/repo", name: "repo", detail: "",
      workingDirectory: URL(fileURLWithPath: "/tmp/repo"),
      repositoryRootURL: URL(fileURLWithPath: "/tmp/repo")
    )
    let host = WorktreeContentHost(
      context: DirectoryContext(worktree: worktree),
      runtime: ContentRuntime(),
      clock: ImmediateClock(),
      runSetupScript: false
    )
    let accepted = UUID()
    let cancelled = UUID()
    var userClosed: [Set<UUID>] = []
    var closed: [Set<UUID>] = []
    host.onUserClosedSurfaces = { userClosed.append($0) }
    host.onSurfacesClosed = { closed.append($0) }

    host.markUserCloseIntent(for: [accepted, cancelled])
    host.cancelExplicitClose(for: cancelled)
    host.cleanupSurfaceState(for: accepted)
    host.cleanupSurfaceState(for: cancelled)

    #expect(userClosed == [[accepted]])
    #expect(closed == [[accepted], [cancelled]])
  }

  @Test func unexpectedZmxRemovesStaleUserCloseIntent() {
    let worktree = Worktree(
      id: "/tmp/repo", name: "repo", detail: "",
      workingDirectory: URL(fileURLWithPath: "/tmp/repo"),
      repositoryRootURL: URL(fileURLWithPath: "/tmp/repo")
    )
    let host = WorktreeContentHost(
      context: DirectoryContext(worktree: worktree), runtime: ContentRuntime(),
      clock: ImmediateClock(), runSetupScript: false
    )
    let surfaceID = UUID()
    var userClosed: [Set<UUID>] = []
    host.onUserClosedSurfaces = { userClosed.append($0) }
    host.onSurfacesClosed = { _ in }
    host.markUserCloseIntent(for: [surfaceID])
    host.removeUserCloseIntent(for: surfaceID)
    host.cleanupSurfaceState(for: surfaceID)
    #expect(userClosed.isEmpty)
  }

  @Test func deadNonexplicitConduitMarkAutomaticPreventsUserCloseAttribution() {
    let worktree = Worktree(
      id: "/tmp/repo", name: "repo", detail: "",
      workingDirectory: URL(fileURLWithPath: "/tmp/repo"),
      repositoryRootURL: URL(fileURLWithPath: "/tmp/repo")
    )
    let host = WorktreeContentHost(
      context: DirectoryContext(worktree: worktree), runtime: ContentRuntime(),
      clock: ImmediateClock(), runSetupScript: false
    )
    let surfaceID = UUID()
    var userClosed: [Set<UUID>] = []
    host.onUserClosedSurfaces = { userClosed.append($0) }
    host.onSurfacesClosed = { _ in }
    // Simulate stale intent set before the process died
    host.markUserCloseIntent(for: [surfaceID])
    // Conduit detects !isExplicit && !processAlive and marks automatic
    host.markAutomaticClose(for: surfaceID)
    // Subsequent markUserCloseIntent (from a concurrent path) also skips
    host.markUserCloseIntent(for: [surfaceID])
    host.cleanupSurfaceState(for: surfaceID)
    #expect(userClosed.isEmpty)
  }

  @Test func explicitAndLiveProcessClosePreserveBehavior() {
    let worktree = Worktree(
      id: "/tmp/repo", name: "repo", detail: "",
      workingDirectory: URL(fileURLWithPath: "/tmp/repo"),
      repositoryRootURL: URL(fileURLWithPath: "/tmp/repo")
    )
    let host = WorktreeContentHost(
      context: DirectoryContext(worktree: worktree), runtime: ContentRuntime(),
      clock: ImmediateClock(), runSetupScript: false
    )
    let surfaceID = UUID()
    var userClosed: [Set<UUID>] = []
    host.onUserClosedSurfaces = { userClosed.append($0) }
    host.onSurfacesClosed = { _ in }
    host.markUserCloseIntent(for: [surfaceID])
    host.cleanupSurfaceState(for: surfaceID)
    #expect(userClosed == [[surfaceID]])
  }

  @Test func conduitRoutesDieingNonZmxSurfaceToMarkAutomaticAndContentRequestedClose() {
    let worktree = Worktree(
      id: "/tmp/repo", name: "repo", detail: "",
      workingDirectory: URL(fileURLWithPath: "/tmp/repo"),
      repositoryRootURL: URL(fileURLWithPath: "/tmp/repo")
    )
    let ghosttyRuntime = GhosttyRuntime(surfaceTeardownQueue: TeardownTestSupport.queue(probe: TeardownProbeSpy()))
    let contentRuntime = ContentRuntime()
    let host = WorktreeContentHost(
      context: DirectoryContext(worktree: worktree), runtime: contentRuntime,
      clock: ImmediateClock(), runSetupScript: false
    )
    var capturedActions: [LayoutFeature.Action] = []
    host.sendLayoutAction = { capturedActions.append($0) }
    var userClosed: [Set<UUID>] = []
    host.onUserClosedSurfaces = { userClosed.append($0) }
    host.onSurfacesClosed = { _ in }
    let content = TeardownTestSupport.content(id: ContentID(), runtime: ghosttyRuntime, usesZmx: false)
    let surfaceID = content.id.rawValue
    #expect(contentRuntime.provision(content, at: .fallback))
    guard let view = content.renderer as? GhosttySurfaceView
    else {
      Issue.record("Expected GhosttySurfaceView")
      return
    }
    host.registerSurfaceState(for: surfaceID)
    var unexpectedZmxClosed = false
    LayoutSurfaceConduit(
      host: host, runtime: contentRuntime,
      handleUnexpectedZmxClose: { _, _ in unexpectedZmxClosed = true }
    ).wire(view, contentID: content.id)
    view.bridge.onCloseRequest?(false)
    #expect(!unexpectedZmxClosed, "non-zmx surface must not probe zmx")
    #expect(userClosed.isEmpty, "automatic close must not emit user-close")
    #expect(
      capturedActions.contains { action in
        if case .contentRequestedClose(let id, _) = action { return id == content.id }
        return false
      }, "conduit must send contentRequestedClose for dead non-zmx process")
  }

  @Test func conduitRoutesDyingZmxSurfaceToHandleUnexpectedZmxClose() throws {
    let worktree = Worktree(
      id: "/tmp/repo", name: "repo", detail: "",
      workingDirectory: URL(fileURLWithPath: "/tmp/repo"),
      repositoryRootURL: URL(fileURLWithPath: "/tmp/repo")
    )
    let ghosttyRuntime = GhosttyRuntime(surfaceTeardownQueue: TeardownTestSupport.queue(probe: TeardownProbeSpy()))
    let contentRuntime = ContentRuntime()
    let host = WorktreeContentHost(
      context: DirectoryContext(worktree: worktree), runtime: contentRuntime,
      clock: ImmediateClock(), runSetupScript: false
    )
    host.sendLayoutAction = { _ in }
    host.onSurfacesClosed = { _ in }
    let content = TeardownTestSupport.content(id: ContentID(), runtime: ghosttyRuntime, usesZmx: true)
    #expect(contentRuntime.provision(content, at: .fallback))
    let view = try #require(content.renderer as? GhosttySurfaceView)
    host.registerSurfaceState(for: content.id.rawValue)
    var unexpectedZmxArgs: (GhosttySurfaceView, Bool)?
    LayoutSurfaceConduit(
      host: host, runtime: contentRuntime,
      handleUnexpectedZmxClose: { closedView, alive in unexpectedZmxArgs = (closedView, alive) }
    ).wire(view, contentID: content.id)
    view.bridge.onCloseRequest?(false)
    #expect(unexpectedZmxArgs?.0 === view, "conduit must forward exact view to zmx probe")
    #expect(unexpectedZmxArgs?.1 == false)
  }

  @Test func killSessionSuppressesHarnessEndForKilledSurface() async {
    let surfaceID = UUID()
    let manager = withDependencies {
      $0.zmxClient = ZmxClient(
        executableURL: { nil },
        isBundled: { true },
        killSession: { _ in },
        killRemoteSession: { _, _ in },
        listSessionsWithClients: { [] }
      )
    } operation: {
      WorktreeTerminalManager(runtime: GhosttyRuntime())
    }

    await manager.killSession(for: ContentID(rawValue: surfaceID), worktreeID: WorktreeID("/tmp/repo"))

    #expect(manager.isHarnessEndSuppressed(surfaceID: surfaceID))
  }
}

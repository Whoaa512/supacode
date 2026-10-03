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
      worktree: worktree,
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
      worktree: worktree, runtime: ContentRuntime(),
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
      worktree: worktree, runtime: ContentRuntime(),
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
      worktree: worktree, runtime: ContentRuntime(),
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

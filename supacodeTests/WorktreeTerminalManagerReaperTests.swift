import Clocks
import Dependencies
import Foundation
import IdentifiedCollections
import Testing

@testable import supacode

@MainActor
struct WorktreeTerminalManagerReaperTests {
  /// Builds a manager whose injected zmx client records every kill and serves
  /// the supplied `ls` listing (nil = probe failed).
  private func makeManager(
    listing: [ZmxSessionListParser.Entry]?,
    killed: LockIsolated<[String]>
  ) -> WorktreeTerminalManager {
    withDependencies {
      $0.zmxClient = ZmxClient(
        executableURL: { nil },
        isBundled: { true },
        killSession: { id in
          killed.withValue { $0.append(id) }
          return true
        },
        killRemoteSession: { _, _ in },
        listSessionsWithClients: { listing }
      )
    } operation: {
      WorktreeTerminalManager(runtime: GhosttyRuntime())
    }
  }

  private func session(for surfaceID: UUID) -> String {
    ZmxSessionID.make(surfaceID: surfaceID)
  }

  @Test func reapSparesAttachedOrphanEvenWhenUnknown() async {
    let attached = UUID()
    let idle = UUID()
    let killed = LockIsolated<[String]>([])
    let manager = makeManager(
      listing: [
        .init(name: session(for: attached), clients: 1),
        .init(name: session(for: idle), clients: 0),
      ],
      killed: killed
    )

    await manager.reapOrphanSessions(knownSurfaceIDs: [])

    #expect(killed.value == [session(for: idle)])
  }

  @Test func reapSkipsErrAndUnreachableSessions() async {
    let unreachable = UUID()
    let killed = LockIsolated<[String]>([])
    let manager = makeManager(
      listing: [.init(name: session(for: unreachable), clients: nil)],
      killed: killed
    )

    await manager.reapOrphanSessions(knownSurfaceIDs: [])

    #expect(killed.value.isEmpty)
  }

  @Test func reapKillsNothingWhenProbeUnavailable() async {
    let idle = UUID()
    let killed = LockIsolated<[String]>([])
    let manager = makeManager(listing: nil, killed: killed)

    await manager.reapOrphanSessions(knownSurfaceIDs: [idle])

    #expect(killed.value.isEmpty)
  }

  @Test func terminateKillsTrackedEvenWithLiveClientsButSparesUntrackedInUse() async {
    let killed = LockIsolated<[String]>([])
    let listing = LockIsolated<[ZmxSessionListParser.Entry]?>([])
    let manager = withDependencies {
      $0.zmxClient = ZmxClient(
        executableURL: { nil },
        isBundled: { true },
        killSession: { id in
          killed.withValue { $0.append(id) }
          return true
        },
        killRemoteSession: { _, _ in },
        listSessionsWithClients: { listing.value }
      )
    } operation: {
      WorktreeTerminalManager(runtime: GhosttyRuntime())
    }
    let trackedSession = trackOneSurface(in: manager)
    let untrackedSession = session(for: UUID())
    // The tracked session reports clients>0 (must still die) and an untracked
    // session is in use (must be spared).
    listing.setValue([
      .init(name: trackedSession, clients: 2),
      .init(name: untrackedSession, clients: 3),
    ])

    await manager.terminateAllSessions()

    #expect(killed.value == [trackedSession])
  }

  /// Two terminate paths meet on one tracked session: the budgeted kill lands
  /// at the daemon but the budget expires before it returns, and the
  /// post-budget fallback decides whether to kill it again. The ordering is
  /// forced: the first kill blocks until the budget has been cancelled.
  @Test func aKillThatLandedBeforeTheBudgetExpiredIsNotKilledAgain() async {
    let killed = LockIsolated<[String]>([])
    let (started, startedSignal) = AsyncStream<Void>.makeStream()
    let (held, holdSignal) = AsyncStream<Void>.makeStream()
    let clock = TestClock()
    let manager = withDependencies {
      $0.zmxClient = ZmxClient(
        executableURL: { nil },
        isBundled: { true },
        killSession: { id in
          let count = killed.withValue { kills in
            kills.append(id)
            return kills.count
          }
          guard count == 1 else { return true }
          startedSignal.yield()
          var holds = held.makeAsyncIterator()
          _ = await holds.next()
          return true
        },
        killRemoteSession: { _, _ in },
        listSessionsWithClients: { [] }
      )
    } operation: {
      WorktreeTerminalManager(runtime: GhosttyRuntime(), clock: clock)
    }
    let trackedSession = trackOneSurface(in: manager)

    let terminate = Task { await manager.terminateAllSessions(killBudget: .seconds(6)) }
    var starts = started.makeAsyncIterator()
    _ = await starts.next()
    await clock.advance(by: .seconds(6))
    holdSignal.finish()
    await terminate.value
    await clock.run()

    #expect(killed.value == [trackedSession])
  }

  /// The budgeted kill was cut short (cancelled or timed out mid-subprocess),
  /// so the session may still be running its ssh reconnect loop: the fallback
  /// must kill it again, uncancelled.
  @Test func aKillCutShortByTheBudgetIsRetried() async {
    let killed = LockIsolated<[String]>([])
    let (started, startedSignal) = AsyncStream<Void>.makeStream()
    let (held, holdSignal) = AsyncStream<Void>.makeStream()
    let clock = TestClock()
    let manager = withDependencies {
      $0.zmxClient = ZmxClient(
        executableURL: { nil },
        isBundled: { true },
        killSession: { id in
          let count = killed.withValue { kills in
            kills.append(id)
            return kills.count
          }
          guard count == 1 else { return true }
          startedSignal.yield()
          var holds = held.makeAsyncIterator()
          _ = await holds.next()
          return false
        },
        killRemoteSession: { _, _ in },
        listSessionsWithClients: { [] }
      )
    } operation: {
      WorktreeTerminalManager(runtime: GhosttyRuntime(), clock: clock)
    }
    let trackedSession = trackOneSurface(in: manager)

    let terminate = Task { await manager.terminateAllSessions(killBudget: .seconds(6)) }
    var starts = started.makeAsyncIterator()
    _ = await starts.next()
    await clock.advance(by: .seconds(6))
    holdSignal.finish()
    await terminate.value
    await clock.run()

    #expect(killed.value == [trackedSession, trackedSession])
  }

  /// Gives `manager` one host with one tracked terminal surface; returns the
  /// zmx session that surface maps to.
  private func trackOneSurface(in manager: WorktreeTerminalManager) -> String {
    let worktree = makeWorktree()
    let host = manager.host(for: worktree.id.layoutID, context: DirectoryContext(worktree: worktree))
    let trackedSurfaceID = UUID()
    let paneID = PaneID()
    let tabID = TabID(rawValue: trackedSurfaceID)
    let layout = PaneLayout(
      tree: SplitTree(view: paneID),
      panes: [
        Pane(
          id: paneID,
          tabs: [
            TabItem(
              id: tabID,
              title: "Tab",
              content: ContentSnapshot(
                id: ContentID(rawValue: trackedSurfaceID),
                state: .terminal(TerminalContentState(workingDirectory: nil))
              )
            )
          ],
          selectedTabID: tabID
        )
      ],
      focusedPaneID: paneID
    )
    host.layout = { layout }
    return session(for: trackedSurfaceID)
  }

  private func makeWorktree(id: String = "/tmp/repo/wt-1") -> Worktree {
    let name = URL(fileURLWithPath: id).lastPathComponent
    return Worktree(
      id: WorktreeID(id),
      name: name,
      detail: "detail",
      workingDirectory: URL(fileURLWithPath: id),
      repositoryRootURL: URL(fileURLWithPath: "/tmp/repo")
    )
  }
}

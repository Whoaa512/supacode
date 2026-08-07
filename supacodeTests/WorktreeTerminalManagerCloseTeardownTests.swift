import Clocks
import ConcurrencyExtras
import Dependencies
import DependenciesTestSupport
import Foundation
import GhosttyKit
import Sharing
import Testing

@testable import SupacodeSettingsShared
@testable import supacode

/// Behavior C: normal/explicit close gets the same protection as hibernation.
/// `ghostty_surface_free` joins the surface's pty io thread, so it must never run
/// on the closing turn of the main actor — no matter which of the ~12 teardown
/// paths triggered it. These tests pin that a plain tab close hands every leaf to
/// `SurfaceTeardownQueue` while leaving the close's OTHER semantics (tab removal,
/// bookkeeping, the deliberate zmx SESSION kill) exactly as they were.
///
/// Deliberately synchronous, like `WakeWhileTeardownPendingTests`: the queue's
/// per-view Tasks only run at a suspension point, so every entry stays pending for
/// the whole test, which is the wedged-pty case these tests care about.
@MainActor
@Suite(.serialized, .dependencies)
struct CloseTeardownTests {
  private func makeWorktree() -> Worktree {
    let id = "/tmp/repo/wt-close-teardown"
    return Worktree(
      id: WorktreeID(id),
      name: URL(fileURLWithPath: id).lastPathComponent,
      detail: "detail",
      workingDirectory: URL(fileURLWithPath: id),
      repositoryRootURL: URL(fileURLWithPath: "/tmp/repo")
    )
  }

  private func makeState(
    runtime: GhosttyRuntime,
    events: LockIsolated<[String]> = LockIsolated([])
  ) -> WorktreeTerminalState {
    withDependencies {
      $0.continuousClock = ImmediateClock()
      $0.date.now = Date(timeIntervalSince1970: 0)
      $0.analyticsClient.capture = { event, _ in events.withValue { $0.append(event) } }
      $0.zmxClient = ZmxClient(
        executableURL: { URL(fileURLWithPath: "/usr/bin/true") },
        isBundled: { true },
        killSession: { _ in },
        killRemoteSession: { _, _ in },
        listSessionsWithClients: { [] }
      )
    } operation: {
      WorktreeTerminalState(
        runtime: runtime,
        worktree: makeWorktree(),
        splitPreserveZoomOnNavigation: { false }
      )
    }
  }

  private func leaves(_ state: WorktreeTerminalState, tab: TerminalTabID) -> [GhosttySurfaceView] {
    state.splitTree(for: tab).root?.leaves() ?? []
  }

  /// Weak handles: the queue must be the LAST strong reference, so ownership is
  /// only observable through weak boxes.
  private final class WeakRef {
    weak var view: GhosttySurfaceView?
  }

  /// Closing a tab must not free its surfaces inline. Every leaf ends up owned by
  /// the teardown queue (still alive, parked at `.killRequested`), while the tab
  /// itself is gone and the zmx SESSION kill an explicit close asks for still
  /// happens — session kill and attach-client kill are orthogonal.
  @Test func closingATabHandsEveryLeafToTheTeardownQueue() {
    let runtime = GhosttyRuntime()
    let events = LockIsolated<[String]>([])
    let state = makeState(runtime: runtime, events: events)
    let queue = runtime.surfaceTeardownQueue
    var closedTabs = 0
    state.onTabClosed = { closedTabs += 1 }

    var refs: [WeakRef] = []
    var surfaceIDs: Set<UUID> = []
    // Surface creation autoreleases the views, so the tab's whole lifetime has to
    // sit inside one pool and the weak checks after it drains.
    autoreleasepool {
      let tab = state.createTab(focusing: false)!
      let first = leaves(state, tab: tab)[0]
      #expect(state.performSplitAction(.newSplit(direction: .right), for: first.id))
      let views = leaves(state, tab: tab)
      #expect(views.count == 2)
      surfaceIDs = Set(views.map(\.id))
      refs = views.map { view in
        let ref = WeakRef()
        ref.view = view
        return ref
      }

      state.closeTab(tab)

      #expect(!state.hasTab(tab))
      #expect(state.tabManager.tabs.isEmpty)
      #expect(closedTabs == 1)
      // Session kill semantics unchanged: an explicit close still kills the zmx
      // session (the queue only ever kills the attach CLIENT).
      #expect(events.value.contains("terminal_persistence_session_killed"))
      // Checked in here, where the view objects still exist; ownership is checked
      // after the pool drains, where holding one would make it vacuous.
      #expect(views.allSatisfy { queue.stage(for: $0) == .killRequested })
    }

    #expect(refs.count == 2)
    #expect(refs.allSatisfy { $0.view != nil })
    #expect(queue.pendingCount == 2)
    #expect(queue.pendingSurfaceIDs == surfaceIDs)
    #expect(queue.leakedCount == 0)
  }
}

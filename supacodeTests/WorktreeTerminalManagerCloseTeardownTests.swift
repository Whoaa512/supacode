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

  /// Runtime whose teardown queue runs against a recorded shell instead of the real
  /// one: the queue resolves `shellClient` at CONSTRUCTION, so the spy
  /// has to be in scope here.
  private func makeRuntime(commands: LockIsolated<[[String]]>) -> GhosttyRuntime {
    withDependencies {
      $0.shellClient.run = { executable, arguments, _ in
        commands.withValue { $0.append([executable.lastPathComponent] + arguments) }
        return ShellOutput(stdout: "", stderr: "", exitCode: 0)
      }
    } operation: {
      GhosttyRuntime()
    }
  }

  private func makeState(
    runtime: GhosttyRuntime,
    events: LockIsolated<[String]> = LockIsolated([]),
    sessions: LockIsolated<[ZmxSessionListParser.Entry]> = LockIsolated([])
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
        listSessionsWithClients: { sessions.value }
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
  /// the teardown queue (still alive, still pending), while the tab
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
      #expect(views.allSatisfy { queue.isPending($0) })
    }

    #expect(refs.count == 2)
    #expect(refs.allSatisfy { $0.view != nil })
    #expect(queue.pendingCount == 2)
    #expect(queue.pendingSurfaceIDs == surfaceIDs)
    #expect(queue.leakedCount == 0)
  }

  /// `closeAllSurfaces` (worktree teardown / quit) must not free inline either: it
  /// walks every live surface at once, so one wedged pty there would freeze the app
  /// during quit.
  @Test func closingAllSurfacesHandsEveryLiveSurfaceToTheTeardownQueue() {
    let runtime = GhosttyRuntime()
    let state = makeState(runtime: runtime)
    let queue = runtime.surfaceTeardownQueue

    var refs: [WeakRef] = []
    var surfaceIDs: Set<UUID> = []
    autoreleasepool {
      let firstTab = state.createTab(focusing: false)!
      let secondTab = state.createTab(focusing: false)!
      let views = leaves(state, tab: firstTab) + leaves(state, tab: secondTab)
      #expect(views.count == 2)
      surfaceIDs = Set(views.map(\.id))
      refs = views.map { view in
        let ref = WeakRef()
        ref.view = view
        return ref
      }

      state.closeAllSurfaces()

      #expect(views.allSatisfy { queue.isPending($0) })
      #expect(state.surfaceIDs(inTab: firstTab).isEmpty)
      #expect(state.surfaceIDs(inTab: secondTab).isEmpty)
    }

    #expect(refs.count == 2)
    #expect(refs.allSatisfy { $0.view != nil })
    #expect(queue.pendingCount == 2)
    #expect(queue.pendingSurfaceIDs == surfaceIDs)
  }

  /// The reattach branch exists for a zmx CLIENT that died under a surviving
  /// session. Ghostty reports `processAlive == true` when the surface's child is
  /// still running, i.e. the close came from the shell/app inside the session — there
  /// is nothing to reattach to, and minting a replacement would resurrect a pane the
  /// user just closed.
  @Test func closeRequestWithALiveProcessNeverTakesTheReattachBranch() async {
    let runtime = GhosttyRuntime()
    let sessions = LockIsolated<[ZmxSessionListParser.Entry]>([])
    let state = makeState(runtime: runtime, sessions: sessions)
    let tab = state.createTab(focusing: false)!
    let view = leaves(state, tab: tab)[0]
    // An idle session we own: everything the reattach branch needs is in place, so
    // only `processAlive` can keep it from firing.
    sessions.setValue([.init(name: ZmxSessionID.make(surfaceID: view.id), clients: 0)])

    view.bridge.closeSurface(processAlive: true)
    await Task.megaYield()

    #expect(leaves(state, tab: tab).isEmpty)
    #expect(state.surfaceIDs(inTab: tab).isEmpty)
    #expect(!state.hasTab(tab))
  }

  /// The zmx reattach path is the ONE hand-off that must not kill an attach client.
  /// The replacement surface reuses the exited surface's id, i.e. its zmx session,
  /// and the kill matches by session pattern — so killing here would take out the
  /// client the reattach just spawned (the pattern-kill hazard, reached by ordering
  /// instead of by retry).
  @Test func reattachingAnExitedZmxSurfaceNeverKillsTheAttachClient() async {
    let commands = LockIsolated<[[String]]>([])
    let runtime = makeRuntime(commands: commands)
    // The session id is only known after the surface exists, so the listing is a
    // mutable box the injected client reads at call time.
    let sessions = LockIsolated<[ZmxSessionListParser.Entry]>([])
    let state = makeState(runtime: runtime, sessions: sessions)
    let tab = state.createTab(focusing: false)!
    let view = leaves(state, tab: tab)[0]
    let sessionID = ZmxSessionID.make(surfaceID: view.id)
    // An idle session we own is what sends `handleUnexpectedZmxClose` down the
    // reattach branch instead of the close branch.
    sessions.setValue([.init(name: sessionID, clients: 0)])

    view.bridge.closeSurface(processAlive: false)
    for _ in 0..<50 where leaves(state, tab: tab).first === view {
      await Task.megaYield()
    }

    // Drain the old view's teardown Task, otherwise a kill it WOULD have run has
    // simply not happened yet and the assertion below is vacuous.
    for _ in 0..<50 {
      guard let task = runtime.surfaceTeardownQueue.teardownTask(for: view) else { break }
      await task.value
    }
    await Task.megaYield()

    let replacement = leaves(state, tab: tab).first
    #expect(replacement !== view)
    #expect(replacement?.id == view.id)
    // Nothing may go looking for — let alone kill — this session's client.
    #expect(!commands.value.contains { $0.contains(where: { $0.contains(sessionID) }) })
  }
}

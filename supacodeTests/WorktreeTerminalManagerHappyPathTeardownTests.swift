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

/// Records the queue's shell commands and tells `pgrep` what to report.
private actor ShellSpy {
  private let pgrepStdout: String?
  private(set) var commands: [[String]] = []

  init(pgrepStdout: String? = "4242\n") {
    self.pgrepStdout = pgrepStdout
  }

  func run(_ command: [String]) -> String? {
    commands.append(command)
    guard command.first == "pgrep" else { return "" }
    return pgrepStdout
  }
}

/// Stands in for `ghostty_surface_process_exited`. A healthy teardown reports the
/// child as gone; a wedged pty never does.
@MainActor
private final class ProbeSpy {
  var hasExited: Bool

  init(hasExited: Bool) {
    self.hasExited = hasExited
  }

  func probe(_ view: GhosttySurfaceView) -> Bool { hasExited }
}

/// Counts frees PER SURFACE so "freed exactly once" is a real assertion, and still
/// performs the real free so the test process leaks nothing.
@MainActor
private final class FreeSpy {
  private(set) var freedSurfaceIDs: [UUID] = []

  func free(_ view: GhosttySurfaceView) {
    freedSurfaceIDs.append(view.id)
    view.performDeferredFree()
  }

  func freeCount(_ id: UUID) -> Int {
    freedSurfaceIDs.filter { $0 == id }.count
  }
}

/// Weak handle: the queue is the last strong reference, so a resolved teardown is
/// only observable as a dealloc.
@MainActor
private final class WeakSurfaceRef {
  weak var view: GhosttySurfaceView?
}

/// Behavior D: the deferred path must not TRADE the deadlock for a leak. On the
/// happy path — pty child exits promptly — every surface handed to
/// `SurfaceTeardownQueue` gets freed exactly once, the queue empties, its per-view
/// Tasks are dropped, and nothing lands in the leak bucket.
///
/// Everything here drives the REAL close / hibernate paths through
/// `WorktreeTerminalState`; only the queue's three side-effecting edges (shell,
/// clock, exit probe / free) are doubled.
@MainActor
@Suite(.serialized, .dependencies)
struct HappyPathTeardownTests {
  private func makeWorktree() -> Worktree {
    let id = "/tmp/repo/wt-happy-teardown"
    return Worktree(
      id: WorktreeID(id),
      name: URL(fileURLWithPath: id).lastPathComponent,
      detail: "detail",
      workingDirectory: URL(fileURLWithPath: id),
      repositoryRootURL: URL(fileURLWithPath: "/tmp/repo")
    )
  }

  private func makeQueue(
    shell: ShellSpy,
    clock: any Clock<Duration>,
    probe: ProbeSpy,
    free: FreeSpy
  ) -> SurfaceTeardownQueue {
    SurfaceTeardownQueue(
      shell: SurfaceTeardownShell { executable, arguments in
        await shell.run([executable.lastPathComponent] + arguments)
      },
      clock: clock,
      analytics: .testValue,
      hasProcessExited: { probe.probe($0) },
      free: { free.free($0) }
    )
  }

  private func makeState(runtime: GhosttyRuntime) -> WorktreeTerminalState {
    HibernationTestSupport.enableHibernation()
    return withDependencies {
      $0.continuousClock = ImmediateClock()
      $0.date.now = Date(timeIntervalSince1970: 0)
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

  private func weakRefs(_ views: [GhosttySurfaceView]) -> [WeakSurfaceRef] {
    views.map { view in
      let ref = WeakSurfaceRef()
      ref.view = view
      return ref
    }
  }

  /// Whether every view is gone, retried across a BOUNDED number of yields.
  ///
  /// Two Objective-C facts make a single read unreliable, and neither is a leak:
  /// reading a weak reference to a live `NSView` retains AND autoreleases it (so the
  /// read itself props the view up inside the current pool), and the release that
  /// follows the queue's last `release` lands one statement later. Each attempt
  /// therefore reads inside its own `autoreleasepool` so the read's own temporary
  /// drains, and the loop yields instead of sleeping. It still bites: a view the
  /// queue (or anything else) actually owns never goes nil, which is exactly what
  /// the wedged-probe mutation shows.
  private func awaitDeallocated(_ refs: [WeakSurfaceRef]) async -> Bool {
    for _ in 0..<10 {
      if autoreleasepool(invoking: { refs.allSatisfy { $0.view == nil } }) { return true }
      await Task.megaYield()
    }
    return autoreleasepool { refs.allSatisfy { $0.view == nil } }
  }

  /// Agent records embedded in a dormant layout, by surface id. Walks the node
  /// directly instead of going through `captureLayoutSnapshot()`, which re-derives
  /// dormant agents from the LIVE map and would mask what hibernation captured.
  private func layoutAgents(
    _ node: TerminalLayoutSnapshot.LayoutNode
  ) -> [UUID: [TerminalLayoutSnapshot.SurfaceAgentRecord]] {
    switch node {
    case .leaf(let surface):
      guard let id = surface.id, let agents = surface.agents else { return [:] }
      return [id: agents]
    case .split(let split):
      return layoutAgents(split.left).merging(layoutAgents(split.right)) { first, _ in first }
    }
  }

  /// Closing a multi-leaf tab with a healthy teardown: every leaf is freed exactly
  /// once, the queue is empty, its Tasks are gone, and no view is retained — i.e.
  /// deferring the free did not turn into leaking it.
  @Test func closingAMultiLeafTabFreesEverySurfaceExactlyOnce() async {
    let probe = ProbeSpy(hasExited: true)
    let free = FreeSpy()
    let queue = makeQueue(shell: ShellSpy(), clock: TestClock(), probe: probe, free: free)
    let runtime = GhosttyRuntime(surfaceTeardownQueue: queue)
    let state = makeState(runtime: runtime)

    var refs: [WeakSurfaceRef] = []
    var surfaceIDs: [UUID] = []
    var tasks: [Task<Void, Never>] = []
    // Surface creation autoreleases the views, so the whole live phase sits in one
    // pool and the dealloc checks run after it drains.
    autoreleasepool {
      let tab = state.createTab(focusing: false)!
      #expect(state.performSplitAction(.newSplit(direction: .right), for: leaves(state, tab: tab)[0].id))
      let views = leaves(state, tab: tab)
      #expect(views.count == 2)
      surfaceIDs = views.map(\.id)
      refs = weakRefs(views)

      state.closeTab(tab)

      // Grab the Tasks while the views still exist: they are the only handle on
      // "teardown finished", and awaiting them is what replaces Task.sleep.
      tasks = views.compactMap { queue.teardownTask(for: $0) }
      #expect(tasks.count == 2)
    }

    for task in tasks { await task.value }

    #expect(surfaceIDs.count == 2)
    #expect(surfaceIDs.allSatisfy { free.freeCount($0) == 1 })
    #expect(free.freedSurfaceIDs.count == 2)
    #expect(queue.pendingCount == 0)
    #expect(queue.pendingSurfaceIDs.isEmpty)
    #expect(queue.leakedCount == 0)
    // No Task outlives its surface, so a long session can't accumulate them.
    #expect(queue.teardownTaskCount == 0)
    // The queue was the last owner; a resolved teardown releases the view.
    #expect(refs.count == 2)
    #expect(await awaitDeallocated(refs))
  }

  /// Same proof for hibernation, the path the original deadlock came from.
  @Test func hibernatingAMultiLeafTabFreesEverySurfaceExactlyOnce() async {
    let probe = ProbeSpy(hasExited: true)
    let free = FreeSpy()
    let queue = makeQueue(shell: ShellSpy(), clock: TestClock(), probe: probe, free: free)
    let runtime = GhosttyRuntime(surfaceTeardownQueue: queue)
    let state = makeState(runtime: runtime)

    var refs: [WeakSurfaceRef] = []
    var surfaceIDs: [UUID] = []
    var tasks: [Task<Void, Never>] = []
    var tab: TerminalTabID!
    autoreleasepool {
      tab = state.createTab(focusing: false)!
      #expect(state.performSplitAction(.newSplit(direction: .right), for: leaves(state, tab: tab)[0].id))
      let views = leaves(state, tab: tab)
      #expect(views.count == 2)
      surfaceIDs = views.map(\.id)
      refs = weakRefs(views)

      state.hibernateTabForTesting(tab)

      tasks = views.compactMap { queue.teardownTask(for: $0) }
      #expect(tasks.count == 2)
    }

    for task in tasks { await task.value }

    #expect(surfaceIDs.count == 2)
    #expect(surfaceIDs.allSatisfy { free.freeCount($0) == 1 })
    #expect(queue.pendingCount == 0)
    #expect(queue.leakedCount == 0)
    #expect(queue.teardownTaskCount == 0)
    #expect(refs.count == 2)
    #expect(await awaitDeallocated(refs))
    // The tab is still dormant with its layout intact: freeing the surfaces is not
    // allowed to disturb the dormant entry it left behind.
    #expect(state.isTabDormant(tab))
    #expect(Set(state.dormantTabLayouts[tab]?.layout.leafSurfaceIDs ?? []) == Set(surfaceIDs))
  }

  /// `performHibernation` must capture the dormant layout BEFORE handing surfaces
  /// off, so a wedged teardown cannot cost the user their dormant tab. Pinned with
  /// an agents source derived from the LIVE tree: capture after hand-off (i.e. after
  /// the tree and bookkeeping are gone) would freeze empty records into the layout.
  @Test func dormantLayoutIsCapturedBeforeSurfaceHandOff() {
    // Wedged pty: the probe never reports an exit, so every hand-off stays pending
    // for the whole test — the worst case the ordering has to survive.
    let probe = ProbeSpy(hasExited: false)
    let free = FreeSpy()
    let queue = makeQueue(shell: ShellSpy(), clock: TestClock(), probe: probe, free: free)
    let runtime = GhosttyRuntime(surfaceTeardownQueue: queue)
    let state = makeState(runtime: runtime)
    let record = TerminalLayoutSnapshot.SurfaceAgentRecord(agent: "claude", pids: [42], activity: "busy")

    let tab = state.createTab(focusing: false)!
    #expect(state.performSplitAction(.newSplit(direction: .right), for: leaves(state, tab: tab)[0].id))
    let surfaceIDs = leaves(state, tab: tab).map(\.id)
    #expect(surfaceIDs.count == 2)
    state.hibernationAgentsBySurface = { [weak state] in
      guard let state else { return [:] }
      // Only surfaces still IN the tree have agents, which is exactly the window
      // `captureLayoutNode` has to run inside.
      return Dictionary(
        uniqueKeysWithValues: (state.splitTree(for: tab).root?.leaves() ?? []).map { ($0.id, [record]) }
      )
    }

    state.hibernateTabForTesting(tab)

    let layout = state.dormantTabLayouts[tab]?.layout
    #expect(layout != nil)
    let agents = layout.map { layoutAgents($0) } ?? [:]
    #expect(Set(agents.keys) == Set(surfaceIDs))
    #expect(surfaceIDs.allSatisfy { agents[$0] == [record] })
    // And the wedge really is a wedge: nothing freed, everything still pending.
    #expect(free.freedSurfaceIDs.isEmpty)
    #expect(queue.pendingCount == 2)
  }
}

import Clocks
import ConcurrencyExtras
import Dependencies
import DependenciesTestSupport
import Foundation
import GhosttyKit
import Sharing
import Testing

@testable import supacode

/// Wake-while-teardown-pending. A dormant tab reuses its surface UUIDs on wake, so
/// the woken generation is a DIFFERENT view object under the SAME id while the old
/// generation is still parked in `SurfaceTeardownQueue`. Two things must hold for
/// the whole overlap: the queue keeps every generation (it is keyed by view
/// identity, not surface id), and the pending old view can never mutate state that
/// now belongs to the woken one.
///
/// The teardown queue's per-view Tasks only run at a suspension point, so these
/// tests are deliberately synchronous: entries stay pending for the whole test,
/// which is exactly the "teardown never resolves" (wedged pty) case.
@MainActor
@Suite(.serialized, .dependencies)
struct WakeWhileTeardownPendingTests {
  private func makeWorktree() -> Worktree {
    let id = "/tmp/repo/wt-wake-teardown"
    return Worktree(
      id: WorktreeID(id),
      name: URL(fileURLWithPath: id).lastPathComponent,
      detail: "detail",
      workingDirectory: URL(fileURLWithPath: id),
      repositoryRootURL: URL(fileURLWithPath: "/tmp/repo")
    )
  }

  /// State bound to a zmx client that reports an executable (so every surface is
  /// hibernation-eligible through the real `hibernateTab`) and records each kill.
  private func makeState(
    runtime: GhosttyRuntime,
    killed: LockIsolated<[String]> = LockIsolated([])
  ) -> WorktreeTerminalState {
    HibernationTestSupport.enableHibernation()
    return withDependencies {
      $0.continuousClock = ImmediateClock()
      $0.date.now = Date(timeIntervalSince1970: 0)
      $0.zmxClient = ZmxClient(
        executableURL: { URL(fileURLWithPath: "/usr/bin/true") },
        isBundled: { true },
        killSession: { id in killed.withValue { $0.append(id) } },
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

  /// Wake mints a NEW view per frozen leaf under the ORIGINAL surface id, while the
  /// old generation is still pending: the tab is live again and nothing about the
  /// pending teardown was skipped or resolved by the wake.
  @Test func wakeMintsANewGenerationWhileTheOldViewStaysPending() {
    let runtime = GhosttyRuntime()
    let killed = LockIsolated<[String]>([])
    let state = makeState(runtime: runtime, killed: killed)
    let queue = runtime.surfaceTeardownQueue
    let tab = state.createTab(focusing: false)!
    let oldViews = leaves(state, tab: tab)
    let surfaceIDs = oldViews.map(\.id)
    #expect(!surfaceIDs.isEmpty)

    #expect(state.canHibernate(tabId: tab))
    state.hibernateTab(tab)
    #expect(queue.pendingCount == oldViews.count)

    state.wakeTab(tab)

    let newViews = leaves(state, tab: tab)
    // Same surface ids (the zmx session is reattached under its original id)...
    #expect(newViews.map(\.id) == surfaceIDs)
    // ...but different objects: the woken generation is a fresh view.
    #expect(zip(newViews, oldViews).allSatisfy { $0 !== $1 })
    // The tab is fully awake again.
    #expect(state.dormantTabLayouts[tab] == nil)
    #expect(!state.isTabDormant(tab))
    #expect(state.surfaceIDs(inTab: tab) == surfaceIDs)
    // ...and the OLD generation is still queued: a wake neither frees nor drops it.
    #expect(queue.pendingCount == oldViews.count)
    #expect(queue.pendingSurfaceIDs == Set(surfaceIDs))
    #expect(oldViews.allSatisfy { queue.stage(for: $0) == .killRequested })
    // The pending entries are the OLD views, never the live ones — freeing a
    // surface that is back in the tree would tear down a working terminal.
    #expect(newViews.allSatisfy { queue.stage(for: $0) == nil })
    // Reattach never kills the session.
    #expect(killed.value.isEmpty)
  }

  /// Re-hibernating while the first generation is still pending must hand the
  /// SECOND generation off too. The queue is keyed by view identity for exactly
  /// this: a surface-id-keyed queue would treat the new view as already pending,
  /// skip the hand-off, and let its free run inline on the main actor — the
  /// deadlock this whole change exists to remove.
  @Test func reHibernatingQueuesBothGenerationsOfTheSameSurfaceID() {
    let runtime = GhosttyRuntime()
    let killed = LockIsolated<[String]>([])
    let state = makeState(runtime: runtime, killed: killed)
    let queue = runtime.surfaceTeardownQueue
    let tab = state.createTab(focusing: false)!
    let firstGeneration = leaves(state, tab: tab)
    let surfaceIDs = firstGeneration.map(\.id)

    state.hibernateTab(tab)
    state.wakeTab(tab)
    let secondGeneration = leaves(state, tab: tab)
    #expect(zip(secondGeneration, firstGeneration).allSatisfy { $0 !== $1 })

    #expect(state.canHibernate(tabId: tab))
    state.hibernateTab(tab)

    // Both generations own a live ghostty surface, so both must be pending under
    // the one reused surface id.
    #expect(queue.pendingCount == 2 * firstGeneration.count)
    #expect(queue.pendingSurfaceIDs == Set(surfaceIDs))
    #expect(firstGeneration.allSatisfy { queue.stage(for: $0) == .killRequested })
    #expect(secondGeneration.allSatisfy { queue.stage(for: $0) == .killRequested })
    // Each generation got its OWN teardown Task, i.e. its own attach-client kill:
    // the second hand-off was not deduped away.
    #expect(secondGeneration.allSatisfy { queue.teardownTask(for: $0) != nil })
    #expect(queue.leakedCount == 0)
    #expect(state.isTabDormant(tab))
    #expect(killed.value.isEmpty)
  }

  /// No callback crossover. A pending view keeps its ghostty bridge closures (they
  /// are what a late runtime callback lands on), and its surface id now resolves to
  /// the WOKEN view — so every closure must be inert. The protection is the
  /// `surfaces[view.id] === view` identity guard, not key presence.
  @Test func staleCallbacksFromThePendingViewCannotMutateTheWokenTab() {
    let runtime = GhosttyRuntime()
    let killed = LockIsolated<[String]>([])
    let state = makeState(runtime: runtime, killed: killed)
    let tab = state.createTab(focusing: false)!
    let oldView = leaves(state, tab: tab)[0]
    let surfaceID = oldView.id
    #expect(state.renameTab(tab, title: "Awake"))

    state.hibernateTab(tab)
    state.wakeTab(tab)
    let newView = leaves(state, tab: tab)[0]
    #expect(newView !== oldView)
    #expect(newView.id == surfaceID)

    var closedSurfaces: Set<UUID> = []
    var removedTabs: [TerminalTabID] = []
    state.onSurfacesClosed = { closedSurfaces.formUnion($0) }
    state.onTabRemoved = { removedTabs.append($0) }

    // Every callback the runtime can still deliver to the pending view.
    oldView.bridge.onCloseRequest?(false)
    oldView.bridge.onTitleChange?("STALE")
    oldView.bridge.onDesktopNotification?("stale", "body")
    let handledSplit = oldView.bridge.onSplitAction?(.newSplit(direction: .right)) ?? false
    let handledNewTab = oldView.bridge.onNewTab?() ?? false
    let handledCloseTab = oldView.bridge.onCloseTab?(GHOSTTY_ACTION_CLOSE_TAB_MODE_THIS) ?? false

    // Nothing was handled, and nothing about the woken tab moved.
    #expect(!handledSplit)
    #expect(!handledNewTab)
    #expect(!handledCloseTab)
    #expect(closedSurfaces.isEmpty)
    #expect(removedTabs.isEmpty)
    #expect(killed.value.isEmpty)
    #expect(state.hasTab(tab))
    #expect(state.tabManager.tabs.count == 1)
    #expect(state.surfaceIDs(inTab: tab) == [surfaceID])
    #expect(leaves(state, tab: tab)[0] === newView)
    #expect(state.tabManager.tabs[0].customTitle == "Awake")
    #expect(!state.hasUnseenNotification)
    #expect(state.pendingCloseConfirmation == nil)
  }
}

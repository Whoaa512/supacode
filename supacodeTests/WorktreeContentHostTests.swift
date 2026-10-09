import AppKit
import Clocks
import Dependencies
import DependenciesTestSupport
import Foundation
import GhosttyKit
import IdentifiedCollections
import Sharing
import SupacodeSettingsShared
import Testing

@testable import supacode

@MainActor
struct WorktreeContentHostTests {
  private func makeWorktree(id: String = "/tmp/repo/wt-host") -> Worktree {
    Worktree(
      id: WorktreeID(id),
      name: URL(fileURLWithPath: id).lastPathComponent,
      detail: "detail",
      workingDirectory: URL(fileURLWithPath: id),
      repositoryRootURL: URL(fileURLWithPath: "/tmp/repo")
    )
  }

  private func singleTabLayout(contentID: UUID) -> PaneLayout {
    let paneID = PaneID()
    let tabID = TabID(rawValue: contentID)
    return PaneLayout(
      tree: SplitTree(view: paneID),
      panes: [
        Pane(
          id: paneID,
          tabs: [
            TabItem(
              id: tabID,
              title: "Tab",
              content: ContentSnapshot(
                id: ContentID(rawValue: contentID),
                state: .terminal(TerminalContentState(workingDirectory: nil))
              )
            )
          ],
          selectedTabID: tabID
        )
      ],
      focusedPaneID: paneID
    )
  }

  private func makeHost(layout: PaneLayout?, runtime: ContentRuntime = ContentRuntime()) -> WorktreeContentHost {
    let host = WorktreeContentHost(
      context: DirectoryContext(worktree: makeWorktree()),
      runtime: runtime,
      clock: ContinuousClock()
    )
    host.layout = { layout }
    return host
  }

  private func append(_ titles: some Sequence<String>, to host: WorktreeContentHost, surfaceID: UUID) {
    withDependencies {
      $0.date = .constant(Date(timeIntervalSince1970: 0))
    } operation: {
      for title in titles {
        host.appendNotification(title: title, body: "body", surfaceID: surfaceID)
      }
    }
  }

  @Test(.dependencies) func retentionTrimKeepsTheNewestUnread() {
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global.notificationRetentionLimit = .oneHundred }
    let surfaceID = UUID()
    let host = makeHost(layout: singleTabLayout(contentID: surfaceID))
    host.registerSurfaceState(for: surfaceID)

    append((0...100).map { "N\($0)" }, to: host, surfaceID: surfaceID)

    #expect(host.notifications.count == 100)
    // Every entry is unread, so the OLDEST drops and the newest survives.
    #expect(host.notifications.first?.title == "N100")
    #expect(!host.notifications.contains { $0.title == "N0" })
  }

  @Test(.dependencies) func retentionTrimDropsReadBeforeUnreadRegardlessOfAge() throws {
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global.notificationRetentionLimit = .oneHundred }
    let surfaceID = UUID()
    let host = makeHost(layout: singleTabLayout(contentID: surfaceID))
    host.registerSurfaceState(for: surfaceID)

    append((0...99).map { "N\($0)" }, to: host, surfaceID: surfaceID)
    let read = try #require(host.notifications.first { $0.title == "N50" })
    host.markNotificationRead(id: read.id)
    append(["N100"], to: host, surfaceID: surfaceID)

    #expect(host.notifications.count == 100)
    // The read entry goes first, even though older unread entries exist.
    #expect(!host.notifications.contains { $0.title == "N50" })
    #expect(host.notifications.contains { $0.title == "N0" })
    #expect(host.notifications.first?.title == "N100")
  }

  @Test(.dependencies) func unseenCounterCountsFromRegistrationAtProvision() {
    let surfaceID = UUID()
    let host = makeHost(layout: singleTabLayout(contentID: surfaceID))
    // Provision-time registration: without it the increment would no-op.
    host.registerSurfaceState(for: surfaceID)

    append(["Ping"], to: host, surfaceID: surfaceID)

    #expect(host.surfaceStates[surfaceID]?.unseenNotificationCount == 1)
    #expect(host.hasUnseenNotification)
  }

  /// #828: a tracked blocking script alone must not shimmer the worktree row.
  /// Only genuine OSC-9 progress does, and a completed-parked script's lingering
  /// progress stays off the row.
  @Test func rowActivityBusyReflectsProgressNotScriptPresence() {
    #expect(!WorktreeContentHost.isTabActivityBusy(isCompletedBlockingScript: false, progressState: nil))
    #expect(
      WorktreeContentHost.isTabActivityBusy(
        isCompletedBlockingScript: false, progressState: GHOSTTY_PROGRESS_STATE_SET
      ))
    #expect(
      WorktreeContentHost.isTabActivityBusy(
        isCompletedBlockingScript: false, progressState: GHOSTTY_PROGRESS_STATE_INDETERMINATE
      ))
    #expect(
      !WorktreeContentHost.isTabActivityBusy(
        isCompletedBlockingScript: true, progressState: GHOSTTY_PROGRESS_STATE_SET
      ))
  }

  @Test(.dependencies) func blockingScriptCompletionLocksTheTabChrome() {
    let surfaceID = UUID()
    let tabID = TabID(rawValue: surfaceID)
    let runtime = ContentRuntime()
    let content = ChromeTabContent(id: ContentID(rawValue: surfaceID))
    #expect(runtime.provision(content, at: .fallback))
    let host = makeHost(layout: singleTabLayout(contentID: surfaceID), runtime: runtime)

    host.trackBlockingScript(kind: .archive, tabID: tabID, launchDirectory: nil)
    #expect(content.terminalChrome.isReadOnly == false)

    host.handleBlockingScriptCommandFinished(tabID: tabID, exitCode: 0)
    #expect(content.terminalChrome.isReadOnly)

    // Re-running the script unlocks the parked shell's replacement.
    host.trackBlockingScript(kind: .archive, tabID: tabID, launchDirectory: nil)
    #expect(content.terminalChrome.isReadOnly == false)
  }

  @Test func aReportedTitleLandsOnTheChromeAndRearmsPersistenceOnce() {
    let surfaceID = UUID()
    let contentID = ContentID(rawValue: surfaceID)
    let runtime = ContentRuntime()
    let content = ChromeTabContent(id: contentID)
    #expect(runtime.provision(content, at: .fallback))
    let host = makeHost(layout: singleTabLayout(contentID: surfaceID), runtime: runtime)
    var sentLayoutActions = 0
    var persistenceRearms = 0
    host.sendLayoutAction = { _ in sentLayoutActions += 1 }
    host.onReportedTitleChanged = { persistenceRearms += 1 }

    host.updateReportedTitle(for: contentID, title: "claude")
    // An unchanged report is dropped before it can touch the chrome.
    host.updateReportedTitle(for: contentID, title: "claude")

    #expect(content.terminalChrome.reportedTitle == "claude")
    #expect(persistenceRearms == 1)
    // The whole point: a title storm never reaches the store.
    #expect(sentLayoutActions == 0)
  }

  @Test(.dependencies) func anEmptyReportedTitleIsIgnoredSoTheLabelHoldsItsLastValue() {
    let surfaceID = UUID()
    let contentID = ContentID(rawValue: surfaceID)
    let runtime = ContentRuntime()
    let content = ChromeTabContent(id: contentID)
    #expect(runtime.provision(content, at: .fallback))
    let host = makeHost(layout: singleTabLayout(contentID: surfaceID), runtime: runtime)
    var persistenceRearms = 0
    host.onReportedTitleChanged = { persistenceRearms += 1 }

    host.updateReportedTitle(for: contentID, title: "~/project")
    // A shell that clears the title mid-command must not flash the label: the
    // empty and whitespace reports are dropped, keeping the last real title.
    host.updateReportedTitle(for: contentID, title: "")
    host.updateReportedTitle(for: contentID, title: "   ")

    #expect(content.terminalChrome.reportedTitle == "~/project")
    #expect(persistenceRearms == 1)
  }

  // MARK: - Tabs moving between tasks.

  /// A layout the test edits, as the store would.
  @MainActor
  private final class LayoutBox {
    var layout: PaneLayout
    init(_ layout: PaneLayout) { self.layout = layout }
  }

  /// What a host reported: a moved tab must report nothing.
  @MainActor
  private final class Reports {
    var closed: [Set<UUID>] = []
    var userClosed: [Set<UUID>] = []
    var hibernated: [Set<UUID>] = []
    var scripts = 0
    var received: [String] = []
  }

  private struct TransferFixture {
    let host: WorktreeContentHost
    let box: LayoutBox
    let reports: Reports
  }

  private func tabs(_ surfaceIDs: [UUID]) -> [TabItem] {
    surfaceIDs.map {
      TabItem(
        id: TabID(rawValue: $0), title: "Tab",
        content: ContentSnapshot(
          id: ContentID(rawValue: $0), state: .terminal(TerminalContentState(workingDirectory: nil))))
    }
  }

  private func layout(_ surfaceIDs: [UUID]) -> PaneLayout {
    guard let first = surfaceIDs.first else { return PaneLayout() }
    let paneID = PaneID()
    return PaneLayout(
      tree: SplitTree(view: paneID),
      panes: [
        Pane(id: paneID, tabs: IdentifiedArray(uniqueElements: tabs(surfaceIDs)), selectedTabID: TabID(rawValue: first))
      ],
      focusedPaneID: paneID)
  }

  /// A swept host over an editable layout, with every report recorded.
  private func makeTransferHost(
    _ surfaceIDs: [UUID], runtime: ContentRuntime = ContentRuntime(), clock: any Clock<Duration> = ContinuousClock()
  ) -> TransferFixture {
    let box = LayoutBox(layout(surfaceIDs))
    let reports = Reports()
    let host = WorktreeContentHost(context: DirectoryContext(worktree: makeWorktree()), runtime: runtime, clock: clock)
    host.layout = { box.layout }
    host.onSurfacesClosed = { reports.closed.append($0) }
    host.onUserClosedSurfaces = { reports.userClosed.append($0) }
    host.onSurfacesHibernated = { reports.hibernated.append($0) }
    host.onBlockingScriptCompleted = { _, _, _ in reports.scripts += 1 }
    host.onNotificationReceived = { _, title, _, _ in reports.received.append(title) }
    for surfaceID in surfaceIDs { host.registerSurfaceState(for: surfaceID) }
    host.reconcileContentLifecycle()
    reports.hibernated = []
    return TransferFixture(host: host, box: box, reports: reports)
  }

  /// Moves one tab the way the manager does: forget, change the layouts, adopt.
  private func move(
    _ surfaceID: UUID, from source: TransferFixture, to destination: TransferFixture
  ) {
    let kept = source.box.layout.allContentIDs.map(\.rawValue).filter { $0 != surfaceID }
    let grown = destination.box.layout.allContentIDs.map(\.rawValue) + [surfaceID]
    let baggage = source.host.relinquish(tabs([surfaceID]))
    source.box.layout = layout(kept)
    destination.box.layout = layout(grown)
    destination.host.adopt(baggage)
  }

  @Test(.dependencies) func relinquishEmitsNothingAndTheNextSweepIsSilent() {
    let (staying, leaving) = (UUID(), UUID())
    let source = makeTransferHost([staying, leaving])
    source.host.markUserCloseIntent(for: [leaving])

    _ = source.host.relinquish(tabs([leaving]))
    source.box.layout = layout([staying])
    source.host.reconcileContentLifecycle()

    #expect(source.reports.closed.isEmpty, "a tab that moved away did not close")
    #expect(source.reports.userClosed.isEmpty)
    #expect(source.reports.scripts == 0)
    #expect(source.host.surfaceStates[leaving] == nil)

    // The tab that stayed still closes like any other.
    source.box.layout = layout([])
    source.host.reconcileContentLifecycle()
    #expect(source.reports.closed == [[staying]])
  }

  @Test(.dependencies) func adoptKeepsCountersNotificationsAndOrder() throws {
    let (own, moved) = (UUID(), UUID())
    let source = makeTransferHost([moved])
    let destination = makeTransferHost([own])
    func notify(_ host: WorktreeContentHost, _ title: String, on surfaceID: UUID, at seconds: TimeInterval) {
      withDependencies {
        $0.date = .constant(Date(timeIntervalSince1970: seconds))
      } operation: {
        host.appendNotification(title: title, body: "body", surfaceID: surfaceID)
      }
    }
    notify(destination.host, "own-1", on: own, at: 1)
    notify(source.host, "moved-2", on: moved, at: 2)
    notify(destination.host, "own-3", on: own, at: 3)
    notify(source.host, "moved-4", on: moved, at: 4)
    let counter = try #require(source.host.surfaceStates[moved])
    #expect(counter.unseenNotificationCount == 2)

    move(moved, from: source, to: destination)

    #expect(source.host.notifications.isEmpty)
    #expect(!source.host.hasUnseenNotification)
    // Newest first across both logs.
    #expect(destination.host.notifications.map(\.title) == ["moved-4", "own-3", "moved-2", "own-1"])
    // The same counter instance: the tab badge that observes it keeps counting.
    #expect(destination.host.surfaceStates[moved] === counter)
    #expect(destination.host.totalUnseenNotificationCount == 4)
    #expect(destination.host.unseenNotificationCount(forTabID: TabID(rawValue: moved)) == 2)
  }

  @Test(.dependencies) func adoptTrimsTheJoinedLogToTheRetentionLimit() {
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global.notificationRetentionLimit = .oneHundred }
    let (own, moved) = (UUID(), UUID())
    let source = makeTransferHost([moved])
    let destination = makeTransferHost([own])
    append((1...60).map { "moved-\($0)" }, to: source.host, surfaceID: moved)
    append((1...60).map { "own-\($0)" }, to: destination.host, surfaceID: own)

    move(moved, from: source, to: destination)

    #expect(destination.host.notifications.count == 100)
  }

  @Test(.dependencies) func adoptedDormantSurfaceDoesNotReportHibernated() {
    let moved = UUID()
    // Nothing is provisioned, so the tab is hibernated in both hosts' eyes.
    let source = makeTransferHost([moved])
    let destination = makeTransferHost([])

    move(moved, from: source, to: destination)
    destination.host.reconcileContentLifecycle()
    source.host.reconcileContentLifecycle()

    #expect(destination.reports.hibernated.isEmpty, "it was hibernated before it arrived")
    #expect(destination.reports.closed.isEmpty)
    #expect(source.reports.closed.isEmpty)
    #expect(destination.host.watchedDormantSurfaceIDsForTesting == [moved])
    #expect(source.host.watchedDormantSurfaceIDsForTesting.isEmpty)
  }

  @Test(.dependencies) func heldOSCIsDeliveredByTheAdopter() async {
    let moved = UUID()
    let clock = TestClock()
    let source = makeTransferHost([moved], clock: clock)
    let destination = makeTransferHost([], clock: clock)
    source.host.handleAgentOSCNotification(title: "held", body: "body", surfaceID: moved)

    // The re-held timer is a task: it carries the date it will stamp with.
    await withDependencies {
      $0.date = .constant(Date(timeIntervalSince1970: 0))
    } operation: {
      move(moved, from: source, to: destination)
      // Let the re-held timer start sleeping before time moves.
      await Task.megaYield()
      await clock.advance(by: .seconds(AgentSignal.oscHoldWindow))
      await Task.megaYield()
    }

    #expect(destination.reports.received == ["held"], "held again where the tab is now, not dropped")
    #expect(source.reports.received.isEmpty)
  }

  @Test(.dependencies) func closeIntentTravels() {
    let moved = UUID()
    let source = makeTransferHost([moved])
    let destination = makeTransferHost([])
    source.host.markUserCloseIntent(for: [moved])

    move(moved, from: source, to: destination)
    // The close the user already asked for lands after the move.
    destination.box.layout = layout([])
    destination.host.reconcileContentLifecycle()

    #expect(destination.reports.userClosed == [[moved]])
    #expect(destination.reports.closed == [[moved]])
    #expect(source.reports.userClosed.isEmpty)
    #expect(source.reports.closed.isEmpty)
  }

  @Test(.dependencies) func completedScriptTabStaysFrozen() {
    let moved = UUID()
    let tabID = TabID(rawValue: moved)
    let runtime = ContentRuntime()
    let content = ChromeTabContent(id: ContentID(rawValue: moved))
    #expect(runtime.provision(content, at: .fallback))
    let source = makeTransferHost([moved], runtime: runtime)
    let destination = makeTransferHost([], runtime: runtime)
    source.host.trackBlockingScript(kind: .archive, tabID: tabID, launchDirectory: nil)
    source.host.handleBlockingScriptCommandFinished(tabID: tabID, exitCode: 0)

    move(moved, from: source, to: destination)

    #expect(destination.host.isFrozenBlockingScriptSurface(moved))
    #expect(destination.host.isBlockingScriptCompleted(tabID))
    #expect(content.terminalChrome.isReadOnly, "the parked shell stays locked")
    #expect(!source.host.isBlockingScript(tabID))
    #expect(source.host.lingeringBlockingScriptTab(for: .archive) == nil)
  }

  @Test(.dependencies) func aTabOfAHostlessTaskArrivesWithItsDormancyKnown() {
    let moved = UUID()
    let destination = makeTransferHost([])

    destination.box.layout = layout([moved])
    destination.host.adopt(WorktreeContentHost.bare(tabs([moved]), runtime: ContentRuntime()))
    destination.host.reconcileContentLifecycle()

    #expect(destination.reports.hibernated.isEmpty)
    destination.box.layout = layout([])
    destination.host.reconcileContentLifecycle()
    #expect(destination.reports.closed == [[moved]], "the baseline holds it, so its close is seen")
  }
}

/// Pins the render-host claim invariants the steal-proof mount depends on.
@MainActor
struct WorktreeContentRuntimeRenderHostTests {
  @Test func aNewerClaimInvalidatesTheOlderOne() {
    let runtime = ContentRuntime()
    let contentID = ContentID()
    let first = runtime.claimRenderHost(for: contentID)
    #expect(runtime.isCurrentRenderHost(first, for: contentID))
    let second = runtime.claimRenderHost(for: contentID)
    #expect(!runtime.isCurrentRenderHost(first, for: contentID))
    #expect(runtime.isCurrentRenderHost(second, for: contentID))
  }

  @Test func aClaimSurvivesRemovalForTheReattachFlow() {
    let runtime = ContentRuntime()
    let content = ChromeTabContent(id: ContentID())
    #expect(runtime.provision(content, at: .fallback))
    let claim = runtime.claimRenderHost(for: content.id)
    // Reattach removes and re-provisions the same ID under the live host.
    runtime.remove(content.id, tombstone: false)
    #expect(runtime.isCurrentRenderHost(claim, for: content.id))
  }

  @Test func confirmKillReleasesTheClaim() {
    let runtime = ContentRuntime()
    let content = ChromeTabContent(id: ContentID())
    #expect(runtime.provision(content, at: .fallback))
    let claim = runtime.claimRenderHost(for: content.id)
    runtime.remove(content.id, tombstone: true)
    runtime.confirmKill(content.id)
    #expect(!runtime.isCurrentRenderHost(claim, for: content.id))
  }

}

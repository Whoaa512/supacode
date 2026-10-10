import AppKit
import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import SupacodeSettingsShared
import Testing

@testable import supacode

@MainActor
struct TerminalsFeatureTests {
  /// Minimal live content whose renderer and eligibility the tests control.
  @MainActor
  private final class HibernatableContent: TabContent {
    let id: ContentID
    let kind: ContentKind = .terminal
    /// Eligibility knob for the fire-time re-arm path.
    var claimsHibernation = true
    private(set) var startCalls = 0
    private var view: NSView?
    private let state: TerminalContentState

    init(id: ContentID, state: TerminalContentState = TerminalContentState(workingDirectory: nil)) {
      self.id = id
      self.state = state
    }

    var renderer: NSView? { view }
    var isHibernatable: Bool { view != nil && claimsHibernation }

    func startSession(at geometry: ContentGeometry) {
      startCalls += 1
      guard view == nil else { return }
      view = NSView()
    }

    func hibernate() {
      view = nil
    }

    func snapshot() -> ContentSnapshot {
      ContentSnapshot(id: id, state: .terminal(state))
    }
  }
  private static func layout(paneID: PaneID, tabID: TabID, contentID: ContentID) -> PaneLayout {
    PaneLayout(
      tree: SplitTree(view: paneID),
      panes: [
        Pane(
          id: paneID,
          tabs: [
            TabItem(
              id: tabID,
              title: "One",
              content: ContentSnapshot(
                id: contentID,
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

  // MARK: - Hibernation.

  private struct HibernationHarness {
    let store: TestStoreOf<TerminalsFeature>
    let clock: TestClock<Duration>
    let runtime: ContentRuntime
    let worktreeID: LayoutID
    let paneID: PaneID
    let selectedTab: TabID
    let hiddenTab: TabID
    let selectedContent: HibernatableContent
    let hiddenContent: HibernatableContent
    /// Drives injected memory-pressure warnings; `.task` must be sent to subscribe.
    let pressure: AsyncStream<Void>.Continuation
  }

  /// One worktree, one pane, two tabs; both contents live in the runtime.
  private func makeHibernationHarness(startSessions: Bool = true) -> HibernationHarness {
    let worktreeID = LayoutID(legacyWorktreeKey: "/tmp/hib")
    let paneID = PaneID()
    let selectedTab = TabID()
    let hiddenTab = TabID()
    let selectedContent = HibernatableContent(id: ContentID())
    let hiddenContent = HibernatableContent(id: ContentID())
    let runtime = ContentRuntime()
    if startSessions {
      _ = runtime.provision(selectedContent, at: .fallback)
      _ = runtime.provision(hiddenContent, at: .fallback)
    }
    let layout = PaneLayout(
      tree: SplitTree(view: paneID),
      panes: [
        Pane(
          id: paneID,
          tabs: [
            TabItem(
              id: selectedTab,
              title: "One",
              content: ContentSnapshot(
                id: selectedContent.id,
                state: .terminal(TerminalContentState(workingDirectory: nil))
              )
            ),
            TabItem(
              id: hiddenTab,
              title: "Two",
              content: ContentSnapshot(
                id: hiddenContent.id,
                state: .terminal(TerminalContentState(workingDirectory: nil))
              )
            ),
          ],
          selectedTabID: selectedTab
        )
      ],
      focusedPaneID: paneID
    )
    let clock = TestClock()
    let pressure = AsyncStream<Void>.makeStream()
    let store = TestStore(
      initialState: TerminalsFeature.State(layouts: [LayoutFeature.State(id: worktreeID, layout: layout)])
    ) {
      TerminalsFeature()
    } withDependencies: {
      $0.continuousClock = clock
      $0.contentRuntime = runtime
      $0[ContentSessionKiller.self] = ContentSessionKiller(kill: { _, _ in })
      $0[MemoryPressureClient.self] = MemoryPressureClient(warnings: { pressure.stream })
    }
    return HibernationHarness(
      store: store,
      clock: clock,
      runtime: runtime,
      worktreeID: worktreeID,
      paneID: paneID,
      selectedTab: selectedTab,
      hiddenTab: hiddenTab,
      selectedContent: selectedContent,
      hiddenContent: hiddenContent,
      pressure: pressure.continuation
    )
  }

  @Test(.dependencies) func hiddenTabHibernatesAfterTheGraceWindow() async {
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global.terminalHibernationEnabled = true }
    let harness = makeHibernationHarness()
    await harness.store.send(.selectedLayoutChanged(harness.worktreeID)) {
      $0.selectedLayoutID = harness.worktreeID
      $0.recentLayoutIDs = [harness.worktreeID]
      $0.selectionOrder = [harness.worktreeID]
      $0.hibernationArmedTabs = [harness.hiddenTab]
    }
    await harness.clock.advance(by: TerminalsFeature.hibernationGraceWindow)
    await harness.store.receive(\.hibernationGraceElapsed) {
      $0.hibernationArmedTabs = []
    }
    await harness.store.receive(\.layouts) {
      $0.layouts[id: harness.worktreeID]?.renderEpoch = 1
    }
    #expect(harness.hiddenContent.renderer == nil)
    #expect(harness.selectedContent.renderer != nil)
  }

  @Test(.dependencies) func selectingTheTabCancelsItsGraceTimer() async {
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global.terminalHibernationEnabled = true }
    let harness = makeHibernationHarness()
    await harness.store.send(.selectedLayoutChanged(harness.worktreeID)) {
      $0.selectedLayoutID = harness.worktreeID
      $0.recentLayoutIDs = [harness.worktreeID]
      $0.selectionOrder = [harness.worktreeID]
      $0.hibernationArmedTabs = [harness.hiddenTab]
    }
    // Selecting the hidden tab makes it visible and hides the other one.
    await harness.store.send(
      .layouts(.element(id: harness.worktreeID, action: .selectTab(id: harness.hiddenTab)))
    ) {
      $0.layouts[id: harness.worktreeID]?.layout.panes[id: harness.paneID]?.selectedTabID = harness.hiddenTab
      $0.hibernationArmedTabs = [harness.selectedTab]
    }
    await harness.clock.advance(by: TerminalsFeature.hibernationGraceWindow)
    // Only the newly hidden tab fires; the cancelled timer stays silent.
    await harness.store.receive(\.hibernationGraceElapsed) {
      $0.hibernationArmedTabs = []
    }
    await harness.store.receive(\.layouts) {
      $0.layouts[id: harness.worktreeID]?.renderEpoch = 1
    }
    #expect(harness.hiddenContent.renderer != nil)
    #expect(harness.selectedContent.renderer == nil)
  }

  @Test(.dependencies) func disablingTheFlagCancelsPendingTimers() async {
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global.terminalHibernationEnabled = true }
    let harness = makeHibernationHarness()
    await harness.store.send(.selectedLayoutChanged(harness.worktreeID)) {
      $0.selectedLayoutID = harness.worktreeID
      $0.recentLayoutIDs = [harness.worktreeID]
      $0.selectionOrder = [harness.worktreeID]
      $0.hibernationArmedTabs = [harness.hiddenTab]
    }
    $settingsFile.withLock { $0.global.terminalHibernationEnabled = false }
    await harness.store.send(.hibernationPolicyChanged) {
      $0.hibernationArmedTabs = []
    }
    await harness.clock.advance(by: TerminalsFeature.hibernationGraceWindow)
    #expect(harness.hiddenContent.renderer != nil)
  }

  @Test(.dependencies) func ineligibleHiddenTabReArmsAtFireTime() async {
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global.terminalHibernationEnabled = true }
    let harness = makeHibernationHarness()
    harness.hiddenContent.claimsHibernation = false
    await harness.store.send(.selectedLayoutChanged(harness.worktreeID)) {
      $0.selectedLayoutID = harness.worktreeID
      $0.recentLayoutIDs = [harness.worktreeID]
      $0.selectionOrder = [harness.worktreeID]
      $0.hibernationArmedTabs = [harness.hiddenTab]
    }
    await harness.clock.advance(by: TerminalsFeature.hibernationGraceWindow)
    await harness.store.receive(\.hibernationGraceElapsed) {
      $0.hibernationDeferralLogged = [harness.hiddenTab]
    }
    #expect(harness.hiddenContent.renderer != nil)
    // Eligibility returns; the re-armed timer hibernates on the next window.
    harness.hiddenContent.claimsHibernation = true
    await harness.clock.advance(by: TerminalsFeature.hibernationGraceWindow)
    await harness.store.receive(\.hibernationGraceElapsed) {
      $0.hibernationArmedTabs = []
      $0.hibernationDeferralLogged = []
    }
    await harness.store.receive(\.layouts) {
      $0.layouts[id: harness.worktreeID]?.renderEpoch = 1
    }
    #expect(harness.hiddenContent.renderer == nil)
  }

  @Test(.dependencies) func selectingAWorktreeWakesItsHibernatedSelection() async {
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global.terminalHibernationEnabled = true }
    let harness = makeHibernationHarness()
    harness.selectedContent.hibernate()
    await harness.store.send(.selectedLayoutChanged(harness.worktreeID)) {
      $0.selectedLayoutID = harness.worktreeID
      $0.recentLayoutIDs = [harness.worktreeID]
      $0.selectionOrder = [harness.worktreeID]
      $0.hibernationArmedTabs = [harness.hiddenTab]
      $0.wakeRequestedTabs = [harness.selectedTab]
    }
    await harness.store.receive(\.layouts) {
      $0.layouts[id: harness.worktreeID]?.renderEpoch = 1
      $0.wakeRequestedTabs = []
    }
    #expect(harness.selectedContent.renderer != nil)
    // Drain the armed timer so the store finishes clean.
    $settingsFile.withLock { $0.global.terminalHibernationEnabled = false }
    await harness.store.send(.hibernationPolicyChanged) {
      $0.hibernationArmedTabs = []
    }
    await harness.store.finish()
  }

  @Test(.dependencies) func windowedPaneKeepsItsSelectionAwakeWhileTheWorktreeIsUnselected() async {
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global.terminalHibernationEnabled = true }
    let harness = makeHibernationHarness()
    await harness.store.send(
      .layouts(.element(id: harness.worktreeID, action: .enterWindowMode(paneID: harness.paneID)))
    ) {
      $0.layouts[id: harness.worktreeID]?.windowedPaneIDs = [harness.paneID]
      // The pane's unselected tab still hides behind its strip and arms.
      $0.hibernationArmedTabs = [harness.hiddenTab]
    }
    // The window floats over any worktree; leaving this one must not arm its
    // selection.
    await harness.store.send(.selectedLayoutChanged(LayoutID(legacyWorktreeKey: "/tmp/other"))) {
      $0.selectedLayoutID = LayoutID(legacyWorktreeKey: "/tmp/other")
      $0.recentLayoutIDs = [LayoutID(legacyWorktreeKey: "/tmp/other")]
      $0.selectionOrder = [LayoutID(legacyWorktreeKey: "/tmp/other")]
    }
    await harness.clock.advance(by: TerminalsFeature.hibernationGraceWindow)
    await harness.store.receive(\.hibernationGraceElapsed) {
      $0.hibernationArmedTabs = []
    }
    await harness.store.receive(\.layouts) {
      $0.layouts[id: harness.worktreeID]?.renderEpoch = 1
    }
    #expect(harness.selectedContent.renderer != nil)
    #expect(harness.hiddenContent.renderer == nil)
  }

  @Test(.dependencies) func leavingWindowModeArmsTheSelectionOfAnUnselectedWorktree() async {
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global.terminalHibernationEnabled = true }
    let harness = makeHibernationHarness()
    await harness.store.send(
      .layouts(.element(id: harness.worktreeID, action: .enterWindowMode(paneID: harness.paneID)))
    ) {
      $0.layouts[id: harness.worktreeID]?.windowedPaneIDs = [harness.paneID]
      $0.hibernationArmedTabs = [harness.hiddenTab]
    }
    await harness.store.send(.selectedLayoutChanged(LayoutID(legacyWorktreeKey: "/tmp/other"))) {
      $0.selectedLayoutID = LayoutID(legacyWorktreeKey: "/tmp/other")
      $0.recentLayoutIDs = [LayoutID(legacyWorktreeKey: "/tmp/other")]
      $0.selectionOrder = [LayoutID(legacyWorktreeKey: "/tmp/other")]
    }
    // Re-attaching withdraws the exemption: the selection is hidden again.
    await harness.store.send(
      .layouts(.element(id: harness.worktreeID, action: .exitWindowMode(paneID: harness.paneID)))
    ) {
      $0.layouts[id: harness.worktreeID]?.windowedPaneIDs = []
      $0.hibernationArmedTabs = [harness.selectedTab, harness.hiddenTab]
    }
    $settingsFile.withLock { $0.global.terminalHibernationEnabled = false }
    await harness.store.send(.hibernationPolicyChanged) {
      $0.hibernationArmedTabs = []
    }
    await harness.store.finish()
  }

  @Test(.dependencies) func windowedPaneWakesItsHibernatedSelectionWhileTheWorktreeIsUnselected() async {
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global.terminalHibernationEnabled = true }
    let harness = makeHibernationHarness()
    harness.selectedContent.hibernate()
    // Windowing a pane whose selection is hibernated must re-provision it,
    // or the window opens dead.
    await harness.store.send(
      .layouts(.element(id: harness.worktreeID, action: .enterWindowMode(paneID: harness.paneID)))
    ) {
      $0.layouts[id: harness.worktreeID]?.windowedPaneIDs = [harness.paneID]
      $0.hibernationArmedTabs = [harness.hiddenTab]
      $0.wakeRequestedTabs = [harness.selectedTab]
    }
    await harness.store.receive(\.layouts) {
      $0.layouts[id: harness.worktreeID]?.renderEpoch = 1
      $0.wakeRequestedTabs = []
    }
    #expect(harness.selectedContent.renderer != nil)
    // Drain the armed timer so the store finishes clean.
    $settingsFile.withLock { $0.global.terminalHibernationEnabled = false }
    await harness.store.send(.hibernationPolicyChanged) {
      $0.hibernationArmedTabs = []
    }
    await harness.store.finish()
  }

  @Test(.dependencies) func zoomedPaneHidesTheOtherPanesSelectedTab() async throws {
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global.terminalHibernationEnabled = true }
    let worktreeID = LayoutID(legacyWorktreeKey: "/tmp/zoom")
    let paneA = PaneID()
    let paneB = PaneID()
    let tabA = TabID()
    let tabB = TabID()
    let contentA = HibernatableContent(id: ContentID())
    let contentB = HibernatableContent(id: ContentID())
    let runtime = ContentRuntime()
    _ = runtime.provision(contentA, at: .fallback)
    _ = runtime.provision(contentB, at: .fallback)
    var tree = try SplitTree(view: paneA).inserting(view: paneB, at: paneA, direction: .right)
    tree = tree.settingZoomed(try #require(tree.find(id: paneA.rawValue)))
    let layout = PaneLayout(
      tree: tree,
      panes: [
        Pane(
          id: paneA,
          tabs: [
            TabItem(
              id: tabA,
              title: "A",
              content: ContentSnapshot(
                id: contentA.id,
                state: .terminal(TerminalContentState(workingDirectory: nil))
              )
            )
          ],
          selectedTabID: tabA
        ),
        Pane(
          id: paneB,
          tabs: [
            TabItem(
              id: tabB,
              title: "B",
              content: ContentSnapshot(
                id: contentB.id,
                state: .terminal(TerminalContentState(workingDirectory: nil))
              )
            )
          ],
          selectedTabID: tabB
        ),
      ],
      focusedPaneID: paneA
    )
    let clock = TestClock()
    let store = TestStore(
      initialState: TerminalsFeature.State(layouts: [LayoutFeature.State(id: worktreeID, layout: layout)])
    ) {
      TerminalsFeature()
    } withDependencies: {
      $0.continuousClock = clock
      $0.contentRuntime = runtime
      $0[ContentSessionKiller.self] = ContentSessionKiller(kill: { _, _ in })
    }
    await store.send(.selectedLayoutChanged(worktreeID)) {
      $0.selectedLayoutID = worktreeID
      $0.recentLayoutIDs = [worktreeID]
      $0.selectionOrder = [worktreeID]
      // Pane B sits behind the zoom, so its selection is hidden and arms.
      $0.hibernationArmedTabs = [tabB]
    }
    $settingsFile.withLock { $0.global.terminalHibernationEnabled = false }
    await store.send(.hibernationPolicyChanged) {
      $0.hibernationArmedTabs = []
    }
  }

  @Test(.dependencies) func detachLayoutCancelsArmedGraceTimers() async {
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global.terminalHibernationEnabled = true }
    let harness = makeHibernationHarness()
    // Selecting another worktree hides both tabs; both arm.
    await harness.store.send(.selectedLayoutChanged(LayoutID(legacyWorktreeKey: "/tmp/other"))) {
      $0.selectedLayoutID = LayoutID(legacyWorktreeKey: "/tmp/other")
      $0.recentLayoutIDs = [LayoutID(legacyWorktreeKey: "/tmp/other")]
      $0.selectionOrder = [LayoutID(legacyWorktreeKey: "/tmp/other")]
      $0.hibernationArmedTabs = [harness.selectedTab, harness.hiddenTab]
    }
    await harness.store.send(.detachLayout(worktreeID: harness.worktreeID)) {
      $0.layouts = []
      $0.removedLayoutIDs = [harness.worktreeID]
      $0.hibernationArmedTabs = []
    }
    // Cancelled timers must never fire.
    await harness.clock.advance(by: TerminalsFeature.hibernationGraceWindow)
    await harness.store.finish()
  }

  @Test(.dependencies) func aRecentWorktreesSelectionStaysLiveWhileDeselected() async {
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global.terminalHibernationEnabled = true }
    let harness = makeHibernationHarness()
    await harness.store.send(.selectedLayoutChanged(harness.worktreeID)) {
      $0.selectedLayoutID = harness.worktreeID
      $0.recentLayoutIDs = [harness.worktreeID]
      $0.selectionOrder = [harness.worktreeID]
      $0.hibernationArmedTabs = [harness.hiddenTab]
    }
    // Deselecting keeps the worktree inside the recency window, so its visible
    // selection is retained (never arms) even though it is now hidden; only the
    // stacked tab stays armed.
    await harness.store.send(.selectedLayoutChanged(LayoutID(legacyWorktreeKey: "/tmp/other"))) {
      $0.selectedLayoutID = LayoutID(legacyWorktreeKey: "/tmp/other")
      $0.recentLayoutIDs = [LayoutID(legacyWorktreeKey: "/tmp/other"), harness.worktreeID]
      $0.selectionOrder = [harness.worktreeID, LayoutID(legacyWorktreeKey: "/tmp/other")]
    }
    // Advance well past the grace window: a retained selection never arms, so no
    // amount of idle time hibernates it, while the stacked tab fires once.
    await harness.clock.advance(by: TerminalsFeature.hibernationGraceWindow * 2)
    await harness.store.receive(\.hibernationGraceElapsed) {
      $0.hibernationArmedTabs = []
    }
    await harness.store.receive(\.layouts) {
      $0.layouts[id: harness.worktreeID]?.renderEpoch = 1
    }
    // The stacked tab hibernated; the recency-retained selection did not.
    #expect(harness.hiddenContent.renderer == nil)
    #expect(harness.selectedContent.renderer != nil)
    await harness.store.finish()
  }

  @Test(.dependencies) func aWorktreePushedOutOfTheRecencyWindowArmsItsSelection() async {
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global.terminalHibernationEnabled = true }
    let harness = makeHibernationHarness()
    await harness.store.send(.selectedLayoutChanged(harness.worktreeID)) {
      $0.selectedLayoutID = harness.worktreeID
      $0.recentLayoutIDs = [harness.worktreeID]
      $0.selectionOrder = [harness.worktreeID]
      $0.hibernationArmedTabs = [harness.hiddenTab]
    }
    // Visit enough other worktrees to push this one past `liveWorktreeLimit`.
    let others = ["/tmp/o1", "/tmp/o2", "/tmp/o3"].map { LayoutID(legacyWorktreeKey: $0) }
    await harness.store.send(.selectedLayoutChanged(others[0])) {
      $0.selectedLayoutID = others[0]
      $0.recentLayoutIDs = [others[0], harness.worktreeID]
      $0.selectionOrder = [harness.worktreeID, others[0]]
    }
    await harness.store.send(.selectedLayoutChanged(others[1])) {
      $0.selectedLayoutID = others[1]
      $0.recentLayoutIDs = [others[1], others[0], harness.worktreeID]
      $0.selectionOrder = [harness.worktreeID, others[0], others[1]]
    }
    await harness.store.send(.selectedLayoutChanged(others[2])) {
      $0.selectedLayoutID = others[2]
      // The worktree drops out of the window, so its selection loses recency
      // cover and arms alongside the stacked tab.
      $0.recentLayoutIDs = [others[2], others[1], others[0]]
      $0.selectionOrder = [harness.worktreeID, others[0], others[1], others[2]]
      $0.hibernationArmedTabs = [harness.hiddenTab, harness.selectedTab]
    }
    $settingsFile.withLock { $0.global.terminalHibernationEnabled = false }
    await harness.store.send(.hibernationPolicyChanged) {
      $0.hibernationArmedTabs = []
    }
    await harness.store.finish()
  }

  @Test(.dependencies) func memoryPressureDropsRecencyAndHibernatesEveryHiddenTab() async {
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global.terminalHibernationEnabled = true }
    let harness = makeHibernationHarness()
    // The sweep fans out one hibernate per hidden tab; assert the outcome, not
    // each cascading action.
    harness.store.exhaustivity = .off
    await harness.store.send(.task)
    await harness.store.send(.selectedLayoutChanged(harness.worktreeID))
    // Deselect but stay recent: without pressure the selection is retained live.
    await harness.store.send(.selectedLayoutChanged(LayoutID(legacyWorktreeKey: "/tmp/other")))
    #expect(harness.selectedContent.renderer != nil)

    harness.pressure.yield()
    await harness.store.receive(\.memoryPressureWarning)
    await harness.store.skipReceivedActions()

    // Recency collapses to the current selection, and the deselected worktree's
    // retained selection hibernates now instead of waiting out the grace window.
    #expect(harness.store.state.recentLayoutIDs == [LayoutID(legacyWorktreeKey: "/tmp/other")])
    #expect(harness.selectedContent.renderer == nil)
    #expect(harness.hiddenContent.renderer == nil)

    harness.pressure.finish()
    await harness.store.finish()
  }

  @Test(.dependencies) func memoryPressureSparesTheVisibleSelection() async {
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global.terminalHibernationEnabled = true }
    let harness = makeHibernationHarness()
    harness.store.exhaustivity = .off
    await harness.store.send(.task)
    // The worktree stays selected across the pressure event.
    await harness.store.send(.selectedLayoutChanged(harness.worktreeID))

    harness.pressure.yield()
    await harness.store.receive(\.memoryPressureWarning)
    await harness.store.skipReceivedActions()

    // The on-screen selection survives; only the stacked tab hibernates.
    #expect(harness.selectedContent.renderer != nil)
    #expect(harness.hiddenContent.renderer == nil)

    harness.pressure.finish()
    await harness.store.finish()
  }

  @Test(.dependencies) func pressureSparesATabReselectedBeforeItsHibernateLands() async {
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global.terminalHibernationEnabled = true }
    let harness = makeHibernationHarness()
    harness.store.exhaustivity = .off
    await harness.store.send(.task)
    await harness.store.send(.selectedLayoutChanged(harness.worktreeID))
    // Deselect so the selection tab is hidden and becomes a pressure target.
    await harness.store.send(.selectedLayoutChanged(LayoutID(legacyWorktreeKey: "/tmp/other")))

    harness.pressure.yield()
    await harness.store.receive(\.memoryPressureWarning)
    // Before the queued hibernations land, the user flips back, making the
    // selection visible again. Routing pressure through the fire-time action
    // means its re-check spares the now-visible tab.
    await harness.store.send(.selectedLayoutChanged(harness.worktreeID))
    await harness.store.skipReceivedActions()

    #expect(harness.selectedContent.renderer != nil)

    // The reselect re-armed the stacked tab's grace timer; drain it so the
    // store finishes with no in-flight effect.
    await harness.clock.advance(by: TerminalsFeature.hibernationGraceWindow)
    await harness.store.skipReceivedActions()
    harness.pressure.finish()
    await harness.store.finish()
  }

  @Test(.dependencies) func memoryPressureRespectsTheHibernationFlag() async {
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global.terminalHibernationEnabled = false }
    let harness = makeHibernationHarness()
    await harness.store.send(.task)
    await harness.store.send(.selectedLayoutChanged(harness.worktreeID)) {
      $0.selectedLayoutID = harness.worktreeID
      $0.recentLayoutIDs = [harness.worktreeID]
      $0.selectionOrder = [harness.worktreeID]
    }
    await harness.store.send(.selectedLayoutChanged(LayoutID(legacyWorktreeKey: "/tmp/other"))) {
      $0.selectedLayoutID = LayoutID(legacyWorktreeKey: "/tmp/other")
      $0.recentLayoutIDs = [LayoutID(legacyWorktreeKey: "/tmp/other"), harness.worktreeID]
      $0.selectionOrder = [harness.worktreeID, LayoutID(legacyWorktreeKey: "/tmp/other")]
    }

    harness.pressure.yield()
    // Hibernation disabled: the warning is a no-op. No surface is dropped and
    // the recency budget is left intact.
    await harness.store.receive(\.memoryPressureWarning)
    #expect(harness.selectedContent.renderer != nil)
    #expect(harness.hiddenContent.renderer != nil)
    #expect(harness.store.state.recentLayoutIDs == [LayoutID(legacyWorktreeKey: "/tmp/other"), harness.worktreeID])

    harness.pressure.finish()
    await harness.store.finish()
  }

  @Test(.dependencies) func theFireTimeGateSparesASelectionThatBecameRecent() async {
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global.terminalHibernationEnabled = true }
    let harness = makeHibernationHarness()
    await harness.store.send(.selectedLayoutChanged(harness.worktreeID)) {
      $0.selectedLayoutID = harness.worktreeID
      $0.recentLayoutIDs = [harness.worktreeID]
      $0.selectionOrder = [harness.worktreeID]
      $0.hibernationArmedTabs = [harness.hiddenTab]
    }
    // Deselect but stay recent: the selection is retained, never armed.
    await harness.store.send(.selectedLayoutChanged(LayoutID(legacyWorktreeKey: "/tmp/other"))) {
      $0.selectedLayoutID = LayoutID(legacyWorktreeKey: "/tmp/other")
      $0.recentLayoutIDs = [LayoutID(legacyWorktreeKey: "/tmp/other"), harness.worktreeID]
      $0.selectionOrder = [harness.worktreeID, LayoutID(legacyWorktreeKey: "/tmp/other")]
    }
    // A grace timer that fired for the now-retained selection (a race the
    // arm-time cancel could miss) must not hibernate it: the fire-time gate wins.
    await harness.store.send(
      .hibernationGraceElapsed(worktreeID: harness.worktreeID, tabID: harness.selectedTab)
    )
    #expect(harness.selectedContent.renderer != nil)
    // Drain the stacked tab's still-armed timer.
    $settingsFile.withLock { $0.global.terminalHibernationEnabled = false }
    await harness.store.send(.hibernationPolicyChanged) {
      $0.hibernationArmedTabs = []
    }
    await harness.store.finish()
  }

  @Test(.dependencies) func graceElapsedSettlesInsteadOfReArmingAHibernatedTab() async {
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global.terminalHibernationEnabled = true }
    let harness = makeHibernationHarness()
    await harness.store.send(.selectedLayoutChanged(harness.worktreeID)) {
      $0.selectedLayoutID = harness.worktreeID
      $0.recentLayoutIDs = [harness.worktreeID]
      $0.selectionOrder = [harness.worktreeID]
      $0.hibernationArmedTabs = [harness.hiddenTab]
    }
    // The armed tab hibernates out of band (as a concurrent pressure sweep
    // would), so when its grace timer fires there is nothing left to hibernate.
    harness.hiddenContent.hibernate()
    await harness.clock.advance(by: TerminalsFeature.hibernationGraceWindow)
    await harness.store.receive(\.hibernationGraceElapsed) {
      $0.hibernationArmedTabs = []
    }
    // Settled, not re-armed: a second window produces no further grace action.
    await harness.clock.advance(by: TerminalsFeature.hibernationGraceWindow)
    await harness.store.finish()
  }

  @Test(.dependencies) func reSelectingARecentWorktreeMovesItToFrontWithoutGrowing() async {
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global.terminalHibernationEnabled = false }
    let harness = makeHibernationHarness()
    let worktreeA = harness.worktreeID
    let worktreeB = LayoutID(legacyWorktreeKey: "/tmp/b")
    await harness.store.send(.selectedLayoutChanged(worktreeA)) {
      $0.selectedLayoutID = worktreeA
      $0.recentLayoutIDs = [worktreeA]
      $0.selectionOrder = [worktreeA]
    }
    await harness.store.send(.selectedLayoutChanged(worktreeB)) {
      $0.selectedLayoutID = worktreeB
      $0.recentLayoutIDs = [worktreeB, worktreeA]
      $0.selectionOrder = [worktreeA, worktreeB]
    }
    // Re-selecting the first worktree moves it to front without duplicating or growing the list.
    await harness.store.send(.selectedLayoutChanged(worktreeA)) {
      $0.selectedLayoutID = worktreeA
      $0.recentLayoutIDs = [worktreeA, worktreeB]
      $0.selectionOrder = [worktreeB, worktreeA]
    }
  }

  @Test(.dependencies) func detachLayoutRemovesTheWorktreeFromRecents() async {
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global.terminalHibernationEnabled = false }
    let harness = makeHibernationHarness()
    await harness.store.send(.selectedLayoutChanged(harness.worktreeID)) {
      $0.selectedLayoutID = harness.worktreeID
      $0.recentLayoutIDs = [harness.worktreeID]
      $0.selectionOrder = [harness.worktreeID]
    }
    await harness.store.send(.detachLayout(worktreeID: harness.worktreeID)) {
      $0.layouts = []
      $0.removedLayoutIDs = [harness.worktreeID]
      $0.recentLayoutIDs = []
      $0.selectionOrder = []
    }
  }

  @Test func layoutsHydrationServesConsistentRecordsOnly() async {
    let paneID = PaneID()
    let good = Self.layout(paneID: paneID, tabID: TabID(), contentID: ContentID())
    // A tree leaf with no matching pane fails the consistency gate.
    let bad = PaneLayout(tree: SplitTree(view: PaneID()), panes: [], focusedPaneID: nil)
    let file = TaskLayoutsFile(
      oneTaskPerDirectory: LayoutsFile(worktrees: [
        "/tmp/good": LayoutRecord(layout: good),
        "/tmp/bad": LayoutRecord(layout: bad),
      ]))
    let store = TestStore(initialState: TerminalsFeature.State()) { TerminalsFeature() }
    await store.send(.layoutsHydrated(file)) {
      $0.layoutsLoaded = true
      $0.storedSessions = .loaded
      $0.layouts = [LayoutFeature.State(id: LayoutID(legacyWorktreeKey: "/tmp/good"), layout: good)]
      $0.directories = [LayoutID(legacyWorktreeKey: "/tmp/good"): TaskRecord.Directory(worktreeID: "/tmp/good")]
    }
  }

  @Test func layoutsHydrationTakesTheDirectoryFromTheRecordNotTheKey() async {
    let layout = Self.layout(paneID: PaneID(), tabID: TabID(), contentID: ContentID())
    let taskID = LayoutID(task: UUID())
    let directory = TaskRecord.Directory(worktreeID: "/tmp/repo")
    let task = TaskRecord(id: taskID, directory: directory, layout: layout, createdAt: Date(timeIntervalSince1970: 1))
    let store = TestStore(initialState: TerminalsFeature.State()) { TerminalsFeature() }
    await store.send(.layoutsHydrated(TaskLayoutsFile(tasks: [taskID.persistenceKey: task]))) {
      $0.layoutsLoaded = true
      $0.storedSessions = .loaded
      $0.layouts = [LayoutFeature.State(id: taskID, layout: layout)]
      $0.directories = [taskID: directory]
    }
    await store.send(.detachLayout(worktreeID: taskID)) {
      $0.layouts = []
      $0.removedLayoutIDs = [taskID]
      $0.directories = [:]
    }
    // Attached again under the same id, it is a task again.
    await store.send(.attachLayout(worktreeID: taskID, directory: directory, titlePrefix: "repo")) {
      $0.layouts = [LayoutFeature.State(id: taskID, layout: PaneLayout())]
      $0.layouts[id: taskID]?.titlePrefix = "repo"
      $0.removedLayoutIDs = []
      $0.directories = [taskID: directory]
    }
  }

  @Test func layoutsHydrationDropsCrossWorktreeIDCollisions() async {
    let sharedContentID = ContentID()
    let first = Self.layout(paneID: PaneID(), tabID: TabID(), contentID: sharedContentID)
    // The second worktree reuses the same content id (pre-gate data); it would
    // collide in the globally keyed runtime, so only the first key hydrates.
    let second = Self.layout(paneID: PaneID(), tabID: TabID(), contentID: sharedContentID)
    let file = TaskLayoutsFile(
      oneTaskPerDirectory: LayoutsFile(worktrees: [
        "/tmp/a": LayoutRecord(layout: first),
        "/tmp/b": LayoutRecord(layout: second),
      ]))
    let store = TestStore(initialState: TerminalsFeature.State()) { TerminalsFeature() }
    await store.send(.layoutsHydrated(file)) {
      $0.layoutsLoaded = true
      $0.storedSessions = .loaded
      $0.layouts = [LayoutFeature.State(id: LayoutID(legacyWorktreeKey: "/tmp/a"), layout: first)]
      $0.directories = [LayoutID(legacyWorktreeKey: "/tmp/a"): TaskRecord.Directory(worktreeID: "/tmp/a")]
    }
  }

  @Test func layoutsHydrationNeverReplacesALiveLayout() async {
    let live = Self.layout(paneID: PaneID(), tabID: TabID(), contentID: ContentID())
    let persisted = Self.layout(paneID: PaneID(), tabID: TabID(), contentID: ContentID())
    let worktreeID = LayoutID(legacyWorktreeKey: "/tmp/repo")
    let store = TestStore(
      initialState: TerminalsFeature.State(layouts: [LayoutFeature.State(id: worktreeID, layout: live)])
    ) {
      TerminalsFeature()
    }
    await store.send(
      .layoutsHydrated(
        TaskLayoutsFile(oneTaskPerDirectory: LayoutsFile(worktrees: ["/tmp/repo": LayoutRecord(layout: persisted)])))
    ) {
      $0.layoutsLoaded = true
      $0.storedSessions = .loaded
    }
  }

  @Test func newerSchemaServesRecordsButMarksThemReadOnly() async {
    let good = Self.layout(paneID: PaneID(), tabID: TabID(), contentID: ContentID())
    let taskID = LayoutID(legacyWorktreeKey: "/tmp/good")
    let directory = TaskRecord.Directory(worktreeID: "/tmp/good")
    let file = TaskLayoutsFile(
      schemaVersion: TaskLayoutsFile.currentSchemaVersion + 1,
      tasks: ["/tmp/good": TaskRecord(id: taskID, directory: directory, layout: good, createdAt: .distantPast)]
    )
    let store = TestStore(initialState: TerminalsFeature.State()) { TerminalsFeature() }
    await store.send(.layoutsHydrated(file)) {
      $0.layoutsLoaded = true
      $0.storedSessions = .loaded
      $0.layoutsAreReadOnly = true
      $0.layouts = [LayoutFeature.State(id: taskID, layout: good)]
      $0.directories = [taskID: directory]
    }
  }

  // MARK: - Directory resolution.

  /// A task with no tabs, so selecting it has no content to wake.
  private static func task(_ id: LayoutID, on directory: Worktree.ID) -> TaskRecord {
    TaskRecord(
      id: id,
      directory: TaskRecord.Directory(worktreeID: directory),
      createdAt: Date(timeIntervalSince1970: 1)
    )
  }

  private static func file(_ tasks: [TaskRecord], activeTasks: [String: String] = [:]) -> TaskLayoutsFile {
    var file = TaskLayoutsFile(tasks: Dictionary(uniqueKeysWithValues: tasks.map { ($0.id.persistenceKey, $0) }))
    file.activeTasks = activeTasks
    return file
  }

  /// A store that records every active-task change the reducer reports.
  private func makeResolverStore() -> (store: TestStoreOf<TerminalsFeature>, reported: LockIsolated<[String]>) {
    let reported = LockIsolated<[String]>([])
    let store = TestStore(initialState: TerminalsFeature.State()) {
      TerminalsFeature()
    } withDependencies: {
      $0[LayoutChangeObserver.self] = LayoutChangeObserver(
        layoutChanged: { _ in },
        activeTaskChanged: { directoryID in
          reported.withValue { $0.append(directoryID.rawValue) }
        }
      )
    }
    store.exhaustivity = .off
    return (store, reported)
  }

  @Test(.dependencies) func aDirectoryResolvesToItsOwnKeyUntilAnotherTaskIsSelected() async {
    let directory: Worktree.ID = "/tmp/repo"
    let ownKey = LayoutID(legacyWorktreeKey: "/tmp/repo")
    let minted = LayoutID(task: UUID())
    let (store, reported) = makeResolverStore()
    await store.send(.layoutsHydrated(Self.file([Self.task(ownKey, on: directory), Self.task(minted, on: directory)])))
    #expect(store.state.layoutID(forDirectory: directory) == ownKey)

    // Selecting the own-key task stores and writes nothing.
    await store.send(.selectedLayoutChanged(ownKey))
    await store.finish()
    #expect(store.state.activeTasks.isEmpty)
    #expect(reported.value.isEmpty)

    await store.send(.selectedLayoutChanged(minted))
    await store.finish()
    #expect(store.state.layoutID(forDirectory: directory) == minted)
    #expect(reported.value == ["/tmp/repo"])

    // Re-selecting it reports nothing new.
    await store.send(.selectedLayoutChanged(nil))
    await store.send(.selectedLayoutChanged(minted))
    await store.finish()
    #expect(reported.value == ["/tmp/repo"])

    await store.send(.selectedLayoutChanged(ownKey))
    await store.finish()
    #expect(store.state.layoutID(forDirectory: directory) == ownKey)
    #expect(store.state.activeTasks.isEmpty)
    #expect(reported.value == ["/tmp/repo", "/tmp/repo"])
  }

  @Test(.dependencies) func selectingATaskLeavesOtherDirectoriesResolutionAlone() async {
    let first = LayoutID(task: UUID())
    let second = LayoutID(task: UUID())
    let file = Self.file([Self.task(first, on: "/tmp/a"), Self.task(second, on: "/tmp/b")])
    let (store, _) = makeResolverStore()
    await store.send(.layoutsHydrated(file))
    await store.send(.selectedLayoutChanged(first))
    await store.send(.selectedLayoutChanged(second))
    #expect(store.state.activeTasks == ["/tmp/a": first, "/tmp/b": second])
  }

  @Test(.dependencies) func detachingTheActiveTaskFallsBackToTheDirectorysOwnKey() async {
    let directory: Worktree.ID = "/tmp/repo"
    let minted = LayoutID(task: UUID())
    let file = Self.file([Self.task(minted, on: directory)])
    let (store, _) = makeResolverStore()
    await store.send(.layoutsHydrated(file))
    await store.send(.selectedLayoutChanged(minted))
    #expect(store.state.layoutID(forDirectory: directory) == minted)

    await store.send(.detachLayout(worktreeID: minted))
    #expect(store.state.activeTasks.isEmpty)
    #expect(store.state.layoutID(forDirectory: directory) == LayoutID(legacyWorktreeKey: "/tmp/repo"))
  }

  @Test(.dependencies) func hydrationRestoresTheActiveTaskOfEachDirectory() async {
    let minted = LayoutID(task: UUID())
    let elsewhere = LayoutID(task: UUID())
    let file = Self.file(
      [Self.task(minted, on: "/tmp/repo"), Self.task(elsewhere, on: "/tmp/elsewhere")],
      activeTasks: [
        "/tmp/repo": minted.persistenceKey,
        // Neither a task that is gone nor one on another directory is served.
        "/tmp/gone": "no-such-task",
        "/tmp/wrong": elsewhere.persistenceKey,
      ])
    let (store, reported) = makeResolverStore()
    await store.send(.layoutsHydrated(file))
    await store.finish()
    #expect(store.state.activeTasks == ["/tmp/repo": minted])
    #expect(reported.value.isEmpty)
  }

  @Test(.dependencies) func anOwnKeySelectionBeforeHydrationOutranksTheStoredTask() async {
    let ownKey = LayoutID(legacyWorktreeKey: "/tmp/a")
    let minted = LayoutID(task: UUID())
    let other = LayoutID(legacyWorktreeKey: "/tmp/b")
    let (store, reported) = makeResolverStore()
    await store.send(
      .attachLayout(worktreeID: ownKey, directory: TaskRecord.Directory(worktreeID: "/tmp/a"), titlePrefix: "a"))
    await store.send(
      .attachLayout(worktreeID: other, directory: TaskRecord.Directory(worktreeID: "/tmp/b"), titlePrefix: "b"))
    await store.send(.selectedLayoutChanged(ownKey))
    await store.send(.selectedLayoutChanged(other))
    await store.finish()
    #expect(reported.value.isEmpty)

    // The file still names the task that was active when the app last quit.
    let file = Self.file(
      [Self.task(ownKey, on: "/tmp/a"), Self.task(minted, on: "/tmp/a"), Self.task(other, on: "/tmp/b")],
      activeTasks: ["/tmp/a": minted.persistenceKey])
    await store.send(.layoutsHydrated(file))
    await store.finish()
    #expect(store.state.layoutID(forDirectory: "/tmp/a") == ownKey)
    #expect(store.state.activeTasks.isEmpty)
    // The stale entry is cleared from the file, or the next launch restores it.
    #expect(reported.value == ["/tmp/a"])
  }

  @Test(.dependencies) func aSelectionAttachedAfterHydrationOutranksTheStoredTaskOnceTheUserMovedOn() async {
    let selected = LayoutID(task: UUID())
    let stored = LayoutID(task: UUID())
    let other = LayoutID(legacyWorktreeKey: "/tmp/b")
    let (store, reported) = makeResolverStore()
    // Selected before anything names its directory, then the user moves on.
    await store.send(.selectedLayoutChanged(selected))
    await store.send(.selectedLayoutChanged(other))
    await store.send(
      .layoutsHydrated(
        Self.file([Self.task(stored, on: "/tmp/a")], activeTasks: ["/tmp/a": stored.persistenceKey])))
    await store.finish()
    #expect(store.state.layoutID(forDirectory: "/tmp/a") == stored)

    await store.send(
      .attachLayout(worktreeID: selected, directory: TaskRecord.Directory(worktreeID: "/tmp/a"), titlePrefix: "a"))
    await store.finish()
    #expect(store.state.layoutID(forDirectory: "/tmp/a") == selected)
    #expect(store.state.selectedLayoutID == other)
    #expect(reported.value == ["/tmp/a"])
  }

  @Test(.dependencies) func aSelectionWhoseDirectoryHydrationNamesOutranksTheStoredTask() async {
    let selected = LayoutID(task: UUID())
    let stored = LayoutID(task: UUID())
    let (store, reported) = makeResolverStore()
    await store.send(.selectedLayoutChanged(selected))
    await store.send(.selectedLayoutChanged(LayoutID(legacyWorktreeKey: "/tmp/b")))
    await store.send(
      .layoutsHydrated(
        Self.file(
          [Self.task(selected, on: "/tmp/a"), Self.task(stored, on: "/tmp/a")],
          activeTasks: ["/tmp/a": stored.persistenceKey])))
    await store.finish()
    #expect(store.state.layoutID(forDirectory: "/tmp/a") == selected)
    // One write for the directory, not a clear racing it.
    #expect(reported.value == ["/tmp/a"])
  }

  @Test(.dependencies) func aLateAttachNeverOverridesALaterSelectionOnTheSameDirectory() async {
    let early = LayoutID(task: UUID())
    let later = LayoutID(task: UUID())
    let directory = TaskRecord.Directory(worktreeID: "/tmp/a")
    let (store, reported) = makeResolverStore()
    await store.send(.selectedLayoutChanged(early))
    await store.send(.attachLayout(worktreeID: later, directory: directory, titlePrefix: "a"))
    await store.send(.selectedLayoutChanged(later))
    await store.send(.selectedLayoutChanged(LayoutID(legacyWorktreeKey: "/tmp/b")))
    await store.send(.attachLayout(worktreeID: early, directory: directory, titlePrefix: "a"))
    await store.finish()
    #expect(store.state.layoutID(forDirectory: "/tmp/a") == later)
    #expect(reported.value == ["/tmp/a"])
  }

  @Test(.dependencies) func aLayoutAttachedAfterItsSelectionBecomesItsDirectorysActiveTask() async {
    let minted = LayoutID(task: UUID())
    let directory = TaskRecord.Directory(worktreeID: "/tmp/repo")
    let (store, reported) = makeResolverStore()
    // The selection lands first; the host that names the directory follows.
    await store.send(.selectedLayoutChanged(minted))
    #expect(store.state.activeTasks.isEmpty)
    await store.send(.attachLayout(worktreeID: minted, directory: directory, titlePrefix: "repo"))
    await store.finish()
    #expect(store.state.directories == [minted: directory])
    #expect(store.state.layoutID(forDirectory: "/tmp/repo") == minted)
    #expect(reported.value == ["/tmp/repo"])
  }

  @Test(.dependencies) func attachNeverReplacesAHydratedTasksDirectory() async {
    let minted = LayoutID(task: UUID())
    let file = Self.file([Self.task(minted, on: "/tmp/recorded")])
    let (store, _) = makeResolverStore()
    await store.send(.layoutsHydrated(file))
    await store.send(
      .attachLayout(
        worktreeID: minted, directory: TaskRecord.Directory(worktreeID: "/tmp/other"), titlePrefix: "other"))
    #expect(store.state.directories[minted]?.worktreeID == "/tmp/recorded")
  }

  // MARK: - Task membership

  @Test(.dependencies) func hydrationLoadsATasksSessionsEvenWithNoTabLeft() async {
    let minted = LayoutID(task: UUID())
    let stored = SessionKey(harness: .pi, sessionID: "stored")
    let early = SessionKey(harness: .pi, sessionID: "early")
    var record = Self.task(minted, on: "/tmp/repo")
    record.sessions = [stored]
    var initial = TerminalsFeature.State()
    // An agent reported before the file loaded.
    initial.members[minted] = [.session(early), .session(stored)]
    let store = TestStore(initialState: initial) { TerminalsFeature() }
    store.exhaustivity = .off

    await store.send(.layoutsHydrated(Self.file([record])))

    #expect(store.state.members == [minted: [.session(stored), .session(early)]])
    #expect(store.state.layouts[id: minted]?.layout.panes.isEmpty == true)
  }

  /// The launch-time read: sessions only, ahead of the layouts. What was
  /// queued before it is applied to the stored order, and from then on the
  /// run's list is the one written.
  @Test(.dependencies) func theStoredSessionsLoadAheadOfTheLayouts() async {
    let minted = LayoutID(task: UUID())
    let key = { SessionKey(harness: .pi, sessionID: $0) }
    let (primary, tangent, third) = (key("a"), key("b"), key("c"))
    var record = Self.task(minted, on: "/tmp/repo")
    record.sessions = [primary, tangent]
    let reported = LockIsolated<[LayoutID]>([])
    let store = TestStore(initialState: TerminalsFeature.State()) {
      TerminalsFeature()
    } withDependencies: {
      $0[LayoutChangeObserver.self].sessionsChanged = { id in reported.withValue { $0.append(id) } }
    }
    store.exhaustivity = .off
    await store.send(.membersChanged([minted: [.session(tangent)]]))
    await store.send(.sessionReplaced(minted, old: primary, new: third))
    await store.finish()
    reported.setValue([])

    await store.send(.storedSessionsLoaded(Self.file([record])))
    await store.finish()

    let members: [TaskMember] = [.session(third), .session(primary), .session(tangent)]
    #expect(store.state.members[minted] == members)
    #expect(store.state.storedSessions == .loaded)
    #expect(store.state.pendingMembership.isEmpty)
    #expect(store.state.layouts.isEmpty, "the layouts wait for their own load")
    #expect(reported.value == [minted])

    // Nothing is queued any more, and the layouts' load changes no member.
    await store.send(.sessionReplaced(minted, old: third, new: tangent))
    await store.finish()
    #expect(store.state.pendingMembership.isEmpty)
    reported.setValue([])
    await store.send(.layoutsHydrated(Self.file([record])))
    await store.finish()
    #expect(store.state.members[minted] == [.session(tangent), .session(third), .session(primary)])
    #expect(store.state.layouts[id: minted] != nil)
    #expect(reported.value == [minted], "the run's order is still to be written")
  }

  @Test func theLaunchReadOfTheStoreSaysWhatIsKnownOfItsSessions() {
    let minted = LayoutID(task: UUID())
    let file = Self.file([Self.task(minted, on: "/tmp/repo")])
    guard case .storedSessionsLoaded(file) = TerminalsFeature.Action.storedSessions(.file(file)) else {
      Issue.record("a readable store loads its sessions")
      return
    }
    guard case .storedSessionsLoaded(TaskLayoutsFile()) = TerminalsFeature.Action.storedSessions(.absent) else {
      Issue.record("no store is a loaded, empty one")
      return
    }
    guard case .storedSessionsUnreadable = TerminalsFeature.Action.storedSessions(.unreadable) else {
      Issue.record("an unreadable store is never loaded")
      return
    }
  }

  /// The review's sequence, all before the file loaded: stored `[a, b]`,
  /// then a>b, b>a, b>c, c>b. Whichever agent reported first, the task ends
  /// as it would have had the stored sessions been there from the start.
  @Test(.dependencies, arguments: [false, true])
  func replacementsBeforeTheStoredSessionsLoadAreAppliedToTheStoredOrder(tangentReportsFirst: Bool) async {
    let minted = LayoutID(task: UUID())
    let key = { SessionKey(harness: .pi, sessionID: $0) }
    let (primary, tangent, third) = (key("a"), key("b"), key("c"))
    var record = Self.task(minted, on: "/tmp/repo")
    record.sessions = [primary, tangent]
    let reported = LockIsolated<[LayoutID]>([])
    let store = TestStore(initialState: TerminalsFeature.State()) {
      TerminalsFeature()
    } withDependencies: {
      $0[LayoutChangeObserver.self].sessionsChanged = { id in reported.withValue { $0.append(id) } }
    }
    store.exhaustivity = .off
    let agent = { (surface: UUID, key: SessionKey) in
      TaskAgent(layoutID: minted, harness: .pi, surfaceID: surface, sessionRef: String(key.rawValue.dropFirst(3)))
    }
    let (left, right) = (UUID(), UUID())

    let first = tangentReportsFirst ? tangent : primary
    let second = tangentReportsFirst ? primary : tangent
    await store.send(.membersChanged([minted: [.session(first)]], agents: [agent(left, first)]))
    await store.send(
      .membersChanged(
        [minted: [.session(first), .session(second)]], agents: [agent(left, first), agent(right, second)]))
    #expect(store.state.members[minted]?.first == .session(first))
    await store.send(.sessionReplaced(minted, old: primary, new: tangent))
    await store.send(.sessionReplaced(minted, old: tangent, new: primary))
    await store.send(.sessionReplaced(minted, old: tangent, new: third))
    await store.send(.sessionReplaced(minted, old: third, new: tangent))
    await store.finish()
    reported.setValue([])

    await store.send(.layoutsHydrated(Self.file([record])))
    await store.finish()
    let members: [TaskMember] = [.session(primary), .session(tangent), .session(third)]
    #expect(store.state.members[minted] == members, "the stored primary still leads")
    #expect(store.state.pendingMembership.isEmpty)
    // Nothing was written while the stored sessions were pending.
    #expect(reported.value == [minted])

    await store.send(.layoutsHydrated(Self.file([record])))
    #expect(store.state.members[minted] == members)
  }

  /// A stored tangent that reports before the stored primary does not lead
  /// once the file is read, and an agent still waiting keeps its place.
  @Test(.dependencies) func aTangentReportingFirstDoesNotBecomeThePrimary() async {
    let minted = LayoutID(task: UUID())
    let key = { SessionKey(harness: .pi, sessionID: $0) }
    var record = Self.task(minted, on: "/tmp/repo")
    record.sessions = [key("one"), key("two")]
    let store = TestStore(initialState: TerminalsFeature.State()) { TerminalsFeature() }
    store.exhaustivity = .off
    let (left, right) = (UUID(), UUID())
    let waiting = TaskMember.provisional(harness: .pi, surfaceID: right)
    let agents = [
      TaskAgent(layoutID: minted, harness: .pi, surfaceID: left, sessionRef: "two"),
      TaskAgent(layoutID: minted, harness: .pi, surfaceID: right, sessionRef: nil),
    ]

    await store.send(.membersChanged([minted: [.session(key("two")), waiting]], agents: agents))
    await store.send(.layoutsHydrated(Self.file([record])))

    #expect(store.state.members[minted] == [.session(key("one")), .session(key("two")), waiting])
  }

  /// A replacement of a session only the stored list names moves nothing
  /// before the load and is still applied by it.
  @Test(.dependencies) func aReplacementOfASessionOnlyTheStoreNamesIsAppliedAtTheLoad() async {
    let minted = LayoutID(task: UUID())
    let key = { SessionKey(harness: .pi, sessionID: $0) }
    var record = Self.task(minted, on: "/tmp/repo")
    record.sessions = [key("one"), key("two")]
    let store = TestStore(initialState: TerminalsFeature.State()) { TerminalsFeature() }
    store.exhaustivity = .off
    let agent = TaskAgent(layoutID: minted, harness: .pi, surfaceID: UUID(), sessionRef: "new")

    await store.send(.sessionReplaced(minted, old: key("two"), new: key("new")))
    #expect(store.state.members[minted] == nil)
    await store.send(.membersChanged([minted: [.session(key("new"))]], agents: [agent]))
    await store.send(.layoutsHydrated(Self.file([record])))

    #expect(store.state.members[minted] == [.session(key("one")), .session(key("new")), .session(key("two"))])
  }

  /// A task minted this run and written before the load is stored with no
  /// session: the run's list, launch primary first, is all there is.
  @Test(.dependencies) func aTaskStoredWithNoSessionKeepsTheRunsOrder() async {
    let minted = LayoutID(task: UUID())
    let key = { SessionKey(harness: .pi, sessionID: $0) }
    let members: [TaskMember] = [.session(key("resumed")), .session(key("reported"))]
    let store = TestStore(initialState: TerminalsFeature.State()) { TerminalsFeature() }
    store.exhaustivity = .off
    let agent = TaskAgent(layoutID: minted, harness: .pi, surfaceID: UUID(), sessionRef: "reported")

    await store.send(.membersChanged([minted: members], agents: [agent]))
    await store.send(.layoutsHydrated(Self.file([Self.task(minted, on: "/tmp/repo")])))

    #expect(store.state.members[minted] == members)
  }

  /// The load writes only the tasks whose sessions differ from the stored
  /// ones: a task the run changed nothing about is left alone.
  @Test(.dependencies) func theLoadWritesOnlyTasksWhoseSessionsChanged() async {
    let key = { SessionKey(harness: .pi, sessionID: $0) }
    let (same, grown, fresh) = (LayoutID(task: UUID()), LayoutID(task: UUID()), LayoutID(task: UUID()))
    var unchanged = Self.task(same, on: "/tmp/repo")
    unchanged.sessions = [key("one"), key("two")]
    var added = Self.task(grown, on: "/tmp/repo")
    added.sessions = [key("three")]
    let reported = LockIsolated<[LayoutID]>([])
    let store = TestStore(initialState: TerminalsFeature.State()) {
      TerminalsFeature()
    } withDependencies: {
      $0[LayoutChangeObserver.self].sessionsChanged = { id in reported.withValue { $0.append(id) } }
    }
    store.exhaustivity = .off
    let agents = [
      TaskAgent(layoutID: same, harness: .pi, surfaceID: UUID(), sessionRef: "two"),
      TaskAgent(layoutID: grown, harness: .pi, surfaceID: UUID(), sessionRef: "four"),
      TaskAgent(layoutID: fresh, harness: .pi, surfaceID: UUID(), sessionRef: "five"),
    ]
    await store.send(
      .membersChanged(
        [same: [.session(key("two"))], grown: [.session(key("four"))], fresh: [.session(key("five"))]],
        agents: agents))
    await store.finish()
    reported.setValue([])

    await store.send(.layoutsHydrated(Self.file([unchanged, added])))
    await store.finish()

    #expect(store.state.members[same] == [.session(key("one")), .session(key("two"))])
    #expect(store.state.members[grown] == [.session(key("three")), .session(key("four"))])
    #expect(store.state.members[fresh] == [.session(key("five"))])
    #expect(Set(reported.value) == [grown, fresh])
    #expect(reported.value.count == 2)
  }

  /// A task removed before the load takes its queued changes with it: a
  /// record of the same id read afterwards gets none of them.
  @Test(.dependencies) func aTaskRemovedBeforeTheLoadIsNotReplayed() async {
    let minted = LayoutID(task: UUID())
    let key = { SessionKey(harness: .pi, sessionID: $0) }
    var record = Self.task(minted, on: "/tmp/repo")
    record.sessions = [key("one"), key("two")]
    let store = TestStore(initialState: TerminalsFeature.State()) { TerminalsFeature() }
    store.exhaustivity = .off
    let agent = TaskAgent(layoutID: minted, harness: .pi, surfaceID: UUID(), sessionRef: "two")

    await store.send(.membersChanged([minted: [.session(key("two"))]], agents: [agent]))
    await store.send(.sessionReplaced(minted, old: key("one"), new: key("two")))
    await store.send(.detachLayout(worktreeID: minted))
    #expect(store.state.pendingMembership == [.agents([])])
    await store.send(.layoutsHydrated(Self.file([record])))

    #expect(store.state.members[minted] == [.session(key("one")), .session(key("two"))])
  }

  @Test(.dependencies) func anUnreadableStoreEndsTheWaitAndWritesWhatTheRunLists() async {
    let minted = LayoutID(task: UUID())
    let key = SessionKey(harness: .pi, sessionID: "one")
    let reported = LockIsolated<[LayoutID]>([])
    let store = TestStore(initialState: TerminalsFeature.State()) {
      TerminalsFeature()
    } withDependencies: {
      $0[LayoutChangeObserver.self].sessionsChanged = { id in reported.withValue { $0.append(id) } }
    }
    store.exhaustivity = .off
    await store.send(.membersChanged([minted: [.session(key)]]))
    await store.finish()
    reported.setValue([])

    await store.send(.storedSessionsUnreadable)
    await store.finish()

    #expect(store.state.storedSessions == .unreadable)
    #expect(store.state.pendingMembership.isEmpty)
    #expect(reported.value == [minted])
    // Nothing is queued any more.
    await store.send(.sessionReplaced(minted, old: key, new: SessionKey(harness: .pi, sessionID: "two")))
    #expect(store.state.pendingMembership.isEmpty)
  }

  /// Once the stored sessions are loaded the run's order is the one to
  /// keep: a later load must not reorder it from a stale replacement.
  @Test(.dependencies) func afterTheStoredSessionsLoadTheRunsOrderStands() async {
    let minted = LayoutID(task: UUID())
    let key = { SessionKey(harness: .pi, sessionID: $0) }
    let (one, two, three) = (key("one"), key("two"), key("three"))
    var record = Self.task(minted, on: "/tmp/repo")
    record.sessions = [one, two]
    let store = TestStore(initialState: TerminalsFeature.State()) { TerminalsFeature() }
    store.exhaustivity = .off
    #expect(store.state.storedSessions == .pending)

    await store.send(.layoutsHydrated(Self.file([record])))
    #expect(store.state.storedSessions == .loaded)
    await store.send(.sessionReplaced(minted, old: one, new: two))
    await store.send(.sessionReplaced(minted, old: two, new: one))
    await store.send(.sessionReplaced(minted, old: two, new: three))
    await store.send(.sessionReplaced(minted, old: one, new: two))
    let members: [TaskMember] = [.session(two), .session(one), .session(three)]
    #expect(store.state.members[minted] == members)

    await store.send(.layoutsHydrated(Self.file([record])))
    #expect(store.state.members[minted] == members)
  }

  @Test(.dependencies) func detachingATaskForgetsItsMembers() async {
    let minted = LayoutID(task: UUID())
    let kept = LayoutID(task: UUID())
    let key = SessionKey(harness: .pi, sessionID: "one")
    var initial = TerminalsFeature.State()
    initial.layouts = [LayoutFeature.State(id: minted, layout: PaneLayout())]
    initial.members = [minted: [.session(key)], kept: [.session(key)]]
    let store = TestStore(initialState: initial) { TerminalsFeature() }
    store.exhaustivity = .off

    await store.send(.detachLayout(worktreeID: minted))

    #expect(store.state.members == [kept: [.session(key)]])
  }

  @Test(.dependencies) func onlyAChangeInStoredSessionsIsReported() async {
    let minted = LayoutID(task: UUID())
    let surface = UUID()
    let reported = LockIsolated<[LayoutID]>([])
    let store = TestStore(initialState: TerminalsFeature.State()) {
      TerminalsFeature()
    } withDependencies: {
      $0[LayoutChangeObserver.self].sessionsChanged = { id in reported.withValue { $0.append(id) } }
    }
    store.exhaustivity = .off

    await store.send(.membersChanged([minted: [.provisional(harness: .pi, surfaceID: surface)]]))
    await store.finish()
    #expect(reported.value.isEmpty)

    await store.send(.membersChanged([minted: [.session(SessionKey(harness: .pi, sessionID: "one"))]]))
    await store.finish()
    #expect(reported.value == [minted])
  }

  @Test(.dependencies) func aReplacingSessionTakesTheReplacedOnesSlotAndIsWritten() async {
    let minted = LayoutID(task: UUID())
    let reported = LockIsolated<[LayoutID]>([])
    let key = { SessionKey(harness: .pi, sessionID: $0) }
    var initial = TerminalsFeature.State()
    initial.members[minted] = [.session(key("one")), .session(key("two"))]
    let store = TestStore(initialState: initial) {
      TerminalsFeature()
    } withDependencies: {
      $0[LayoutChangeObserver.self].sessionsChanged = { id in reported.withValue { $0.append(id) } }
    }
    store.exhaustivity = .off

    // The primary's surface moved on: the newcomer leads, the replaced one stays behind it.
    await store.send(.sessionReplaced(minted, old: key("one"), new: key("new")))
    await store.finish()
    #expect(store.state.members[minted] == [.session(key("new")), .session(key("one")), .session(key("two"))])

    // A tangent's slot works the same way and the primary is untouched.
    await store.send(.sessionReplaced(minted, old: key("two"), new: key("fork")))
    await store.finish()
    #expect(
      store.state.members[minted]
        == [.session(key("new")), .session(key("one")), .session(key("fork")), .session(key("two"))])
    #expect(reported.value == [minted, minted])

    // A session already listed moves up into the slot of the one it
    // replaced; everything else keeps its order.
    await store.send(.sessionReplaced(minted, old: key("new"), new: key("two")))
    await store.finish()
    #expect(
      store.state.members[minted]
        == [.session(key("two")), .session(key("new")), .session(key("one")), .session(key("fork"))])
    #expect(reported.value == [minted, minted, minted])
    // One already ahead of the session it replaced stays where it is: a
    // primary resumed on a tangent's surface is still the primary.
    await store.send(.sessionReplaced(minted, old: key("fork"), new: key("two")))
    await store.finish()
    #expect(store.state.members[minted]?.first == .session(key("two")))
    await store.send(.sessionReplaced(minted, old: key("two"), new: key("fork")))
    await store.finish()
    #expect(
      store.state.members[minted]
        == [.session(key("fork")), .session(key("two")), .session(key("new")), .session(key("one"))])
    reported.setValue([minted, minted])

    // Nothing to place: an unlisted old session names no slot.
    await store.send(.sessionReplaced(minted, old: key("stranger"), new: key("other")))
    await store.send(.sessionReplaced(LayoutID(task: UUID()), old: key("one"), new: key("other")))
    await store.finish()
    #expect(store.state.members.count == 1)
    #expect(store.state.members[minted]?.count == 4)
    #expect(reported.value == [minted, minted])

    // A removed task takes its queued changes with it.
    #expect(store.state.pendingMembership.count == 7)
    await store.send(.detachLayout(worktreeID: minted))
    #expect(store.state.pendingMembership.count == 1)
  }
}

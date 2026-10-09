import AppKit
import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import SupacodeSettingsShared
import Testing

@testable import supacode

/// Tabs and members moving between two tasks in one reducer turn: both
/// layouts change or neither does, and nothing is closed.
@MainActor
struct TerminalsFeatureTransferTests {
  @MainActor
  private final class LiveContent: TabContent {
    let id: ContentID
    let kind: ContentKind = .terminal
    private(set) var startCalls = 0
    private var view: NSView?

    init(id: ContentID) { self.id = id }

    var renderer: NSView? { view }
    var isHibernatable: Bool { view != nil }

    func startSession(at geometry: ContentGeometry) {
      startCalls += 1
      if view == nil { view = NSView() }
    }

    func hibernate() { view = nil }

    func snapshot() -> ContentSnapshot {
      ContentSnapshot(id: id, state: .terminal(TerminalContentState(workingDirectory: nil)))
    }
  }

  private static let source = LayoutID(task: UUID())
  private static let destination = LayoutID(task: UUID())
  private static let directory = TaskRecord.Directory(worktreeID: "/tmp/transfer")

  private static func tab(_ title: String) -> TabItem {
    TabItem(
      id: TabID(), title: title,
      content: ContentSnapshot(id: ContentID(), state: .terminal(TerminalContentState(workingDirectory: nil))))
  }

  private static func layout(_ tabs: [TabItem]) -> PaneLayout {
    guard let first = tabs.first else { return PaneLayout() }
    let paneID = PaneID()
    return PaneLayout(
      tree: SplitTree(view: paneID),
      panes: [Pane(id: paneID, tabs: IdentifiedArray(uniqueElements: tabs), selectedTabID: first.id)],
      focusedPaneID: paneID)
  }

  private static func session(_ ref: String) -> TaskMember { .session(SessionKey(harness: .pi, sessionID: ref)) }

  /// Two hydrated tasks on one directory, ready to transfer between.
  private static func state(
    source sourceTabs: [TabItem], members sourceMembers: [TaskMember] = [],
    destination destinationTabs: [TabItem]?, holding destinationMembers: [TaskMember] = []
  ) -> TerminalsFeature.State {
    var state = TerminalsFeature.State(layouts: [LayoutFeature.State(id: source, layout: layout(sourceTabs))])
    state.directories[source] = directory
    state.members[source] = sourceMembers.isEmpty ? nil : sourceMembers
    if let destinationTabs {
      state.layouts.append(LayoutFeature.State(id: destination, layout: layout(destinationTabs)))
      state.directories[destination] = directory
      state.members[destination] = destinationMembers.isEmpty ? nil : destinationMembers
    }
    state.layoutsLoaded = true
    state.storedSessions = .loaded
    return state
  }

  private static func store(
    _ state: TerminalsFeature.State, runtime: ContentRuntime = ContentRuntime(),
    clock: TestClock<Duration> = TestClock()
  ) -> TestStoreOf<TerminalsFeature> {
    let store = TestStore(initialState: state) {
      TerminalsFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.continuousClock = clock
      $0.contentRuntime = runtime
      $0[ContentSessionKiller.self] = ContentSessionKiller(kill: { _, _ in })
    }
    store.exhaustivity = .off
    return store
  }

  private static func tabIDs(_ state: TerminalsFeature.State, _ id: LayoutID) -> [TabID] {
    state.layouts[id: id]?.layout.panes.flatMap(\.tabs.ids) ?? []
  }

  // MARK: - Merge.

  @Test(.dependencies) func mergeMovesTabsAndMembersInOrder() async {
    let (first, second, own) = (Self.tab("a1"), Self.tab("a2"), Self.tab("b1"))
    let store = Self.store(
      Self.state(
        source: [first, second], members: [Self.session("PA"), Self.session("TA")],
        destination: [own], holding: [Self.session("PB")]))

    await store.send(.transferTabs(from: Self.source, into: Self.destination, scope: .all))

    #expect(Self.tabIDs(store.state, Self.destination) == [own.id, first.id, second.id])
    #expect(store.state.members[Self.destination] == [Self.session("PB"), Self.session("PA"), Self.session("TA")])
    #expect(store.state.members[Self.source] == nil)
    #expect(store.state.layouts[id: Self.source]?.layout == PaneLayout())
    #expect(store.state.layouts[id: Self.destination]?.layout.isConsistent == true)
    // The destination keeps showing what it showed.
    #expect(store.state.layouts[id: Self.destination]?.layout.panes.first?.selectedTabID == own.id)
    // The content rides along untouched.
    let landed = store.state.layouts[id: Self.destination]?.layout.pane(containingTab: first.id)?.tabs[id: first.id]
    #expect(landed == first)
  }

  @Test(.dependencies) func mergeIntoShellOnlyTaskKeepsSourceOrder() async {
    let store = Self.store(
      Self.state(
        source: [Self.tab("a1")], members: [Self.session("PA"), Self.session("TA")],
        destination: [Self.tab("b1")]))

    await store.send(.transferTabs(from: Self.source, into: Self.destination, scope: .all))

    #expect(store.state.members[Self.destination] == [Self.session("PA"), Self.session("TA")])
  }

  @Test(.dependencies) func mergeIntoEmptyLayoutBootstrapsOnePane() async {
    let (first, second) = (Self.tab("a1"), Self.tab("a2"))
    let store = Self.store(Self.state(source: [first, second], destination: [], holding: [Self.session("PB")]))

    await store.send(.transferTabs(from: Self.source, into: Self.destination, scope: .all))

    let landed = store.state.layouts[id: Self.destination]?.layout
    #expect(landed?.panes.count == 1)
    #expect(landed?.isConsistent == true)
    #expect(landed?.panes.first.map { Array($0.tabs.ids) } == [first.id, second.id])
    #expect(landed?.focusedPaneID == landed?.panes.first?.id)
  }

  @Test(.dependencies) func provisionalMemberMovesWithItsTask() async {
    let waiting = TaskMember.provisional(harness: .pi, surfaceID: UUID())
    let store = Self.store(
      Self.state(
        source: [Self.tab("a1")], members: [waiting],
        destination: [Self.tab("b1")], holding: [Self.session("PB")]))

    await store.send(.transferTabs(from: Self.source, into: Self.destination, scope: .all))

    // Its place is held in the destination, so the ref upgrades there.
    #expect(store.state.members[Self.destination] == [Self.session("PB"), waiting])
    let upgraded = TaskMembership.reconciled(
      store.state.members,
      agents: [
        TaskAgent(
          layoutID: Self.destination, harness: .pi, surfaceID: waiting.surfaceIDForTesting, sessionRef: "late")
      ])
    #expect(upgraded[Self.destination] == [Self.session("PB"), Self.session("late")])
    #expect(upgraded[Self.source] == nil)
  }

  // MARK: - Detach.

  @Test(.dependencies) func detachMovesOneTabAndNamedMembers() async {
    let (first, second) = (Self.tab("a1"), Self.tab("a2"))
    let store = Self.store(
      Self.state(source: [first, second], members: [Self.session("PA"), Self.session("TA")], destination: nil))
    // The manager attaches the new task before it asks for the move.
    await store.send(.attachLayout(worktreeID: Self.destination, directory: Self.directory, titlePrefix: "wt"))

    await store.send(
      .transferTabs(from: Self.source, into: Self.destination, scope: .tab(second.id, members: [Self.session("TA")])))

    #expect(Self.tabIDs(store.state, Self.source) == [first.id])
    #expect(Self.tabIDs(store.state, Self.destination) == [second.id])
    #expect(store.state.members[Self.source] == [Self.session("PA")])
    #expect(store.state.members[Self.destination] == [Self.session("TA")])
    #expect(store.state.layouts[id: Self.source]?.layout.isConsistent == true)
    #expect(store.state.layouts[id: Self.destination]?.layout.isConsistent == true)
    #expect(store.state.mergedTasks.isEmpty, "the source still exists: nothing forwards")
  }

  // MARK: - All or nothing.

  @Test(.dependencies) func unknownTabOrLayoutChangesNothing() async {
    let state = Self.state(
      source: [Self.tab("a1")], members: [Self.session("PA")],
      destination: [Self.tab("b1")], holding: [Self.session("PB")])
    let store = Self.store(state)
    store.exhaustivity = .on
    let stranger = LayoutID(task: UUID())

    await store.send(.transferTabs(from: stranger, into: Self.destination, scope: .all))
    await store.send(.transferTabs(from: Self.source, into: stranger, scope: .all))
    await store.send(.transferTabs(from: Self.source, into: Self.source, scope: .all))
    await store.send(.transferTabs(from: Self.source, into: Self.destination, scope: .tab(TabID(), members: [])))

    #expect(store.state == state)
  }

  @Test(.dependencies) func aSharedTabIDMovesNothing() async {
    let shared = Self.tab("both")
    let state = Self.state(
      source: [shared, Self.tab("a2")], members: [Self.session("PA")],
      destination: [shared], holding: [Self.session("PB")])
    let store = Self.store(state)
    store.exhaustivity = .on

    await store.send(.transferTabs(from: Self.source, into: Self.destination, scope: .all))

    #expect(store.state == state)
  }

  // MARK: - Layout bookkeeping.

  @Test(.dependencies) func windowedSourcePaneIsForgotten() async throws {
    let (first, second) = (Self.tab("a1"), Self.tab("a2"))
    // A second pane, in its own window, holding only the tab that leaves.
    let (staying, leaving) = (PaneID(), PaneID())
    var state = Self.state(source: [], destination: nil)
    state.layouts[id: Self.source]?.layout = PaneLayout(
      tree: try SplitTree(view: staying).inserting(view: leaving, at: staying, direction: .right),
      panes: [
        Pane(id: staying, tabs: [first], selectedTabID: first.id),
        Pane(id: leaving, tabs: [second], selectedTabID: second.id),
      ],
      focusedPaneID: staying)
    state.layouts[id: Self.source]?.windowedPaneIDs = [leaving]
    #expect(state.layouts[id: Self.source]?.layout.isConsistent == true)
    let store = Self.store(state)
    await store.send(.attachLayout(worktreeID: Self.destination, directory: Self.directory, titlePrefix: "wt"))

    await store.send(.transferTabs(from: Self.source, into: Self.destination, scope: .tab(second.id, members: [])))

    #expect(store.state.layouts[id: Self.source]?.windowedPaneIDs.isEmpty == true)
    #expect(store.state.layouts[id: Self.source].map { Array($0.layout.panes.ids) } == [staying])
    #expect(Self.tabIDs(store.state, Self.destination) == [second.id])
  }

  @Test(.dependencies) func editingTabIsCleared() async {
    let (first, second) = (Self.tab("a1"), Self.tab("a2"))
    var state = Self.state(source: [first, second], destination: [Self.tab("b1")])
    state.layouts[id: Self.source]?.editingTabID = second.id
    let store = Self.store(state)

    await store.send(.transferTabs(from: Self.source, into: Self.destination, scope: .all))

    #expect(store.state.layouts[id: Self.source]?.editingTabID == nil)
  }

  // MARK: - Hibernation.

  private struct HibernationFixture {
    let state: TerminalsFeature.State
    let runtime: ContentRuntime
    let hidden: TabItem
    let content: LiveContent
  }

  /// Source selected with a hidden second tab whose content is live.
  private func hibernationFixture() -> HibernationFixture {
    let (shown, hidden) = (Self.tab("a1"), Self.tab("a2"))
    let runtime = ContentRuntime()
    let content = LiveContent(id: hidden.content.id)
    _ = runtime.provision(LiveContent(id: shown.content.id), at: .fallback)
    _ = runtime.provision(content, at: .fallback)
    // The destination's own tab has no renderer, so it never arms a timer.
    return HibernationFixture(
      state: Self.state(source: [shown, hidden], destination: [Self.tab("b1")]), runtime: runtime, hidden: hidden,
      content: content)
  }

  @Test(.dependencies) func armedTimerIsReArmedUnderTheDestination() async {
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global.terminalHibernationEnabled = true }
    let fixture = hibernationFixture()
    let clock = TestClock()
    let store = Self.store(fixture.state, runtime: fixture.runtime, clock: clock)
    await store.send(.selectedLayoutChanged(Self.source))
    #expect(store.state.hibernationArmedTabs.contains(fixture.hidden.id))

    await store.send(.transferTabs(from: Self.source, into: Self.destination, scope: .all))
    #expect(store.state.hibernationArmedTabs.contains(fixture.hidden.id))

    // The timer names the task that holds the tab now, so it finds the tab.
    await clock.advance(by: TerminalsFeature.hibernationGraceWindow)
    await store.skipReceivedActions(strict: false)
    #expect(fixture.content.renderer == nil)
    #expect(store.state.layouts[id: Self.destination]?.renderEpoch != 0)
    #expect(store.state.layouts[id: Self.source]?.renderEpoch == 0)
  }

  @Test(.dependencies) func staleTimerForSourceIsANoOp() async {
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global.terminalHibernationEnabled = true }
    let fixture = hibernationFixture()
    let store = Self.store(fixture.state, runtime: fixture.runtime)
    await store.send(.selectedLayoutChanged(Self.source))
    await store.send(.transferTabs(from: Self.source, into: Self.destination, scope: .all))
    let layouts = store.state.layouts

    await store.send(.hibernationGraceElapsed(worktreeID: Self.source, tabID: fixture.hidden.id))

    #expect(fixture.content.renderer != nil, "a timer for the task the tab left hibernates nothing")
    #expect(store.state.layouts == layouts)
  }

  @Test(.dependencies) func hiddenHibernatedTabMadeVisibleIsWokenOnce() async {
    let moved = Self.tab("a1")
    let runtime = ContentRuntime()
    let content = LiveContent(id: moved.content.id)
    _ = runtime.provision(content, at: .fallback)
    content.hibernate()
    let store = Self.store(Self.state(source: [moved], destination: []), runtime: runtime)
    // The empty destination is on screen; the source, and its tab, are not.
    await store.send(.selectedLayoutChanged(Self.destination))
    #expect(content.startCalls == 1)

    await store.send(.transferTabs(from: Self.source, into: Self.destination, scope: .all))
    await store.skipReceivedActions(strict: false)

    #expect(content.renderer != nil)
    #expect(content.startCalls == 2, "woken once, by the task that shows it now")
  }

  // MARK: - Refusals.

  @Test func refusalTable() {
    let (first, own) = (Self.tab("a1"), Self.tab("b1"))
    let ready = Self.state(
      source: [first], members: [Self.session("PA")], destination: [own], holding: [Self.session("PB")])
    let fresh = LayoutID(task: UUID())
    func refusal(
      _ state: TerminalsFeature.State, from: LayoutID = Self.source, into target: LayoutID = Self.destination,
      scope: TabTransferScope = .all, on directory: TaskRecord.Directory = Self.directory
    ) -> TabTransferRefusal? {
      state.transferRefusal(from: from, into: target, scope: scope, destination: directory)
    }
    func changed(_ change: (inout TerminalsFeature.State) -> Void) -> TerminalsFeature.State {
      var state = ready
      change(&state)
      return state
    }

    #expect(refusal(ready) == nil)
    #expect(refusal(ready, into: fresh, scope: .tab(first.id, members: [Self.session("PA")])) == nil)
    #expect(refusal(ready, into: Self.source) == .sameTask)
    #expect(refusal(changed { $0.layoutsLoaded = false }) == .notReady)
    #expect(refusal(changed { $0.storedSessions = .pending }) == .notReady)
    #expect(refusal(changed { $0.storedSessions = .unreadable }) == .notReady)
    #expect(refusal(changed { $0.layoutsAreReadOnly = true }) == .notReady)
    #expect(refusal(ready, from: fresh) == .unknownSource)
    #expect(refusal(ready, into: fresh) == .unknownDestination)
    #expect(refusal(ready, scope: .tab(first.id, members: [])) == .destinationExists)
    #expect(refusal(ready, into: fresh, scope: .tab(TabID(), members: [])) == .unknownTab)
    #expect(refusal(ready, into: fresh, scope: .tab(first.id, members: [Self.session("PB")])) == .memberNotInSource)
    let alert = AlertState<LayoutFeature.Action.Alert> { TextState("Close?") }
    #expect(refusal(changed { $0.layouts[id: Self.source]?.alert = alert }) == .confirmationPending)
    #expect(refusal(changed { $0.layouts[id: Self.destination]?.alert = alert }) == .confirmationPending)
    let remote = TaskRecord.Directory(
      worktreeID: Self.directory.worktreeID, host: RemoteHost(alias: "build-box"))
    #expect(refusal(ready, on: remote) == .differentMachine)
    #expect(refusal(changed { $0.directories[Self.source] = remote }) == .differentMachine)
    #expect(refusal(changed { $0.directories[Self.source] = remote }, on: remote) == nil)
  }

  // MARK: - The stored result.

  @Test(.dependencies) func hydratedOrderSurvivesARoundTrip() async throws {
    let (first, second, own) = (Self.tab("a1"), Self.tab("a2"), Self.tab("b1"))
    let members = (source: [Self.session("PA"), Self.session("TA")], destination: [Self.session("PB")])
    let before = Self.state(
      source: [first, second], members: members.source, destination: [own], holding: members.destination)
    let defaults = UserDefaults.inMemory
    let writer = LayoutsIncrementalWriter(store: LayoutsUserDefaultsStore(defaults: defaults))
    func record(_ state: TerminalsFeature.State, _ id: LayoutID) -> LayoutsIncrementalWriter.RecordChange {
      .record(
        layout: state.layouts[id: id]?.layout ?? PaneLayout(), directory: Self.directory,
        sessions: (state.members[id] ?? []).compactMap(\.sessionKey), storedSessions: .loaded,
        createdAt: Date(timeIntervalSince1970: 1))
    }
    await writer.flush(records: [
      Self.source: record(before, Self.source), Self.destination: record(before, Self.destination),
    ])
    let store = Self.store(before)

    await store.send(.transferTabs(from: Self.source, into: Self.destination, scope: .all))
    // The two changes the manager writes, in its one flush.
    await writer.flush(records: [
      Self.source: .mergedInto(Self.destination), Self.destination: record(store.state, Self.destination),
    ])

    let data = try #require(defaults.data(forKey: LayoutsFile.userDefaultsKey))
    let file = try JSONDecoder().decode(TaskLayoutsFile.self, from: data)
    let relaunched = Self.store(TerminalsFeature.State())
    await relaunched.send(.storedSessions(.file(file)))
    await relaunched.send(.layoutsHydrated(file))

    #expect(Array(relaunched.state.layouts.ids) == [Self.destination])
    #expect(Self.tabIDs(relaunched.state, Self.destination) == [own.id, first.id, second.id])
    #expect(relaunched.state.members == [Self.destination: members.destination + members.source])
    #expect(relaunched.state.mergedTasks == [Self.source: Self.destination])
    #expect(relaunched.state.layoutsLoaded)
  }

  // MARK: - A merged task id stays addressable.

  @Test(.dependencies) func mergedTaskIdResolvesToItsDestination() async {
    let store = Self.store(Self.state(source: [Self.tab("a1")], destination: [Self.tab("b1")]))
    #expect(
      store.state.commandLayoutID(forDirectory: Self.directory.worktreeID, task: Self.source) == Self.source)

    await store.send(.transferTabs(from: Self.source, into: Self.destination, scope: .all))
    // What the manager does next: the emptied source is removed.
    await store.send(.detachLayout(worktreeID: Self.source))

    #expect(store.state.mergedTasks == [Self.source: Self.destination])
    #expect(
      store.state.commandLayoutID(forDirectory: Self.directory.worktreeID, task: Self.source) == Self.destination)
  }

  @Test(.dependencies) func aliasChainStaysOneHop() async {
    let third = LayoutID(task: UUID())
    var state = Self.state(source: [Self.tab("a1")], destination: [Self.tab("b1")])
    state.layouts.append(LayoutFeature.State(id: third, layout: Self.layout([Self.tab("c1")])))
    state.directories[third] = Self.directory
    let store = Self.store(state)

    await store.send(.transferTabs(from: Self.source, into: Self.destination, scope: .all))
    await store.send(.detachLayout(worktreeID: Self.source))
    await store.send(.transferTabs(from: Self.destination, into: third, scope: .all))
    await store.send(.detachLayout(worktreeID: Self.destination))

    #expect(store.state.mergedTasks == [Self.source: third, Self.destination: third])
    #expect(store.state.commandLayoutID(forDirectory: Self.directory.worktreeID, task: Self.source) == third)
  }

  @Test(.dependencies) func aliasOnAnotherDirectoryStillFails() async {
    var state = Self.state(source: [Self.tab("a1")], destination: [Self.tab("b1")])
    state.directories[Self.destination] = TaskRecord.Directory(worktreeID: "/tmp/elsewhere")
    let store = Self.store(state)

    await store.send(.transferTabs(from: Self.source, into: Self.destination, scope: .all))
    await store.send(.detachLayout(worktreeID: Self.source))

    // The shell's own directory no longer holds the task it names.
    #expect(store.state.commandLayoutID(forDirectory: Self.directory.worktreeID, task: Self.source) == nil)
    #expect(store.state.commandLayoutID(forDirectory: "/tmp/elsewhere", task: Self.source) == Self.destination)
  }

  @Test(.dependencies) func reattachClearsTheAlias() async {
    let store = Self.store(Self.state(source: [Self.tab("a1")], destination: [Self.tab("b1")]))
    await store.send(.transferTabs(from: Self.source, into: Self.destination, scope: .all))
    await store.send(.detachLayout(worktreeID: Self.source))

    // A tab creation already scheduled into the source lands after the merge.
    await store.send(.attachLayout(worktreeID: Self.source, directory: Self.directory, titlePrefix: "wt"))

    #expect(store.state.mergedTasks.isEmpty)
    #expect(!store.state.removedLayoutIDs.contains(Self.source))
  }

  @Test(.dependencies) func removingTheDestinationDropsItsAliases() async {
    let store = Self.store(Self.state(source: [Self.tab("a1")], destination: [Self.tab("b1")]))
    await store.send(.transferTabs(from: Self.source, into: Self.destination, scope: .all))
    await store.send(.detachLayout(worktreeID: Self.source))

    await store.send(.detachLayout(worktreeID: Self.destination))

    #expect(store.state.mergedTasks.isEmpty)
  }
}

extension TaskMember {
  fileprivate var surfaceIDForTesting: UUID {
    guard case .provisional(_, let surfaceID) = self else { return UUID() }
    return surfaceID
  }
}

import Clocks
import ComposableArchitecture
import ConcurrencyExtras
import Dependencies
import DependenciesTestSupport
import Foundation
import IdentifiedCollections
import OrderedCollections
import Sharing
import SupacodeSettingsFeature
import SupacodeSettingsShared
import Testing

@testable import supacode

/// Moving live tabs between tasks: no session is killed, nothing reports the
/// tabs closed, and the store never holds a moved tab in neither task or both.
@MainActor
@Suite(.serialized)
struct WorktreeTerminalManagerTransferTests {
  private struct Harness {
    let manager: WorktreeTerminalManager
    let store: Store<AppFeature.State, AppFeature.Action>
    let recorder: Recorder
    let clock: TestClock<Duration>
    let events: EventLog

    var terminals: TerminalsFeature.State { store.withState(\.terminals) }

    func tabIDs(_ layoutID: LayoutID) -> [UUID] {
      terminals.layouts[id: layoutID]?.layout.panes.flatMap { $0.tabs.ids.map(\.rawValue) } ?? []
    }
  }

  private static func worktree(_ id: String) -> Worktree {
    Worktree(
      id: WorktreeID(id),
      name: URL(fileURLWithPath: id).lastPathComponent,
      detail: "detail",
      workingDirectory: URL(fileURLWithPath: id),
      repositoryRootURL: URL(fileURLWithPath: "/tmp/repo")
    )
  }

  private static let directory = worktree("/tmp/repo/wt-transfer")

  /// A manager on a real `AppFeature` store with the app's own persistence
  /// and kill wiring, its stored layouts and sessions already loaded.
  /// `liveSurfaces` builds real terminal contents in the live runtime, wired
  /// as the app wires them.
  private func makeHarness(
    liveSurfaces: GhosttyRuntime? = nil,
    listSessions: @escaping @Sendable () async -> [ZmxSessionListParser.Entry]? = { nil },
    seed: (inout AppFeature.State) -> Void = { _ in }
  ) async -> Harness {
    let recorder = Recorder()
    let clock = TestClock()
    let manager = withDependencies {
      $0.settingsFileStorage = .inMemory()
      $0.defaultAppStorage = recorder.defaults
      $0.zmxClient = ZmxClient(
        executableURL: { nil },
        isBundled: { true },
        killSession: { session in recorder.localKills.withValue { $0.append(session) } },
        killRemoteSession: { _, session in recorder.remoteKills.withValue { $0.append(session) } },
        listSessionsWithClients: listSessions
      )
    } operation: {
      WorktreeTerminalManager(runtime: GhosttyRuntime(), clock: clock)
    }
    var initial = AppFeature.State(repositories: RepositoriesFeature.State(), settings: SettingsFeature.State())
    seed(&initial)
    let store = Store(initialState: initial) {
      AppFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.date.now = Date(timeIntervalSince1970: 0)
      $0.continuousClock = clock
      $0.contentRuntime = liveSurfaces == nil ? ContentRuntime() : ContentRuntime.liveValue
      $0[LayoutContentFactory.self] = LayoutContentFactory { request in
        guard let liveSurfaces else { return InertTabContent(id: request.contentID, state: request.content) }
        return TeardownTestSupport.content(id: request.contentID, runtime: liveSurfaces) { view in
          manager.wireSurface(view, contentID: request.contentID, layoutID: request.worktreeID)
        }
      }
      $0[ContentSessionKiller.self] = ContentSessionKiller(kill: { contentID, layoutID in
        await manager.killSession(for: contentID, layoutID: layoutID)
      })
      $0[LayoutChangeObserver.self] = .persisting(through: manager)
      // The app's commands wait in a queue until the test delivers them, so a
      // request can be made before a change and land after it.
      $0.terminalClient.send = { command in recorder.queuedCommands.withValue { $0.append(command) } }
      $0.worktreeInfoWatcher.send = { _ in }
      $0.settingsFileStorage = .inMemory()
    }
    manager.appStore = store
    let events = EventLog(manager)
    await store.send(.terminals(.storedSessions(.absent))).finish()
    await store.send(.terminals(.layoutsHydrated(TaskLayoutsFile()))).finish()
    return Harness(manager: manager, store: store, recorder: recorder, clock: clock, events: events)
  }

  /// Opens one tab in `layoutID`; returns its surface id (also its tab id).
  private func open(
    _ layoutID: LayoutID, on directory: Worktree = WorktreeTerminalManagerTransferTests.directory, in harness: Harness
  ) async -> UUID {
    let surfaceID = UUID()
    harness.manager.handleCommand(
      .createTab(
        layoutID, DirectoryContext(worktree: directory), runSetupScriptIfNew: false, id: surfaceID,
        focusing: false))
    _ = await harness.events.collect { $0 == .surfaceCreated(layoutID: layoutID, id: surfaceID) }
    return surfaceID
  }

  private func merge(
    _ source: LayoutID, into destination: LayoutID,
    on directory: Worktree = WorktreeTerminalManagerTransferTests.directory, in harness: Harness
  ) {
    harness.manager.handleCommand(
      .transferTabs(from: source, into: destination, DirectoryContext(worktree: directory), request: .all))
  }

  /// Hands the manager every command the app queued since the last delivery,
  /// in order: the asynchronous boundary a `.run` effect is, made explicit.
  private func deliverQueuedCommands(in harness: Harness) {
    let commands = harness.recorder.queuedCommands.withValue { queued in
      defer { queued.removeAll() }
      return queued
    }
    for command in commands { harness.manager.handleCommand(command) }
  }

  /// The app's roster lists the fixture directory, so selecting a task on it
  /// takes the directory path that shows the task.
  private static func listDirectory(_ state: inout AppFeature.State) {
    state.repositories.repositories = [
      Repository(
        id: RepositoryID(directory.repositoryRootURL.path), rootURL: directory.repositoryRootURL, name: "repo",
        worktrees: [directory])
    ]
    state.repositories.isInitialLoadComplete = true
  }

  /// What the store holds once every debounced save has been driven through.
  private func settledStore(_ harness: Harness) async -> TaskLayoutsFile {
    for _ in 0..<20 {
      await harness.clock.advance(by: .seconds(1))
      await Task.megaYield()
    }
    return harness.recorder.current() ?? TaskLayoutsFile()
  }

  /// The first matching write, with the save debounce driven until it lands.
  private func stored(_ harness: Harness, where matches: (TaskLayoutsFile) -> Bool) async -> TaskLayoutsFile {
    let debounce = Task { @MainActor in
      for _ in 0..<20 where !Task.isCancelled {
        await harness.clock.advance(by: .seconds(1))
      }
    }
    defer { debounce.cancel() }
    return await harness.recorder.nextWrite(where: matches)
  }

  private static func session(_ ref: String) -> SessionKey { SessionKey(harness: .pi, sessionID: ref) }

  /// An agent reports its session on a surface; the link reducer lists it
  /// under the task that holds the surface.
  /// Not awaited to completion: the restore starts clock-driven work that
  /// never finishes under the test clock. Waits for the listing instead.
  private func report(_ ref: String, on surfaceID: UUID, pid: pid_t, in harness: Harness) async {
    let key = AgentPresenceFeature.PresenceKey(agent: .pi, surfaceID: surfaceID)
    harness.store.send(
      .agentPresence(
        .restoreFromSnapshotChecked(
          records: [key: AgentPresenceFeature.RestoredRecord(alivePids: [pid], activity: .idle, sessionRef: ref)],
          resumeCandidates: [:])))
    let listed = Self.session(ref)
    for _ in 0..<500 where !harness.terminals.members.values.contains(where: { $0.contains(.session(listed)) }) {
      await Task.yield()
    }
  }

  /// The app's request, as the effect delivers it: tab identity only.
  private func detach(_ tabID: UUID, from source: LayoutID, into minted: LayoutID, in harness: Harness) {
    harness.manager.handleCommand(
      .transferTabs(
        from: source, into: minted, DirectoryContext(worktree: Self.directory), request: .tab(TabID(rawValue: tabID))
      ))
  }

  private static func isTransferOutcome(_ event: TerminalClient.Event) -> Bool {
    switch event {
    case .tabsTransferred, .tabsTransferFailed: true
    default: false
    }
  }

  private static func reportsAClose(_ event: TerminalClient.Event) -> Bool {
    switch event {
    case .surfacesClosed, .userClosedSurfaces, .tabClosed, .tabRemoved, .blockingScriptCompleted: true
    default: false
    }
  }

  // MARK: - Nothing is killed, nothing is closed.

  @Test(.dependencies) func mergeKillsNothingAndClosesNothing() async {
    let harness = await makeHarness()
    let (source, destination) = (LayoutID(task: UUID()), LayoutID(task: UUID()))
    let first = await open(source, in: harness)
    let second = await open(source, in: harness)
    let own = await open(destination, in: harness)
    let before = Set(harness.terminals.layouts.flatMap { $0.layout.allContentIDs })

    merge(source, into: destination, in: harness)
    let events = await harness.events.collect(until: Self.isTransferOutcome)

    #expect(harness.tabIDs(destination) == [own, first, second])
    #expect(Set(harness.terminals.layouts.flatMap { $0.layout.allContentIDs }) == before)
    #expect(before.count == 3)
    #expect(!events.contains(where: Self.reportsAClose), "a moved tab is not a closed tab: \(events)")
    #expect(
      events.filter(Self.isTransferOutcome) == [
        .tabsTransferred(
          from: source, into: destination, tabIDs: [first, second].map(TabID.init(rawValue:)), sourceRemoved: true)
      ])
    #expect(
      events.filter { if case .worktreeStateTornDown = $0 { true } else { false } }
        == [.worktreeStateTornDown(worktreeID: Self.directory.id, layoutID: source)])

    // The source is gone without a teardown of its sessions.
    #expect(harness.manager.hostIfExists(for: source) == nil)
    #expect(harness.manager.hostIfExists(for: destination) != nil)
    #expect(harness.terminals.layouts[id: source] == nil)
    #expect(harness.terminals.removedLayoutIDs.contains(source))
    // Any kill would have been requested by now: let every effect settle.
    await harness.clock.advance(by: .seconds(5))
    await Task.megaYield()
    #expect(harness.recorder.localKills.value.isEmpty)
    #expect(harness.recorder.remoteKills.value.isEmpty)
  }

  @Test(.dependencies) func mergeSettlesNothingInTheApp() async {
    let harness = await makeHarness()
    let (source, destination) = (LayoutID(task: UUID()), LayoutID(task: UUID()))
    _ = await open(source, in: harness)
    _ = await open(destination, in: harness)
    let (sourcePrimary, destinationPrimary) = (Self.session("PA"), Self.session("PB"))
    await harness.store.send(
      .terminals(.membersChanged([source: [.session(sourcePrimary)], destination: [.session(destinationPrimary)]]))
    ).finish()
    let presence = harness.store.withState(\.agentPresence)

    merge(source, into: destination, in: harness)
    _ = await harness.events.collect(until: Self.isTransferOutcome)
    await Task.megaYield()

    // The source's primary is a tangent of the destination now, in order.
    #expect(harness.terminals.members == [destination: [.session(destinationPrimary), .session(sourcePrimary)]])
    #expect(harness.store.withState(\.agentPresence) == presence)
  }

  @Test(.dependencies) func closingAMovedTabKillsItOnce() async {
    let harness = await makeHarness()
    let (source, destination) = (LayoutID(task: UUID()), LayoutID(task: UUID()))
    let moved = await open(source, in: harness)
    let other = await open(source, in: harness)
    _ = await open(destination, in: harness)
    merge(source, into: destination, in: harness)
    _ = await harness.events.collect(until: Self.isTransferOutcome)

    await harness.store.send(
      .terminals(.layouts(.element(id: destination, action: .closeTab(id: TabID(rawValue: moved)))))
    ).finish()
    let events = await harness.events.collect {
      if case .surfacesClosed = $0 { true } else { false }
    }

    // The task that holds the tab now reports its close, exactly once.
    #expect(events.contains(.surfacesClosed(layoutID: destination, [moved])))
    #expect(harness.recorder.localKills.value == [ZmxSessionID.make(surfaceID: moved)])
    #expect(harness.tabIDs(destination).contains(other))
  }

  // MARK: - Detach.

  /// What moves is read when the request lands, not when it was made: the
  /// tangent that reported on the tab after the menu opened goes with it.
  @Test(.dependencies) func detachRequestMovesTheMembersOnTheTabAtDelivery() async {
    let harness = await makeHarness()
    let (source, minted) = (LayoutID(task: UUID()), LayoutID(task: UUID()))
    let staying = await open(source, in: harness)
    let leaving = await open(source, in: harness)
    await report("PA", on: staying, pid: 101, in: harness)
    await report("TA", on: leaving, pid: 102, in: harness)
    let (primary, tangent) = (Self.session("PA"), Self.session("TA"))
    #expect(harness.terminals.members[source] == [.session(primary), .session(tangent)])

    detach(leaving, from: source, into: minted, in: harness)
    let events = await harness.events.collect(until: Self.isTransferOutcome)

    #expect(
      events.filter(Self.isTransferOutcome) == [
        .tabsTransferred(from: source, into: minted, tabIDs: [TabID(rawValue: leaving)], sourceRemoved: false)
      ])
    #expect(harness.tabIDs(source) == [staying])
    #expect(harness.tabIDs(minted) == [leaving])
    #expect(harness.terminals.members == [source: [.session(primary)], minted: [.session(tangent)]])
  }

  /// A shell tab was asked to detach; by delivery an agent started on it and
  /// is the task's primary (Q8). Nothing moves, nothing is minted.
  @Test(.dependencies) func detachRequestIsRefusedWhenThePrimaryStartedOnTheTabMeanwhile() async {
    let harness = await makeHarness()
    let (source, minted) = (LayoutID(task: UUID()), LayoutID(task: UUID()))
    let staying = await open(source, in: harness)
    let leaving = await open(source, in: harness)
    await report("PA", on: leaving, pid: 101, in: harness)
    #expect(harness.terminals.members[source] == [.session(Self.session("PA"))])
    let before = harness.terminals

    detach(leaving, from: source, into: minted, in: harness)
    let events = await harness.events.collect(until: Self.isTransferOutcome)

    #expect(
      events.filter(Self.isTransferOutcome) == [.tabsTransferFailed(from: source, into: minted, reason: .primaryTab)])
    #expect(harness.terminals == before)
    #expect(harness.tabIDs(source) == [staying, leaving])
    #expect(harness.manager.hostIfExists(for: minted) == nil, "a refusal creates no host")
  }

  /// The source's other tab closed before the request landed: detaching the
  /// one left would leave a task with nothing. Refused at delivery.
  @Test(.dependencies) func detachRequestIsRefusedWhenTheTabBecameTheOnlyOneMeanwhile() async {
    let harness = await makeHarness()
    let (source, minted) = (LayoutID(task: UUID()), LayoutID(task: UUID()))
    let closing = await open(source, in: harness)
    let leaving = await open(source, in: harness)
    await harness.store.send(
      .terminals(.layouts(.element(id: source, action: .closeTab(id: TabID(rawValue: closing)))))
    ).finish()
    _ = await harness.events.collect { $0 == .surfacesClosed(layoutID: source, [closing]) }
    #expect(harness.tabIDs(source) == [leaving])
    let before = harness.terminals

    detach(leaving, from: source, into: minted, in: harness)
    let events = await harness.events.collect(until: Self.isTransferOutcome)

    #expect(
      events.filter(Self.isTransferOutcome) == [.tabsTransferFailed(from: source, into: minted, reason: .onlyTab)])
    #expect(harness.terminals == before)
    #expect(harness.manager.hostIfExists(for: minted) == nil)
  }

  /// A resume into a dormant source was accepted after the merge request and
  /// its tab has not appeared. Moving the source out from under it would let
  /// the launch recreate the removed task: refused at delivery.
  @Test(.dependencies) func mergeRequestIsRefusedWhileALaunchIntoTheSourceIsPendingAtDelivery() async {
    let (source, destination) = (LayoutID(task: UUID()), LayoutID(task: UUID()))
    let harness = await makeHarness { state in
      state.pendingTaskLaunches = [PendingTaskLaunch(layoutID: source, directoryID: Self.directory.id)]
    }
    let record = TaskRecord(
      id: source, directory: TaskRecord.Directory(worktreeID: Self.directory.id),
      sessions: [Self.session("PA")], createdAt: Date(timeIntervalSince1970: 1))
    let seeded = TaskLayoutsFile(tasks: [source.persistenceKey: record])
    await harness.store.send(.terminals(.storedSessions(.file(seeded)))).finish()
    await harness.store.send(.terminals(.layoutsHydrated(seeded))).finish()
    _ = await open(destination, in: harness)
    #expect(harness.store.withState(\.pendingTaskLaunches).map(\.layoutID) == [source], "no tab yet: still pending")
    let before = harness.terminals

    merge(source, into: destination, in: harness)
    let events = await harness.events.collect(until: Self.isTransferOutcome)

    #expect(
      events.filter(Self.isTransferOutcome)
        == [.tabsTransferFailed(from: source, into: destination, reason: .launchPending)])
    #expect(harness.terminals == before)
    #expect(harness.terminals.members[source] == [.session(Self.session("PA"))])
  }

  @Test(.dependencies) func detachLeavesTheSourceRunning() async {
    let harness = await makeHarness()
    let (source, minted) = (LayoutID(task: UUID()), LayoutID(task: UUID()))
    let staying = await open(source, in: harness)
    let leaving = await open(source, in: harness)
    let (primary, tangent) = (Self.session("PA"), Self.session("TA"))
    await harness.store.send(.terminals(.membersChanged([source: [.session(primary), .session(tangent)]]))).finish()

    harness.manager.transferTabs(
      from: source, into: minted, context: DirectoryContext(worktree: Self.directory),
      scope: .tab(TabID(rawValue: leaving), members: [.session(tangent)]))
    let events = await harness.events.collect(until: Self.isTransferOutcome)

    #expect(
      events.filter(Self.isTransferOutcome) == [
        .tabsTransferred(from: source, into: minted, tabIDs: [TabID(rawValue: leaving)], sourceRemoved: false)
      ])
    #expect(!events.contains(where: Self.reportsAClose))
    #expect(harness.tabIDs(source) == [staying])
    #expect(harness.tabIDs(minted) == [leaving])
    #expect(harness.terminals.members == [source: [.session(primary)], minted: [.session(tangent)]])
    #expect(harness.manager.hostIfExists(for: source) != nil)
    #expect(harness.manager.hostIfExists(for: minted) != nil)
    #expect(harness.terminals.directories[minted]?.worktreeID == Self.directory.id)
    await harness.clock.advance(by: .seconds(5))
    await Task.megaYield()
    #expect(harness.recorder.localKills.value.isEmpty)
  }

  @Test(.dependencies) func detachingAShellOnlyTasksLastTabRemovesTheSource() async {
    let harness = await makeHarness()
    let (source, minted) = (LayoutID(task: UUID()), LayoutID(task: UUID()))
    let only = await open(source, in: harness)

    harness.manager.transferTabs(
      from: source, into: minted, context: DirectoryContext(worktree: Self.directory),
      scope: .tab(TabID(rawValue: only), members: []))
    let events = await harness.events.collect(until: Self.isTransferOutcome)

    #expect(
      events.filter(Self.isTransferOutcome) == [
        .tabsTransferred(from: source, into: minted, tabIDs: [TabID(rawValue: only)], sourceRemoved: true)
      ])
    #expect(harness.terminals.layouts[id: source] == nil)
    #expect(harness.terminals.mergedTasks.isEmpty, "a detach forwards nothing")
    #expect(harness.tabIDs(minted) == [only])
    #expect(harness.recorder.localKills.value.isEmpty)
  }

  // MARK: - Showing the destination is decided when the command lands.

  private static func createsATab(_ event: TerminalClient.Event) -> Bool {
    switch event {
    case .tabCreated, .surfaceCreated: true
    default: false
    }
  }

  /// The selection, both the manager's and the terminal state's, stays on
  /// the task that survived, and the removed one is in no selection history.
  private func expectSelection(
    on surviving: LayoutID?, not removed: LayoutID, in harness: Harness,
    sourceLocation: SourceLocation = #_sourceLocation
  ) {
    #expect(harness.manager.selectedLayoutID == surviving, sourceLocation: sourceLocation)
    #expect(harness.terminals.selectedLayoutID == surviving, sourceLocation: sourceLocation)
    #expect(!harness.terminals.selectionOrder.contains(removed), sourceLocation: sourceLocation)
    #expect(!harness.terminals.recentLayoutIDs.contains(removed), sourceLocation: sourceLocation)
    #expect(!harness.terminals.activeTasks.values.contains(removed), sourceLocation: sourceLocation)
  }

  /// A→B lands and the app asks to show B; before that reaches the manager,
  /// B→C removes B. The stale request must not bring B back as a host, a
  /// layout or a shell tab, nor leave it selected or stored.
  @Test(.dependencies) func aShowOfTheDestinationLandingAfterItWasMergedAwayShowsNothing() async {
    let harness = await makeHarness(seed: Self.listDirectory)
    let (first, second, third) = (LayoutID(task: UUID()), LayoutID(task: UUID()), LayoutID(task: UUID()))
    _ = await open(first, in: harness)
    _ = await open(second, in: harness)
    _ = await open(third, in: harness)
    harness.manager.handleCommand(.setSelectedLayoutID(first))
    merge(first, into: second, in: harness)
    let landed = await harness.events.collect(until: Self.isTransferOutcome)
    guard let completion = landed.last(where: Self.isTransferOutcome) else {
      Issue.record("no transfer outcome in \(landed)")
      return
    }

    await harness.store.send(.terminalEvent(completion)).finish()
    #expect(harness.store.withState(\.repositories.selectedTaskID) == second)
    merge(second, into: third, in: harness)
    _ = await harness.events.collect(until: Self.isTransferOutcome)
    #expect(harness.terminals.layouts[id: second] == nil)
    #expect(!harness.recorder.queuedCommands.value.isEmpty, "the show request is still in flight")

    deliverQueuedCommands(in: harness)
    let after = await harness.events.collect(until: Self.createsATab)

    #expect(harness.manager.hostIfExists(for: second) == nil, "no host attached to a removed task")
    #expect(harness.terminals.layouts[id: second] == nil, "no layout recreated")
    #expect(harness.terminals.removedLayoutIDs.contains(second))
    #expect(!after.contains(where: Self.createsATab), "no tab created: \(after)")
    #expect(harness.terminals.layouts.map(\.id) == [third])
    #expect(harness.store.withState(\.repositories.selectedTaskID) != second, "a removed task is not selected")
    expectSelection(on: third, not: second, in: harness)
    #expect(
      harness.store.withState { AppFeature.focusedSurfaceID(state: $0) } != nil,
      "the surviving task is what the chords act on")
    let stored = await settledStore(harness)
    #expect(stored.tasks[second.persistenceKey] == nil, "nothing persisted for the removed task")
    #expect(Array(stored.tasks.keys) == [third.persistenceKey])
    #expect(stored.activeTasks[Self.directory.id.rawValue] != second.persistenceKey)
  }

  /// The destination loses its last tab between the completion and the show.
  /// Its tabs leave by detach rather than close: a close's kill confirmation
  /// lands on the removed layout after the fact and is reported as an issue,
  /// which is noise here; the emptied task is removed the same way.
  @Test(.dependencies) func aShowOfADestinationEmptiedBeforeItLandsShowsNothing() async {
    let harness = await makeHarness(seed: Self.listDirectory)
    let (source, destination) = (LayoutID(task: UUID()), LayoutID(task: UUID()))
    let moved = await open(source, in: harness)
    let own = await open(destination, in: harness)
    harness.manager.handleCommand(.setSelectedLayoutID(source))
    merge(source, into: destination, in: harness)
    let landed = await harness.events.collect(until: Self.isTransferOutcome)
    guard let completion = landed.last(where: Self.isTransferOutcome) else {
      Issue.record("no transfer outcome in \(landed)")
      return
    }
    await harness.store.send(.terminalEvent(completion)).finish()

    detach(moved, from: destination, into: LayoutID(task: UUID()), in: harness)
    _ = await harness.events.collect(until: Self.isTransferOutcome)
    // The app refuses to detach a task's only tab; the primitive is the
    // shape a close of that tab leaves behind.
    let last = LayoutID(task: UUID())
    harness.manager.transferTabs(
      from: destination, into: last, context: DirectoryContext(worktree: Self.directory),
      scope: .tab(TabID(rawValue: own), members: []))
    _ = await harness.events.collect(until: Self.isTransferOutcome)
    #expect(harness.terminals.layouts[id: destination] == nil, "a shell-only task with no tab is gone")
    #expect(harness.manager.selectedLayoutID == last, "the emptied selection moved to where its last tab went")

    deliverQueuedCommands(in: harness)
    let after = await harness.events.collect(until: Self.createsATab)

    #expect(harness.manager.hostIfExists(for: destination) == nil)
    #expect(harness.terminals.layouts[id: destination] == nil, "no layout recreated")
    #expect(harness.terminals.layouts.count == 2, "only the two tasks the tabs went to")
    #expect(!after.contains(where: Self.createsATab), "no tab created: \(after)")
    #expect(harness.store.withState(\.repositories.selectedTaskID) != destination)
    expectSelection(on: last, not: destination, in: harness)
    let stored = await settledStore(harness)
    #expect(stored.tasks[destination.persistenceKey] == nil, "nothing persisted for the removed task")
    #expect(stored.tasks.count == 2)
  }

  /// The same through a plain selection: the task is picked while it exists
  /// and gone when the pick reaches the manager.
  @Test(.dependencies) func aSelectionLandingAfterTheTaskWasMergedAwayShowsNothing() async {
    let harness = await makeHarness(seed: Self.listDirectory)
    let (source, destination) = (LayoutID(task: UUID()), LayoutID(task: UUID()))
    _ = await open(source, in: harness)
    _ = await open(destination, in: harness)

    harness.manager.handleCommand(.setSelectedLayoutID(destination))
    await harness.store.send(.repositories(.selectTask(source, directory: Self.directory.id))).finish()
    #expect(harness.store.withState(\.repositories.selectedTaskID) == source)
    merge(source, into: destination, in: harness)
    _ = await harness.events.collect(until: Self.isTransferOutcome)
    #expect(harness.store.withState(\.repositories.selectedTaskID) != source, "the pick ends with the task")

    deliverQueuedCommands(in: harness)
    let after = await harness.events.collect(until: Self.createsATab)

    #expect(harness.manager.hostIfExists(for: source) == nil)
    #expect(harness.terminals.layouts[id: source] == nil)
    #expect(!after.contains(where: Self.createsATab), "no tab created: \(after)")
    #expect(harness.terminals.layouts.map(\.id) == [destination])
    #expect(harness.store.withState(\.repositories.selectedTaskID) != source)
    expectSelection(on: destination, not: source, in: harness)
    let stored = await settledStore(harness)
    #expect(Array(stored.tasks.keys) == [destination.persistenceKey])
  }

  /// The same pick on a directory the roster does not list: the task is
  /// selected with no directory beside it, and the stale selection lands
  /// through the bare command rather than the directory's path.
  @Test(.dependencies) func anOrphanSelectionLandingAfterTheTaskWasMergedAwaySelectsNothing() async {
    let harness = await makeHarness()
    let (source, destination) = (LayoutID(task: UUID()), LayoutID(task: UUID()))
    _ = await open(source, in: harness)
    _ = await open(destination, in: harness)

    harness.manager.handleCommand(.setSelectedLayoutID(destination))
    await harness.store.send(.repositories(.selectTask(source, directory: Self.directory.id))).finish()
    #expect(harness.store.withState(\.repositories.orphanTaskID) == source)
    merge(source, into: destination, in: harness)
    _ = await harness.events.collect(until: Self.isTransferOutcome)

    deliverQueuedCommands(in: harness)
    let after = await harness.events.collect(until: Self.createsATab)

    #expect(harness.manager.hostIfExists(for: source) == nil)
    #expect(harness.terminals.layouts.map(\.id) == [destination])
    #expect(!after.contains(where: Self.createsATab), "no tab created: \(after)")
    expectSelection(on: destination, not: source, in: harness)
  }

  /// A removed task's own key is not a task, but it is still where the
  /// directory's next tab lands: selecting the directory after its only task
  /// closed shows the empty state there, as before.
  @Test(.dependencies) func selectingADirectoryWhoseOwnKeyTaskClosedLandsOnTheOwnKey() async {
    let harness = await makeHarness(seed: Self.listDirectory)
    let ownKey = TerminalsFeature.State.ownKeyLayoutID(forDirectory: Self.directory.id)
    let (elsewhere, other) = (Self.worktree("/tmp/repo/wt-other"), LayoutID(task: UUID()))
    _ = await open(ownKey, in: harness)
    _ = await open(other, on: elsewhere, in: harness)
    harness.manager.handleCommand(.setSelectedLayoutID(other))
    // The only tab leaves for a task on another directory: this one is bare.
    harness.manager.transferTabs(
      from: ownKey, into: LayoutID(task: UUID()), context: DirectoryContext(worktree: elsewhere),
      scope: .tab(TabID(rawValue: harness.tabIDs(ownKey)[0]), members: []))
    _ = await harness.events.collect(until: Self.isTransferOutcome)
    #expect(harness.terminals.removedLayoutIDs.contains(ownKey))

    await harness.store.send(.repositories(.delegate(.selectedWorktreeChanged(Self.directory)))).finish()
    deliverQueuedCommands(in: harness)
    let after = await harness.events.collect(until: Self.createsATab)

    #expect(harness.manager.selectedLayoutID == ownKey)
    #expect(harness.terminals.selectedLayoutID == ownKey)
    #expect(harness.manager.hostIfExists(for: ownKey) == nil, "an empty directory attaches no host")
    #expect(!after.contains(where: Self.createsATab), "no tab created: \(after)")
  }

  /// The own key is a task while it holds tabs. Picked as one and merged
  /// into a sibling on the same directory before the pick lands, it is not
  /// where the directory's first tab lands any more: the directory shows the
  /// task that took its tabs, and that is what the stale pick selects.
  @Test(.dependencies) func aSelectionOfAnOwnKeyTaskMergedAwayLandsOnTheTaskThatTookItsTabs() async {
    let harness = await makeHarness(seed: Self.listDirectory)
    let ownKey = TerminalsFeature.State.ownKeyLayoutID(forDirectory: Self.directory.id)
    let destination = LayoutID(task: UUID())
    _ = await open(ownKey, in: harness)
    _ = await open(destination, in: harness)

    harness.manager.handleCommand(.setSelectedLayoutID(destination))
    await harness.store.send(.repositories(.selectTask(ownKey, directory: Self.directory.id))).finish()
    #expect(harness.store.withState(\.repositories.selectedTaskID) == ownKey)
    merge(ownKey, into: destination, in: harness)
    _ = await harness.events.collect(until: Self.isTransferOutcome)
    #expect(harness.terminals.removedLayoutIDs.contains(ownKey))

    deliverQueuedCommands(in: harness)
    let after = await harness.events.collect(until: Self.createsATab)

    #expect(harness.manager.hostIfExists(for: ownKey) == nil)
    #expect(harness.terminals.layouts.map(\.id) == [destination])
    #expect(!after.contains(where: Self.createsATab), "no tab created: \(after)")
    #expect(harness.store.withState(\.repositories.selectedTaskID) != ownKey)
    expectSelection(on: destination, not: ownKey, in: harness)
    #expect(
      harness.store.withState { AppFeature.focusedSurfaceID(state: $0) } != nil,
      "the surviving task is what the chords act on")
    let stored = await settledStore(harness)
    #expect(stored.activeTasks[Self.directory.id.rawValue] == destination.persistenceKey)
  }

  /// The task picked keeps its layout and a dormant primary, but its only tab
  /// left for a new task before the pick lands. Selected, it would show an
  /// empty layout over the tab the user is looking at: the pick lands on the
  /// task the directory shows now, where the app sent the tab.
  @Test(.dependencies) func aSelectionLandingAfterTheTasksOnlyTabDetachedLandsWhereTheTabWent() async {
    let harness = await makeHarness(seed: Self.listDirectory)
    let (source, sibling, minted) = (LayoutID(task: UUID()), LayoutID(task: UUID()), LayoutID(task: UUID()))
    let leaving = await open(source, in: harness)
    _ = await open(sibling, in: harness)
    let dormant = Self.session("PA")
    await harness.store.send(.terminals(.membersChanged([source: [.session(dormant)]]))).finish()

    harness.manager.handleCommand(.setSelectedLayoutID(sibling))
    await harness.store.send(.repositories(.selectTask(source, directory: Self.directory.id))).finish()
    // Two effects in flight order themselves as they please: here the pick
    // made first lands last, after the app has shown where the tab went.
    let stalePick = harness.recorder.queuedCommands.withValue { queued in
      defer { queued.removeAll() }
      return queued
    }
    #expect(stalePick.contains(.selectLayout(source, forDirectory: Self.directory.id)))
    detach(leaving, from: source, into: minted, in: harness)
    let landed = await harness.events.collect(until: Self.isTransferOutcome)
    guard let completion = landed.last(where: Self.isTransferOutcome) else {
      Issue.record("no transfer outcome in \(landed)")
      return
    }
    #expect(
      completion
        == .tabsTransferred(from: source, into: minted, tabIDs: [TabID(rawValue: leaving)], sourceRemoved: false))
    #expect(harness.terminals.layouts[id: source]?.layout.panes.isEmpty == true, "the source keeps its empty layout")
    #expect(harness.terminals.members[source] == [.session(dormant)])
    // The app shows where the tab went; the stale pick is still ahead of it.
    await harness.store.send(.terminalEvent(completion)).finish()
    #expect(harness.store.withState(\.repositories.selectedTaskID) == minted)
    deliverQueuedCommands(in: harness)
    #expect(harness.manager.selectedLayoutID == minted)

    for command in stalePick { harness.manager.handleCommand(command) }
    let after = await harness.events.collect(until: Self.createsATab)

    #expect(!after.contains(where: Self.createsATab), "no tab created: \(after)")
    #expect(harness.manager.selectedLayoutID == minted)
    #expect(harness.terminals.selectedLayoutID == minted)
    #expect(harness.terminals.selectionOrder.last == minted)
    #expect(harness.terminals.recentLayoutIDs.first == minted)
    #expect(harness.terminals.activeTasks[Self.directory.id] == minted)
    #expect(
      harness.store.withState { AppFeature.focusedSurfaceID(state: $0) } == leaving,
      "the moved tab is what the chords act on")
    let stored = await settledStore(harness)
    #expect(stored.activeTasks[Self.directory.id.rawValue] == minted.persistenceKey)
  }

  /// A pick that names a task already gone when the reducer sees it is no
  /// pick at all: the directory is shown as it is now.
  @Test(.dependencies) func selectingATaskAlreadyRemovedSelectsNothing() async {
    let harness = await makeHarness(seed: Self.listDirectory)
    let (source, destination) = (LayoutID(task: UUID()), LayoutID(task: UUID()))
    _ = await open(source, in: harness)
    _ = await open(destination, in: harness)
    merge(source, into: destination, in: harness)
    _ = await harness.events.collect(until: Self.isTransferOutcome)

    await harness.store.send(.repositories(.selectTask(source, directory: Self.directory.id))).finish()
    deliverQueuedCommands(in: harness)
    let after = await harness.events.collect(until: Self.createsATab)

    #expect(harness.store.withState(\.repositories.selectedTask) == nil)
    #expect(harness.manager.hostIfExists(for: source) == nil)
    #expect(harness.terminals.layouts.map(\.id) == [destination])
    #expect(!after.contains(where: Self.createsATab), "no tab created: \(after)")
  }

  // MARK: - The stored result.

  @Test(.dependencies) func oneWriteCarriesBothRecords() async {
    let harness = await makeHarness()
    let (source, destination) = (LayoutID(task: UUID()), LayoutID(task: UUID()))
    let first = await open(source, in: harness)
    let second = await open(source, in: harness)
    let own = await open(destination, in: harness)
    let (sourcePrimary, destinationPrimary) = (Self.session("PA"), Self.session("PB"))
    await harness.store.send(
      .terminals(.membersChanged([source: [.session(sourcePrimary)], destination: [.session(destinationPrimary)]]))
    ).finish()
    _ = await stored(harness) {
      $0.tasks[source.persistenceKey]?.sessions == [sourcePrimary]
        && $0.tasks[source.persistenceKey]?.layout.allContentIDs.count == 2
        && $0.tasks[destination.persistenceKey]?.sessions == [destinationPrimary]
    }

    // Every write from here on: the one that stored all three tabs is the last so far.
    let baseline = harness.recorder.everyWrite.value.count - 1

    merge(source, into: destination, in: harness)
    let written = await stored(harness) { $0.tasks[source.persistenceKey] == nil }

    #expect(written.tasks.keys.map { $0 } == [destination.persistenceKey])
    let record = written.tasks[destination.persistenceKey]
    #expect(record?.layout.panes.flatMap { $0.tabs.ids.map(\.rawValue) } == [own, first, second])
    #expect(record?.sessions == [destinationPrimary, sourcePrimary])
    #expect(written.mergedTasks == [source.persistenceKey: destination.persistenceKey])
    // No write, this one or any around it, holds a moved tab in neither
    // task or in both.
    await harness.clock.advance(by: .seconds(5))
    await Task.megaYield()
    let writes = harness.recorder.everyWrite.value
    #expect(writes.count > baseline + 1)
    for file in writes[baseline...] {
      for surfaceID in [first, second, own] {
        let holders = file.tasks.values.filter { $0.layout.allContentIDs.contains(ContentID(rawValue: surfaceID)) }
        #expect(holders.count == 1, "\(surfaceID) is in \(holders.count) stored tasks")
      }
    }
  }

  @Test(.dependencies) func detachReleasesTheSessionFromTheStoredSource() async {
    let harness = await makeHarness()
    let (source, minted) = (LayoutID(task: UUID()), LayoutID(task: UUID()))
    _ = await open(source, in: harness)
    let leaving = await open(source, in: harness)
    let (primary, tangent) = (Self.session("PA"), Self.session("TA"))
    await harness.store.send(.terminals(.membersChanged([source: [.session(primary), .session(tangent)]]))).finish()
    _ = await stored(harness) { $0.tasks[source.persistenceKey]?.sessions == [primary, tangent] }

    harness.manager.transferTabs(
      from: source, into: minted, context: DirectoryContext(worktree: Self.directory),
      scope: .tab(TabID(rawValue: leaving), members: [.session(tangent)]))
    let written = await stored(harness) { $0.tasks[minted.persistenceKey] != nil }

    // The one way a stored session leaves a record that stays.
    #expect(written.tasks[source.persistenceKey]?.sessions == [primary])
    #expect(written.tasks[minted.persistenceKey]?.sessions == [tangent])
    #expect(written.tasks[minted.persistenceKey]?.layout.allContentIDs == [ContentID(rawValue: leaving)])
    // The source's later, ordinary saves do not bring it back.
    harness.manager.markLayoutDirty(worktreeID: source)
    await harness.clock.advance(by: .seconds(5))
    await Task.megaYield()
    #expect(harness.recorder.current()?.tasks[source.persistenceKey]?.sessions == [primary])
  }

  @Test(.dependencies) func quitRightAfterMergeStoresNoSource() async throws {
    let harness = await makeHarness()
    let (source, destination) = (LayoutID(task: UUID()), LayoutID(task: UUID()))
    let moved = await open(source, in: harness)
    let own = await open(destination, in: harness)
    _ = await stored(harness) {
      $0.tasks[source.persistenceKey] != nil && $0.tasks[destination.persistenceKey] != nil
    }

    // No suspension between the two: the transfer's own write has not run.
    merge(source, into: destination, in: harness)
    harness.manager.saveAllLayoutSnapshots()

    let file = try #require(harness.recorder.current())
    #expect(file.tasks[source.persistenceKey] == nil, "a stored source would hold the same tabs as the destination")
    #expect(
      file.tasks[destination.persistenceKey]?.layout.allContentIDs == [own, moved].map(ContentID.init(rawValue:)))
    #expect(file.mergedTasks == [source.persistenceKey: destination.persistenceKey])
  }

  @Test(.dependencies) func quitRightAfterDetachReleasesTheSessionFromTheStoredSource() async throws {
    let harness = await makeHarness()
    let (source, minted) = (LayoutID(task: UUID()), LayoutID(task: UUID()))
    let staying = await open(source, in: harness)
    let leaving = await open(source, in: harness)
    let (primary, tangent) = (Self.session("PA"), Self.session("TA"))
    await harness.store.send(.terminals(.membersChanged([source: [.session(primary), .session(tangent)]]))).finish()
    _ = await stored(harness) { $0.tasks[source.persistenceKey]?.sessions == [primary, tangent] }

    // No suspension between the two: the transfer's own write has not run.
    harness.manager.transferTabs(
      from: source, into: minted, context: DirectoryContext(worktree: Self.directory),
      scope: .tab(TabID(rawValue: leaving), members: [.session(tangent)]))
    harness.manager.saveAllLayoutSnapshots()

    let file = try #require(harness.recorder.current())
    #expect(file.tasks[source.persistenceKey]?.sessions == [primary])
    #expect(file.tasks[minted.persistenceKey]?.sessions == [tangent])
    let relaunched = await Self.relaunched(from: file)
    #expect(Set(relaunched.layouts.ids) == [source, minted])
    #expect(relaunched.layouts[id: source]?.layout.allContentIDs == [ContentID(rawValue: staying)])
    #expect(relaunched.layouts[id: minted]?.layout.allContentIDs == [ContentID(rawValue: leaving)])
    #expect(relaunched.members == [source: [.session(primary)], minted: [.session(tangent)]])
  }

  @Test(.dependencies) func quitRightAfterDetachFromATaskNeverOpenedStoresEachTabOnce() async throws {
    let harness = await makeHarness()
    let (source, minted) = (LayoutID(task: UUID()), LayoutID(task: UUID()))
    // Hydrated, never opened: a layout and a record, no host.
    let (paneID, staying, leaving) = (PaneID(), UUID(), UUID())
    let tabs = [staying, leaving].map {
      TabItem(
        id: TabID(rawValue: $0), title: "Tab",
        content: ContentSnapshot(
          id: ContentID(rawValue: $0), state: .terminal(TerminalContentState(workingDirectory: nil))))
    }
    let (primary, tangent) = (Self.session("PA"), Self.session("TA"))
    let record = TaskRecord(
      id: source, directory: TaskRecord.Directory(worktreeID: Self.directory.id),
      layout: PaneLayout(
        tree: SplitTree(view: paneID),
        panes: [Pane(id: paneID, tabs: IdentifiedArray(uniqueElements: tabs), selectedTabID: TabID(rawValue: staying))],
        focusedPaneID: paneID),
      sessions: [primary, tangent], createdAt: Date(timeIntervalSince1970: 1))
    harness.recorder.seed([record])
    let seeded = TaskLayoutsFile(tasks: [source.persistenceKey: record])
    await harness.store.send(.terminals(.storedSessions(.file(seeded)))).finish()
    await harness.store.send(.terminals(.layoutsHydrated(seeded))).finish()

    // No suspension between the two: the transfer's own write has not run.
    harness.manager.transferTabs(
      from: source, into: minted, context: DirectoryContext(worktree: Self.directory),
      scope: .tab(TabID(rawValue: leaving), members: [.session(tangent)]))
    harness.manager.saveAllLayoutSnapshots()

    #expect(harness.manager.hostIfExists(for: source) == nil)
    let file = try #require(harness.recorder.current())
    for surfaceID in [staying, leaving] {
      let holders = file.tasks.values.filter { $0.layout.allContentIDs.contains(ContentID(rawValue: surfaceID)) }
      #expect(holders.count == 1, "\(surfaceID) is in \(holders.count) stored tasks")
    }
    #expect(file.tasks[source.persistenceKey]?.sessions == [primary])
    #expect(file.tasks[minted.persistenceKey]?.sessions == [tangent])
    let relaunched = await Self.relaunched(from: file)
    #expect(Set(relaunched.layouts.ids) == [source, minted], "a colliding tab drops a whole task at hydration")
    #expect(relaunched.layouts[id: source]?.layout.allContentIDs == [ContentID(rawValue: staying)])
    #expect(relaunched.layouts[id: minted]?.layout.allContentIDs == [ContentID(rawValue: leaving)])
    #expect(relaunched.members == [source: [.session(primary)], minted: [.session(tangent)]])
  }

  @Test(.dependencies) func aSessionThatCameBackIsNotReleasedAtQuit() async throws {
    let harness = await makeHarness()
    let (source, minted) = (LayoutID(task: UUID()), LayoutID(task: UUID()))
    _ = await open(source, in: harness)
    let leaving = await open(source, in: harness)
    let (primary, tangent) = (Self.session("PA"), Self.session("TA"))
    await harness.store.send(.terminals(.membersChanged([source: [.session(primary), .session(tangent)]]))).finish()
    _ = await stored(harness) { $0.tasks[source.persistenceKey]?.sessions == [primary, tangent] }

    // Out and straight back, then quit: neither transfer's write has run.
    harness.manager.transferTabs(
      from: source, into: minted, context: DirectoryContext(worktree: Self.directory),
      scope: .tab(TabID(rawValue: leaving), members: [.session(tangent)]))
    merge(minted, into: source, in: harness)
    harness.manager.saveAllLayoutSnapshots()

    let file = try #require(harness.recorder.current())
    #expect(file.tasks.keys.map { $0 } == [source.persistenceKey])
    #expect(file.tasks[source.persistenceKey]?.sessions == [primary, tangent])
  }

  @Test(.dependencies) func aTransferWaitingOnAnEarlierWriteCannotUndoTheQuitSave() async throws {
    let harness = await makeHarness()
    let (source, destination) = (LayoutID(task: UUID()), LayoutID(task: UUID()))
    let moved = await open(source, in: harness)
    let own = await open(destination, in: harness)
    _ = await stored(harness) {
      $0.tasks[source.persistenceKey] != nil && $0.tasks[destination.persistenceKey] != nil
    }
    await harness.clock.advance(by: .seconds(5))
    await drainWrites(harness)

    // An ordinary save of the source, stuck in the store.
    let release = harness.recorder.holdNextWrite()
    let extra = await open(source, in: harness)
    await harness.clock.advance(by: .seconds(1))
    for _ in 0..<10_000 where !harness.recorder.isHolding.value { await Task.yield() }
    guard harness.recorder.isHolding.value else {
      release()
      Issue.record("the earlier save never reached the store")
      return
    }

    // The transfer's write waits behind it, its records already built.
    merge(source, into: destination, in: harness)
    let outcome = await harness.events.collect(until: Self.isTransferOutcome)
    #expect(outcome.contains { if case .tabsTransferred = $0 { true } else { false } })
    // Both tasks change after that: the merged source is created again.
    let again = await open(source, in: harness)
    let later = await open(destination, in: harness)

    // Quit. No suspension: the transfer is still waiting when the save runs.
    release()
    harness.manager.cancelPendingLayoutSaves()
    harness.manager.saveAllLayoutSnapshots()
    await drainWrites(harness)

    let file = try #require(harness.recorder.current())
    #expect(file.tasks[source.persistenceKey]?.layout.allContentIDs == [ContentID(rawValue: again)])
    #expect(
      file.tasks[destination.persistenceKey]?.layout.allContentIDs
        == [own, moved, extra, later].map(ContentID.init(rawValue:)))
    for surfaceID in [moved, extra, own, again, later] {
      let holders = file.tasks.values.filter { $0.layout.allContentIDs.contains(ContentID(rawValue: surfaceID)) }
      #expect(holders.count == 1, "\(surfaceID) is in \(holders.count) stored tasks")
    }
    let relaunched = await Self.relaunched(from: file)
    #expect(Set(relaunched.layouts.ids) == [source, destination])
    #expect(relaunched.layouts[id: source]?.layout.allContentIDs == [ContentID(rawValue: again)])
    #expect(
      relaunched.layouts[id: destination]?.layout.allContentIDs
        == [own, moved, extra, later].map(ContentID.init(rawValue:)))
  }

  @Test(.dependencies) func aRemovalCancelledByQuitIsCarriedByTheQuitSave() async throws {
    let harness = await makeHarness()
    let (gone, kept) = (LayoutID(task: UUID()), LayoutID(task: UUID()))
    let elsewhere = Self.worktree("/tmp/repo/wt-transfer-kept")
    _ = await open(gone, in: harness)
    let staying = await open(kept, on: elsewhere, in: harness)
    _ = await stored(harness) { $0.tasks[gone.persistenceKey] != nil && $0.tasks[kept.persistenceKey] != nil }
    await harness.clock.advance(by: .seconds(5))
    await drainWrites(harness)

    // No suspension between the three: the removal's own write has not run.
    harness.manager.prune(keepingDirectories: [elsewhere.id], archivedDirectories: [Self.directory.id])
    harness.manager.cancelPendingLayoutSaves()
    harness.manager.saveAllLayoutSnapshots()
    await drainWrites(harness)

    let file = try #require(harness.recorder.current())
    #expect(file.tasks.keys.map { $0 } == [kept.persistenceKey])
    #expect(file.tasks[kept.persistenceKey]?.layout.allContentIDs == [ContentID(rawValue: staying)])
  }

  // MARK: - Write order: a later state is never overwritten by an earlier one.

  /// Sticks an ordinary save of `source` in the store, the writer's queue
  /// behind it. Returns nil when the save never got there.
  private func holdASave(of source: LayoutID, in harness: Harness) async -> (@Sendable () -> Void)? {
    let release = harness.recorder.holdNextWrite()
    _ = await open(source, in: harness)
    await harness.clock.advance(by: .seconds(1))
    for _ in 0..<10_000 where !harness.recorder.isHolding.value { await Task.yield() }
    guard harness.recorder.isHolding.value else {
      release()
      Issue.record("the earlier save never reached the store")
      return nil
    }
    return release
  }

  /// Every task with a tab, as the app holds it now.
  private static func live(_ harness: Harness) -> [String: [ContentID]] {
    var tasks: [String: [ContentID]] = [:]
    for layout in harness.terminals.layouts where !layout.layout.allContentIDs.isEmpty {
      tasks[layout.id.persistenceKey] = layout.layout.allContentIDs
    }
    return tasks
  }

  /// The store holds exactly the app's tasks and tabs, and a relaunch reads
  /// them back: no tab lost, none twice, no task lost.
  private func expectStoredMatchesLive(_ harness: Harness, _ note: Comment = "") async {
    let live = Self.live(harness)
    let file = harness.recorder.current() ?? TaskLayoutsFile()
    #expect(file.tasks.mapValues(\.layout.allContentIDs) == live, note)
    let relaunched = await Self.relaunched(from: file)
    var reread: [String: [ContentID]] = [:]
    for layout in relaunched.layouts { reread[layout.id.persistenceKey] = layout.layout.allContentIDs }
    #expect(reread == live, note)
    let everyTab = reread.values.flatMap { $0 }
    #expect(Set(everyTab).count == everyTab.count, note)
  }

  @Test(.dependencies, arguments: [false, true])
  func aSaveMadeAfterATransferIsNotUndoneByIt(quit: Bool) async throws {
    let harness = await makeHarness()
    let (source, destination) = (LayoutID(task: UUID()), LayoutID(task: UUID()))
    _ = await open(source, in: harness)
    _ = await open(destination, in: harness)
    await harness.clock.advance(by: .seconds(5))
    await drainWrites(harness)
    guard let release = await holdASave(of: source, in: harness) else { return }

    // The transfer is written behind the stuck save; the destination then
    // gains a tab, and its debounced save is made before the store moves.
    merge(source, into: destination, in: harness)
    let later = await open(destination, in: harness)
    await harness.clock.advance(by: .seconds(5))
    await Task.megaYield()

    release()
    if quit { harness.manager.saveAllLayoutSnapshots() }
    await drainWrites(harness)

    let file = try #require(harness.recorder.current())
    #expect(file.tasks[destination.persistenceKey]?.layout.allContentIDs.contains(ContentID(rawValue: later)) == true)
    await expectStoredMatchesLive(harness)
  }

  @Test(.dependencies, arguments: [false, true])
  func aSourceCreatedAgainSurvivesTheTransferThatRemovedIt(quit: Bool) async throws {
    let harness = await makeHarness()
    let (source, destination) = (LayoutID(task: UUID()), LayoutID(task: UUID()))
    _ = await open(source, in: harness)
    _ = await open(destination, in: harness)
    await harness.clock.advance(by: .seconds(5))
    await drainWrites(harness)
    guard let release = await holdASave(of: source, in: harness) else { return }

    merge(source, into: destination, in: harness)
    let again = await open(source, in: harness)
    _ = await open(destination, in: harness)
    // Both later saves are made while the earlier one is still stuck.
    await harness.clock.advance(by: .seconds(5))
    await Task.megaYield()

    release()
    if quit {
      harness.manager.cancelPendingLayoutSaves()
      harness.manager.saveAllLayoutSnapshots()
    }
    await drainWrites(harness)

    let file = try #require(harness.recorder.current())
    #expect(file.tasks[source.persistenceKey]?.layout.allContentIDs == [ContentID(rawValue: again)])
    #expect(file.mergedTasks.isEmpty, "a task that exists again forwards nowhere")
    await expectStoredMatchesLive(harness)
  }

  @Test(.dependencies) func aQuitBeforeTheLaterDebouncesFireStoresWhatIsThereNow() async throws {
    let harness = await makeHarness()
    let (source, destination) = (LayoutID(task: UUID()), LayoutID(task: UUID()))
    _ = await open(source, in: harness)
    _ = await open(destination, in: harness)
    await harness.clock.advance(by: .seconds(5))
    await drainWrites(harness)
    guard let release = await holdASave(of: source, in: harness) else { return }

    merge(source, into: destination, in: harness)
    _ = await open(source, in: harness)
    _ = await open(destination, in: harness)

    // No suspension after the release: nothing but the quit save follows.
    release()
    harness.manager.saveAllLayoutSnapshots()
    await expectStoredMatchesLive(harness, "right after the quit save")

    // Nothing left over lands on top of it.
    await harness.clock.advance(by: .seconds(5))
    await drainWrites(harness)
    await expectStoredMatchesLive(harness, "after everything drained")
  }

  /// Seeded walks over opening tabs, merging, debounces firing, a write
  /// sticking in the store and coming loose, and the quit save.
  @Test(.dependencies, arguments: [1, 2, 3, 4, 5, 6] as [UInt64])
  func noInterleavingOfWritesLosesATab(seed: UInt64) async throws {
    let harness = await makeHarness()
    let tasks = (0..<3).map { _ in LayoutID(task: UUID()) }
    var state = seed &* 0x9E37_79B9_7F4A_7C15 | 1
    func next(_ bound: Int) -> Int {
      state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
      return Int((state >> 33) % UInt64(bound))
    }
    var release: (@Sendable () -> Void)?
    for step in 0..<30 {
      switch next(6) {
      case 0, 1:
        _ = await open(tasks[next(3)], in: harness)
      case 2:
        let (from, into) = (tasks[next(3)], tasks[next(3)])
        let live = Self.live(harness)
        guard from != into, live[from.persistenceKey] != nil, live[into.persistenceKey] != nil else { continue }
        merge(from, into: into, in: harness)
        let outcome = await harness.events.collect(until: Self.isTransferOutcome)
        #expect(outcome.contains { if case .tabsTransferred = $0 { true } else { false } }, "step \(step)")
      case 3:
        await harness.clock.advance(by: .seconds(1))
        await Task.megaYield()
      case 4:
        if let held = release {
          held()
          release = nil
        } else {
          release = harness.recorder.holdNextWrite()
        }
      default:
        // The quit save waits for the writer, so the store has to move.
        release?()
        release = nil
        harness.manager.cancelPendingLayoutSaves()
        harness.manager.saveAllLayoutSnapshots()
        await expectStoredMatchesLive(harness, "seed \(seed), quit save at step \(step)")
      }
    }
    release?()
    await harness.clock.advance(by: .seconds(5))
    await drainWrites(harness)
    await expectStoredMatchesLive(harness, "seed \(seed), drained")
  }

  /// Lets every queued write task reach the writer and the writer finish it.
  private func drainWrites(_ harness: Harness) async {
    for _ in 0..<5 {
      await Task.megaYield()
      await harness.manager.layoutsWriter.flush(records: [:])
    }
    await Task.megaYield()
  }

  /// A fresh state hydrated from `file`, as a relaunch reads it.
  private static func relaunched(from file: TaskLayoutsFile) async -> TerminalsFeature.State {
    let store = Store(initialState: TerminalsFeature.State()) {
      TerminalsFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.continuousClock = TestClock()
      $0.contentRuntime = ContentRuntime()
      $0[ContentSessionKiller.self] = ContentSessionKiller(kill: { _, _ in })
    }
    await store.send(.storedSessions(.file(file))).finish()
    await store.send(.layoutsHydrated(file)).finish()
    return store.withState { $0 }
  }

  @Test(.dependencies) func aPendingSaveOfTheSourceCannotResurrectIt() async throws {
    let harness = await makeHarness()
    let (source, destination) = (LayoutID(task: UUID()), LayoutID(task: UUID()))
    _ = await open(source, in: harness)
    _ = await open(destination, in: harness)
    _ = await stored(harness) {
      $0.tasks[source.persistenceKey] != nil && $0.tasks[destination.persistenceKey] != nil
    }
    // A debounced save of the source is waiting when the merge runs.
    harness.manager.markLayoutDirty(worktreeID: source)

    merge(source, into: destination, in: harness)
    _ = await stored(harness) { $0.tasks[source.persistenceKey] == nil }
    await harness.clock.advance(by: .seconds(5))
    // A later write through the same writer: whatever was queued is behind it.
    harness.manager.handleCommand(.setSelectedLayoutID(destination))
    harness.manager.handleActiveTaskChanged(directoryID: Self.directory.id)
    _ = await harness.recorder.nextWrite { $0.activeTasks[Self.directory.id.rawValue] == destination.persistenceKey }

    #expect(try #require(harness.recorder.current()).tasks.keys.map { $0 } == [destination.persistenceKey])
  }

  // MARK: - Refusals.

  @Test(.dependencies) func refusalChangesNothing() async throws {
    let harness = await makeHarness()
    let (source, destination) = (LayoutID(task: UUID()), LayoutID(task: UUID()))
    let tab = await open(source, in: harness)
    // The destination is stored but was never opened: it has no host.
    let record = TaskRecord(
      id: destination, directory: TaskRecord.Directory(worktreeID: Self.directory.id),
      createdAt: Date(timeIntervalSince1970: 1))
    await harness.store.send(
      .terminals(.layoutsHydrated(TaskLayoutsFile(tasks: [destination.persistenceKey: record])))
    ).finish()
    _ = await stored(harness) { $0.tasks[source.persistenceKey] != nil }
    let before = harness.terminals
    let writes = harness.recorder.everyWrite.value.count

    harness.manager.transferTabs(
      from: source, into: destination, context: DirectoryContext(worktree: Self.directory),
      scope: .tab(TabID(rawValue: tab), members: []))
    let events = await harness.events.collect(until: Self.isTransferOutcome)

    #expect(
      events.filter(Self.isTransferOutcome)
        == [.tabsTransferFailed(from: source, into: destination, reason: .destinationExists)])
    #expect(harness.terminals == before)
    #expect(harness.manager.hostIfExists(for: destination) == nil, "a refusal creates no host")
    await harness.clock.advance(by: .seconds(5))
    await Task.megaYield()
    #expect(harness.recorder.everyWrite.value.count == writes)
  }

  @Test(.dependencies) func runningScriptRefuses() async throws {
    let harness = await makeHarness()
    let (source, destination) = (LayoutID(task: UUID()), LayoutID(task: UUID()))
    let tab = await open(source, in: harness)
    _ = await open(destination, in: harness)
    try #require(harness.manager.hostIfExists(for: source))
      .trackBlockingScript(kind: .archive, tabID: TabID(rawValue: tab), launchDirectory: nil)

    merge(source, into: destination, in: harness)
    let events = await harness.events.collect(until: Self.isTransferOutcome)

    #expect(
      events.filter(Self.isTransferOutcome)
        == [.tabsTransferFailed(from: source, into: destination, reason: .scriptRunning)])
    #expect(!events.contains(where: Self.reportsAClose), "the script is not reported cancelled")
    #expect(harness.tabIDs(source) == [tab])
    #expect(harness.manager.hostIfExists(for: source)?.blockingScriptKind(for: TabID(rawValue: tab)) == .archive)
  }

  @Test(.dependencies) func quittingRefuses() async {
    let harness = await makeHarness()
    let (source, destination) = (LayoutID(task: UUID()), LayoutID(task: UUID()))
    let tab = await open(source, in: harness)
    _ = await open(destination, in: harness)
    harness.manager.beginEndingAllSessions()

    merge(source, into: destination, in: harness)
    let events = await harness.events.collect(until: Self.isTransferOutcome)

    #expect(
      events.filter(Self.isTransferOutcome) == [.tabsTransferFailed(from: source, into: destination, reason: .quitting)]
    )
    #expect(harness.tabIDs(source) == [tab])
  }

  @Test(.dependencies) func mergeNamingAnotherDirectoryThanTheDestinationsIsRefused() async throws {
    let harness = await makeHarness()
    let (sourceDirectory, destinationDirectory) = (Self.worktree("/tmp/repo/wt-x"), Self.worktree("/tmp/repo/wt-y"))
    let (source, destination) = (LayoutID(task: UUID()), LayoutID(task: UUID()))
    let moved = await open(source, on: sourceDirectory, in: harness)
    let own = await open(destination, on: destinationDirectory, in: harness)
    _ = await stored(harness) {
      $0.tasks[source.persistenceKey] != nil && $0.tasks[destination.persistenceKey] != nil
    }
    let before = harness.terminals
    let writes = harness.recorder.everyWrite.value.count

    // The caller says the source's directory; the destination lives elsewhere.
    merge(source, into: destination, on: sourceDirectory, in: harness)
    let events = await harness.events.collect(until: Self.isTransferOutcome)

    #expect(
      events.filter(Self.isTransferOutcome)
        == [.tabsTransferFailed(from: source, into: destination, reason: .destinationMismatch)])
    #expect(harness.terminals == before)
    #expect(harness.tabIDs(source) == [moved])
    #expect(harness.tabIDs(destination) == [own])
    #expect(harness.manager.hostIfExists(for: destination)?.worktreeID == destinationDirectory.id)
    #expect(harness.recorder.localKills.value.isEmpty)
    await harness.clock.advance(by: .seconds(5))
    await Task.megaYield()
    #expect(harness.recorder.everyWrite.value.count == writes)
  }

  @Test(.dependencies) func mergeIntoARemoteTaskIsRefusedWhateverTheCallerSays() async throws {
    let harness = await makeHarness()
    let remote = RemoteHost(alias: "build-box")
    let (source, destination) = (LayoutID(task: UUID()), LayoutID(task: UUID()))
    let tab = await open(source, in: harness)
    // The destination is stored on another machine and was never opened.
    let record = TaskRecord(
      id: destination, directory: TaskRecord.Directory(worktreeID: Self.directory.id, host: remote),
      createdAt: Date(timeIntervalSince1970: 1))
    await harness.store.send(
      .terminals(.layoutsHydrated(TaskLayoutsFile(tasks: [destination.persistenceKey: record])))
    ).finish()
    _ = await stored(harness) { $0.tasks[source.persistenceKey] != nil }
    let before = harness.terminals
    let writes = harness.recorder.everyWrite.value.count

    // A local context would create a host that disagrees with the stored task.
    merge(source, into: destination, in: harness)
    var events = await harness.events.collect(until: Self.isTransferOutcome)
    #expect(
      events.filter(Self.isTransferOutcome)
        == [.tabsTransferFailed(from: source, into: destination, reason: .differentMachine)])

    // A remote context matches the task, but the source is local.
    merge(
      source, into: destination, on: RepositoriesFeature.remoteMainWorktree(host: remote, remotePath: "/srv/repo"),
      in: harness)
    events = await harness.events.collect(until: Self.isTransferOutcome)
    #expect(
      events.filter(Self.isTransferOutcome)
        == [.tabsTransferFailed(from: source, into: destination, reason: .differentMachine)])

    #expect(harness.terminals == before)
    #expect(harness.tabIDs(source) == [tab])
    #expect(harness.manager.hostIfExists(for: destination) == nil, "a refusal creates no host")
    #expect(harness.recorder.localKills.value.isEmpty)
    #expect(harness.recorder.remoteKills.value.isEmpty)
    await harness.clock.advance(by: .seconds(5))
    await Task.megaYield()
    #expect(harness.recorder.everyWrite.value.count == writes)
  }

  // MARK: - The active-task hint.

  @Test(.dependencies) func quitSaveStoresTheSelectionWhoseHintHasNotLanded() async throws {
    let harness = await makeHarness()
    let (source, destination) = (LayoutID(task: UUID()), LayoutID(task: UUID()))
    _ = await open(source, in: harness)
    _ = await open(destination, in: harness)
    harness.manager.handleCommand(.setSelectedLayoutID(source))
    _ = await harness.recorder.nextWrite { $0.activeTasks[Self.directory.id.rawValue] == source.persistenceKey }

    // No suspension between the two: the selection's hint effect has not run.
    harness.manager.handleCommand(.setSelectedLayoutID(destination))
    harness.manager.saveAllLayoutSnapshots()

    let file = try #require(harness.recorder.current())
    #expect(file.activeTasks[Self.directory.id.rawValue] == destination.persistenceKey)
    await Task.megaYield()
    #expect(
      try #require(harness.recorder.current()).activeTasks[Self.directory.id.rawValue] == destination.persistenceKey)
  }

  @Test(.dependencies) func aHintLandingLateStoresTheCurrentSelection() async throws {
    let harness = await makeHarness()
    let (source, destination) = (LayoutID(task: UUID()), LayoutID(task: UUID()))
    _ = await open(source, in: harness)
    _ = await open(destination, in: harness)

    // Two selections in one turn: whichever hint lands last must store the second.
    harness.manager.handleCommand(.setSelectedLayoutID(source))
    harness.manager.handleCommand(.setSelectedLayoutID(destination))
    _ = await harness.recorder.nextWrite { $0.activeTasks[Self.directory.id.rawValue] == destination.persistenceKey }
    for _ in 0..<5 { await Task.megaYield() }

    #expect(
      try #require(harness.recorder.current()).activeTasks[Self.directory.id.rawValue] == destination.persistenceKey)
    #expect(harness.terminals.activeTasks == [Self.directory.id: destination])
  }

  // MARK: - What follows the tab.

  @Test(.dependencies) func pruneAfterMergeFollowsTheDestinationDirectory() async {
    let harness = await makeHarness()
    let (sourceDirectory, destinationDirectory) = (Self.worktree("/tmp/repo/wt-x"), Self.worktree("/tmp/repo/wt-y"))
    let (source, destination) = (LayoutID(task: UUID()), LayoutID(task: UUID()))
    let moved = await open(source, on: sourceDirectory, in: harness)
    let own = await open(destination, on: destinationDirectory, in: harness)
    merge(source, into: destination, on: destinationDirectory, in: harness)
    _ = await harness.events.collect(until: Self.isTransferOutcome)

    // The directory the tab came from goes: the tab is another directory's now.
    harness.manager.prune(keepingDirectories: [destinationDirectory.id], archivedDirectories: [sourceDirectory.id])
    harness.manager.removeLayouts(forDirectory: sourceDirectory.id, remoteHost: nil)
    await Task.megaYield()
    #expect(harness.recorder.localKills.value.isEmpty)
    #expect(harness.tabIDs(destination) == [own, moved])

    harness.manager.removeLayouts(forDirectory: destinationDirectory.id, remoteHost: nil)
    for _ in 0..<50 where harness.recorder.localKills.value.count < 2 { await Task.megaYield() }
    #expect(Set(harness.recorder.localKills.value) == Set([own, moved].map(ZmxSessionID.make(surfaceID:))))
  }

  @Test(.dependencies) func selectionMovesToTheDestination() async {
    let harness = await makeHarness()
    let (source, destination) = (LayoutID(task: UUID()), LayoutID(task: UUID()))
    _ = await open(source, in: harness)
    _ = await open(destination, in: harness)
    harness.manager.handleCommand(.setSelectedLayoutID(source))

    merge(source, into: destination, in: harness)
    _ = await harness.events.collect(until: Self.isTransferOutcome)

    #expect(harness.manager.selectedLayoutID == destination)
    #expect(harness.terminals.selectedLayoutID == destination)
  }

  @Test(.dependencies) func aMergedTaskNeverOpenedMovesItsTabsAndRecord() async {
    let harness = await makeHarness()
    let (source, destination) = (LayoutID(task: UUID()), LayoutID(task: UUID()))
    let own = await open(destination, in: harness)
    // Hydrated, never opened: a layout and a record, no host.
    let (paneID, dormant) = (PaneID(), UUID())
    let layout = PaneLayout(
      tree: SplitTree(view: paneID),
      panes: [
        Pane(
          id: paneID,
          tabs: [
            TabItem(
              id: TabID(rawValue: dormant), title: "Tab",
              content: ContentSnapshot(
                id: ContentID(rawValue: dormant), state: .terminal(TerminalContentState(workingDirectory: nil))))
          ], selectedTabID: TabID(rawValue: dormant))
      ], focusedPaneID: paneID)
    let record = TaskRecord(
      id: source, directory: TaskRecord.Directory(worktreeID: Self.directory.id), layout: layout,
      sessions: [Self.session("PA")], createdAt: Date(timeIntervalSince1970: 1))
    harness.recorder.seed([record])
    await harness.store.send(
      .terminals(.layoutsHydrated(TaskLayoutsFile(tasks: [source.persistenceKey: record])))
    ).finish()

    merge(source, into: destination, in: harness)
    let events = await harness.events.collect(until: Self.isTransferOutcome)
    let written = await stored(harness) { $0.tasks[source.persistenceKey] == nil }

    #expect(!events.contains(where: Self.reportsAClose))
    #expect(harness.manager.hostIfExists(for: source) == nil, "the source's host is never created to move it")
    #expect(harness.tabIDs(destination) == [own, dormant])
    #expect(written.tasks[destination.persistenceKey]?.sessions == [Self.session("PA")])
    #expect(harness.recorder.localKills.value.isEmpty)
    // The baseline holds the arrival: its close is seen and kills it once.
    await harness.store.send(
      .terminals(.layouts(.element(id: destination, action: .closeTab(id: TabID(rawValue: dormant)))))
    ).finish()
    let closing = await harness.events.collect { if case .surfacesClosed = $0 { true } else { false } }
    #expect(closing.contains(.surfacesClosed(layoutID: destination, [dormant])))
  }

  // MARK: - A new task's first tab is decided when the launch lands.

  enum DirectoryChange: CaseIterable {
    case archived, deleting, removed
  }

  /// The roster changes after the launch was accepted, before it lands.
  private func change(_ change: DirectoryChange, in harness: Harness) async {
    let directory = Self.directory
    switch change {
    case .archived:
      let repoID = RepositoryID(directory.repositoryRootURL.path)
      harness.store.withState { $0.repositories.$sidebar }.withLock { sidebar in
        sidebar.sections[repoID] = .init(buckets: [.archived: .init(items: [directory.id: .init()])])
      }
      #expect(harness.store.withState { $0.repositories.isWorktreeArchived(directory.id) })
    case .deleting:
      await harness.store.send(
        .repositories(.sidebarItems(.element(id: directory.id, action: .lifecycleChanged(.deleting))))
      ).finish()
      #expect(harness.store.withState { $0.repositories.sidebarItems[id: directory.id]?.lifecycle } == .deleting)
    case .removed:
      await harness.store.send(
        .repositories(.repositoriesLoaded([], failures: [], roots: [], animated: false))
      ).finish()
      #expect(harness.store.withState { $0.repositories.worktree(for: directory.id) } == nil)
    }
  }

  private static func isTaskLaunch(_ command: TerminalClient.Command) -> Bool {
    if case .createTaskTab = command { return true }
    return false
  }

  /// The picker accepted a live directory; by the time its first tab lands
  /// the directory is archived, winding down or gone from the roster. The
  /// launch carried the directory's identity only, and the manager decides
  /// now: no host, no layout, no tab, nothing selected, nothing stored.
  @Test(.dependencies, arguments: DirectoryChange.allCases, [NewTaskKind.agent, .shell])
  func aLaunchLandingAfterItsDirectoryChangedCreatesNothing(change: DirectoryChange, kind: NewTaskKind) async {
    let harness = await makeHarness { state in
      Self.listDirectory(&state)
      state.repositories.reconcileSidebarForTesting()
    }
    await harness.store.send(.newTask(inDirectory: Self.directory.id, kind: kind)).finish()
    let queued = harness.recorder.queuedCommands.value
    #expect(queued.count(where: Self.isTaskLaunch) == 1, "the launch is in flight: \(queued)")
    guard case .createTaskTab(let minted, let source, let input, _)? = queued.first(where: Self.isTaskLaunch)
    else { return }
    #expect(source == .roster(Self.directory.id))
    #expect(input == (kind == .agent ? "pi" : nil))

    await self.change(change, in: harness)
    deliverQueuedCommands(in: harness)
    let after = await harness.events.collect(until: Self.createsATab)

    #expect(harness.manager.hostIfExists(for: minted) == nil, "no host for a task on a dead directory")
    #expect(harness.terminals.layouts[id: minted] == nil, "no layout attached")
    #expect(!after.contains(where: Self.createsATab), "no tab created: \(after)")
    #expect(harness.manager.selectedLayoutID != minted)
    #expect(harness.store.withState(\.repositories.selectedTaskID) != minted)
    #expect(harness.store.withState(\.terminals.selectedLayoutID) != minted)
    let stored = await settledStore(harness)
    #expect(stored.tasks[minted.persistenceKey] == nil, "nothing persisted for the task")
    #expect(stored.activeTasks[Self.directory.id.rawValue] != minted.persistenceKey)
  }

  /// A roster launch carries the row's identity, never "the directory":
  /// when its repository leaves the roster but a task on that directory
  /// survives, open or stored, the orphan does not stand in for the row.
  /// Nothing is created, selected or persisted.
  @Test(.dependencies, arguments: [true, false], [NewTaskKind.agent, .shell])
  func aRosterLaunchLandingAfterItsRepositoryLeftCreatesNothingDespiteAnOrphanTask(liveOrphan: Bool, kind: NewTaskKind)
    async
  {
    let harness = await makeHarness { state in
      Self.listDirectory(&state)
      state.repositories.reconcileSidebarForTesting()
    }
    let orphan = LayoutID(task: UUID())
    if liveOrphan {
      _ = await open(orphan, in: harness)
    } else {
      await seedStoredTask(orphan, in: harness)
    }
    await harness.store.send(.repositories(.selectTask(orphan, directory: Self.directory.id))).finish()
    await harness.store.send(.newTask(inDirectory: Self.directory.id, kind: kind)).finish()
    guard
      case .createTaskTab(let minted, let source, _, _)? = harness.recorder.queuedCommands.value.first(
        where: Self.isTaskLaunch)
    else {
      Issue.record("no launch queued")
      return
    }
    #expect(source == .roster(Self.directory.id))

    await change(.removed, in: harness)
    #expect(harness.store.withState { AppFeature.hasTask(orphan, state: $0) }, "the orphan task survives the removal")
    // The removal itself may move the selection; the delivery must not.
    let selectedBefore = (
      harness.manager.selectedLayoutID, harness.store.withState(\.repositories.selectedTaskID),
      harness.store.withState(\.terminals.selectedLayoutID)
    )
    deliverQueuedCommands(in: harness)
    let after = await harness.events.collect(until: Self.createsATab)

    #expect(harness.manager.hostIfExists(for: minted) == nil, "no host for a row the roster no longer lists")
    #expect(harness.terminals.layouts[id: minted] == nil)
    #expect(!after.contains(where: Self.createsATab), "no tab created: \(after)")
    #expect(harness.manager.selectedLayoutID == selectedBefore.0)
    #expect(harness.store.withState(\.repositories.selectedTaskID) == selectedBefore.1)
    #expect(harness.store.withState(\.terminals.selectedLayoutID) == selectedBefore.2)
    let stored = await settledStore(harness)
    #expect(stored.tasks[minted.persistenceKey] == nil, "nothing persisted for the task")
    #expect(stored.activeTasks[Self.directory.id.rawValue] != minted.persistenceKey)
  }

  /// Cmd-N on a task carries the task's identity: its directory is re-read
  /// when the launch lands. An orphan task (its repository gone from the
  /// roster) still gets its sibling; once the task itself is gone, nothing
  /// is created.
  @Test(.dependencies, arguments: [NewTaskKind.agent, .shell])
  func aTaskLaunchLandsWhileItsTaskExistsAndNotAfter(kind: NewTaskKind) async {
    let harness = await makeHarness { state in
      Self.listDirectory(&state)
      state.repositories.reconcileSidebarForTesting()
    }
    let orphan = LayoutID(task: UUID())
    let own = await open(orphan, in: harness)
    await change(.removed, in: harness)
    #expect(harness.store.withState { AppFeature.launchDirectory(for: .task(orphan), state: $0) } != nil)
    let input = kind == .agent ? "pi" : nil

    let sibling = LayoutID(task: UUID())
    harness.manager.handleCommand(.createTaskTab(sibling, source: .task(orphan), input: input, focusing: true))
    let created = await harness.events.collect(until: Self.createsATab)
    #expect(created.count(where: Self.createsATab) == 1, "one tab for the orphan's sibling: \(created)")
    #expect(harness.tabIDs(sibling).count == 1)
    #expect(harness.terminals.directories[sibling]?.worktreeID == Self.directory.id)

    // The task goes; a launch that named it lands after.
    await harness.store.send(
      .terminals(.layouts(.element(id: orphan, action: .closeTab(id: TabID(rawValue: own)))))
    ).finish()
    for _ in 0..<50 where harness.store.withState({ AppFeature.hasTask(orphan, state: $0) }) { await Task.megaYield() }
    #expect(!harness.store.withState { AppFeature.hasTask(orphan, state: $0) }, "the orphan task is gone")
    let late = LayoutID(task: UUID())
    harness.manager.handleCommand(.createTaskTab(late, source: .task(orphan), input: input, focusing: true))
    let after = await harness.events.collect(until: Self.createsATab)
    #expect(harness.manager.hostIfExists(for: late) == nil, "no host for a sibling of a task that is gone")
    #expect(harness.terminals.layouts[id: late] == nil)
    #expect(!after.contains(where: Self.createsATab), "no tab created: \(after)")
    let stored = await settledStore(harness)
    #expect(stored.tasks[late.persistenceKey] == nil)
  }

  enum TaskRemoval: CaseIterable {
    case closed, merged
  }

  /// A roster worktree on a directory that exists on disk, as a path route
  /// would require of it.
  private func onDiskWorktree(named name: String) throws -> Worktree {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("supacode-tests-\(UUID().uuidString)-\(name)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return Self.worktree(url.standardizedFileURL.path(percentEncoded: false))
  }

  private static func listDirectory(_ directory: Worktree, in state: inout AppFeature.State) {
    state.repositories.repositories = [
      Repository(
        id: RepositoryID(directory.repositoryRootURL.path), rootURL: directory.repositoryRootURL, name: "repo",
        worktrees: [directory])
    ]
    state.repositories.isInitialLoadComplete = true
  }

  private func removeTask(_ task: LayoutID, _ removal: TaskRemoval, ownTab: UUID, in harness: Harness) async {
    switch removal {
    case .closed:
      await harness.store.send(
        .terminals(.layouts(.element(id: task, action: .closeTab(id: TabID(rawValue: ownTab)))))
      ).finish()
    case .merged:
      let destination = LayoutID(task: UUID())
      _ = await open(destination, in: harness)
      merge(task, into: destination, in: harness)
      _ = await harness.events.collect(until: Self.isTransferOutcome)
    }
    for _ in 0..<50 where harness.store.withState({ AppFeature.hasTask(task, state: $0) }) { await Task.megaYield() }
    #expect(!harness.store.withState { AppFeature.hasTask(task, state: $0) }, "the task is gone (\(removal))")
  }

  /// Cmd-N on a local task, through the app: the launch names the task,
  /// not its directory. The task is closed or merged away before the launch
  /// lands; its directory is still a live roster row, and still nothing is
  /// created, selected or stored.
  @Test(.dependencies, arguments: TaskRemoval.allCases)
  func aLocalCmdNLandingAfterItsTaskWentCreatesNothing(removal: TaskRemoval) async throws {
    let directory = try onDiskWorktree(named: "cmd-n-\(removal)")
    let harness = await makeHarness { state in
      Self.listDirectory(directory, in: &state)
      state.repositories.reconcileSidebarForTesting()
    }
    let task = LayoutID(task: UUID())
    let own = await open(task, on: directory, in: harness)
    await harness.store.send(.repositories(.selectTask(task, directory: directory.id))).finish()
    #expect(harness.store.withState { AppFeature.currentTaskID(state: $0) } == task)

    await harness.store.send(.newSession).finish()
    let queued = harness.recorder.queuedCommands.value
    #expect(queued.count(where: Self.isTaskLaunch) == 1, "the launch is in flight: \(queued)")
    guard case .createTaskTab(let minted, let source, let input, _)? = queued.first(where: Self.isTaskLaunch)
    else { return }
    #expect(source == .task(task), "a local Cmd-N carries the task, as a remote one does")
    #expect(input == "pi")

    await removeTask(task, removal, ownTab: own, in: harness)
    #expect(
      harness.store.withState { AppFeature.rosterDirectory(directory.id, state: $0) } != nil,
      "the directory itself stays live; only the task is gone")
    deliverQueuedCommands(in: harness)
    let after = await harness.events.collect(until: Self.createsATab)

    #expect(harness.manager.hostIfExists(for: minted) == nil, "no host for a sibling of a task that is gone")
    #expect(harness.terminals.layouts[id: minted] == nil)
    #expect(!after.contains(where: Self.createsATab), "no tab created: \(after)")
    // The removal itself lands the directory on its own layout; the
    // delivery must not select the task it did not create.
    #expect(harness.manager.selectedLayoutID != minted)
    #expect(harness.store.withState(\.repositories.selectedTaskID) != minted)
    #expect(harness.store.withState(\.terminals.selectedLayoutID) != minted)
    let stored = await settledStore(harness)
    #expect(stored.tasks[minted.persistenceKey] == nil, "nothing persisted for the task")
    #expect(stored.activeTasks[directory.id.rawValue] != minted.persistenceKey)
  }

  /// Cmd-N on a local orphan task (its directory in no roster entry), through
  /// the app: the sibling starts on the task's recorded directory and the
  /// directory is not registered as a folder to get there.
  @Test(.dependencies) func aLocalOrphanCmdNStartsASiblingWithoutRegisteringItsDirectory() async throws {
    let directory = try onDiskWorktree(named: "cmd-n-orphan")
    let harness = await makeHarness { state in state.repositories.isInitialLoadComplete = true }
    let orphan = LayoutID(task: UUID())
    _ = await open(orphan, on: directory, in: harness)
    await harness.store.send(.repositories(.selectTask(orphan, directory: directory.id))).finish()
    #expect(harness.store.withState { AppFeature.currentTaskID(state: $0) } == orphan)
    #expect(harness.store.withState { $0.repositories.worktree(for: directory.id) } == nil)

    await harness.store.send(.newSession).finish()
    let queued = harness.recorder.queuedCommands.value
    #expect(queued.count(where: Self.isTaskLaunch) == 1, "the launch is in flight: \(queued)")
    guard case .createTaskTab(let minted, let source, _, _)? = queued.first(where: Self.isTaskLaunch)
    else { return }
    #expect(source == .task(orphan))
    #expect(
      harness.store.withState { $0.repositories.worktree(for: directory.id) } == nil,
      "the orphan's directory is not registered to start a sibling")
    #expect(harness.store.withState(\.pendingSessionLaunch) == nil, "the launch went out, not into registration")

    deliverQueuedCommands(in: harness)
    let created = await harness.events.collect(until: Self.createsATab)
    #expect(created.count(where: Self.createsATab) == 1, "one tab for the orphan's sibling: \(created)")
    #expect(harness.tabIDs(minted).count == 1)
    #expect(harness.terminals.directories[minted]?.worktreeID == directory.id)
    #expect(harness.store.withState { $0.repositories.worktree(for: directory.id) } == nil)
  }

  /// A record for `layoutID` on the fixture directory, never opened: stored,
  /// no layout, no host.
  private func seedStoredTask(_ layoutID: LayoutID, in harness: Harness) async {
    let (paneID, dormant) = (PaneID(), UUID())
    let layout = PaneLayout(
      tree: SplitTree(view: paneID),
      panes: [
        Pane(
          id: paneID,
          tabs: [
            TabItem(
              id: TabID(rawValue: dormant), title: "Tab",
              content: ContentSnapshot(
                id: ContentID(rawValue: dormant), state: .terminal(TerminalContentState(workingDirectory: nil))))
          ], selectedTabID: TabID(rawValue: dormant))
      ], focusedPaneID: paneID)
    let record = TaskRecord(
      id: layoutID, directory: TaskRecord.Directory(worktreeID: Self.directory.id), layout: layout,
      sessions: [Self.session("PA")], createdAt: Date(timeIntervalSince1970: 1))
    harness.recorder.seed([record])
    await harness.store.send(
      .terminals(.layoutsHydrated(TaskLayoutsFile(tasks: [layoutID.persistenceKey: record])))
    ).finish()
  }

  /// The same launch on a directory still live: one tab, in the minted
  /// task, from the roster's current directory.
  @Test(.dependencies, arguments: [NewTaskKind.agent, .shell])
  func aLaunchLandingOnALiveDirectoryCreatesItsOneTab(kind: NewTaskKind) async {
    let harness = await makeHarness { state in
      Self.listDirectory(&state)
      state.repositories.reconcileSidebarForTesting()
    }
    await harness.store.send(.newTask(inDirectory: Self.directory.id, kind: kind)).finish()
    guard
      case .createTaskTab(let minted, .roster, _, _)? = harness.recorder.queuedCommands.value.first(
        where: Self.isTaskLaunch)
    else {
      Issue.record("no launch queued")
      return
    }

    deliverQueuedCommands(in: harness)
    let after = await harness.events.collect(until: Self.createsATab)

    #expect(after.count(where: Self.createsATab) == 1, "exactly one tab: \(after)")
    #expect(harness.tabIDs(minted).count == 1)
    #expect(harness.manager.hostIfExists(for: minted) != nil)
    #expect(harness.terminals.directories[minted]?.worktreeID == Self.directory.id)
  }

  // MARK: - Live surfaces.

  @Test(.dependencies) func liveSurfaceIsRewiredToTheDestination() async throws {
    let ghostty = GhosttyRuntime(surfaceTeardownQueue: TeardownTestSupport.queue(probe: TeardownProbeSpy()))
    let harness = await makeHarness(liveSurfaces: ghostty)
    let (source, destination) = (LayoutID(task: UUID()), LayoutID(task: UUID()))
    let moved = await open(source, in: harness)
    let own = await open(destination, in: harness)
    defer {
      for surfaceID in [moved, own] {
        ContentRuntime.liveValue.remove(ContentID(rawValue: surfaceID), tombstone: false)
      }
    }
    let content = ContentRuntime.liveValue.content(for: ContentID(rawValue: moved))
    let view = try #require(content?.renderer as? GhosttySurfaceView)

    merge(source, into: destination, in: harness)
    _ = await harness.events.collect(until: Self.isTransferOutcome)

    // Same content, same surface: only who it reports to changed.
    #expect(ContentRuntime.liveValue.content(for: ContentID(rawValue: moved)) === content)
    #expect(ContentRuntime.liveValue.renderer(for: ContentID(rawValue: moved)) === view)
    #expect(!ContentRuntime.liveValue.pendingKill.contains(ContentID(rawValue: moved)))
    _ = view.bridge.onCommandPaletteToggle?()
    let events = await harness.events.collect { if case .commandPaletteToggleRequested = $0 { true } else { false } }
    #expect(
      events.last == .commandPaletteToggleRequested(layoutID: destination, worktreeID: Self.directory.id),
      "a surface still wired to the task it left is deaf")
  }

  @Test(.dependencies) func unexpectedCloseProbeFollowsTheMove() async throws {
    let ghostty = GhosttyRuntime(surfaceTeardownQueue: TeardownTestSupport.queue(probe: TeardownProbeSpy()))
    let (gate, release) = AsyncStream<Void>.makeStream()
    let harness = await makeHarness(liveSurfaces: ghostty) {
      for await _ in gate { break }
      // The session is gone.
      return []
    }
    let (source, destination) = (LayoutID(task: UUID()), LayoutID(task: UUID()))
    let moved = await open(source, in: harness)
    let own = await open(destination, in: harness)
    defer {
      for surfaceID in [moved, own] {
        ContentRuntime.liveValue.remove(ContentID(rawValue: surfaceID), tombstone: false)
      }
    }
    let view = try #require(ContentRuntime.liveValue.renderer(for: ContentID(rawValue: moved)) as? GhosttySurfaceView)

    // The probe is in flight when the tab moves.
    harness.manager.handleUnexpectedZmxClose(view, worktreeID: source)
    await Task.megaYield()
    merge(source, into: destination, in: harness)
    _ = await harness.events.collect(until: Self.isTransferOutcome)
    release.yield()
    let events = await harness.events.collect { if case .surfacesClosed = $0 { true } else { false } }

    // It acts on the task that holds the tab now, not on the one it started in.
    #expect(events.contains(.surfacesClosed(layoutID: destination, [moved])))
    #expect(harness.tabIDs(destination) == [own])
  }
}

/// Every layouts blob written and every session kill requested.
private final class Recorder {
  let defaults: RecordingDefaults
  let localKills = LockIsolated<[String]>([])
  let remoteKills = LockIsolated<[String]>([])
  let queuedCommands = LockIsolated<[TerminalClient.Command]>([])
  let everyWrite = LockIsolated<[TaskLayoutsFile]>([])
  /// True while a write is stuck in the store, the writer's queue with it.
  let isHolding = LockIsolated(false)
  private let hold = LockIsolated<DispatchSemaphore?>(nil)
  // Pulled sequentially on the test's one task.
  nonisolated(unsafe) private var writes: AsyncStream<TaskLayoutsFile>.AsyncIterator

  init() {
    let (writes, signal) = AsyncStream<TaskLayoutsFile>.makeStream()
    let (everyWrite, isHolding, hold) = (everyWrite, isHolding, hold)
    defaults = RecordingDefaults { data in
      defer {
        let gate = hold.withValue { gate in
          defer { gate = nil }
          return gate
        }
        if let gate {
          isHolding.setValue(true)
          gate.wait()
          isHolding.setValue(false)
        }
      }
      guard let file = try? JSONDecoder().decode(TaskLayoutsFile.self, from: data) else { return }
      everyWrite.withValue { $0.append(file) }
      signal.yield(file)
    }
    self.writes = writes.makeAsyncIterator()
  }

  /// Blocks the next write inside the store until the returned closure runs.
  func holdNextWrite() -> @Sendable () -> Void {
    let gate = DispatchSemaphore(value: 0)
    hold.setValue(gate)
    return { gate.signal() }
  }

  func seed(_ tasks: [TaskRecord]) {
    var file = current() ?? TaskLayoutsFile()
    for task in tasks { file.tasks[task.id.persistenceKey] = task }
    defaults.seed((try? JSONEncoder().encode(file)) ?? Data())
  }

  /// What is stored right now.
  func current() -> TaskLayoutsFile? {
    defaults.data(forKey: LayoutsFile.userDefaultsKey).flatMap {
      try? JSONDecoder().decode(TaskLayoutsFile.self, from: $0)
    }
  }

  /// The first written blob that satisfies `matches`.
  func nextWrite(where matches: (TaskLayoutsFile) -> Bool) async -> TaskLayoutsFile {
    while let file = await writes.next() {
      if matches(file) { return file }
    }
    return TaskLayoutsFile()
  }
}

/// In-memory defaults that report every layouts write.
private nonisolated final class RecordingDefaults: UserDefaults, @unchecked Sendable {
  private let lock = NSLock()
  private var store: [String: Data] = [:]
  private let onWrite: @Sendable (Data) -> Void

  init(onWrite: @escaping @Sendable (Data) -> Void) {
    self.onWrite = onWrite
    super.init(suiteName: "layouts-transfer-\(UUID().uuidString)")!
  }

  func seed(_ data: Data) {
    lock.lock()
    defer { lock.unlock() }
    store[LayoutsFile.userDefaultsKey] = data
  }

  override func data(forKey defaultName: String) -> Data? {
    lock.lock()
    defer { lock.unlock() }
    return store[defaultName]
  }

  override func set(_ value: Any?, forKey defaultName: String) {
    lock.lock()
    store[defaultName] = value as? Data
    lock.unlock()
    guard defaultName == LayoutsFile.userDefaultsKey, let data = value as? Data else { return }
    onWrite(data)
  }
}

/// One long-lived subscription per test: resubscribing would strand one-shot
/// events in the abandoned stream. Everything is pulled as it arrives, so a
/// wait for an event that never comes ends as a failed expectation, not a hang.
@MainActor
private final class EventLog {
  private var events: [TerminalClient.Event] = []
  private var cursor = 0
  private var pump: Task<Void, Never>?

  init(_ manager: WorktreeTerminalManager) {
    let stream = manager.eventStream()
    pump = Task { @MainActor [weak self] in
      for await event in stream {
        self?.events.append(event)
      }
    }
  }

  isolated deinit { pump?.cancel() }

  /// Every event not yet returned, up to and including the first that
  /// satisfies `until`; all of them when none does within the bound.
  func collect(until matches: (TerminalClient.Event) -> Bool) async -> [TerminalClient.Event] {
    for _ in 0..<500 {
      if let index = events[cursor...].firstIndex(where: matches) {
        defer { cursor = index + 1 }
        return Array(events[cursor...index])
      }
      await Task.megaYield()
    }
    defer { cursor = events.count }
    return Array(events[cursor...])
  }
}

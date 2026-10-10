import Clocks
import ComposableArchitecture
import ConcurrencyExtras
import Dependencies
import DependenciesTestSupport
import Foundation
import IdentifiedCollections
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
    listSessions: @escaping @Sendable () async -> [ZmxSessionListParser.Entry]? = { nil }
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
    let store = Store(
      initialState: AppFeature.State(repositories: RepositoriesFeature.State(), settings: SettingsFeature.State())
    ) {
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
      .transferTabs(from: source, into: destination, DirectoryContext(worktree: directory), scope: .all))
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

  @Test(.dependencies) func detachLeavesTheSourceRunning() async {
    let harness = await makeHarness()
    let (source, minted) = (LayoutID(task: UUID()), LayoutID(task: UUID()))
    let staying = await open(source, in: harness)
    let leaving = await open(source, in: harness)
    let (primary, tangent) = (Self.session("PA"), Self.session("TA"))
    await harness.store.send(.terminals(.membersChanged([source: [.session(primary), .session(tangent)]]))).finish()

    harness.manager.handleCommand(
      .transferTabs(
        from: source, into: minted, DirectoryContext(worktree: Self.directory),
        scope: .tab(TabID(rawValue: leaving), members: [.session(tangent)])))
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

    harness.manager.handleCommand(
      .transferTabs(
        from: source, into: minted, DirectoryContext(worktree: Self.directory),
        scope: .tab(TabID(rawValue: only), members: [])))
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

    harness.manager.handleCommand(
      .transferTabs(
        from: source, into: minted, DirectoryContext(worktree: Self.directory),
        scope: .tab(TabID(rawValue: leaving), members: [.session(tangent)])))
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
    harness.manager.handleCommand(
      .transferTabs(
        from: source, into: minted, DirectoryContext(worktree: Self.directory),
        scope: .tab(TabID(rawValue: leaving), members: [.session(tangent)])))
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
    harness.manager.handleCommand(
      .transferTabs(
        from: source, into: minted, DirectoryContext(worktree: Self.directory),
        scope: .tab(TabID(rawValue: leaving), members: [.session(tangent)])))
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
    harness.manager.handleCommand(
      .transferTabs(
        from: source, into: minted, DirectoryContext(worktree: Self.directory),
        scope: .tab(TabID(rawValue: leaving), members: [.session(tangent)])))
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
    harness.manager.handleActiveTaskChanged(directoryID: Self.directory.id, layoutID: destination)
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

    harness.manager.handleCommand(
      .transferTabs(
        from: source, into: destination, DirectoryContext(worktree: Self.directory),
        scope: .tab(TabID(rawValue: tab), members: [])))
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

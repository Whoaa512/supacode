import ComposableArchitecture
import Dependencies
import DependenciesTestSupport
import Foundation
import IdentifiedCollections
import Sharing
import SupacodeSettingsFeature
import SupacodeSettingsShared
import Testing

@testable import supacode

/// Pins the manager's creation-ack contract: every `createTab` command emits
/// either the success pair (`tabCreated` + `surfaceCreated`) or a
/// `surfaceCreationFailed`, so a CLI or deeplink client can never strand on
/// the watchdog.
@MainActor
struct WorktreeTerminalManagerAckTests {
  private struct Harness {
    let manager: WorktreeTerminalManager
    let store: Store<AppFeature.State, AppFeature.Action>
    let worktree: Worktree
  }

  private func makeWorktree(id: String = "/tmp/repo/wt-ack") -> Worktree {
    Worktree(
      id: WorktreeID(id),
      name: URL(fileURLWithPath: id).lastPathComponent,
      detail: "detail",
      workingDirectory: URL(fileURLWithPath: id),
      repositoryRootURL: URL(fileURLWithPath: "/tmp/repo")
    )
  }

  /// Manager wired to a live store whose factory provisions inert content, so
  /// creation flows run end to end without spawning surfaces.
  private func makeHarness(
    storage: SettingsFileStorage = .inMemory(),
    defaults: UserDefaults = .inMemory,
    killSession: @escaping @Sendable (String) -> Void = { _ in },
    killRemoteSession: @escaping @Sendable (RemoteHost, String) -> Void = { _, _ in }
  ) -> Harness {
    let worktree = makeWorktree()
    let manager = withDependencies {
      $0.settingsFileStorage = storage
      $0.defaultAppStorage = defaults
      $0.zmxClient = ZmxClient(
        executableURL: { nil },
        isBundled: { false },
        killSession: { session in killSession(session) },
        killRemoteSession: { host, session in killRemoteSession(host, session) },
        listSessionsWithClients: { nil }
      )
    } operation: {
      WorktreeTerminalManager(runtime: GhosttyRuntime())
    }
    let store = Store(
      initialState: AppFeature.State(
        repositories: RepositoriesFeature.State(),
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      // One shared registry: the per-access `testValue` would otherwise hand
      // provision and lookup different runtimes.
      $0.contentRuntime = ContentRuntime()
      $0[LayoutContentFactory.self] = LayoutContentFactory { request in
        InertTabContent(id: request.contentID, state: request.content)
      }
      $0[ContentSessionKiller.self] = ContentSessionKiller(kill: { _, _ in })
    }
    manager.appStore = store
    return Harness(manager: manager, store: store, worktree: worktree)
  }

  /// One long-lived subscription per test: resubscribing between commands
  /// would strand one-shot events in the abandoned stream. Pulls creation
  /// events only; state replays (indicator counts, projections) pass through.
  private final class CreationEvents {
    // Tests pull sequentially on one task; the iterator only needs to escape
    // the actor so its mutating async `next` can run across suspensions.
    nonisolated(unsafe) private var iterator: AsyncStream<TerminalClient.Event>.AsyncIterator

    init(_ manager: WorktreeTerminalManager) {
      iterator = manager.eventStream().makeAsyncIterator()
    }

    func next(_ count: Int) async -> [TerminalClient.Event] {
      var events: [TerminalClient.Event] = []
      while events.count < count, let event = await iterator.next() {
        switch event {
        case .tabCreated, .surfaceCreated, .surfaceCreationFailed, .initialTabCreationFailed:
          events.append(event)
        default:
          continue
        }
      }
      return events
    }
  }

  @Test(.dependencies) func explicitIDCreateEmitsTheSuccessPair() async {
    let harness = makeHarness()
    let pump = CreationEvents(harness.manager)
    let id = UUID()
    harness.manager.handleCommand(
      .createTab(
        harness.worktree.id.layoutID, DirectoryContext(worktree: harness.worktree), runSetupScriptIfNew: false, id: id,
        focusing: false))

    let events = await pump.next(2)
    #expect(events.contains(.tabCreated(layoutID: harness.worktree.id.layoutID)))
    #expect(events.contains(.surfaceCreated(layoutID: harness.worktree.id.layoutID, id: id)))
    // The documented invariant: the initial surface ID equals the tab ID.
    let layout = harness.store.withState { $0.terminals.layouts[id: harness.worktree.id.layoutID]?.layout }
    #expect(layout?.pane(containingTab: TabID(rawValue: id))?.tabs[id: TabID(rawValue: id)]?.content.id.rawValue == id)
  }

  @Test(.dependencies) func createWithoutAStoreDrainsTheAckAsFailure() async {
    let worktree = makeWorktree()
    let manager = withDependencies {
      $0.zmxClient = .noop
    } operation: {
      WorktreeTerminalManager(runtime: GhosttyRuntime())
    }
    let pump = CreationEvents(manager)
    let id = UUID()
    manager.handleCommand(
      .createTab(
        worktree.id.layoutID, DirectoryContext(worktree: worktree), runSetupScriptIfNew: false, id: id, focusing: false)
    )

    let events = await pump.next(1)
    guard case .surfaceCreationFailed(let worktreeID, let attemptedID, _) = events.first else {
      Issue.record("Expected surfaceCreationFailed, got \(events)")
      return
    }
    #expect(worktreeID == worktree.layoutID)
    #expect(attemptedID == id)
  }

  @Test(.dependencies) func ensureInitialTabWithoutAStoreEmitsInitialTabFailure() async {
    // The initial bootstrap emits its own failure event so only it settles the
    // worktree-new ack and the creation-progress overlay.
    let worktree = makeWorktree()
    let manager = withDependencies {
      $0.zmxClient = .noop
    } operation: {
      WorktreeTerminalManager(runtime: GhosttyRuntime())
    }
    let pump = CreationEvents(manager)
    manager.handleCommand(
      .ensureInitialTab(
        worktree.id.layoutID, DirectoryContext(worktree: worktree), runSetupScriptIfNew: false, focusing: false))

    let events = await pump.next(1)
    guard case .initialTabCreationFailed(let worktreeID, _) = events.first else {
      Issue.record("Expected initialTabCreationFailed, got \(events)")
      return
    }
    #expect(worktreeID == worktree.layoutID)
  }

  @Test(.dependencies) func collidingContentIDCreateFailsInsteadOfFalselyAcking() async {
    let harness = makeHarness()
    let pump = CreationEvents(harness.manager)
    let first = UUID()
    harness.manager.handleCommand(
      .createTab(
        harness.worktree.id.layoutID, DirectoryContext(worktree: harness.worktree), runSetupScriptIfNew: false,
        id: first,
        focusing: false))
    _ = await pump.next(2)

    // Reusing the surface id of the EXISTING tab must refuse and say so, not
    // match the old content and ack a creation that never happened.
    harness.manager.handleCommand(
      .createTab(
        harness.worktree.id.layoutID, DirectoryContext(worktree: harness.worktree), runSetupScriptIfNew: false,
        id: first,
        focusing: false))
    let events = await pump.next(1)
    guard case .surfaceCreationFailed = events.first else {
      Issue.record("Expected surfaceCreationFailed, got \(events)")
      return
    }
  }

  @Test(.dependencies) func ensureInitialTabOnAPopulatedLayoutStillAcks() async {
    let harness = makeHarness()
    let pump = CreationEvents(harness.manager)
    harness.manager.handleCommand(
      .createTab(
        harness.worktree.id.layoutID, DirectoryContext(worktree: harness.worktree), runSetupScriptIfNew: false,
        id: UUID(),
        focusing: false))
    _ = await pump.next(2)

    // A hydrated or already-bootstrapped layout resolves a waiting
    // worktree-new ack instead of stranding it until the watchdog.
    harness.manager.handleCommand(
      .ensureInitialTab(
        harness.worktree.id.layoutID, DirectoryContext(worktree: harness.worktree), runSetupScriptIfNew: false,
        focusing: false))
    let events = await pump.next(1)
    #expect(events.first == .tabCreated(layoutID: harness.worktree.id.layoutID))
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
              title: "Restored",
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

  @Test(.dependencies) func removingADeletedWorktreesLayoutWorksWithoutAHost() async throws {
    // Layouts persist to UserDefaults now; signal each write so the async
    // incremental flush can be awaited without polling.
    let (fileWrites, writeSignal) = AsyncStream<TaskLayoutsFile>.makeStream()
    let defaults = LayoutsSignalingDefaults { data in
      if let file = try? JSONDecoder().decode(TaskLayoutsFile.self, from: data) {
        writeSignal.yield(file)
      }
    }
    let harness = makeHarness(defaults: defaults)
    let contentID = UUID()
    let layout = singleTabLayout(contentID: contentID)
    let record = LayoutRecord(layout: layout)
    defaults.seed(
      try JSONEncoder().encode(LayoutsFile(worktrees: [harness.worktree.id.rawValue: record]))
    )
    // Hydrated but never selected: no host exists for this worktree.
    harness.store.send(
      .terminals(
        .layoutsHydrated(
          TaskLayoutsFile(oneTaskPerDirectory: LayoutsFile(worktrees: [harness.worktree.id.rawValue: record])))
      )
    )
    #expect(harness.store.withState { $0.terminals.layouts[id: harness.worktree.id.layoutID] } != nil)

    harness.manager.handleCommand(
      .removeLayouts(forDirectory: harness.worktree.id, remoteHost: nil))

    // The in-memory layout detaches AND the persisted record goes with it;
    // this hostless-hydrated case is exactly the one roster prune cannot reach.
    #expect(harness.store.withState { $0.terminals.layouts[id: harness.worktree.id.layoutID] } == nil)
    var writes = fileWrites.makeAsyncIterator()
    let written = await writes.next()
    #expect(written?.tasks.isEmpty == true)
  }

  @Test(.dependencies) func removingAWorktreeLayoutRetractsItsSurfacesFromPresence() async {
    let harness = makeHarness()
    let contentID = UUID()
    let record = LayoutRecord(layout: singleTabLayout(contentID: contentID))
    // Subscribe before the command so the one-shot event isn't stranded.
    var iterator = harness.manager.eventStream().makeAsyncIterator()
    harness.store.send(
      .terminals(
        .layoutsHydrated(
          TaskLayoutsFile(oneTaskPerDirectory: LayoutsFile(worktrees: [harness.worktree.id.rawValue: record])))))

    harness.manager.handleCommand(
      .removeLayouts(forDirectory: harness.worktree.id, remoteHost: nil))

    // The prune must retract the surface so AppFeature clears its agent presence.
    var closed: (worktreeID: LayoutID, ids: Set<UUID>)?
    while closed == nil, let event = await iterator.next() {
      if case .surfacesClosed(let worktreeID, let ids) = event {
        closed = (worktreeID, ids)
      }
    }
    #expect(closed?.worktreeID == harness.worktree.layoutID)
    #expect(closed?.ids == [contentID])
  }

  @Test(.dependencies) func removingADeletedRemoteWorktreesLayoutKillsItsHostSessions() async {
    let (remoteKills, killSignal) = AsyncStream<(String, String)>.makeStream()
    let harness = makeHarness(killRemoteSession: { host, session in
      killSignal.yield((host.alias, session))
    })
    let contentID = UUID()
    harness.store.send(
      .terminals(
        .layoutsHydrated(
          TaskLayoutsFile(
            oneTaskPerDirectory: LayoutsFile(
              worktrees: [
                harness.worktree.id.rawValue: LayoutRecord(layout: singleTabLayout(contentID: contentID))
              ]
            )
          )
        )
      )
    )

    harness.manager.handleCommand(
      .removeLayouts(
        forDirectory: harness.worktree.id, remoteHost: RemoteHost(alias: "build-box")))

    var kills = remoteKills.makeAsyncIterator()
    let kill = await kills.next()
    #expect(kill?.0 == "build-box")
    #expect(kill?.1 == ZmxSessionID.make(surfaceID: contentID))
  }

  /// Opens one tab so the manager holds a host under `layoutID` whose
  /// directory is `directory`; returns the tab's surface id.
  private func openLayout(
    _ layoutID: LayoutID, on directory: Worktree, in harness: Harness, pump: CreationEvents
  ) async -> UUID {
    let surfaceID = UUID()
    harness.manager.handleCommand(
      .createTab(
        layoutID, DirectoryContext(worktree: directory), runSetupScriptIfNew: false, id: surfaceID,
        focusing: false))
    _ = await pump.next(2)
    return surfaceID
  }

  @Test(.dependencies) func pruneDecidesByTheHostsDirectoryNotItsKey() async {
    let harness = makeHarness()
    let pump = CreationEvents(harness.manager)
    let directory = makeWorktree(id: "/tmp/repo/wt-directory")
    let layoutID = LayoutID(legacyWorktreeKey: "/tmp/repo/wt-layout-key")
    _ = await openLayout(layoutID, on: directory, in: harness, pump: pump)

    harness.manager.handleCommand(.prune(keepingDirectories: [directory.id], protectingRepositoryIDs: []))

    #expect(harness.manager.hostIfExists(for: layoutID) != nil)
    #expect(harness.store.withState { $0.terminals.layouts[id: layoutID] } != nil)

    // Archiving the key names no directory a host sits on.
    harness.manager.handleCommand(
      .prune(
        keepingDirectories: [], protectingRepositoryIDs: [], archivedDirectories: ["/tmp/repo/wt-layout-key"]))

    #expect(harness.manager.hostIfExists(for: layoutID) != nil)

    // Keeping the key alone protects nothing once the directory is archived.
    harness.manager.handleCommand(
      .prune(
        keepingDirectories: ["/tmp/repo/wt-layout-key"], protectingRepositoryIDs: [],
        archivedDirectories: [directory.id]))

    #expect(harness.manager.hostIfExists(for: layoutID) == nil)
    #expect(harness.store.withState { $0.terminals.layouts[id: layoutID] } == nil)
  }

  @Test(.dependencies) func removingADirectoryTearsDownEveryLayoutOnItAndNoOther() async {
    let harness = makeHarness()
    let pump = CreationEvents(harness.manager)
    let directory = makeWorktree(id: "/tmp/repo/wt-directory")
    let other = makeWorktree(id: "/tmp/repo/wt-other")
    let first = LayoutID(legacyWorktreeKey: "/tmp/repo/wt-layout-first")
    let second = LayoutID(legacyWorktreeKey: "/tmp/repo/wt-layout-second")
    let firstSurface = await openLayout(first, on: directory, in: harness, pump: pump)
    let secondSurface = await openLayout(second, on: directory, in: harness, pump: pump)
    _ = await openLayout(other.id.layoutID, on: other, in: harness, pump: pump)
    var iterator = harness.manager.eventStream().makeAsyncIterator()

    harness.manager.handleCommand(.removeLayouts(forDirectory: directory.id, remoteHost: nil))

    #expect(harness.manager.hostIfExists(for: first) == nil)
    #expect(harness.manager.hostIfExists(for: second) == nil)
    #expect(harness.manager.hostIfExists(for: other.id.layoutID) != nil)
    #expect(harness.store.withState { Array($0.terminals.layouts.ids) } == [other.layoutID])

    // Each layout reports its own closed surfaces and its own teardown.
    var closed: [LayoutID: Set<UUID>] = [:]
    var tornDown: Set<LayoutID> = []
    while tornDown.count < 2, let event = await iterator.next() {
      switch event {
      case .surfacesClosed(let layoutID, let ids): closed[layoutID] = ids
      case .worktreeStateTornDown(let worktreeID, let layoutID):
        #expect(worktreeID == directory.id)
        tornDown.insert(layoutID)
      default: continue
      }
    }
    #expect(closed == [first: [firstSurface], second: [secondSurface]])
    #expect(tornDown == [first, second])
  }

  // MARK: - Several tasks on one directory.

  @Test(.dependencies) func twoTasksOnOneDirectoryBothSurviveAPruneThatKeepsIt() async {
    let harness = makeHarness()
    let pump = CreationEvents(harness.manager)
    let directory = makeWorktree(id: "/tmp/repo/wt-directory")
    let first = LayoutID(task: UUID())
    let second = LayoutID(task: UUID())
    _ = await openLayout(first, on: directory, in: harness, pump: pump)
    _ = await openLayout(second, on: directory, in: harness, pump: pump)

    harness.manager.handleCommand(.prune(keepingDirectories: [directory.id], protectingRepositoryIDs: []))

    #expect(harness.manager.hostIfExists(for: first) != nil)
    #expect(harness.manager.hostIfExists(for: second) != nil)
    #expect(harness.store.withState { Set($0.terminals.layouts.ids) } == [first, second])
  }

  @Test(.dependencies) func archivingADirectoryPrunesEveryTaskOnItAndNoOther() async {
    let harness = makeHarness()
    let pump = CreationEvents(harness.manager)
    let archived = makeWorktree(id: "/tmp/repo/wt-archived")
    let other = makeWorktree(id: "/tmp/repo/wt-other")
    let first = LayoutID(task: UUID())
    let second = LayoutID(task: UUID())
    let kept = LayoutID(task: UUID())
    _ = await openLayout(first, on: archived, in: harness, pump: pump)
    _ = await openLayout(second, on: archived, in: harness, pump: pump)
    _ = await openLayout(kept, on: other, in: harness, pump: pump)

    harness.manager.handleCommand(
      .prune(keepingDirectories: [other.id], protectingRepositoryIDs: [], archivedDirectories: [archived.id]))

    #expect(harness.manager.hostIfExists(for: first) == nil)
    #expect(harness.manager.hostIfExists(for: second) == nil)
    #expect(harness.manager.hostIfExists(for: kept) != nil)
    #expect(harness.store.withState { Array($0.terminals.layouts.ids) } == [kept])
  }

  @Test(.dependencies) func aTaskAttachedAfterThePruneWasComputedKeepsItsHostRecordAndSessions() async throws {
    let recorder = TeardownRecorder()
    let harness = makeHarness(
      defaults: recorder.defaults, killSession: recorder.killSession, killRemoteSession: recorder.killRemoteSession)
    let pump = CreationEvents(harness.manager)
    let listed = makeWorktree(id: "/tmp/repo/wt-listed")
    let archived = makeWorktree(id: "/tmp/repo/wt-archived")
    let gone = makeWorktree(id: "/tmp/gone")
    let listedTask = LayoutID(task: UUID())
    let archivedTask = LayoutID(task: UUID())
    let orphanTask = LayoutID(task: UUID())
    let listedSurface = await openLayout(listedTask, on: listed, in: harness, pump: pump)
    // The reducer computes the prune from the roster it sees: one listed
    // directory, nothing archived, and no orphan yet.
    let computedEarlier = TerminalClient.Command.prune(
      keepingDirectories: [listed.id], protectingRepositoryIDs: [], archivedDirectories: [])
    // Before that command is delivered, a task opens on a directory the
    // roster does not list.
    let orphanSurface = await openLayout(orphanTask, on: gone, in: harness, pump: pump)
    let archivedSurface = await openLayout(archivedTask, on: archived, in: harness, pump: pump)
    let created = Date(timeIntervalSince1970: 1)
    recorder.seed([
      TaskRecord(
        id: listedTask, directory: .init(worktreeID: listed.id), layout: singleTabLayout(contentID: listedSurface),
        createdAt: created),
      TaskRecord(
        id: orphanTask, directory: .init(worktreeID: gone.id), layout: singleTabLayout(contentID: orphanSurface),
        createdAt: created),
      TaskRecord(
        id: archivedTask, directory: .init(worktreeID: archived.id),
        layout: singleTabLayout(contentID: archivedSurface), createdAt: created),
    ])

    harness.manager.handleCommand(computedEarlier)

    #expect(harness.manager.hostIfExists(for: orphanTask) != nil)
    #expect(harness.manager.hostIfExists(for: archivedTask) != nil)
    #expect(harness.store.withState { Set($0.terminals.layouts.ids) } == [listedTask, orphanTask, archivedTask])
    #expect(harness.store.withState { $0.terminals.directories[orphanTask]?.worktreeID } == gone.id)

    // A later, positively archived directory is the only thing that goes. Its
    // delete and kill land after anything the stale command could have queued.
    harness.manager.handleCommand(
      .prune(keepingDirectories: [listed.id], protectingRepositoryIDs: [], archivedDirectories: [archived.id]))

    let written = await recorder.nextWrite { $0.tasks[archivedTask.persistenceKey] == nil }
    #expect(Set(written.tasks.keys) == [listedTask.persistenceKey, orphanTask.persistenceKey])
    await recorder.awaitKills(1)
    #expect(recorder.localKills.value == [ZmxSessionID.make(surfaceID: archivedSurface)])
    #expect(recorder.remoteKills.value.isEmpty)
    #expect(harness.manager.hostIfExists(for: orphanTask) != nil)
  }

  @Test(.dependencies) func archivingADirectoryPrunesItsNeverOpenedTasksToo() async throws {
    let (fileWrites, writeSignal) = AsyncStream<TaskLayoutsFile>.makeStream()
    let defaults = LayoutsSignalingDefaults { data in
      if let file = try? JSONDecoder().decode(TaskLayoutsFile.self, from: data) {
        writeSignal.yield(file)
      }
    }
    let killed = LockIsolated<Set<String>>([])
    let (kills, killSignal) = AsyncStream<Void>.makeStream()
    let harness = makeHarness(
      defaults: defaults,
      killSession: { session in
        killed.withValue { _ = $0.insert(session) }
        killSignal.yield()
      })
    let archived = TaskRecord.Directory(worktreeID: "/tmp/repo/wt-archived")
    let other = TaskRecord.Directory(worktreeID: "/tmp/repo/wt-other")
    let first = LayoutID(task: UUID())
    let second = LayoutID(task: UUID())
    let kept = LayoutID(task: UUID())
    let firstSurface = UUID()
    let secondSurface = UUID()
    let created = Date(timeIntervalSince1970: 1)
    let tasks = [
      TaskRecord(id: first, directory: archived, layout: singleTabLayout(contentID: firstSurface), createdAt: created),
      TaskRecord(
        id: second, directory: archived, layout: singleTabLayout(contentID: secondSurface), createdAt: created),
      TaskRecord(id: kept, directory: other, layout: singleTabLayout(contentID: UUID()), createdAt: created),
    ]
    let file = TaskLayoutsFile(tasks: Dictionary(uniqueKeysWithValues: tasks.map { ($0.id.persistenceKey, $0) }))
    defaults.seed(try JSONEncoder().encode(file))
    // Hydrated, never selected: none of the three has a host.
    harness.store.send(.terminals(.layoutsHydrated(file)))

    // Absence from the kept set alone prunes no hostless task: its repository
    // may simply not be listed yet.
    harness.manager.handleCommand(.prune(keepingDirectories: [other.worktreeID], protectingRepositoryIDs: []))
    #expect(harness.store.withState { $0.terminals.layouts.count } == 3)

    // A directory still kept (its delete script is running) outranks the archive.
    harness.manager.handleCommand(
      .prune(
        keepingDirectories: [archived.worktreeID, other.worktreeID], protectingRepositoryIDs: [],
        archivedDirectories: [archived.worktreeID]))
    #expect(harness.store.withState { $0.terminals.layouts.count } == 3)

    harness.manager.handleCommand(
      .prune(
        keepingDirectories: [other.worktreeID], protectingRepositoryIDs: [],
        archivedDirectories: [archived.worktreeID]))

    try #require(harness.store.withState { Array($0.terminals.layouts.ids) } == [kept])
    #expect(harness.store.withState { $0.terminals.directories } == [kept: other])
    var killIterator = kills.makeAsyncIterator()
    for _ in 0..<2 { await killIterator.next() }
    var writes = fileWrites.makeAsyncIterator()
    while let written = await writes.next() {
      guard written.tasks.count == 1 else { continue }
      #expect(Array(written.tasks.keys) == [kept.persistenceKey])
      break
    }
    #expect(
      killed.value == [ZmxSessionID.make(surfaceID: firstSurface), ZmxSessionID.make(surfaceID: secondSurface)])
  }

  @Test(.dependencies) func removingADirectoryTearsDownItsNeverOpenedTasksToo() {
    let harness = makeHarness()
    let directory = TaskRecord.Directory(worktreeID: "/tmp/repo/wt-directory")
    let other = TaskRecord.Directory(worktreeID: "/tmp/repo/wt-other")
    let first = LayoutID(task: UUID())
    let second = LayoutID(task: UUID())
    let kept = LayoutID(task: UUID())
    let created = Date(timeIntervalSince1970: 1)
    let tasks = [
      TaskRecord(id: first, directory: directory, layout: singleTabLayout(contentID: UUID()), createdAt: created),
      TaskRecord(id: second, directory: directory, layout: singleTabLayout(contentID: UUID()), createdAt: created),
      TaskRecord(id: kept, directory: other, layout: singleTabLayout(contentID: UUID()), createdAt: created),
    ]
    // Hydrated, never selected: none of the three has a host.
    harness.store.send(
      .terminals(
        .layoutsHydrated(
          TaskLayoutsFile(tasks: Dictionary(uniqueKeysWithValues: tasks.map { ($0.id.persistenceKey, $0) })))))

    harness.manager.handleCommand(.removeLayouts(forDirectory: directory.worktreeID, remoteHost: nil))

    #expect(harness.store.withState { Array($0.terminals.layouts.ids) } == [kept])
    #expect(harness.store.withState { $0.terminals.directories } == [kept: other])
  }

  @Test(.dependencies) func theDirectoryRowProjectionCoversEveryTaskOnIt() async {
    let harness = makeHarness()
    let pump = CreationEvents(harness.manager)
    let directory = makeWorktree(id: "/tmp/repo/wt-directory")
    let other = makeWorktree(id: "/tmp/repo/wt-other")
    let first = LayoutID(task: UUID())
    let second = LayoutID(task: UUID())
    let firstSurface = await openLayout(first, on: directory, in: harness, pump: pump)
    let secondSurface = await openLayout(second, on: directory, in: harness, pump: pump)
    let otherSurface = await openLayout(LayoutID(task: UUID()), on: other, in: harness, pump: pump)
    // A new subscriber is seeded with one projection per directory.
    var iterator = harness.manager.eventStream().makeAsyncIterator()
    // One task changing must not replace what the other contributes.
    harness.manager.handleLayoutChanged(for: second)

    var projected: [Worktree.ID: [Set<UUID>]] = [:]
    while projected.count < 2, let event = await iterator.next() {
      guard case .worktreeProjectionChanged(let worktreeID, let projection) = event else { continue }
      projected[worktreeID, default: []].append(Set(projection.surfaceIDs))
    }
    #expect(projected == [directory.id: [[firstSurface, secondSurface]], other.id: [[otherSurface]]])
  }

  @Test(.dependencies) func setupScriptRunsOncePerDirectoryNotOncePerTask() async throws {
    let localStorage = RepositoryLocalSettingsTestStorage()
    let directory = makeWorktree(id: "/tmp/repo/wt-directory")
    var settings = RepositorySettings.default
    settings.setupScript = "echo setup"
    try localStorage.save(
      JSONEncoder().encode(settings), at: SupacodePaths.repositorySettingsURL(for: directory.repositoryRootURL))

    await withDependencies {
      $0.settingsFileStorage = SettingsTestStorage().storage
      $0.settingsFileURL = URL(fileURLWithPath: "/tmp/supacode-settings-\(UUID().uuidString).json")
      $0.repositoryLocalSettingsStorage = localStorage.storage
    } operation: {
      let harness = makeHarness()
      var iterator = harness.manager.eventStream().makeAsyncIterator()
      let first = LayoutID(task: UUID())
      let second = LayoutID(task: UUID())
      let lastSurface = UUID()
      harness.manager.handleCommand(
        .createTab(first, DirectoryContext(worktree: directory), runSetupScriptIfNew: true, id: UUID(), focusing: false)
      )
      // A second task on the same, still-new directory asks for it again.
      harness.manager.handleCommand(
        .createTab(
          second, DirectoryContext(worktree: directory), runSetupScriptIfNew: true, id: lastSurface,
          focusing: false))

      var consumed: [LayoutID] = []
      while let event = await iterator.next() {
        if case .setupScriptConsumed(let layoutID) = event { consumed.append(layoutID) }
        if case .surfaceCreated(_, lastSurface) = event { break }
      }
      #expect(consumed == [first])
    }
  }

  @Test(.dependencies) func anchoredCreateLandsInTheAnchorsPane() async {
    let harness = makeHarness()
    let pump = CreationEvents(harness.manager)
    let anchor = UUID()
    harness.manager.handleCommand(
      .createTab(
        harness.worktree.id.layoutID, DirectoryContext(worktree: harness.worktree), runSetupScriptIfNew: false,
        id: anchor,
        focusing: false))
    _ = await pump.next(2)

    let added = UUID()
    harness.manager.handleCommand(
      .createTab(
        harness.worktree.id.layoutID, DirectoryContext(worktree: harness.worktree), runSetupScriptIfNew: false,
        id: added,
        focusing: false, anchor: anchor))
    _ = await pump.next(2)

    let layout = harness.store.withState { $0.terminals.layouts[id: harness.worktree.id.layoutID]?.layout }
    let anchorPane = layout?.tab(containingContent: ContentID(rawValue: anchor))?.pane
    #expect(anchorPane?.tabs[id: TabID(rawValue: added)] != nil)
  }
}

/// Records what a teardown leaves behind: every layouts blob written and
/// every local and remote session kill, each awaitable without polling.
private final class TeardownRecorder {
  nonisolated struct RemoteKill: Hashable, Sendable {
    let alias: String
    let session: String
  }

  let defaults: LayoutsSignalingDefaults
  let localKills = LockIsolated<Set<String>>([])
  let remoteKills = LockIsolated<Set<RemoteKill>>([])
  // Pulled sequentially on the test's one task, as in `CreationEvents`.
  nonisolated(unsafe) private var writes: AsyncStream<TaskLayoutsFile>.AsyncIterator
  nonisolated(unsafe) private var kills: AsyncStream<Void>.AsyncIterator
  private let killSignal: AsyncStream<Void>.Continuation

  init() {
    let (writes, writeSignal) = AsyncStream<TaskLayoutsFile>.makeStream()
    let (kills, killSignal) = AsyncStream<Void>.makeStream()
    defaults = LayoutsSignalingDefaults { data in
      if let file = try? JSONDecoder().decode(TaskLayoutsFile.self, from: data) {
        writeSignal.yield(file)
      }
    }
    self.writes = writes.makeAsyncIterator()
    self.kills = kills.makeAsyncIterator()
    self.killSignal = killSignal
  }

  var killSession: @Sendable (String) -> Void {
    { [localKills, killSignal] session in
      localKills.withValue { _ = $0.insert(session) }
      killSignal.yield()
    }
  }

  var killRemoteSession: @Sendable (RemoteHost, String) -> Void {
    { [remoteKills, killSignal] host, session in
      remoteKills.withValue { _ = $0.insert(RemoteKill(alias: host.alias, session: session)) }
      killSignal.yield()
    }
  }

  func seed(_ tasks: [TaskRecord], origins: [String: TerminalLayoutSnapshot] = [:]) {
    let file = TaskLayoutsFile(
      tasks: Dictionary(uniqueKeysWithValues: tasks.map { ($0.id.persistenceKey, $0) }), origins: origins)
    // The fixture cannot fail to encode; an empty seed would fail the test's
    // own assertions.
    defaults.seed((try? JSONEncoder().encode(file)) ?? Data())
  }

  /// The first written blob that satisfies `matches`.
  func nextWrite(where matches: (TaskLayoutsFile) -> Bool) async -> TaskLayoutsFile {
    while let file = await writes.next() {
      if matches(file) { return file }
    }
    return TaskLayoutsFile()
  }

  func awaitKills(_ count: Int) async {
    for _ in 0..<count { await kills.next() }
  }
}

/// In-memory `UserDefaults` that signals every layouts blob write, so a test can
/// await the incremental writer's async flush without polling. `seed(_:)` primes
/// the store without signaling.
private nonisolated final class LayoutsSignalingDefaults: UserDefaults, @unchecked Sendable {
  private let lock = NSLock()
  private var store: [String: Data] = [:]
  private let onWrite: @Sendable (Data) -> Void

  init(onWrite: @escaping @Sendable (Data) -> Void) {
    self.onWrite = onWrite
    super.init(suiteName: "layouts-signal-\(UUID().uuidString)")!
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

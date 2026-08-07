import ComposableArchitecture
import Dependencies
import Foundation
import IdentifiedCollections
import Sharing
import Testing

@testable import SupacodeSettingsShared
@testable import supacode

/// Phase-1 task-inbox reducer contract: assertions A1, A3, A5, A6 (P1 form),
/// A7, A10b, A11 and A13 of `plans/task-inbox-sidebar-plan.md`.
///
/// The store's `tasks.json` URL is `SupacodePaths.tasksURL`, but every test runs
/// with in-memory `settingsFileStorage`, so nothing here touches the real file.
/// Seeding evidence is real: each fixture directory gets a `.git/logs/HEAD` with
/// a git-shaped reflog line, because the reflog is the only activity source the
/// seeder trusts (plan Resolved #2).
@MainActor
struct RepositoriesFeatureTasksTests {
  private static let now = Date(timeIntervalSince1970: 1_800_000_000)
  private static let freshDate = now.addingTimeInterval(-3600)
  private static let staleDate = now.addingTimeInterval(-30 * 24 * 3600)

  // MARK: - Fixture

  /// Temp repo whose worktree directories carry a real reflog, plus the shared
  /// in-memory storage both the reducer and the test read `tasks.json` through.
  private final class Sandbox {
    let rootURL: URL
    let storage: SettingsFileStorage
    let store = TaskStore()

    init() throws {
      rootURL = FileManager.default.temporaryDirectory
        .appending(path: "RepositoriesFeatureTasksTests-\(UUID().uuidString)", directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
      storage = .inMemory()
    }

    /// A worktree directory with a `checkout: moving from main to <branch>`
    /// reflog line at `activityAt`.
    func makeDirectory(_ name: String, activityAt: Date, branch: String = "feature") throws -> URL {
      let directory = rootURL.appending(path: name, directoryHint: .isDirectory)
      let logs = directory.appending(path: ".git/logs", directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
      let sha = String(repeating: "a", count: 40)
      let line = """
        \(sha) \(sha) Tester <t@example.com> \(Int(activityAt.timeIntervalSince1970)) -0700\t\
        checkout: moving from main to \(branch)
        """
      try Data("\(line)\n".utf8).write(to: logs.appending(path: "HEAD", directoryHint: .notDirectory))
      return directory
    }

    func loadFile() -> TaskStoreFile? {
      withDependencies { $0.settingsFileStorage = storage } operation: { store.load().file }
    }

    func save(_ file: TaskStoreFile) throws {
      try withDependencies { $0.settingsFileStorage = storage } operation: { try store.save(file) }
    }

    deinit {
      try? FileManager.default.removeItem(at: rootURL)
    }
  }

  private func makeWorktree(_ directory: URL, rootURL: URL) -> Worktree {
    Worktree(
      id: WorktreeID(directory.path(percentEncoded: false)),
      name: directory.lastPathComponent,
      detail: "",
      workingDirectory: directory,
      repositoryRootURL: rootURL
    )
  }

  /// Reconciled state with one row per directory, each owning `surfacesPerRow`
  /// surfaces and reporting a terminal projection (so ownership reconciliation
  /// treats the row as authoritative).
  private func makeState(
    sandbox: Sandbox,
    directories: [URL],
    surfacesPerRow: [URL: Set<UUID>] = [:]
  ) -> RepositoriesFeature.State {
    let worktrees = directories.map { makeWorktree($0, rootURL: sandbox.rootURL) }
    let repository = Repository(
      id: RepositoryID(sandbox.rootURL.path(percentEncoded: false)),
      rootURL: sandbox.rootURL,
      name: sandbox.rootURL.lastPathComponent,
      worktrees: IdentifiedArray(uniqueElements: worktrees)
    )
    var state = RepositoriesFeature.State(reconciledRepositories: [repository])
    state.isInitialLoadComplete = true
    for (directory, surfaceIDs) in surfacesPerRow {
      let id = WorktreeID(directory.path(percentEncoded: false))
      state.sidebarItems[id: id]?.surfaceIDs = surfaceIDs.sorted { $0.uuidString < $1.uuidString }
      state.sidebarItems[id: id]?.hasTerminalProjection = true
    }
    state.applyPostReduceCacheRecomputes(.all)
    return state
  }

  private func makeStore(
    _ state: RepositoriesFeature.State,
    sandbox: Sandbox
  ) -> TestStoreOf<RepositoriesFeature> {
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    } withDependencies: {
      $0.settingsFileStorage = sandbox.storage
      $0.date.now = Self.now
    }
    // The post-reduce hook rewrites six derived caches on every task arm; this
    // suite asserts the task-owned state, and `expectCachesConverged` in the
    // shared helper already guards the invalidation bits.
    store.exhaustivity = .off
    return store
  }

  private func makeRecord(
    directory: URL,
    surfaceIDs: Set<UUID> = [],
    settledAt: Date? = nil,
    createdAt: Date = Self.freshDate
  ) -> TaskRecord {
    TaskRecord(
      title: directory.lastPathComponent,
      directoryPath: TaskDirectoryPath.canonical(directory),
      createdAt: createdAt,
      settledAt: settledAt,
      surfaceIDs: surfaceIDs
    )
  }

  // MARK: - A1 / A13: load, seed, idempotence

  @Test func loadSeedsOneTaskPerDirectoryAndPopulatesTheStructure() async throws {
    let sandbox = try Sandbox()
    let fresh = try sandbox.makeDirectory("fresh", activityAt: Self.freshDate)
    let stale = try sandbox.makeDirectory("stale", activityAt: Self.staleDate)
    let surfaceID = UUID()
    let state = makeState(
      sandbox: sandbox,
      directories: [fresh, stale],
      surfacesPerRow: [fresh: [surfaceID]]
    )
    let store = makeStore(state, sandbox: sandbox)

    await store.send(.tasks(.load))
    await store.receive(\.tasks.loaded)
    await store.receive(\.tasks.seedIfNeeded)
    await store.receive(\.tasks.seeded)
    await store.finish()

    #expect(store.state.taskRecords.count == 2)
    #expect(store.state.didSeedTasks)
    let freshRecord = try #require(
      store.state.taskRecords.first { $0.directoryPath == TaskDirectoryPath.canonical(fresh) }
    )
    let staleRecord = try #require(
      store.state.taskRecords.first { $0.directoryPath == TaskDirectoryPath.canonical(stale) }
    )
    // A3: the task claims the directory's existing surfaces.
    #expect(freshRecord.surfaceIDs == [surfaceID])
    // A1: a stale directory seeds straight into the settled tail.
    #expect(freshRecord.settledAt == nil)
    #expect(staleRecord.settledAt != nil)
    #expect(store.state.tasksSidebarStructure.activeTaskIDs == [freshRecord.id])
    #expect(store.state.tasksSidebarStructure.settledTotalCount == 1)
    // A11 / A13: the records reached `tasks.json`, and the seeded flag with them.
    let persisted = try #require(sandbox.loadFile())
    #expect(persisted.didSeedTasks)
    #expect(Set(persisted.tasks.map(\.id)) == Set(store.state.taskRecords.map(\.id)))
  }

  /// A13: a second launch reads the flag and the records back and adds nothing.
  @Test func secondLaunchDoesNotReseed() async throws {
    let sandbox = try Sandbox()
    let directory = try sandbox.makeDirectory("fresh", activityAt: Self.freshDate)
    let existing = makeRecord(directory: directory)
    try sandbox.save(TaskStoreFile(didSeedTasks: true, tasks: [existing]))
    let store = makeStore(makeState(sandbox: sandbox, directories: [directory]), sandbox: sandbox)

    await store.send(.tasks(.load))
    await store.receive(\.tasks.loaded)
    await store.receive(\.tasks.seedIfNeeded)
    await store.finish()

    #expect(store.state.taskRecords.map(\.id) == [existing.id])
    #expect(store.state.didSeedTasks)
  }

  /// Even with the flag unset, the seeder's per-directory dedupe keeps a re-seed
  /// from duplicating a record an older build already wrote.
  @Test func reseedAfterUpgradeDoesNotDuplicateExistingDirectories() async throws {
    let sandbox = try Sandbox()
    let directory = try sandbox.makeDirectory("fresh", activityAt: Self.freshDate)
    let existing = makeRecord(directory: directory)
    try sandbox.save(TaskStoreFile(didSeedTasks: false, tasks: [existing]))
    let store = makeStore(makeState(sandbox: sandbox, directories: [directory]), sandbox: sandbox)

    await store.send(.tasks(.load))
    await store.receive(\.tasks.loaded)
    await store.receive(\.tasks.seedIfNeeded)
    await store.finish()

    #expect(store.state.taskRecords.map(\.id) == [existing.id])
    // Nothing was seeded, so the flag stays down and a later launch with real
    // evidence can still seed.
    #expect(!store.state.didSeedTasks)
  }

  /// An unreadable `tasks.json` must never be treated as a fresh install: no
  /// seed, and no save that would overwrite the bytes we failed to read.
  @Test func unreadableStoreDisablesSeedingAndSaving() async throws {
    let sandbox = try Sandbox()
    let directory = try sandbox.makeDirectory("fresh", activityAt: Self.freshDate)
    var state = makeState(sandbox: sandbox, directories: [directory])
    state.taskRecords = [makeRecord(directory: directory)]
    state.applyPostReduceCacheRecomputes(.all)
    let unreadable = SettingsFileStorage(
      load: { _ in throw CocoaError(.fileReadNoPermission) },
      save: { _, _ in
        Issue.record("A save must not follow an unreadable load.")
      },
      moveAside: { _, _ in }
    )
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    } withDependencies: {
      $0.settingsFileStorage = unreadable
      $0.date.now = Self.now
    }
    store.exhaustivity = .off

    await store.send(.tasks(.load))
    await store.receive(\.tasks.loaded)
    await store.finish()

    #expect(store.state.isTaskPersistenceDisabled)
    #expect(!store.state.didSeedTasks)
    // Seeding stays disabled, and a lifecycle mutation writes nothing (the
    // storage's `save` records an issue if it is reached).
    await store.send(.tasks(.seedIfNeeded))
    await store.send(.tasks(.settle(store.state.taskRecords[0].id)))
    await store.finish()
  }

  // MARK: - A6 / A7: settle

  /// A6: sole owner of the directory → lifecycle moves and the owned tabs are
  /// asked to hibernate. A7: the request carries every other task's surfaces so
  /// the parent can subtract their tabs.
  @Test func settlingASoleOwnerStampsSettledAtAndRequestsHibernation() async throws {
    let sandbox = try Sandbox()
    let mine = try sandbox.makeDirectory("mine", activityAt: Self.freshDate)
    let theirs = try sandbox.makeDirectory("theirs", activityAt: Self.freshDate)
    let mySurface = UUID()
    let theirSurface = UUID()
    var state = makeState(
      sandbox: sandbox,
      directories: [mine, theirs],
      surfacesPerRow: [mine: [mySurface], theirs: [theirSurface]]
    )
    let myTask = makeRecord(directory: mine, surfaceIDs: [mySurface])
    let otherTask = makeRecord(directory: theirs, surfaceIDs: [theirSurface])
    state.taskRecords = [myTask, otherTask]
    state.applyPostReduceCacheRecomputes(.all)
    let priorSidebar = state.sidebar
    let store = makeStore(state, sandbox: sandbox)

    await store.send(.tasks(.settle(myTask.id)))
    await store.receive(\.delegate.hibernateTaskSurfaces)
    await store.finish()

    #expect(store.state.taskRecords[id: myTask.id]?.settledAt == Self.now)
    // A11: settling writes `tasks.json` only — `sidebar.json` is untouched.
    #expect(store.state.sidebar == priorSidebar)
    #expect(store.state.tasksSidebarStructure.activeTaskIDs == [otherTask.id])
    #expect(store.state.tasksSidebarStructure.settledTotalCount == 1)
    // The other task's record is untouched.
    #expect(store.state.taskRecords[id: otherTask.id] == otherTask)
  }

  /// A7, at the payload level: the hibernation request targets exactly this
  /// task's surfaces and protects every other task's.
  @Test func hibernationRequestTargetsOnlyOwnedSurfaces() throws {
    let sandbox = try Sandbox()
    let mine = try sandbox.makeDirectory("mine", activityAt: Self.freshDate)
    let theirs = try sandbox.makeDirectory("theirs", activityAt: Self.freshDate)
    let mySurfaces: Set<UUID> = [UUID(), UUID()]
    let theirSurfaces: Set<UUID> = [UUID()]
    var state = makeState(
      sandbox: sandbox,
      directories: [mine, theirs],
      surfacesPerRow: [mine: mySurfaces, theirs: theirSurfaces]
    )
    let myTask = makeRecord(directory: mine, surfaceIDs: mySurfaces)
    state.taskRecords = [myTask, makeRecord(directory: theirs, surfaceIDs: theirSurfaces)]

    let delegate = try #require(state.taskHibernationDelegate(for: myTask))

    guard case .hibernateTaskSurfaces(let worktreeID, let surfaceIDs, let protectedSurfaceIDs) = delegate
    else {
      Issue.record("Expected a hibernation delegate, got \(delegate).")
      return
    }
    #expect(worktreeID == WorktreeID(mine.path(percentEncoded: false)))
    #expect(surfaceIDs == mySurfaces)
    #expect(protectedSurfaceIDs == theirSurfaces)
    #expect(surfaceIDs.isDisjoint(with: protectedSurfaceIDs))
  }

  /// A6, shared-directory half: two live tasks on one directory → the lifecycle
  /// moves but no hibernation is requested, because hibernation is still
  /// worktree/tab-keyed and would take the other task's sessions with it.
  @Test func settlingASharedDirectoryDefersHibernation() async throws {
    let sandbox = try Sandbox()
    let shared = try sandbox.makeDirectory("shared", activityAt: Self.freshDate)
    let surfaceID = UUID()
    var state = makeState(sandbox: sandbox, directories: [shared], surfacesPerRow: [shared: [surfaceID]])
    let first = makeRecord(directory: shared, surfaceIDs: [surfaceID])
    let second = makeRecord(directory: shared)
    state.taskRecords = [first, second]
    state.applyPostReduceCacheRecomputes(.all)
    let store = makeStore(state, sandbox: sandbox)

    await store.send(.tasks(.settle(first.id)))
    await store.finish()

    #expect(store.state.taskRecords[id: first.id]?.settledAt == Self.now)
    #expect(store.state.taskHibernationDelegate(for: first) == nil)
    // Both tasks keep every surface they owned.
    #expect(store.state.taskRecords[id: first.id]?.surfaceIDs == [surfaceID])
    #expect(store.state.taskRecords[id: second.id] == second)
  }

  /// Settling the *last* live task on a shared directory may hibernate again:
  /// the other owner is already settled, so nothing live is left to protect.
  @Test func settlingTheLastLiveOwnerOfASharedDirectoryHibernates() throws {
    let sandbox = try Sandbox()
    let shared = try sandbox.makeDirectory("shared", activityAt: Self.freshDate)
    let surfaceID = UUID()
    var state = makeState(sandbox: sandbox, directories: [shared], surfacesPerRow: [shared: [surfaceID]])
    let live = makeRecord(directory: shared, surfaceIDs: [surfaceID])
    state.taskRecords = [live, makeRecord(directory: shared, settledAt: Self.freshDate)]

    #expect(state.taskHibernationDelegate(for: live) != nil)
  }

  @Test func unsettleRestoresATaskToActive() async throws {
    let sandbox = try Sandbox()
    let directory = try sandbox.makeDirectory("mine", activityAt: Self.freshDate)
    var state = makeState(sandbox: sandbox, directories: [directory])
    var record = makeRecord(directory: directory, settledAt: Self.staleDate)
    record.settledOverride = .settled
    state.taskRecords = [record]
    state.applyPostReduceCacheRecomputes(.all)
    let priorSidebar = state.sidebar
    let store = makeStore(state, sandbox: sandbox)

    await store.send(.tasks(.unsettle(record.id)))
    await store.finish()

    #expect(store.state.taskRecords[id: record.id]?.settledAt == nil)
    #expect(store.state.sidebar == priorSidebar)
    #expect(store.state.taskRecords[id: record.id]?.settledOverride == nil)
    #expect(store.state.tasksSidebarStructure.activeTaskIDs == [record.id])
    #expect(store.state.tasksSidebarStructure.settledTotalCount == 0)
    #expect(sandbox.loadFile()?.tasks.first?.settledAt == nil)
  }

  // MARK: - A5 / A11: selection

  @Test func selectingATaskStampsLastVisitedAndFocusesAnOwnedSurface() async throws {
    let sandbox = try Sandbox()
    let directory = try sandbox.makeDirectory("mine", activityAt: Self.freshDate)
    let surfaceID = UUID()
    var state = makeState(sandbox: sandbox, directories: [directory], surfacesPerRow: [directory: [surfaceID]])
    let record = makeRecord(directory: directory, surfaceIDs: [surfaceID])
    state.taskRecords = [record]
    state.selection = .worktree(WorktreeID(directory.path(percentEncoded: false)))
    let priorFocus = state.sidebar.focusedWorktreeID
    state.applyPostReduceCacheRecomputes(.all)
    let store = makeStore(state, sandbox: sandbox)

    await store.send(.tasks(.select(record.id)))
    await store.receive(\.selectionChanged)
    await store.receive(\.delegate.focusTaskSurface)
    await store.finish()

    #expect(store.state.taskRecords[id: record.id]?.lastVisitedAt == Self.now)
    #expect(store.state.selection == .task(record.id))
    #expect(store.state.selectedWorktreeID == nil)
    // A11: task operations leave `sidebar.json` alone.
    #expect(store.state.sidebar.focusedWorktreeID == priorFocus)
    #expect(sandbox.loadFile()?.tasks.first?.lastVisitedAt == Self.now)
  }

  /// Focus wakes a dormant tab, so browsing the settled tail must not request it.
  @Test func selectingASettledTaskDoesNotRequestFocus() throws {
    let sandbox = try Sandbox()
    let directory = try sandbox.makeDirectory("mine", activityAt: Self.freshDate)
    let surfaceID = UUID()
    var state = makeState(sandbox: sandbox, directories: [directory], surfacesPerRow: [directory: [surfaceID]])
    let record = makeRecord(directory: directory, surfaceIDs: [surfaceID], settledAt: Self.staleDate)
    state.taskRecords = [record]

    #expect(state.taskFocusDelegate(for: record.id) == nil)
  }

  /// A8's P1 form: the open task is pulled into a collapsed settled shelf.
  @Test func openSettledTaskStaysVisibleWithTheTailCollapsed() throws {
    let sandbox = try Sandbox()
    let directory = try sandbox.makeDirectory("mine", activityAt: Self.freshDate)
    var state = makeState(sandbox: sandbox, directories: [directory])
    let record = makeRecord(directory: directory, settledAt: Self.staleDate)
    state.taskRecords = [record]
    state.selection = .task(record.id)
    state.applyCacheRecomputes(.sidebarStructure)

    #expect(state.tasksSidebarStructure.visibleTaskIDs == [record.id])
    #expect(!state.isSettledTailExpanded)
  }

  // MARK: - A10b: ownership reconciliation

  @Test func reconciliationDropsMissingSurfacesWithoutDeletingTheTask() async throws {
    let sandbox = try Sandbox()
    let directory = try sandbox.makeDirectory("mine", activityAt: Self.freshDate)
    let liveSurface = UUID()
    let closedSurface = UUID()
    var state = makeState(
      sandbox: sandbox,
      directories: [directory],
      surfacesPerRow: [directory: [liveSurface]]
    )
    let record = makeRecord(directory: directory, surfaceIDs: [liveSurface, closedSurface])
    state.taskRecords = [record]
    state.applyPostReduceCacheRecomputes(.all)
    let store = makeStore(state, sandbox: sandbox)

    await store.send(.tasks(.reconcileSurfaceOwnership))
    await store.finish()

    #expect(store.state.taskRecords[id: record.id]?.surfaceIDs == [liveSurface])
    #expect(store.state.taskRecords.count == 1)
    #expect(sandbox.loadFile()?.tasks.first?.surfaceIDs == [liveSurface])
  }

  /// A directory whose worktree is gone has no authoritative row, so its claims
  /// are left alone — and the task survives either way.
  @Test func reconciliationKeepsClaimsForADirectoryWithNoRow() async throws {
    let sandbox = try Sandbox()
    let present = try sandbox.makeDirectory("present", activityAt: Self.freshDate)
    let vanished = try sandbox.makeDirectory("vanished", activityAt: Self.freshDate)
    var state = makeState(sandbox: sandbox, directories: [present])
    let orphan = makeRecord(directory: vanished, surfaceIDs: [UUID()])
    state.taskRecords = [orphan]
    state.applyPostReduceCacheRecomputes(.all)
    let store = makeStore(state, sandbox: sandbox)

    await store.send(.tasks(.reconcileSurfaceOwnership))
    await store.finish()

    #expect(store.state.taskRecords[id: orphan.id] == orphan)
  }

  /// A row that has not reported a terminal projection yet still carries the
  /// UUIDs restored from the last-quit layout, so it must not be believed.
  @Test func reconciliationIgnoresRowsWithoutATerminalProjection() throws {
    let sandbox = try Sandbox()
    let directory = try sandbox.makeDirectory("mine", activityAt: Self.freshDate)
    var state = makeState(sandbox: sandbox, directories: [directory])
    let record = makeRecord(directory: directory, surfaceIDs: [UUID()])
    state.taskRecords = [record]

    let didChange = state.reconcileTaskSurfaceOwnership()

    #expect(!didChange)
    #expect(state.taskRecords[id: record.id] == record)
  }

  // MARK: - A4 / A10: activity updates a leaf, never the order

  @Test func agentActivityUpdatesTheLeafAndLeavesTheStructureUnchanged() async throws {
    let sandbox = try Sandbox()
    let directory = try sandbox.makeDirectory("mine", activityAt: Self.freshDate)
    let surfaceID = UUID()
    var state = makeState(sandbox: sandbox, directories: [directory], surfacesPerRow: [directory: [surfaceID]])
    let record = makeRecord(directory: directory, surfaceIDs: [surfaceID])
    state.taskRecords = [record]
    state.applyPostReduceCacheRecomputes(.all)
    let store = makeStore(state, sandbox: sandbox)
    let structureBefore = store.state.tasksSidebarStructure
    let rowID = WorktreeID(directory.path(percentEncoded: false))
    let instance = AgentPresenceFeature.AgentInstance(agent: .claude, activity: .busy)

    await store.send(
      .sidebarItems(.element(id: rowID, action: .agentSnapshotChanged(.init(agents: [instance], isWorking: true))))
    )
    await store.finish()

    #expect(store.state.tasksSidebarStructure == structureBefore)
    #expect(store.state.taskLeaves[record.id]?.agentSnapshot.isWorking == true)
    #expect(store.state.taskLeaves[record.id]?.agentSnapshot.agents == [instance])
  }

  // MARK: - Paging

  @Test func expandingTheSettledTailPagesAndCollapsingResets() async throws {
    let sandbox = try Sandbox()
    let directory = try sandbox.makeDirectory("mine", activityAt: Self.freshDate)
    let store = makeStore(makeState(sandbox: sandbox, directories: [directory]), sandbox: sandbox)

    await store.send(.tasks(.setSettledTailExpanded(true)))
    #expect(store.state.isSettledTailExpanded)

    await store.send(.tasks(.expandSettledTail))
    #expect(
      store.state.settledTailVisibleCount
        == TasksSidebarStructure.expandedSettledVisibleCount(from: TasksSidebarStructure.settledTailInitialCount)
    )

    await store.send(.tasks(.setSettledTailExpanded(false)))
    #expect(store.state.settledTailVisibleCount == TasksSidebarStructure.settledTailInitialCount)
  }
}

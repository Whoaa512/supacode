import ComposableArchitecture
import Dependencies
import DependenciesTestSupport
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
@MainActor
struct RepositoriesFeatureTasksTests {
  private typealias Sandbox = TaskInboxSandbox
  private static let now = TaskInboxFixture.now
  private static let freshDate = TaskInboxFixture.freshDate
  private static let staleDate = TaskInboxFixture.staleDate

  // MARK: - Fixture

  private func makeSandbox() throws -> Sandbox {
    try Sandbox(name: "RepositoriesFeatureTasksTests")
  }

  private func makeState(
    sandbox: Sandbox,
    directories: [URL],
    surfacesPerRow: [URL: Set<UUID>] = [:]
  ) -> RepositoriesFeature.State {
    TaskInboxFixture.makeState(
      sandbox: sandbox,
      directories: directories,
      surfacesPerRow: surfacesPerRow
    )
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
      // `.loaded` arms the coarse re-classification loop (A23), so every test
      // that reaches it needs a clock to arm it against and a `.stopTimers` to
      // take it back down before `finish()`.
      $0.continuousClock = TestClock()
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
    createdAt: Date = TaskInboxFixture.freshDate
  ) -> TaskRecord {
    TaskInboxFixture.makeRecord(
      directory: directory,
      surfaceIDs: surfaceIDs,
      settledAt: settledAt,
      createdAt: createdAt
    )
  }

  // MARK: - A1 / A13: load, no bulk seed, idempotence

  /// Day-one bulk seeding is off: a fresh launch over live directories mints
  /// zero tasks and flips the seeded flag so no later build can bulk-seed either.
  /// Joining the inbox is a per-tab (promote) or per-task (⌘N) choice.
  @Test func loadMintsNoTasksAndFlipsTheSeededFlag() async throws {
    let sandbox = try makeSandbox()
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
    await store.send(.tasks(.stopTimers))
    await store.finish()

    #expect(store.state.taskRecords.isEmpty)
    #expect(store.state.didSeedTasks)
    // A11 / A13: the flag reached `tasks.json`, and nothing else did.
    let persisted = try #require(sandbox.loadFile())
    #expect(persisted.didSeedTasks)
    #expect(persisted.tasks.isEmpty)
  }

  /// A13: a second launch reads the flag and the records back and adds nothing.
  @Test func secondLaunchDoesNotReseed() async throws {
    let sandbox = try makeSandbox()
    let directory = try sandbox.makeDirectory("fresh", activityAt: Self.freshDate)
    let existing = makeRecord(directory: directory)
    try sandbox.save(TaskStoreFile(didSeedTasks: true, tasks: [existing]))
    let store = makeStore(makeState(sandbox: sandbox, directories: [directory]), sandbox: sandbox)

    await store.send(.tasks(.load))
    await store.receive(\.tasks.loaded)
    await store.receive(\.tasks.seedIfNeeded)
    await store.send(.tasks(.stopTimers))
    await store.finish()

    #expect(store.state.taskRecords.map(\.id) == [existing.id])
    #expect(store.state.didSeedTasks)
  }

  /// An upgrade from a build that wrote records with the flag still down keeps
  /// the records, mints nothing, and flips the flag.
  @Test func upgradeWithUnsetFlagKeepsRecordsAndMintsNothing() async throws {
    let sandbox = try makeSandbox()
    let directory = try sandbox.makeDirectory("fresh", activityAt: Self.freshDate)
    let existing = makeRecord(directory: directory)
    try sandbox.save(TaskStoreFile(didSeedTasks: false, tasks: [existing]))
    let store = makeStore(makeState(sandbox: sandbox, directories: [directory]), sandbox: sandbox)

    await store.send(.tasks(.load))
    await store.receive(\.tasks.loaded)
    await store.receive(\.tasks.seedIfNeeded)
    await store.send(.tasks(.stopTimers))
    await store.finish()

    #expect(store.state.taskRecords.map(\.id) == [existing.id])
    #expect(store.state.didSeedTasks)
    let persisted = try #require(sandbox.loadFile())
    #expect(persisted.didSeedTasks)
    #expect(persisted.tasks.map(\.id) == [existing.id])
  }

  /// An unreadable `tasks.json` must never be treated as a fresh install: no
  /// seed, and no save that would overwrite the bytes we failed to read.
  @Test func unreadableStoreDisablesSeedingAndSaving() async throws {
    let sandbox = try makeSandbox()
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
    let sandbox = try makeSandbox()
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
    // A11: the settle stamp survives the round-trip to disk.
    #expect(sandbox.loadFile()?.tasks.first { $0.id == myTask.id }?.settledAt == Self.now)
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
    let sandbox = try makeSandbox()
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

  /// A6 in full form: a shared directory no longer defers. Settling hibernates
  /// exactly the settling task's own surfaces and names the co-tenant's as
  /// protected, so the parent — which resolves surfaces to tabs — drops any tab
  /// the two share before it puts anything to sleep (A7).
  @Test func settlingASharedDirectoryHibernatesOnlyItsOwnSurfaces() async throws {
    let sandbox = try makeSandbox()
    let shared = try sandbox.makeDirectory("shared", activityAt: Self.freshDate)
    let mySurface = UUID()
    let theirSurface = UUID()
    var state = makeState(
      sandbox: sandbox,
      directories: [shared],
      surfacesPerRow: [shared: [mySurface, theirSurface]]
    )
    let first = makeRecord(directory: shared, surfaceIDs: [mySurface])
    let second = makeRecord(directory: shared, surfaceIDs: [theirSurface])
    state.taskRecords = [first, second]
    state.applyPostReduceCacheRecomputes(.all)
    let store = makeStore(state, sandbox: sandbox)

    await store.send(.tasks(.settle(first.id)))
    await store.receive(\.delegate.hibernateTaskSurfaces)
    await store.finish()

    #expect(store.state.taskRecords[id: first.id]?.settledAt == Self.now)
    // Both tasks keep every surface they owned.
    #expect(store.state.taskRecords[id: first.id]?.surfaceIDs == [mySurface])
    #expect(store.state.taskRecords[id: second.id] == second)

    let delegate = try #require(store.state.taskHibernationDelegate(for: first))
    guard case .hibernateTaskSurfaces(_, let surfaceIDs, let protectedSurfaceIDs) = delegate else {
      Issue.record("Expected a hibernation delegate, got \(delegate).")
      return
    }
    #expect(surfaceIDs == [mySurface])
    #expect(protectedSurfaceIDs == [theirSurface])
  }

  /// The A7 invariant restated for the case that used to be waived: settling one
  /// task on a shared directory leaves the co-tenant's claim, lifecycle and
  /// placement untouched, and never names its surfaces as a hibernation target.
  @Test func settlingASharedDirectoryNeverTargetsTheCoTenantsSurfaces() async throws {
    let sandbox = try makeSandbox()
    let shared = try sandbox.makeDirectory("shared", activityAt: Self.freshDate)
    let mySurfaces: Set<UUID> = [UUID(), UUID()]
    let theirSurfaces: Set<UUID> = [UUID()]
    var state = makeState(
      sandbox: sandbox,
      directories: [shared],
      surfacesPerRow: [shared: mySurfaces.union(theirSurfaces)]
    )
    let first = makeRecord(directory: shared, surfaceIDs: mySurfaces)
    let second = makeRecord(directory: shared, surfaceIDs: theirSurfaces)
    state.taskRecords = [first, second]
    state.applyPostReduceCacheRecomputes(.all)
    let store = makeStore(state, sandbox: sandbox)

    await store.send(.tasks(.settle(first.id)))
    await store.receive(\.delegate.hibernateTaskSurfaces)
    await store.finish()

    #expect(store.state.taskRecords[id: second.id] == second)
    #expect(store.state.tasksSidebarStructure.activeTaskIDs == [second.id])

    let delegate = try #require(store.state.taskHibernationDelegate(for: first))
    guard case .hibernateTaskSurfaces(_, let surfaceIDs, let protectedSurfaceIDs) = delegate else {
      Issue.record("Expected a hibernation delegate, got \(delegate).")
      return
    }
    #expect(surfaceIDs.isDisjoint(with: theirSurfaces))
    #expect(protectedSurfaceIDs == theirSurfaces)
  }

  /// The one thing a shared directory still defers: nobody may delete a
  /// directory another live task is standing in, so the auto-managed cleanup
  /// keeps the sole-owner guard the hibernation path just retired.
  @Test func settlingASharedDirectoryStillDefersAutoManagedCleanup() throws {
    let sandbox = try makeSandbox()
    let shared = try sandbox.makeDirectory("shared", activityAt: Self.freshDate)
    var state = makeState(sandbox: sandbox, directories: [shared])
    var first = makeRecord(directory: shared)
    first.autoManagedWorktree = TaskRecord.AutoManagedWorktree(
      path: shared.path(percentEncoded: false),
      branch: "task/shared",
      createdAt: Self.now
    )
    let second = makeRecord(directory: shared)
    state.taskRecords = [first, second]
    state.applyPostReduceCacheRecomputes(.all)

    #expect(state.isSoleActiveTaskOwner(of: first) == false)
  }

  /// Settling the *last* live task on a shared directory may hibernate again:
  /// the other owner is already settled, so nothing live is left to protect.
  @Test func settlingTheLastLiveOwnerOfASharedDirectoryHibernates() throws {
    let sandbox = try makeSandbox()
    let shared = try sandbox.makeDirectory("shared", activityAt: Self.freshDate)
    let surfaceID = UUID()
    var state = makeState(sandbox: sandbox, directories: [shared], surfacesPerRow: [shared: [surfaceID]])
    let live = makeRecord(directory: shared, surfaceIDs: [surfaceID])
    state.taskRecords = [live, makeRecord(directory: shared, settledAt: Self.freshDate)]

    #expect(state.taskHibernationDelegate(for: live) != nil)
  }

  @Test func unsettleRestoresATaskToActive() async throws {
    let sandbox = try makeSandbox()
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

  // MARK: - A37: title search

  /// The wiring half of A37: the query lands in state, the cached structure
  /// narrows, and clearing it puts the whole list back — no reload, no reorder.
  @Test func searchNarrowsTheCachedStructureAndClearingRestoresIt() async throws {
    let sandbox = try makeSandbox()
    let mine = try sandbox.makeDirectory("mine", activityAt: Self.freshDate)
    let theirs = try sandbox.makeDirectory("theirs", activityAt: Self.freshDate)
    var state = makeState(sandbox: sandbox, directories: [mine, theirs])
    var hit = makeRecord(directory: mine)
    hit.title = "Ship the inbox"
    var miss = makeRecord(directory: theirs)
    miss.title = "Unrelated errand"
    state.taskRecords = [hit, miss]
    state.applyPostReduceCacheRecomputes(.all)
    let store = makeStore(state, sandbox: sandbox)
    let unfiltered = store.state.tasksSidebarStructure

    await store.send(.tasks(.setSearchQuery("inbox")))
    #expect(store.state.taskSearchQuery == "inbox")
    #expect(store.state.tasksSidebarStructure.visibleTaskIDs == [hit.id])
    #expect(store.state.tasksSidebarStructure.isSearching)

    await store.send(.tasks(.setSearchQuery("")))
    await store.finish()

    #expect(store.state.tasksSidebarStructure == unfiltered)
    #expect(store.state.tasksSidebarStructure.isSearching == false)
  }

  /// Search is presentation, not lifecycle: it must never write a record or
  /// touch `tasks.json`. The sandbox's save spy is what proves the second half.
  @Test func searchDoesNotSelectOrPersistAnything() async throws {
    let sandbox = try makeSandbox()
    let mine = try sandbox.makeDirectory("mine", activityAt: Self.freshDate)
    var state = makeState(sandbox: sandbox, directories: [mine])
    var record = makeRecord(directory: mine)
    record.title = "Ship the inbox"
    state.taskRecords = [record]
    state.applyPostReduceCacheRecomputes(.all)
    let store = makeStore(state, sandbox: sandbox)
    let priorSelection = store.state.selection

    await store.send(.tasks(.setSearchQuery("nothing matches this")))
    await store.finish()

    #expect(store.state.tasksSidebarStructure.visibleTaskIDs.isEmpty)
    #expect(store.state.taskRecords[id: record.id] == record)
    #expect(store.state.selection == priorSelection)
    #expect(sandbox.didWriteTasksFile == false)
  }

  /// Search rebuilds the structure but must not re-time it: `taskNow` is the
  /// instant every placement rule is evaluated against (A23), so stamping it per
  /// keystroke would age the inbox while the user types — rows receding and
  /// countdowns ticking in response to a search field.
  @Test func searchDoesNotMoveTheClockTheInboxIsClassifiedAgainst() async throws {
    let sandbox = try makeSandbox()
    let mine = try sandbox.makeDirectory("mine", activityAt: Self.freshDate)
    var state = makeState(sandbox: sandbox, directories: [mine])
    var record = makeRecord(directory: mine)
    record.title = "Ship the inbox"
    state.taskRecords = [record]
    // Deliberately behind the store's `date.now`, so a stamp is visible.
    let stale = Self.now.addingTimeInterval(-60 * 60)
    state.taskNow = stale
    state.applyPostReduceCacheRecomputes(.all)
    let store = makeStore(state, sandbox: sandbox)

    await store.send(.tasks(.setSearchQuery("inbox")))
    await store.send(.tasks(.setSnoozedShelfExpanded(true)))
    await store.send(.tasks(.setSettledTailExpanded(true)))
    await store.finish()

    #expect(store.state.taskNow == stale)

    // The lifecycle arms still re-time, or a settle would classify against a
    // clock the user's last keystroke froze.
    await store.send(.tasks(.pin(record.id)))
    await store.send(.tasks(.stopTimers))
    await store.finish()

    #expect(store.state.taskNow == Self.now)
  }

  /// The selection survives a query it does not match (A8), so clearing the
  /// field leaves the user standing exactly where they started.
  @Test func searchKeepsTheOpenTaskVisibleAndSelected() async throws {
    let sandbox = try makeSandbox()
    let mine = try sandbox.makeDirectory("mine", activityAt: Self.freshDate)
    let theirs = try sandbox.makeDirectory("theirs", activityAt: Self.freshDate)
    var state = makeState(sandbox: sandbox, directories: [mine, theirs])
    var open = makeRecord(directory: mine)
    open.title = "Unrelated errand"
    var other = makeRecord(directory: theirs)
    other.title = "Ship the inbox"
    state.taskRecords = [open, other]
    state.applyPostReduceCacheRecomputes(.all)
    let store = makeStore(state, sandbox: sandbox)

    await store.send(.tasks(.select(open.id)))
    await store.send(.tasks(.setSearchQuery("inbox")))
    await store.send(.tasks(.stopTimers))
    await store.finish()

    #expect(store.state.selection?.taskID == open.id)
    #expect(store.state.tasksSidebarStructure.visibleTaskIDs.contains(open.id))
  }

  // MARK: - A5 / A11: selection

  @Test func selectingATaskStampsLastVisitedAndFocusesAnOwnedSurface() async throws {
    let sandbox = try makeSandbox()
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
    // The detail pane mounts the task's owning worktree through this cache;
    // without it a task selection renders the app-wide empty state.
    #expect(store.state.taskDetailWorktreeID == WorktreeID(directory.path(percentEncoded: false)))
    // A11: task operations leave `sidebar.json` alone.
    #expect(store.state.sidebar.focusedWorktreeID == priorFocus)
    #expect(sandbox.loadFile()?.tasks.first?.lastVisitedAt == Self.now)
  }

  /// A settled task must not mount a terminal either — focusing or rendering
  /// one would wake dormant sessions just by browsing the tail.
  @Test func settledTaskSelectionLeavesDetailWorktreeEmpty() throws {
    let sandbox = try makeSandbox()
    let directory = try sandbox.makeDirectory("mine", activityAt: Self.freshDate)
    let surfaceID = UUID()
    var state = makeState(
      sandbox: sandbox,
      directories: [directory],
      surfacesPerRow: [directory: [surfaceID]]
    )
    let record = makeRecord(directory: directory, surfaceIDs: [surfaceID], settledAt: Self.staleDate)
    state.taskRecords = [record]
    state.selection = .task(record.id)
    state.applyPostReduceCacheRecomputes(.all)

    #expect(state.taskDetailWorktreeID == nil)
  }

  /// Focus wakes a dormant tab, so browsing the settled tail must not request it.
  @Test func selectingASettledTaskDoesNotRequestFocus() throws {
    let sandbox = try makeSandbox()
    let directory = try sandbox.makeDirectory("mine", activityAt: Self.freshDate)
    let surfaceID = UUID()
    var state = makeState(sandbox: sandbox, directories: [directory], surfacesPerRow: [directory: [surfaceID]])
    let record = makeRecord(directory: directory, surfaceIDs: [surfaceID], settledAt: Self.staleDate)
    state.taskRecords = [record]

    #expect(state.taskFocusDelegate(for: record.id) == nil)
  }

  /// A8's P1 form: the open task is pulled into a collapsed settled shelf.
  @Test func openSettledTaskStaysVisibleWithTheTailCollapsed() throws {
    let sandbox = try makeSandbox()
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
    let sandbox = try makeSandbox()
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
    let sandbox = try makeSandbox()
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

  /// B1: restore emits one projection per tab, and `hasTerminalProjection` latches
  /// on the first one, so reconciling against the live projection alone would prune
  /// the tabs that have not been rebuilt yet — and persist the loss. The layouts
  /// snapshot knows every tab, so ownership must survive an incremental restore.
  @Test(.dependencies) func incrementalRestoreProjectionsNeverShrinkOwnership() async throws {
    let sandbox = try makeSandbox()
    let directory = try sandbox.makeDirectory("mine", activityAt: Self.freshDate)
    let rowID = WorktreeID(directory.path(percentEncoded: false))
    let tabSurfaces = [UUID(), UUID(), UUID()]
    try sandbox.seedLayout(worktreeID: rowID, tabSurfaceIDs: tabSurfaces)
    var state = makeState(sandbox: sandbox, directories: [directory])
    let record = makeRecord(directory: directory, surfaceIDs: Set(tabSurfaces))
    state.taskRecords = [record]
    state.applyPostReduceCacheRecomputes(.all)
    let store = makeStore(state, sandbox: sandbox)

    // Tab 1 restores, then 2, then 3 — one projection each, cumulative.
    for count in 1...tabSurfaces.count {
      await store.send(
        .sidebarItems(
          .element(
            id: rowID,
            action: .terminalProjectionChanged(
              WorktreeRowProjection(
                surfaceIDs: Array(tabSurfaces.prefix(count)),
                isProgressBusy: false,
                hasUnseenNotifications: false,
                notifications: []
              )
            )
          )
        )
      )
      await store.receive(\.tasks.reconcileSurfaceOwnership)
      await store.finish()
      #expect(store.state.taskRecords[id: record.id]?.surfaceIDs == Set(tabSurfaces))
    }
  }

  /// The other half of B1: a genuinely closed tab leaves both the projection and
  /// the rewritten layout, so exactly that tab's surface is pruned.
  @Test(.dependencies) func closingATabPrunesOnlyThatTabsSurfaces() async throws {
    let sandbox = try makeSandbox()
    let directory = try sandbox.makeDirectory("mine", activityAt: Self.freshDate)
    let rowID = WorktreeID(directory.path(percentEncoded: false))
    let surviving = [UUID(), UUID()]
    let closed = UUID()
    // Closing a tab marks the layout dirty, so the snapshot on disk no longer
    // mentions it while the surviving tabs are still listed.
    try sandbox.seedLayout(worktreeID: rowID, tabSurfaceIDs: surviving)
    var state = makeState(sandbox: sandbox, directories: [directory])
    let record = makeRecord(directory: directory, surfaceIDs: Set(surviving + [closed]))
    state.taskRecords = [record]
    state.applyPostReduceCacheRecomputes(.all)
    let store = makeStore(state, sandbox: sandbox)

    await store.send(
      .sidebarItems(
        .element(
          id: rowID,
          action: .terminalProjectionChanged(
            WorktreeRowProjection(
              surfaceIDs: [surviving[0]],
              isProgressBusy: false,
              hasUnseenNotifications: false,
              notifications: []
            )
          )
        )
      )
    )
    await store.receive(\.tasks.reconcileSurfaceOwnership)
    await store.finish()

    #expect(store.state.taskRecords[id: record.id]?.surfaceIDs == Set(surviving))
    #expect(store.state.taskRecords.count == 1)
  }

  /// A row that has not reported a terminal projection yet still carries the
  /// UUIDs restored from the last-quit layout, so it must not be believed.
  @Test func reconciliationIgnoresRowsWithoutATerminalProjection() throws {
    let sandbox = try makeSandbox()
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
    let sandbox = try makeSandbox()
    let directory = try sandbox.makeDirectory("mine", activityAt: Self.freshDate)
    let surfaceID = UUID()
    var state = makeState(sandbox: sandbox, directories: [directory], surfacesPerRow: [directory: [surfaceID]])
    let record = makeRecord(directory: directory, surfaceIDs: [surfaceID])
    state.taskRecords = [record]
    state.applyPostReduceCacheRecomputes(.all)
    let store = makeStore(state, sandbox: sandbox)
    let structureBefore = store.state.tasksSidebarStructure
    let instance = AgentPresenceFeature.AgentInstance(agent: .claude, activity: .busy)

    await store.send(
      .tasks(.agentSnapshotChanged(taskID: record.id, snapshot: .init(agents: [instance], isWorking: true)))
    )
    await store.finish()

    #expect(store.state.tasksSidebarStructure == structureBefore)
    #expect(store.state.taskLeaves[id: record.id]?.agentSnapshot.isWorking == true)
    #expect(store.state.taskLeaves[id: record.id]?.agentSnapshot.agents == [instance])
  }

  /// A10's state half: a `TaskSidebarRowView` body reads exactly its own
  /// `taskRecords[id:]` and `taskLeaves[id:]`, and the panel body reads only
  /// `tasksSidebarStructure`. So "a tick can't reach a sibling row" reduces to a
  /// claim about state: after an agent tick on one task, every *other* task's
  /// record and leaf must be byte-identical and the cached structure unchanged.
  /// If any of those moved, a sibling row's inputs moved with it.
  ///
  /// Deliberately not asserted via `withObservationTracking` on `store.state`:
  /// that observes a value copy of the reducer's state and reports on TCA's
  /// registrar plumbing rather than on this design. The SwiftUI half (actual
  /// body evaluation counts) is verified manually through
  /// `TaskRowBodyEvalCounter` — steps documented on that type.
  @Test func anAgentTickLeavesEverySiblingTasksRowInputsUntouched() async throws {
    let sandbox = try makeSandbox()
    let mine = try sandbox.makeDirectory("mine", activityAt: Self.freshDate)
    let other = try sandbox.makeDirectory("other", activityAt: Self.freshDate)
    let mineSurface = UUID()
    let otherSurface = UUID()
    var state = makeState(
      sandbox: sandbox,
      directories: [mine, other],
      surfacesPerRow: [mine: [mineSurface], other: [otherSurface]]
    )
    let mineRecord = makeRecord(directory: mine, surfaceIDs: [mineSurface])
    let otherRecord = makeRecord(directory: other, surfaceIDs: [otherSurface])
    state.taskRecords = [mineRecord, otherRecord]
    state.applyPostReduceCacheRecomputes(.all)
    let store = makeStore(state, sandbox: sandbox)
    #expect(store.state.taskLeaves.count == 2)

    let structureBefore = store.state.tasksSidebarStructure
    let otherLeafBefore = store.state.taskLeaves[id: otherRecord.id]

    await store.send(
      .tasks(.agentSnapshotChanged(taskID: mineRecord.id, snapshot: .init(agents: [], isWorking: true)))
    )
    await store.finish()

    #expect(store.state.taskLeaves[id: mineRecord.id]?.agentSnapshot.isWorking == true)
    // The sibling's row inputs: leaf, record, and the order/label plan.
    #expect(store.state.taskLeaves[id: otherRecord.id] == otherLeafBefore)
    #expect(store.state.taskRecords[id: otherRecord.id] == otherRecord)
    #expect(store.state.tasksSidebarStructure == structureBefore)
  }

  /// m9: settling twice must not re-stamp `settledAt` — the settled tail sorts by
  /// it, so a double settle would jump the task back to the head of the tail.
  @Test func settlingAnAlreadySettledTaskIsANoop() async throws {
    let sandbox = try makeSandbox()
    let directory = try sandbox.makeDirectory("mine", activityAt: Self.freshDate)
    var state = makeState(sandbox: sandbox, directories: [directory])
    let record = makeRecord(directory: directory, settledAt: Self.staleDate)
    state.taskRecords = [record]
    state.applyPostReduceCacheRecomputes(.all)
    let store = makeStore(state, sandbox: sandbox)

    await store.send(.tasks(.settle(record.id)))
    await store.finish()

    #expect(store.state.taskRecords[id: record.id]?.settledAt == Self.staleDate)
  }

  /// M4: the stamp lives in the selection arm, so a selection that arrives without
  /// going through `.tasks(.select)` (list view, hotkey, forward nav) still marks
  /// the task visited.
  @Test func directSelectionChangedStampsLastVisited() async throws {
    let sandbox = try makeSandbox()
    let directory = try sandbox.makeDirectory("mine", activityAt: Self.freshDate)
    var state = makeState(sandbox: sandbox, directories: [directory])
    let record = makeRecord(directory: directory)
    state.taskRecords = [record]
    state.applyPostReduceCacheRecomputes(.all)
    let store = makeStore(state, sandbox: sandbox)

    await store.send(.selectionChanged([.task(record.id)]))
    await store.finish()

    #expect(store.state.selection == .task(record.id))
    #expect(store.state.taskRecords[id: record.id]?.lastVisitedAt == Self.now)
    #expect(sandbox.loadFile()?.tasks.first?.lastVisitedAt == Self.now)
  }

  // MARK: - Paging

  @Test func expandingTheSettledTailPagesAndCollapsingResets() async throws {
    let sandbox = try makeSandbox()
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

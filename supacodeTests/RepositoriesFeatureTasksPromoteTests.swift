import ComposableArchitecture
import Dependencies
import DependenciesTestSupport
import Foundation
import IdentifiedCollections
import Sharing
import Testing

@testable import SupacodeSettingsShared
@testable import supacode

/// Phase-3 promote-tab-to-task contract: assertions A3 and A21 of
/// `plans/task-inbox-sidebar-plan.md`.
///
/// Claims are made at *tab* granularity (plan Resolved #10): promoting a tab
/// claims every surface in its split tree, so a tab can never hold two tasks'
/// surfaces. The reducer's only tab-to-surface map is the persisted layout
/// snapshot (`@SharedReader(.layouts)`), which is what these tests seed.
///
/// The claim rule the suite locks, in order:
/// 1. Resolve the row and the tab's surfaces; nothing resolvable → no-op.
/// 2. `target` = the directory's newest-created *active* task, if any.
/// 3. `target` already owns every one of those surfaces → no-op (A21:
///    re-promotion duplicates nothing).
/// 4. Otherwise the surfaces are stripped from every other task (explicit user
///    intent beats stale ownership, A3's "transfers deterministically") and
///    either joined onto `target` or given to a fresh active record.
@MainActor
struct RepositoriesFeatureTasksPromoteTests {
  private typealias Sandbox = TaskInboxSandbox
  private static let now = TaskInboxFixture.now
  private static let earlier = now.addingTimeInterval(-7200)
  private static let freshDate = TaskInboxFixture.freshDate
  private static let staleDate = TaskInboxFixture.staleDate

  // MARK: - Fixture

  private func makeSandbox() throws -> Sandbox {
    try Sandbox(name: "RepositoriesFeatureTasksPromoteTests")
  }

  private func makeState(
    sandbox: Sandbox,
    directories: [URL],
    surfacesPerRow: [URL: Set<UUID>] = [:]
  ) -> RepositoriesFeature.State {
    TaskInboxFixture.makeState(
      sandbox: sandbox,
      directories: directories,
      surfacesPerRow: surfacesPerRow,
      hasLoadedTasks: true
    )
  }

  /// What the *live* terminal reports for each tab. Every test states it
  /// explicitly: the arm resolves its target through `TerminalClient`, never
  /// through the persisted layout's `selectedTabIndex`, so a fixture that only
  /// seeded `layouts.json` would be describing the wrong world.
  private func liveTabs(_ tabs: (id: TerminalTabID, surfaceIDs: [UUID])...) -> [TerminalTabID: Set<UUID>] {
    Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, Set($0.surfaceIDs)) })
  }

  private func makeStore(
    _ state: RepositoriesFeature.State,
    sandbox: Sandbox,
    liveTabs: [TerminalTabID: Set<UUID>] = [:],
    selectedTabID: TerminalTabID? = nil,
    storage: SettingsFileStorage? = nil
  ) -> TestStoreOf<RepositoriesFeature> {
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    } withDependencies: {
      $0.settingsFileStorage = storage ?? sandbox.storage
      $0.date.now = Self.now
      $0.terminalClient.selectedTabID = { _ in selectedTabID }
      $0.terminalClient.tabSurfaceIDs = { _, tabID in liveTabs[tabID] ?? [] }
    }
    store.exhaustivity = .off
    return store
  }

  private func makeRecord(
    directory: URL,
    id: TaskID = TaskID(),
    surfaceIDs: Set<UUID> = [],
    settledAt: Date? = nil,
    createdAt: Date = TaskInboxFixture.freshDate
  ) -> TaskRecord {
    TaskInboxFixture.makeRecord(
      directory: directory,
      id: id,
      surfaceIDs: surfaceIDs,
      settledAt: settledAt,
      createdAt: createdAt
    )
  }

  // MARK: - Creation

  /// A directory with no task at all: promoting one tab mints an active record
  /// that owns exactly that tab's split tree — not the neighbouring tab's
  /// surfaces, which is the whole point of tab granularity (Resolved #10).
  @Test(.dependencies) func promotingATabInAFreshDirectoryCreatesAnActiveTask() async throws {
    let sandbox = try makeSandbox()
    let directory = try sandbox.makeDirectory("mine")
    let rowID = WorktreeID(directory.path(percentEncoded: false))
    let claimed = (id: TerminalTabID(), surfaceIDs: [UUID(), UUID()])
    let untouched = (id: TerminalTabID(), surfaceIDs: [UUID()])
    try sandbox.seedLayout(worktreeID: rowID, tabs: [claimed, untouched])
    let state = makeState(
      sandbox: sandbox,
      directories: [directory],
      surfacesPerRow: [directory: Set(claimed.surfaceIDs + untouched.surfaceIDs)]
    )
    let store = makeStore(state, sandbox: sandbox, liveTabs: liveTabs(claimed, untouched))

    await store.send(.tasks(.promoteTab(worktreeID: rowID, tabID: claimed.id)))
    await store.finish()

    #expect(store.state.taskRecords.count == 1)
    let record = try #require(store.state.taskRecords.first)
    #expect(record.surfaceIDs == Set(claimed.surfaceIDs))
    #expect(record.directoryPath == TaskDirectoryPath.canonical(directory))
    #expect(record.createdAt == Self.now)
    #expect(record.settledAt == nil)
    #expect(record.settledOverride == nil)
    // The user asked for this by hand, so the evidence is not inferred (A2).
    #expect(record.seedEvidence == TaskRecord.SeedEvidence(source: .manual, confidence: .high))
    #expect(record.repositoryID == RepositoryID(sandbox.rootURL.path(percentEncoded: false)))
    // Title cascade (Resolved #15) with no customization: the worktree name.
    #expect(record.title == directory.lastPathComponent)
    #expect(store.state.tasksSidebarStructure.activeTaskIDs == [record.id])
    #expect(sandbox.loadFile()?.tasks.map(\.id) == [record.id])
  }

  /// Same cascade the seeder uses: a customization title wins, and the branch is
  /// recorded only when the row proves one (A2).
  @Test(.dependencies) func promotingTakesTheRowsCustomTitleAndProvableBranch() async throws {
    let sandbox = try makeSandbox()
    let directory = try sandbox.makeDirectory("mine")
    let rowID = WorktreeID(directory.path(percentEncoded: false))
    let tab = (id: TerminalTabID(), surfaceIDs: [UUID()])
    try sandbox.seedLayout(worktreeID: rowID, tabs: [tab])
    var state = makeState(
      sandbox: sandbox,
      directories: [directory],
      surfacesPerRow: [directory: Set(tab.surfaceIDs)]
    )
    state.sidebarItems[id: rowID]?.customTitle = "Ship the inbox"
    state.sidebarItems[id: rowID]?.branchName = "feature/inbox"
    state.sidebarItems[id: rowID]?.isAttached = true
    state.applyPostReduceCacheRecomputes(.all)
    let store = makeStore(state, sandbox: sandbox, liveTabs: liveTabs(tab))

    await store.send(.tasks(.promoteTab(worktreeID: rowID, tabID: tab.id)))
    await store.finish()

    let record = try #require(store.state.taskRecords.first)
    #expect(record.title == "Ship the inbox")
    #expect(record.branch == "feature/inbox")
  }

  /// A detached HEAD has no provable branch, so the record carries none rather
  /// than a guess (A2).
  @Test(.dependencies) func promotingADetachedRowRecordsNoBranch() async throws {
    let sandbox = try makeSandbox()
    let directory = try sandbox.makeDirectory("mine")
    let rowID = WorktreeID(directory.path(percentEncoded: false))
    let tab = (id: TerminalTabID(), surfaceIDs: [UUID()])
    try sandbox.seedLayout(worktreeID: rowID, tabs: [tab])
    var state = makeState(
      sandbox: sandbox,
      directories: [directory],
      surfacesPerRow: [directory: Set(tab.surfaceIDs)]
    )
    state.sidebarItems[id: rowID]?.branchName = "detached-at-abc123"
    state.sidebarItems[id: rowID]?.isAttached = false
    state.applyPostReduceCacheRecomputes(.all)
    let store = makeStore(state, sandbox: sandbox, liveTabs: liveTabs(tab))

    await store.send(.tasks(.promoteTab(worktreeID: rowID, tabID: tab.id)))
    await store.finish()

    let record = try #require(store.state.taskRecords.first)
    #expect(record.branch == nil)
    // The claim still lands: a missing branch is a missing field, not a refusal.
    #expect(record.surfaceIDs == Set(tab.surfaceIDs))
  }

  /// Promoting with no tab id claims the tab the worktree has selected *now*.
  ///
  /// The persisted snapshot deliberately disagrees: it still names tab 0, which
  /// is what `layouts.json` looks like any time the user switches tabs between
  /// saves (it is rewritten only on background / quit). Reading the selection
  /// from the snapshot would claim the wrong tab on every such click.
  @Test(.dependencies) func promotingWithoutATabIDClaimsTheLiveSelectedTab() async throws {
    let sandbox = try makeSandbox()
    let directory = try sandbox.makeDirectory("mine")
    let rowID = WorktreeID(directory.path(percentEncoded: false))
    let first = (id: TerminalTabID(), surfaceIDs: [UUID()])
    let selected = (id: TerminalTabID(), surfaceIDs: [UUID(), UUID()])
    try sandbox.seedLayout(worktreeID: rowID, tabs: [first, selected], selectedTabIndex: 0)
    let state = makeState(
      sandbox: sandbox,
      directories: [directory],
      surfacesPerRow: [directory: Set(first.surfaceIDs + selected.surfaceIDs)]
    )
    let store = makeStore(
      state,
      sandbox: sandbox,
      liveTabs: liveTabs(first, selected),
      selectedTabID: selected.id
    )

    await store.send(.tasks(.promoteTab(worktreeID: rowID, tabID: nil)))
    await store.finish()

    #expect(store.state.taskRecords.first?.surfaceIDs == Set(selected.surfaceIDs))
  }

  // MARK: - A3: joining, transfer, idempotence

  /// The directory already has an active task, so the claim joins it. A second
  /// task for one directory would split one problem across two rows.
  @Test(.dependencies) func promotingIntoADirectoryWithAnActiveTaskJoinsThatTask() async throws {
    let sandbox = try makeSandbox()
    let directory = try sandbox.makeDirectory("mine")
    let rowID = WorktreeID(directory.path(percentEncoded: false))
    let owned = (id: TerminalTabID(), surfaceIDs: [UUID()])
    let claimed = (id: TerminalTabID(), surfaceIDs: [UUID(), UUID()])
    try sandbox.seedLayout(worktreeID: rowID, tabs: [owned, claimed])
    var state = makeState(
      sandbox: sandbox,
      directories: [directory],
      surfacesPerRow: [directory: Set(owned.surfaceIDs + claimed.surfaceIDs)]
    )
    let existing = makeRecord(directory: directory, surfaceIDs: Set(owned.surfaceIDs))
    state.taskRecords = [existing]
    state.applyPostReduceCacheRecomputes(.all)
    let store = makeStore(state, sandbox: sandbox, liveTabs: liveTabs(owned, claimed))

    await store.send(.tasks(.promoteTab(worktreeID: rowID, tabID: claimed.id)))
    await store.finish()

    #expect(store.state.taskRecords.count == 1)
    #expect(
      store.state.taskRecords[id: existing.id]?.surfaceIDs == Set(owned.surfaceIDs + claimed.surfaceIDs)
    )
    // Joining is not a re-creation: identity and creation stamp are unchanged.
    #expect(store.state.taskRecords[id: existing.id]?.createdAt == existing.createdAt)
    #expect(sandbox.loadFile()?.tasks.first?.surfaceIDs == Set(owned.surfaceIDs + claimed.surfaceIDs))
  }

  /// A3's transfer half: the surfaces are already owned (by a task whose own
  /// directory has drifted away), and the user explicitly promotes them here.
  /// Explicit intent wins, and the surfaces move rather than being shared —
  /// after the transfer no surface belongs to two tasks.
  @Test(.dependencies) func promotingATabOwnedByAnotherTaskTransfersOwnership() async throws {
    let sandbox = try makeSandbox()
    let mine = try sandbox.makeDirectory("mine")
    let stale = try sandbox.makeDirectory("stale")
    let rowID = WorktreeID(mine.path(percentEncoded: false))
    let contested = (id: TerminalTabID(), surfaceIDs: [UUID(), UUID()])
    try sandbox.seedLayout(worktreeID: rowID, tabs: [contested])
    var state = makeState(
      sandbox: sandbox,
      directories: [mine, stale],
      surfacesPerRow: [mine: Set(contested.surfaceIDs)]
    )
    let target = makeRecord(directory: mine)
    let previousOwner = makeRecord(directory: stale, surfaceIDs: Set(contested.surfaceIDs))
    state.taskRecords = [target, previousOwner]
    state.applyPostReduceCacheRecomputes(.all)
    let store = makeStore(state, sandbox: sandbox, liveTabs: liveTabs(contested))

    await store.send(.tasks(.promoteTab(worktreeID: rowID, tabID: contested.id)))
    await store.finish()

    #expect(store.state.taskRecords.count == 2)
    #expect(store.state.taskRecords[id: target.id]?.surfaceIDs == Set(contested.surfaceIDs))
    // The loser keeps its record — losing a claim never deletes a task (A10b).
    #expect(store.state.taskRecords[id: previousOwner.id]?.surfaceIDs.isEmpty == true)
    let claimed = store.state.taskRecords.flatMap { Array($0.surfaceIDs) }
    #expect(claimed.count == Set(claimed).count)
  }

  /// Two active tasks share a directory (legitimate per Resolved #11), so the
  /// join target must be deterministic. Newest-created wins — the same order the
  /// Tasks tab puts at the top (A4).
  @Test(.dependencies) func promotingIntoASharedDirectoryJoinsTheNewestActiveTask() async throws {
    let sandbox = try makeSandbox()
    let directory = try sandbox.makeDirectory("mine")
    let rowID = WorktreeID(directory.path(percentEncoded: false))
    let claimed = (id: TerminalTabID(), surfaceIDs: [UUID()])
    try sandbox.seedLayout(worktreeID: rowID, tabs: [claimed])
    var state = makeState(
      sandbox: sandbox,
      directories: [directory],
      surfacesPerRow: [directory: Set(claimed.surfaceIDs)]
    )
    let older = makeRecord(directory: directory, createdAt: Self.earlier)
    let newer = makeRecord(directory: directory, createdAt: Self.freshDate)
    state.taskRecords = [older, newer]
    state.applyPostReduceCacheRecomputes(.all)
    let store = makeStore(state, sandbox: sandbox, liveTabs: liveTabs(claimed))

    await store.send(.tasks(.promoteTab(worktreeID: rowID, tabID: claimed.id)))
    await store.finish()

    #expect(store.state.taskRecords.count == 2)
    #expect(store.state.taskRecords[id: newer.id]?.surfaceIDs == Set(claimed.surfaceIDs))
    #expect(store.state.taskRecords[id: older.id]?.surfaceIDs.isEmpty == true)
  }

  /// Two active tasks in one directory created in the same tick — two promotes
  /// inside one `date.now`, or a seed that stamped a batch. `createdAt` cannot
  /// separate them, so the id breaks the tie and the pick stays stable across
  /// launches. Without the tie-break the winner would be whichever record the
  /// array happened to hold first, which reorders on every load.
  @Test(.dependencies) func promotingIntoTasksCreatedInTheSameTickJoinsTheHigherID() async throws {
    let sandbox = try makeSandbox()
    let directory = try sandbox.makeDirectory("mine")
    let rowID = WorktreeID(directory.path(percentEncoded: false))
    let claimed = (id: TerminalTabID(), surfaceIDs: [UUID()])
    try sandbox.seedLayout(worktreeID: rowID, tabs: [claimed])
    var state = makeState(
      sandbox: sandbox,
      directories: [directory],
      surfacesPerRow: [directory: Set(claimed.surfaceIDs)]
    )
    let ids = [TaskID(), TaskID()].sorted { $0.rawValue < $1.rawValue }
    let loser = makeRecord(directory: directory, id: ids[0], createdAt: Self.freshDate)
    let winner = makeRecord(directory: directory, id: ids[1], createdAt: Self.freshDate)
    // Loser first on purpose: a tie-break that fell back to array order would
    // pick this one, so the assertion below fails the moment the id drops out.
    state.taskRecords = [loser, winner]
    state.applyPostReduceCacheRecomputes(.all)
    let store = makeStore(state, sandbox: sandbox, liveTabs: liveTabs(claimed))

    await store.send(.tasks(.promoteTab(worktreeID: rowID, tabID: claimed.id)))
    await store.finish()

    #expect(store.state.taskRecords[id: winner.id]?.surfaceIDs == Set(claimed.surfaceIDs))
    #expect(store.state.taskRecords[id: loser.id]?.surfaceIDs.isEmpty == true)
  }

  /// A21: re-promoting a tab its own task already owns changes nothing — no
  /// duplicate task, no re-stamped `createdAt` that would reorder the inbox, and
  /// no `tasks.json` write at all. The write matters on its own: a no-op that
  /// still saved would rewrite the file on every stray menu click.
  @Test(.dependencies) func rePromotingATabIntoItsOwnTaskIsANoop() async throws {
    let sandbox = try makeSandbox()
    let directory = try sandbox.makeDirectory("mine")
    let rowID = WorktreeID(directory.path(percentEncoded: false))
    let tab = (id: TerminalTabID(), surfaceIDs: [UUID(), UUID()])
    try sandbox.seedLayout(worktreeID: rowID, tabs: [tab])
    var state = makeState(
      sandbox: sandbox,
      directories: [directory],
      surfacesPerRow: [directory: Set(tab.surfaceIDs)]
    )
    let record = makeRecord(directory: directory, surfaceIDs: Set(tab.surfaceIDs))
    state.taskRecords = [record]
    state.applyPostReduceCacheRecomputes(.all)
    let taskWrites = LockIsolated(0)
    let spy = SettingsFileStorage(
      load: sandbox.storage.load,
      save: { data, url in
        if url == SupacodePaths.tasksURL { taskWrites.withValue { $0 += 1 } }
        try sandbox.storage.save(data, url)
      },
      moveAside: sandbox.storage.moveAside
    )
    let store = makeStore(state, sandbox: sandbox, liveTabs: liveTabs(tab), storage: spy)
    let structureBefore = store.state.tasksSidebarStructure
    let selectionBefore = store.state.selection

    await store.send(.tasks(.promoteTab(worktreeID: rowID, tabID: tab.id)))
    await store.send(.tasks(.promoteTab(worktreeID: rowID, tabID: tab.id)))
    await store.finish()

    #expect(store.state.taskRecords.count == 1)
    #expect(store.state.taskRecords[id: record.id] == record)
    #expect(store.state.tasksSidebarStructure == structureBefore)
    #expect(taskWrites.value == 0)
    // A refused claim does not navigate either: the arm returns before the
    // selection it would otherwise send.
    #expect(store.state.selection == selectionBefore)
  }

  /// The directory's only task is settled, i.e. history. Promoting starts a new
  /// active task rather than resurrecting the old one, and the surfaces move
  /// with the claim so the settled record stops owning live tabs.
  @Test(.dependencies) func promotingIntoASettledOnlyDirectoryCreatesANewActiveTask() async throws {
    let sandbox = try makeSandbox()
    let directory = try sandbox.makeDirectory("mine")
    let rowID = WorktreeID(directory.path(percentEncoded: false))
    let tab = (id: TerminalTabID(), surfaceIDs: [UUID()])
    try sandbox.seedLayout(worktreeID: rowID, tabs: [tab])
    var state = makeState(
      sandbox: sandbox,
      directories: [directory],
      surfacesPerRow: [directory: Set(tab.surfaceIDs)]
    )
    let settled = makeRecord(directory: directory, surfaceIDs: Set(tab.surfaceIDs), settledAt: Self.staleDate)
    state.taskRecords = [settled]
    state.applyPostReduceCacheRecomputes(.all)
    let store = makeStore(state, sandbox: sandbox, liveTabs: liveTabs(tab))

    await store.send(.tasks(.promoteTab(worktreeID: rowID, tabID: tab.id)))
    await store.finish()

    #expect(store.state.taskRecords.count == 2)
    #expect(store.state.taskRecords[id: settled.id]?.settledAt == Self.staleDate)
    #expect(store.state.taskRecords[id: settled.id]?.surfaceIDs.isEmpty == true)
    let created = try #require(store.state.taskRecords.first { $0.id != settled.id })
    #expect(created.settledAt == nil)
    #expect(created.surfaceIDs == Set(tab.surfaceIDs))
    #expect(store.state.tasksSidebarStructure.activeTaskIDs == [created.id])
  }

  // MARK: - A21: the live tab is untouched

  /// A21's "without restarting it or losing scrollback", at the level a reducer
  /// test can honestly assert: promotion touches bookkeeping and the sidebar
  /// selection, nothing else. It must not move the row's live surface
  /// projection, nor the persisted layout the sessions are restored from, nor
  /// `sidebar.json` (A11) — the terminal keeps the tab it had selected.
  ///
  /// The sidebar selection *does* move, to the task that was just created: a
  /// menu command with no visible result reads as a command that did nothing.
  @Test(.dependencies) func promotingLeavesTheLiveTabAndTheSidebarUntouched() async throws {
    let sandbox = try makeSandbox()
    let directory = try sandbox.makeDirectory("mine")
    let rowID = WorktreeID(directory.path(percentEncoded: false))
    let tab = (id: TerminalTabID(), surfaceIDs: [UUID(), UUID()])
    try sandbox.seedLayout(worktreeID: rowID, tabs: [tab])
    var state = makeState(
      sandbox: sandbox,
      directories: [directory],
      surfacesPerRow: [directory: Set(tab.surfaceIDs)]
    )
    state.selection = .worktree(rowID)
    state.applyPostReduceCacheRecomputes(.all)
    let store = makeStore(state, sandbox: sandbox, liveTabs: liveTabs(tab))
    let rowBefore = try #require(store.state.sidebarItems[id: rowID])
    let layoutsBefore = store.state.persistedLayouts
    let sidebarBefore = store.state.sidebar

    await store.send(.tasks(.promoteTab(worktreeID: rowID, tabID: tab.id)))
    await store.receive(\.tasks.select)
    await store.receive(\.selectionChanged)
    await store.finish()

    // The claim happened — otherwise every assertion below passes vacuously.
    let created = try #require(store.state.taskRecords.first)
    #expect(created.surfaceIDs == Set(tab.surfaceIDs))
    #expect(store.state.sidebarItems[id: rowID]?.surfaceIDs == rowBefore.surfaceIDs)
    #expect(store.state.sidebarItems[id: rowID]?.hasTerminalProjection == true)
    #expect(store.state.persistedLayouts == layoutsBefore)
    #expect(store.state.sidebar == sidebarBefore)
    #expect(store.state.selection == .task(created.id))
    // The task's tabs stay visible while it is open, so opening it cannot arm
    // hibernation on the tab the user just promoted.
    #expect(store.state.taskDetailWorktreeID == rowID)
  }

  /// The full effect list of a successful claim, pinned with exhaustivity on:
  /// `.select` (which owns the `tasks.json` write via `.selectionChanged`) plus
  /// the two delegates opening a task always sends — and nothing else. Anything
  /// that restarted, re-selected or re-laid-out the tab would surface here.
  ///
  /// Uses the join path so the task id is known up front; the creation path
  /// mints an id the assertion could only read back after the fact.
  @Test(.dependencies) func promotingSendsOnlyTheSelectionAndFocusEffects() async throws {
    let sandbox = try makeSandbox()
    let directory = try sandbox.makeDirectory("mine")
    let rowID = WorktreeID(directory.path(percentEncoded: false))
    let ownedSurface = UUID()
    let claimedSurface = UUID()
    let owned = (id: TerminalTabID(), surfaceIDs: [ownedSurface])
    let claimed = (id: TerminalTabID(), surfaceIDs: [claimedSurface])
    try sandbox.seedLayout(worktreeID: rowID, tabs: [owned, claimed])
    var state = makeState(
      sandbox: sandbox,
      directories: [directory],
      surfacesPerRow: [directory: [ownedSurface, claimedSurface]]
    )
    let existing = makeRecord(directory: directory, surfaceIDs: [ownedSurface])
    state.taskRecords = [existing]
    state.applyPostReduceCacheRecomputes(.all)
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    } withDependencies: {
      $0.settingsFileStorage = sandbox.storage
      $0.date.now = Self.now
      $0.terminalClient.selectedTabID = { _ in claimed.id }
      $0.terminalClient.tabSurfaceIDs = { _, tabID in tabID == claimed.id ? [claimedSurface] : [ownedSurface] }
    }

    await store.send(.tasks(.promoteTab(worktreeID: rowID, tabID: claimed.id))) {
      $0.taskRecords[id: existing.id]?.surfaceIDs = [ownedSurface, claimedSurface]
      $0.applyPostReduceCacheRecomputes(.sidebarStructure)
    }
    await store.receive(\.tasks.select, existing.id)
    await store.receive(\.selectionChanged) {
      $0.selection = .task(existing.id)
      $0.taskRecords[id: existing.id]?.lastVisitedAt = Self.now
      $0.applyPostReduceCacheRecomputes(.sidebarStructure)
    }
    // Emission order: `.select` merges the selection ahead of the focus, and the
    // selection's own delegate lands behind both.
    await store.receive(\.delegate.focusTaskSurface)
    await store.receive(\.delegate.selectedWorktreeChanged)
    await store.finish()
  }

  // MARK: - Live surfaces vs. the persisted snapshot

  /// `layouts.json` is rewritten only on background / quit, so a pane split
  /// since the last save is missing from it. The claim is the union, otherwise
  /// promoting a freshly split tab would leave half of it unowned.
  @Test(.dependencies) func promotingClaimsPanesTheSnapshotHasNotSeenYet() async throws {
    let sandbox = try makeSandbox()
    let directory = try sandbox.makeDirectory("mine")
    let rowID = WorktreeID(directory.path(percentEncoded: false))
    let persistedSurface = UUID()
    let splitSinceSave = UUID()
    let tabID = TerminalTabID()
    try sandbox.seedLayout(worktreeID: rowID, tabs: [(id: tabID, surfaceIDs: [persistedSurface])])
    let state = makeState(
      sandbox: sandbox,
      directories: [directory],
      surfacesPerRow: [directory: [persistedSurface, splitSinceSave]]
    )
    let store = makeStore(
      state,
      sandbox: sandbox,
      liveTabs: [tabID: [persistedSurface, splitSinceSave]]
    )

    await store.send(.tasks(.promoteTab(worktreeID: rowID, tabID: tabID)))
    await store.finish()

    #expect(store.state.taskRecords.first?.surfaceIDs == [persistedSurface, splitSinceSave])
  }

  /// The mirror case: a tab created since the last save is in no snapshot at
  /// all, and promoting it must still work.
  @Test(.dependencies) func promotingATabNoSnapshotKnowsClaimsItsLiveSurfaces() async throws {
    let sandbox = try makeSandbox()
    let directory = try sandbox.makeDirectory("mine")
    let rowID = WorktreeID(directory.path(percentEncoded: false))
    let persisted = (id: TerminalTabID(), surfaceIDs: [UUID()])
    let fresh = (id: TerminalTabID(), surfaceIDs: [UUID()])
    try sandbox.seedLayout(worktreeID: rowID, tabs: [persisted])
    let state = makeState(
      sandbox: sandbox,
      directories: [directory],
      surfacesPerRow: [directory: Set(persisted.surfaceIDs + fresh.surfaceIDs)]
    )
    let store = makeStore(state, sandbox: sandbox, liveTabs: liveTabs(persisted, fresh))

    await store.send(.tasks(.promoteTab(worktreeID: rowID, tabID: fresh.id)))
    await store.finish()

    #expect(store.state.taskRecords.first?.surfaceIDs == Set(fresh.surfaceIDs))
  }

  // MARK: - Edges

  /// A tab neither the terminal nor the snapshot knows: there are no surfaces to
  /// claim, so nothing is created and nothing is written.
  @Test(.dependencies) func promotingATabWithNoSurfacesIsANoop() async throws {
    let sandbox = try makeSandbox()
    let directory = try sandbox.makeDirectory("mine")
    let rowID = WorktreeID(directory.path(percentEncoded: false))
    try sandbox.seedLayout(worktreeID: rowID, tabs: [(id: TerminalTabID(), surfaceIDs: [UUID()])])
    let store = makeStore(makeState(sandbox: sandbox, directories: [directory]), sandbox: sandbox)

    await store.send(.tasks(.promoteTab(worktreeID: rowID, tabID: TerminalTabID())))
    await store.finish()

    #expect(store.state.taskRecords.isEmpty)
    #expect(sandbox.loadFile()?.tasks.isEmpty ?? true)
  }

  /// No tab id and no live selection: the worktree has no terminal open at all.
  /// Refusing beats falling back to the persisted snapshot, which would claim a
  /// tab from a previous session that no longer exists.
  @Test(.dependencies) func promotingWithNoLiveSelectedTabIsANoop() async throws {
    let sandbox = try makeSandbox()
    let directory = try sandbox.makeDirectory("mine")
    let rowID = WorktreeID(directory.path(percentEncoded: false))
    let stale = (id: TerminalTabID(), surfaceIDs: [UUID()])
    try sandbox.seedLayout(worktreeID: rowID, tabs: [stale])
    let store = makeStore(
      makeState(sandbox: sandbox, directories: [directory]),
      sandbox: sandbox,
      liveTabs: liveTabs(stale),
      selectedTabID: nil
    )

    await store.send(.tasks(.promoteTab(worktreeID: rowID, tabID: nil)))
    await store.finish()

    #expect(store.state.taskRecords.isEmpty)
    #expect(sandbox.loadFile()?.tasks.isEmpty ?? true)
  }

  /// No live row for the worktree (deleted, or a stale menu target): nothing to
  /// read a title, branch or repository from, so nothing is created.
  @Test(.dependencies) func promotingAWorktreeWithNoLiveRowIsANoop() async throws {
    let sandbox = try makeSandbox()
    let directory = try sandbox.makeDirectory("mine")
    let vanished = try sandbox.makeDirectory("vanished")
    let vanishedID = WorktreeID(vanished.path(percentEncoded: false))
    let tab = (id: TerminalTabID(), surfaceIDs: [UUID()])
    try sandbox.seedLayout(worktreeID: vanishedID, tabs: [tab])
    let store = makeStore(
      makeState(sandbox: sandbox, directories: [directory]),
      sandbox: sandbox,
      liveTabs: liveTabs(tab)
    )

    await store.send(.tasks(.promoteTab(worktreeID: vanishedID, tabID: tab.id)))
    await store.finish()

    #expect(store.state.taskRecords.isEmpty)
  }

  /// An unreadable `tasks.json` disables the inbox for the launch: promoting
  /// must not invent a record on top of tasks we failed to read, and must not
  /// write over them.
  @Test(.dependencies) func promotingWithPersistenceDisabledIsANoop() async throws {
    let sandbox = try makeSandbox()
    let directory = try sandbox.makeDirectory("mine")
    let rowID = WorktreeID(directory.path(percentEncoded: false))
    let tab = (id: TerminalTabID(), surfaceIDs: [UUID()])
    try sandbox.seedLayout(worktreeID: rowID, tabs: [tab])
    var state = makeState(
      sandbox: sandbox,
      directories: [directory],
      surfacesPerRow: [directory: Set(tab.surfaceIDs)]
    )
    state.isTaskPersistenceDisabled = true
    state.applyPostReduceCacheRecomputes(.all)
    let unreadable = SettingsFileStorage(
      load: { _ in throw CocoaError(.fileReadNoPermission) },
      save: { _, _ in Issue.record("Promotion must not write over an unreadable tasks.json.") },
      moveAside: { _, _ in }
    )
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    } withDependencies: {
      $0.settingsFileStorage = unreadable
      $0.date.now = Self.now
    }
    store.exhaustivity = .off

    await store.send(.tasks(.promoteTab(worktreeID: rowID, tabID: tab.id)))
    await store.finish()

    #expect(store.state.taskRecords.isEmpty)
  }

  /// The arm changes the record set, so it must invalidate the Tasks render plan.
  @Test func promoteDeclaresTheSidebarStructureInvalidation() {
    let action = RepositoriesFeature.TaskInboxAction.promoteTab(
      worktreeID: WorktreeID("/tmp/mine"),
      tabID: TerminalTabID()
    )

    #expect(action.cacheInvalidations == .sidebarStructure)
  }

  // MARK: - Named claim target

  /// The two-quick-captures race. A and B are captured back to back in one
  /// directory; each gets a tab minted for it, and the tabs land in whatever
  /// order the terminal materializes them. Resolving by "newest active task in
  /// the directory" hands B both tabs and leaves A with none — so each claim
  /// names the record it was minted for.
  @Test(.dependencies) func eachCaptureClaimsOnlyTheTabMintedForIt() async throws {
    let sandbox = try makeSandbox()
    let directory = try sandbox.makeDirectory("mine")
    let rowID = WorktreeID(directory.path(percentEncoded: false))
    let tabA = (id: TerminalTabID(), surfaceIDs: [UUID()])
    let tabB = (id: TerminalTabID(), surfaceIDs: [UUID()])
    try sandbox.seedLayout(worktreeID: rowID, tabs: [tabA, tabB])
    var state = makeState(
      sandbox: sandbox,
      directories: [directory],
      surfacesPerRow: [directory: Set(tabA.surfaceIDs + tabB.surfaceIDs)]
    )
    let taskA = makeRecord(directory: directory, createdAt: Self.earlier)
    let taskB = makeRecord(directory: directory, createdAt: Self.freshDate)
    state.taskRecords = [taskA, taskB]
    state.applyPostReduceCacheRecomputes(.all)
    let store = makeStore(state, sandbox: sandbox, liveTabs: liveTabs(tabA, tabB))

    // B's tab lands first, then A's — the order the newest-active fallback
    // cannot survive.
    await store.send(.tasks(.promoteTab(worktreeID: rowID, tabID: tabB.id, taskID: taskB.id)))
    await store.send(.tasks(.promoteTab(worktreeID: rowID, tabID: tabA.id, taskID: taskA.id)))
    await store.finish()

    #expect(store.state.taskRecords.count == 2)
    #expect(store.state.taskRecords[id: taskA.id]?.surfaceIDs == Set(tabA.surfaceIDs))
    #expect(store.state.taskRecords[id: taskB.id]?.surfaceIDs == Set(tabB.surfaceIDs))
  }

  /// A named target is honored even after it settles: the caller is naming a
  /// record it just created, and the tab was minted for that record. Sending the
  /// claim somewhere else because the user settled the task in the meantime
  /// would put the surfaces on a task that never asked for them.
  @Test(.dependencies) func aNamedTargetIsHonoredEvenWhenItHasAlreadySettled() async throws {
    let sandbox = try makeSandbox()
    let directory = try sandbox.makeDirectory("mine")
    let rowID = WorktreeID(directory.path(percentEncoded: false))
    let tab = (id: TerminalTabID(), surfaceIDs: [UUID()])
    try sandbox.seedLayout(worktreeID: rowID, tabs: [tab])
    var state = makeState(
      sandbox: sandbox,
      directories: [directory],
      surfacesPerRow: [directory: Set(tab.surfaceIDs)]
    )
    let settled = makeRecord(directory: directory, settledAt: Self.now)
    let bystander = makeRecord(directory: directory, createdAt: Self.freshDate)
    state.taskRecords = [settled, bystander]
    state.applyPostReduceCacheRecomputes(.all)
    let store = makeStore(state, sandbox: sandbox, liveTabs: liveTabs(tab))

    await store.send(.tasks(.promoteTab(worktreeID: rowID, tabID: tab.id, taskID: settled.id)))
    await store.finish()

    #expect(store.state.taskRecords[id: settled.id]?.surfaceIDs == Set(tab.surfaceIDs))
    #expect(store.state.taskRecords[id: bystander.id]?.surfaceIDs.isEmpty == true)
    // The claim does not resurrect it — settling is the user's call, not the
    // terminal's.
    #expect(store.state.taskRecords[id: settled.id]?.settledAt == Self.now)
  }

  /// The record was deleted while its tab materialized. The tab is real either
  /// way, so the claim falls back to the directory's live task rather than
  /// evaporating.
  @Test(.dependencies) func aNamedTargetThatVanishedFallsBackToTheNewestActiveTask() async throws {
    let sandbox = try makeSandbox()
    let directory = try sandbox.makeDirectory("mine")
    let rowID = WorktreeID(directory.path(percentEncoded: false))
    let tab = (id: TerminalTabID(), surfaceIDs: [UUID()])
    try sandbox.seedLayout(worktreeID: rowID, tabs: [tab])
    var state = makeState(
      sandbox: sandbox,
      directories: [directory],
      surfacesPerRow: [directory: Set(tab.surfaceIDs)]
    )
    let survivor = makeRecord(directory: directory, createdAt: Self.freshDate)
    state.taskRecords = [survivor]
    state.applyPostReduceCacheRecomputes(.all)
    let store = makeStore(state, sandbox: sandbox, liveTabs: liveTabs(tab))

    await store.send(.tasks(.promoteTab(worktreeID: rowID, tabID: tab.id, taskID: TaskID())))
    await store.finish()

    #expect(store.state.taskRecords.count == 1)
    #expect(store.state.taskRecords[id: survivor.id]?.surfaceIDs == Set(tab.surfaceIDs))
  }
}

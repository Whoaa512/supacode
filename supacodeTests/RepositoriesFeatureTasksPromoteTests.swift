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
  private static let now = Date(timeIntervalSince1970: 1_800_000_000)
  private static let earlier = now.addingTimeInterval(-7200)
  private static let freshDate = now.addingTimeInterval(-3600)
  private static let staleDate = now.addingTimeInterval(-30 * 24 * 3600)

  // MARK: - Fixture

  /// Temp repo plus the in-memory storage the reducer, `@SharedReader(.layouts)`
  /// and the test all read through, so nothing touches the developer's real
  /// `~/.supacode`.
  private final class Sandbox {
    let rootURL: URL
    let storage: SettingsFileStorage
    let store = TaskStore()
    private let files: InMemorySettingsFileStorage

    init() throws {
      rootURL = FileManager.default.temporaryDirectory
        .appending(path: "RepositoriesFeatureTasksPromoteTests-\(UUID().uuidString)", directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
      let files = InMemorySettingsFileStorage()
      self.files = files
      storage = SettingsFileStorage(
        load: { try files.load($0) },
        save: { try files.save($0, $1) },
        moveAside: { try files.moveAside($0, $1) }
      )
    }

    /// Writes `layouts.json` for one worktree. Unlike the Phase-1 helper this
    /// one pins the tab ids (promotion addresses a tab by id) and lets a tab
    /// hold several surfaces, which is the case tab-granular claims exist for.
    func seedLayout(
      worktreeID: Worktree.ID,
      tabs: [(id: TerminalTabID, surfaceIDs: [UUID])],
      selectedTabIndex: Int = 0
    ) throws {
      let snapshot = TerminalLayoutSnapshot(
        tabs: tabs.map { tab in
          TerminalLayoutSnapshot.TabSnapshot(
            id: tab.id.rawValue,
            title: "tab",
            customTitle: nil,
            icon: nil,
            tintColor: nil,
            layout: Self.layout(for: tab.surfaceIDs),
            focusedLeafIndex: 0
          )
        },
        selectedTabIndex: selectedTabIndex
      )
      let payload = try JSONEncoder().encode([worktreeID.rawValue: snapshot])
      try files.save(payload, SupacodePaths.layoutsURL)
    }

    /// Right-leaning split tree over the surfaces, so a multi-surface tab is a
    /// real split rather than a flat list.
    private static func layout(for surfaceIDs: [UUID]) -> TerminalLayoutSnapshot.LayoutNode {
      let leaves = surfaceIDs.map { id in
        TerminalLayoutSnapshot.LayoutNode.leaf(
          TerminalLayoutSnapshot.SurfaceSnapshot(id: id, workingDirectory: nil)
        )
      }
      guard var node = leaves.last else {
        return .leaf(TerminalLayoutSnapshot.SurfaceSnapshot(id: nil, workingDirectory: nil))
      }
      for leaf in leaves.dropLast().reversed() {
        node = .split(
          TerminalLayoutSnapshot.SplitSnapshot(direction: .horizontal, ratio: 0.5, left: leaf, right: node)
        )
      }
      return node
    }

    func makeDirectory(_ name: String) throws -> URL {
      let directory = rootURL.appending(path: name, directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      return directory
    }

    func loadFile() -> TaskStoreFile? {
      withDependencies { $0.settingsFileStorage = storage } operation: { store.load().file }
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
    var state = withDependencies {
      $0.settingsFileStorage = sandbox.storage
    } operation: {
      RepositoriesFeature.State(reconciledRepositories: [repository])
    }
    state.isInitialLoadComplete = true
    state.hasLoadedTasks = true
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

  // MARK: - Creation

  /// A directory with no task at all: promoting one tab mints an active record
  /// that owns exactly that tab's split tree — not the neighbouring tab's
  /// surfaces, which is the whole point of tab granularity (Resolved #10).
  @Test(.dependencies) func promotingATabInAFreshDirectoryCreatesAnActiveTask() async throws {
    let sandbox = try Sandbox()
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
    let store = makeStore(state, sandbox: sandbox)

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
    let sandbox = try Sandbox()
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
    let store = makeStore(state, sandbox: sandbox)

    await store.send(.tasks(.promoteTab(worktreeID: rowID, tabID: tab.id)))
    await store.finish()

    let record = try #require(store.state.taskRecords.first)
    #expect(record.title == "Ship the inbox")
    #expect(record.branch == "feature/inbox")
  }

  /// A detached HEAD has no provable branch, so the record carries none rather
  /// than a guess (A2).
  @Test(.dependencies) func promotingADetachedRowRecordsNoBranch() async throws {
    let sandbox = try Sandbox()
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
    let store = makeStore(state, sandbox: sandbox)

    await store.send(.tasks(.promoteTab(worktreeID: rowID, tabID: tab.id)))
    await store.finish()

    let record = try #require(store.state.taskRecords.first)
    #expect(record.branch == nil)
    // The claim still lands: a missing branch is a missing field, not a refusal.
    #expect(record.surfaceIDs == Set(tab.surfaceIDs))
  }

  /// Promoting with no tab id claims the tab the layout has selected, which is
  /// what a menu command with no explicit target means.
  @Test(.dependencies) func promotingWithoutATabIDClaimsTheSelectedTab() async throws {
    let sandbox = try Sandbox()
    let directory = try sandbox.makeDirectory("mine")
    let rowID = WorktreeID(directory.path(percentEncoded: false))
    let first = (id: TerminalTabID(), surfaceIDs: [UUID()])
    let selected = (id: TerminalTabID(), surfaceIDs: [UUID(), UUID()])
    try sandbox.seedLayout(worktreeID: rowID, tabs: [first, selected], selectedTabIndex: 1)
    let state = makeState(
      sandbox: sandbox,
      directories: [directory],
      surfacesPerRow: [directory: Set(first.surfaceIDs + selected.surfaceIDs)]
    )
    let store = makeStore(state, sandbox: sandbox)

    await store.send(.tasks(.promoteTab(worktreeID: rowID, tabID: nil)))
    await store.finish()

    #expect(store.state.taskRecords.first?.surfaceIDs == Set(selected.surfaceIDs))
  }

  // MARK: - A3: joining, transfer, idempotence

  /// The directory already has an active task, so the claim joins it. A second
  /// task for one directory would split one problem across two rows.
  @Test(.dependencies) func promotingIntoADirectoryWithAnActiveTaskJoinsThatTask() async throws {
    let sandbox = try Sandbox()
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
    let store = makeStore(state, sandbox: sandbox)

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
    let sandbox = try Sandbox()
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
    let store = makeStore(state, sandbox: sandbox)

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
    let sandbox = try Sandbox()
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
    let store = makeStore(state, sandbox: sandbox)

    await store.send(.tasks(.promoteTab(worktreeID: rowID, tabID: claimed.id)))
    await store.finish()

    #expect(store.state.taskRecords.count == 2)
    #expect(store.state.taskRecords[id: newer.id]?.surfaceIDs == Set(claimed.surfaceIDs))
    #expect(store.state.taskRecords[id: older.id]?.surfaceIDs.isEmpty == true)
  }

  /// A21: re-promoting a tab its own task already owns changes nothing — no
  /// duplicate task, no re-stamped `createdAt` that would reorder the inbox.
  @Test(.dependencies) func rePromotingATabIntoItsOwnTaskIsANoop() async throws {
    let sandbox = try Sandbox()
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
    let store = makeStore(state, sandbox: sandbox)
    let structureBefore = store.state.tasksSidebarStructure

    await store.send(.tasks(.promoteTab(worktreeID: rowID, tabID: tab.id)))
    await store.send(.tasks(.promoteTab(worktreeID: rowID, tabID: tab.id)))
    await store.finish()

    #expect(store.state.taskRecords.count == 1)
    #expect(store.state.taskRecords[id: record.id] == record)
    #expect(store.state.tasksSidebarStructure == structureBefore)
  }

  /// The directory's only task is settled, i.e. history. Promoting starts a new
  /// active task rather than resurrecting the old one, and the surfaces move
  /// with the claim so the settled record stops owning live tabs.
  @Test(.dependencies) func promotingIntoASettledOnlyDirectoryCreatesANewActiveTask() async throws {
    let sandbox = try Sandbox()
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
    let store = makeStore(state, sandbox: sandbox)

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
  /// test can honestly assert: promotion is a bookkeeping write. It must not
  /// move the row's live surface projection, the persisted layout the sessions
  /// are restored from, the selection, or `sidebar.json` (A11). The arm's only
  /// effect is the `tasks.json` write.
  @Test(.dependencies) func promotingLeavesTheLiveTabAndTheSidebarUntouched() async throws {
    let sandbox = try Sandbox()
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
    let store = makeStore(state, sandbox: sandbox)
    let rowBefore = try #require(store.state.sidebarItems[id: rowID])
    let layoutsBefore = store.state.persistedLayouts
    let sidebarBefore = store.state.sidebar

    await store.send(.tasks(.promoteTab(worktreeID: rowID, tabID: tab.id)))
    await store.finish()

    // The claim happened — otherwise every assertion below passes vacuously.
    #expect(store.state.taskRecords.first?.surfaceIDs == Set(tab.surfaceIDs))
    #expect(store.state.sidebarItems[id: rowID]?.surfaceIDs == rowBefore.surfaceIDs)
    #expect(store.state.sidebarItems[id: rowID]?.hasTerminalProjection == true)
    #expect(store.state.persistedLayouts == layoutsBefore)
    #expect(store.state.sidebar == sidebarBefore)
    // Promotion claims; it does not navigate.
    #expect(store.state.selection == .worktree(rowID))
  }

  // MARK: - Edges

  @Test(.dependencies) func promotingATabThatNoLayoutKnowsIsANoop() async throws {
    let sandbox = try Sandbox()
    let directory = try sandbox.makeDirectory("mine")
    let rowID = WorktreeID(directory.path(percentEncoded: false))
    try sandbox.seedLayout(worktreeID: rowID, tabs: [(id: TerminalTabID(), surfaceIDs: [UUID()])])
    let store = makeStore(makeState(sandbox: sandbox, directories: [directory]), sandbox: sandbox)

    await store.send(.tasks(.promoteTab(worktreeID: rowID, tabID: TerminalTabID())))
    await store.finish()

    #expect(store.state.taskRecords.isEmpty)
    #expect(sandbox.loadFile()?.tasks.isEmpty ?? true)
  }

  /// No live row for the worktree (deleted, or a stale menu target): nothing to
  /// read a title, branch or repository from, so nothing is created.
  @Test(.dependencies) func promotingAWorktreeWithNoLiveRowIsANoop() async throws {
    let sandbox = try Sandbox()
    let directory = try sandbox.makeDirectory("mine")
    let vanished = try sandbox.makeDirectory("vanished")
    let vanishedID = WorktreeID(vanished.path(percentEncoded: false))
    let tab = (id: TerminalTabID(), surfaceIDs: [UUID()])
    try sandbox.seedLayout(worktreeID: vanishedID, tabs: [tab])
    let store = makeStore(makeState(sandbox: sandbox, directories: [directory]), sandbox: sandbox)

    await store.send(.tasks(.promoteTab(worktreeID: vanishedID, tabID: tab.id)))
    await store.finish()

    #expect(store.state.taskRecords.isEmpty)
  }

  /// An unreadable `tasks.json` disables the inbox for the launch: promoting
  /// must not invent a record on top of tasks we failed to read, and must not
  /// write over them.
  @Test(.dependencies) func promotingWithPersistenceDisabledIsANoop() async throws {
    let sandbox = try Sandbox()
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
}

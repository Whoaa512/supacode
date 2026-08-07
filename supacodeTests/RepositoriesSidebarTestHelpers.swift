import ComposableArchitecture
import Foundation
import IdentifiedCollections
import Testing

@testable import SupacodeSettingsShared
@testable import supacode

/// Temp repo plus the in-memory storage the reducer, `@SharedReader(.layouts)`
/// and the test all read through, so no task-inbox suite touches the
/// developer's real `~/.supacode`.
///
/// Shared by every task-inbox suite: they all need the same three things (a
/// throwaway worktree directory, a `layouts.json` the reducer can resolve tabs
/// through, and a `tasks.json` the test can read back), and three private copies
/// drifted apart at the first fixture that only one of them needed.
final class TaskInboxSandbox {
  let rootURL: URL
  let storage: SettingsFileStorage
  let store = TaskStore()
  /// Every URL written through `storage`, in order. The save spy for flows that
  /// must write *nothing*: `loadFile()` hands back a default `TaskStoreFile`
  /// when `tasks.json` is absent, so a load-based check cannot tell "never
  /// wrote" from "wrote an empty inbox".
  let writtenURLs = LockIsolated<[URL]>([])
  private let files: InMemorySettingsFileStorage

  init(name: String = "TaskInboxSandbox") throws {
    rootURL = FileManager.default.temporaryDirectory
      .appending(path: "\(name)-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    let files = InMemorySettingsFileStorage()
    self.files = files
    let writtenURLs = self.writtenURLs
    storage = SettingsFileStorage(
      load: { try files.load($0) },
      save: { data, url in
        writtenURLs.withValue { $0.append(url) }
        try files.save(data, url)
      },
      moveAside: { try files.moveAside($0, $1) }
    )
  }

  /// Whether `tasks.json` was ever written through this sandbox's storage.
  var didWriteTasksFile: Bool {
    writtenURLs.value.contains(SupacodePaths.tasksURL)
  }

  /// Writes `layouts.json` for one worktree. Tab ids are pinned (promotion
  /// addresses a tab by id) and a tab may hold several surfaces, which is the
  /// case tab-granular claims exist for.
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

  /// One single-surface tab per id, which is what a restore of N tabs looks like
  /// on disk when nothing was ever split.
  func seedLayout(worktreeID: Worktree.ID, tabSurfaceIDs: [UUID]) throws {
    try seedLayout(
      worktreeID: worktreeID,
      tabs: tabSurfaceIDs.map { (id: TerminalTabID(), surfaceIDs: [$0]) }
    )
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

  @discardableResult
  func makeDirectory(_ name: String) throws -> URL {
    let directory = rootURL.appending(path: name, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  /// A worktree directory with a `checkout: moving from main to <branch>` reflog
  /// line at `activityAt` — the only activity source the seeder trusts.
  @discardableResult
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

/// Fixture builders shared by the task-inbox suites: one repository whose
/// worktrees are the sandbox's directories, plus the record shape the
/// assertions are written against.
@MainActor
enum TaskInboxFixture {
  static let now = Date(timeIntervalSince1970: 1_800_000_000)
  static let freshDate = now.addingTimeInterval(-3600)
  static let staleDate = now.addingTimeInterval(-30 * 24 * 3600)

  static func makeWorktree(_ directory: URL, rootURL: URL) -> Worktree {
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
  static func makeState(
    sandbox: TaskInboxSandbox,
    directories: [URL],
    surfacesPerRow: [URL: Set<UUID>] = [:],
    hasLoadedTasks: Bool = false
  ) -> RepositoriesFeature.State {
    let worktrees = directories.map { makeWorktree($0, rootURL: sandbox.rootURL) }
    let repository = Repository(
      id: RepositoryID(sandbox.rootURL.path(percentEncoded: false)),
      rootURL: sandbox.rootURL,
      name: sandbox.rootURL.lastPathComponent,
      worktrees: IdentifiedArray(uniqueElements: worktrees)
    )
    // Built inside the sandbox's storage so `@SharedReader(.layouts)` reads the
    // seeded layout rather than the developer's real `layouts.json`.
    var state = withDependencies {
      $0.settingsFileStorage = sandbox.storage
    } operation: {
      RepositoriesFeature.State(reconciledRepositories: [repository])
    }
    state.isInitialLoadComplete = true
    state.hasLoadedTasks = hasLoadedTasks
    for (directory, surfaceIDs) in surfacesPerRow {
      let id = WorktreeID(directory.path(percentEncoded: false))
      state.sidebarItems[id: id]?.surfaceIDs = surfaceIDs.sorted { $0.uuidString < $1.uuidString }
      state.sidebarItems[id: id]?.hasTerminalProjection = true
    }
    state.applyPostReduceCacheRecomputes(.all)
    return state
  }

  static func makeRecord(
    directory: URL,
    id: TaskID = TaskID(),
    surfaceIDs: Set<UUID> = [],
    settledAt: Date? = nil,
    createdAt: Date = freshDate
  ) -> TaskRecord {
    TaskRecord(
      id: id,
      title: directory.lastPathComponent,
      directoryPath: TaskDirectoryPath.canonical(directory),
      createdAt: createdAt,
      settledAt: settledAt,
      surfaceIDs: surfaceIDs
    )
  }
}

extension AppFeature.State {
  /// Mirrors AppFeature's post-reduce hook for TestStore expectations.
  /// Equatable diff inside the helper keeps no-op writes from invalidating
  /// the menu-bar `WorktreeCommands` snapshot.
  @MainActor
  mutating func applyPostReduceCacheRecomputes() {
    recomputeWorktreeMenuSnapshotIfChanged()
  }
}

extension RepositoriesFeature.State {
  /// Test mirror of the full sidebar pipeline: `syncSidebar` (matching
  /// reducer-body handlers that explicitly resync) + every cache recompute the
  /// post-reduce hook would run. Use this when the action explicitly resyncs.
  @MainActor
  mutating func reconcileSidebarForTesting() {
    RepositoriesFeature.syncSidebar(&self)
    applyPostReduceCacheRecomputes()
  }

  /// Mirrors the post-reduce hook for TestStore expectations. Pass the same
  /// `CacheInvalidations` set the action's `cacheInvalidations` returns so the
  /// expected state mutates exactly what the live reducer does, no more.
  /// The open-action bits are not mirrored here: they dispatch the
  /// `.resolveOpenActions` effect, which the TestStore drives on its own.
  @MainActor
  mutating func applyPostReduceCacheRecomputes(_ invalidations: CacheInvalidations = .all) {
    applyCacheRecomputes(invalidations)
    expectCachesConverged()
  }

  /// The invariant the `CacheInvalidations` switch exists to uphold: once an arm
  /// has run with its declared bits, recomputing every pure cache must be a
  /// no-op. An exhaustive switch only forces a new action to be *listed*, not
  /// classified, so assert sufficiency here, on every action the suite sends.
  ///
  /// `openActionByRepositoryID` is out of scope: it is not recomputed from state
  /// but resolved off disk in an effect, and the TestStore already forces every
  /// arm that must re-arm it to declare the `.resolveOpenActions` it sends.
  @MainActor
  private mutating func expectCachesConverged() {
    let structure = sidebarStructure
    let dashboard = agentDashboardStructure
    let selectionSlice = sidebarSelectionSlice
    let selectedSlice = selectedWorktreeSlice
    let notificationGroups = toolbarNotificationGroupsCache
    let menuBarSections = menuBarSectionsCache
    let tasksStructure = tasksSidebarStructure
    let leaves = taskLeaves

    applyCacheRecomputes(.allSidebar)

    let message = "Declared CacheInvalidations were insufficient: a full recompute changed"
    #expect(sidebarStructure == structure, "\(message) sidebarStructure.")
    #expect(agentDashboardStructure == dashboard, "\(message) agentDashboardStructure.")
    #expect(sidebarSelectionSlice == selectionSlice, "\(message) sidebarSelectionSlice.")
    #expect(selectedWorktreeSlice == selectedSlice, "\(message) selectedWorktreeSlice.")
    #expect(toolbarNotificationGroupsCache == notificationGroups, "\(message) toolbarNotificationGroupsCache.")
    #expect(menuBarSectionsCache == menuBarSections, "\(message) menuBarSectionsCache.")
    #expect(tasksSidebarStructure == tasksStructure, "\(message) tasksSidebarStructure.")
    #expect(taskLeaves == leaves, "\(message) taskLeaves.")

    // Restore, so a shortfall surfaces as this assertion rather than as an
    // unrelated TestStore diff in every test that sends the offending action.
    sidebarStructure = structure
    agentDashboardStructure = dashboard
    sidebarSelectionSlice = selectionSlice
    selectedWorktreeSlice = selectedSlice
    toolbarNotificationGroupsCache = notificationGroups
    menuBarSectionsCache = menuBarSections
    tasksSidebarStructure = tasksStructure
    taskLeaves = leaves
  }

  /// Convenience init for tests that need a populated row/grouping store from a roster.
  @MainActor
  init(reconciledRepositories repositories: [Repository]) {
    self.init()
    self.repositories = IdentifiedArray(uniqueElements: repositories)
    // Remote repos persist via the connections store, never `repositoryRoots`;
    // only local roots belong here, matching production.
    self.repositoryRoots = repositories.filter { $0.host == nil }.map(\.rootURL)
    reconcileSidebarForTesting()
  }

  /// Seed per-row pull-request data for tests directly on the row store.
  @MainActor
  mutating func setWorktreeInfoForTesting(
    id: Worktree.ID,
    addedLines: Int? = nil,
    removedLines: Int? = nil,
    pullRequest: GithubPullRequest? = nil
  ) {
    sidebarItems[id: id]?.addedLines = addedLines
    sidebarItems[id: id]?.removedLines = removedLines
    sidebarItems[id: id]?.pullRequest = pullRequest
  }
}

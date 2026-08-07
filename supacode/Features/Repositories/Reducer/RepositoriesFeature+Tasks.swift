import ComposableArchitecture
import Foundation
import IdentifiedCollections
import SupacodeSettingsShared

/// Task-inbox reducer arms, kept out of `RepositoriesFeature.swift` (already
/// ~6,300 lines) so the whole lifecycle reads in one place.
///
/// Phase 1 lifecycle, per `plans/task-inbox-sidebar-plan.md`: load, day-one
/// seed, select, explicit settle (sole-owner hibernate / shared-directory
/// defer), unsettle as the recovery path, settled-tail paging, and surface-
/// ownership reconciliation. Snooze, pin, auto-settle and the classification
/// cascade are Phase 2/4.
private nonisolated let tasksLogger = SupaLogger("Tasks")

private enum TaskCancelID {
  /// Every save writes the whole file, so a newer save fully supersedes an
  /// in-flight one and cancelling it can never drop state.
  static let persist = "repositories.tasks.persist"
  /// Seeding is armed from two launch paths (`.loaded` and `.repositoriesLoaded`),
  /// so the later arming supersedes an in-flight one instead of racing it into a
  /// duplicate `.seeded`.
  static let seed = "repositories.tasks.seed"
}

extension RepositoriesFeature {
  @CasePathable
  enum TaskInboxAction: Equatable {
    /// Launch: read `~/.supacode/tasks.json`.
    case load
    case loaded(TaskStoreLoadResult)
    /// Day-one seeding. Idempotent twice over: the `didSeedTasks` flag and the
    /// seeder's per-directory dedupe against existing records (A13).
    case seedIfNeeded
    case seeded([TaskRecord])
    /// Open a task: stamp `lastVisitedAt`, make it the sidebar selection, and
    /// pre-position its owning worktree on an owned surface.
    case select(TaskID)
    /// Explicit settle. The only settle path in Phase 1 (no cascade yet).
    case settle(TaskID)
    case unsettle(TaskID)
    case setSettledTailExpanded(Bool)
    case expandSettledTail
    /// Drop owned surfaces that no longer exist, without deleting the task (A10b).
    case reconcileSurfaceOwnership
    /// Claim a tab for the directory's task, creating one when there is none.
    /// `tabID == nil` means the layout's selected tab, which is what a menu
    /// command with no explicit target means.
    case promoteTab(worktreeID: Worktree.ID, tabID: TerminalTabID?)
  }

  var tasksReducer: some Reducer<State, Action> {
    Reduce { state, action in
      @Dependency(\.date.now) var now
      switch action {
      case .tasks(.load):
        guard !state.hasLoadedTasks else { return .none }
        return .run { send in await send(.tasks(.loaded(Self.loadTaskStoreFile()))) }

      case .tasks(.loaded(let result)):
        state.hasLoadedTasks = true
        guard let file = result.file else {
          // A present-but-unreadable file: saving or seeding on top of it would
          // erase tasks we simply failed to read.
          state.isTaskPersistenceDisabled = true
          tasksLogger.error(
            """
            tasks.json is present but unreadable; task persistence and day-one \
            seeding are disabled for this launch.
            """
          )
          return .none
        }
        state.taskStoreSchemaVersion = file.schemaVersion
        state.didSeedTasks = file.didSeedTasks
        state.taskRecords = IdentifiedArray(uniqueElements: file.tasks)
        return .merge(
          .send(.tasks(.reconcileSurfaceOwnership)),
          .send(.tasks(.seedIfNeeded))
        )

      case .tasks(.seedIfNeeded):
        guard state.hasLoadedTasks, !state.didSeedTasks, !state.isTaskPersistenceDisabled else {
          return .none
        }
        // Seeding reads the roster for titles, branches and surfaces, so it
        // waits for the load that carries them; `.repositoriesLoaded` re-arms it.
        guard state.isInitialLoadComplete else { return .none }
        let inputs = state.taskSeedInputs()
        guard !inputs.isEmpty else { return .none }
        let existing = Array(state.taskRecords)
        return .run { send in
          let records = Self.seedRecords(inputs: inputs, existingTasks: existing, now: now)
          await send(.tasks(.seeded(records)))
        }
        .cancellable(id: TaskCancelID.seed, cancelInFlight: true)

      case .tasks(.seeded(let records)):
        guard !state.didSeedTasks, !state.isTaskPersistenceDisabled else { return .none }
        // An empty seed does NOT flip the flag: an install with no evidence yet
        // must still seed once real work exists, and re-running the seeder over
        // zero candidates costs nothing.
        guard !records.isEmpty else { return .none }
        state.taskRecords.append(contentsOf: records.filter { state.taskRecords[id: $0.id] == nil })
        state.didSeedTasks = true
        return Self.persistTasksEffect(state: state)

      case .tasks(.select(let id)):
        guard state.taskRecords[id: id] != nil else { return .none }
        // `.selectionChanged` owns the exclusivity rules (a task selection drops
        // the worktree selection), stamps `lastVisitedAt` and persists, and
        // leaves `sidebar.json` alone (A11). This arm only adds focus, so a
        // selection that arrives by any other route still gets the stamp.
        var effects: [Effect<Action>] = [
          .send(.selectionChanged([.task(id)]))
        ]
        if let focus = state.taskFocusDelegate(for: id) {
          effects.append(.send(.delegate(focus)))
        }
        return .merge(effects)

      case .tasks(.settle(let id)):
        guard let record = state.taskRecords[id: id] else { return .none }
        // Idempotent: a second settle must not re-stamp `settledAt` and jump the
        // task back to the head of the settled tail (which sorts by that stamp).
        guard record.settledAt == nil else { return .none }
        let hibernation = state.taskHibernationDelegate(for: record)
        // Always stamped, never derived: the settled tail sorts and labels by
        // this one timestamp (A17), and an explicit `.active` override would
        // otherwise beat the settle the user just asked for.
        state.taskRecords[id: id]?.settledAt = now
        if record.settledOverride == .active {
          state.taskRecords[id: id]?.settledOverride = nil
        }
        var effects: [Effect<Action>] = [Self.persistTasksEffect(state: state)]
        if let hibernation {
          effects.append(.send(.delegate(hibernation)))
        }
        return .merge(effects)

      case .tasks(.unsettle(let id)):
        guard state.taskRecords[id: id] != nil else { return .none }
        state.taskRecords[id: id]?.settledAt = nil
        // Cleared rather than set to `.active`: Phase 1 has no auto-settle to
        // defend against, and a sticky override would block Phase 2's cascade
        // forever. Sessions are not woken here — opening the task does that.
        state.taskRecords[id: id]?.settledOverride = nil
        return Self.persistTasksEffect(state: state)

      case .tasks(.setSettledTailExpanded(let isExpanded)):
        guard state.isSettledTailExpanded != isExpanded else { return .none }
        state.isSettledTailExpanded = isExpanded
        // Collapsing resets the page window so re-opening the shelf starts at
        // the first page instead of however deep the last visit paged.
        if !isExpanded {
          state.settledTailVisibleCount = TasksSidebarStructure.settledTailInitialCount
        }
        return .none

      case .tasks(.expandSettledTail):
        state.settledTailVisibleCount = TasksSidebarStructure.expandedSettledVisibleCount(
          from: state.settledTailVisibleCount
        )
        return .none

      case .tasks(.reconcileSurfaceOwnership):
        guard state.reconcileTaskSurfaceOwnership() else { return .none }
        return Self.persistTasksEffect(state: state)

      case .tasks(.promoteTab(let worktreeID, let tabID)):
        // An unreadable tasks.json disables the inbox for the launch: a claim
        // written on top of records we failed to read would erase them.
        guard !state.isTaskPersistenceDisabled else { return .none }
        guard state.promoteTab(worktreeID: worktreeID, tabID: tabID, now: now) else { return .none }
        // Bookkeeping only: the live tab keeps its sessions, its scrollback and
        // the selection it had (A21).
        return Self.persistTasksEffect(state: state)

      // A surface set drifted (a tab closed, a worktree restored). Ownership is
      // reconciled off the same projection the rows use, and only when there is
      // a task to reconcile, so a build with an empty inbox fires nothing.
      case .sidebarItems(.element(id: _, action: .terminalProjectionChanged)):
        guard !state.taskRecords.isEmpty else { return .none }
        return .send(.tasks(.reconcileSurfaceOwnership))

      default:
        return .none
      }
    }
  }

  // MARK: - Store I/O

  /// `nonisolated` so the read runs off the main thread: the target compiles with
  /// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, which would otherwise put this
  /// file I/O on the main actor (the `TaskActivitySeeder` precedent). The
  /// `Effect.run` closures that call it are `@Sendable`, hence nonisolated, so a
  /// plain synchronous call already lands on the generic executor.
  nonisolated static func loadTaskStoreFile() -> TaskStoreLoadResult {
    TaskStore().load()
  }

  /// Whole-file save. Never throws out: a refused write (schema from a newer
  /// build) or an I/O failure is logged by `TaskStore` and must not take the app
  /// down over a lifecycle stamp.
  nonisolated static func saveTaskStoreFile(_ file: TaskStoreFile) {
    try? TaskStore().save(file)
  }

  /// Persists the whole inbox, or nothing when the load was `.unreadable`.
  static func persistTasksEffect(state: State) -> Effect<Action> {
    guard !state.isTaskPersistenceDisabled else { return .none }
    let file = state.taskStoreFile
    return .run { _ in Self.saveTaskStoreFile(file) }
      .cancellable(id: TaskCancelID.persist, cancelInFlight: true)
  }

  // MARK: - Seeding

  /// Off-main evidence gathering + seeding. The reducer collects what only state
  /// knows (paths, titles, branches, owned surfaces); the filesystem reads
  /// (reflog, scrollback mtimes) and the pure seeding decision happen here.
  nonisolated static func seedRecords(
    inputs: [TaskSeedInput],
    existingTasks: [TaskRecord],
    now: Date
  ) -> [TaskRecord] {
    var surfacesByPath: [String: Set<UUID>] = [:]
    var candidates: [TaskActivitySeeder.Candidate] = []
    candidates.reserveCapacity(inputs.count)
    for input in inputs {
      // Canonicalized here, not in the reducer: the seeder's idempotency key is
      // the directory path, and it cannot resolve symlinks itself (it is pure),
      // so two spellings of one directory would seed twice.
      let path = TaskDirectoryPath.canonical(input.directoryURL)
      surfacesByPath[path, default: []].formUnion(input.surfaceIDs)
      candidates.append(
        TaskActivitySeeder.Candidate(
          directoryPath: path,
          customizationTitle: input.customizationTitle,
          worktreeName: input.worktreeName,
          worktreeDetail: input.worktreeDetail,
          currentBranch: input.currentBranch,
          hasLiveSurfaces: !input.surfaceIDs.isEmpty,
          scrollbackLastMountedAt: newestScrollbackDate(for: input.surfaceIDs),
          reflogEntries: GitReflogReader.read(worktreeURL: input.directoryURL),
          // Phase 1 has no cheap ref enumeration in state, and reading every
          // repo's refs at launch would be a worse trade than the rare
          // tag-labelled-as-branch the seeder documents.
          knownBranches: nil,
          repositoryID: input.repositoryID
        )
      )
    }
    return TaskActivitySeeder.seeds(candidates: candidates, existingTasks: existingTasks, now: now)
      .map { record in
        var record = record
        // Claims are per directory in Phase 1, so a task owns every surface of
        // the directory it seeded from — which makes "one tab, one task"
        // (plan Resolved #10) true by construction.
        record.surfaceIDs = surfacesByPath[record.directoryPath] ?? []
        return record
      }
  }

  /// Newest scrollback mtime across the surfaces. A *last-mounted* signal only
  /// (the persist loop rewrites every live surface every 30s), which is exactly
  /// how `TaskActivitySeeder` treats it.
  private nonisolated static func newestScrollbackDate(for surfaceIDs: Set<UUID>) -> Date? {
    surfaceIDs.compactMap { surfaceID in
      let url = SupacodePaths.scrollbackFileURL(for: surfaceID)
      return try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }
    .max()
  }
}

/// What only the reducer knows about one candidate directory at seed time.
nonisolated struct TaskSeedInput: Equatable, Sendable {
  var directoryURL: URL
  var customizationTitle: String?
  var worktreeName: String?
  var worktreeDetail: String?
  var currentBranch: String?
  var surfaceIDs: Set<UUID>
  var repositoryID: Repository.ID?
}

/// Directory-path comparison for task records.
///
/// Two spellings: `normalized` is pure (collapses `//`, `..`, trailing slashes)
/// and safe to call from the reducer; `canonical` additionally resolves
/// symlinks, which touches the filesystem and therefore belongs in an effect.
/// Records always store the canonical form.
nonisolated enum TaskDirectoryPath {
  static func normalized(_ path: String) -> String {
    let trimmed = path.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return "" }
    var standardized = URL(filePath: trimmed).standardizedFileURL.path(percentEncoded: false)
    while standardized.count > 1, standardized.hasSuffix("/") {
      standardized.removeLast()
    }
    return standardized
  }

  static func canonical(_ url: URL) -> String {
    normalized(url.resolvingSymlinksInPath().path(percentEncoded: false))
  }
}

extension RepositoriesFeature.State {
  /// The value written to `tasks.json`. Carries the loaded schema version so a
  /// file from a newer build is refused by `TaskStore.save` rather than
  /// downgraded in place.
  var taskStoreFile: TaskStoreFile {
    var file = TaskStoreFile(
      didSeedTasks: didSeedTasks,
      tasks: Array(taskRecords)
    )
    file.schemaVersion = taskStoreSchemaVersion
    return file
  }

  /// Candidate directories for day-one seeding, straight from the live rows.
  /// Remote rows are excluded: reflog and scrollback evidence is local-only, and
  /// reading a remote path as a local one would be reading the wrong directory.
  func taskSeedInputs() -> [TaskSeedInput] {
    sidebarItems.compactMap { row in
      guard row.host == nil, !row.isMissing else { return nil }
      return TaskSeedInput(
        directoryURL: row.workingDirectory,
        customizationTitle: row.customTitle,
        worktreeName: row.name,
        worktreeDetail: row.subtitle,
        // A detached or unreadable HEAD reports no branch rather than a guess (A2).
        currentBranch: row.isAttached && !row.branchName.isEmpty ? row.branchName : nil,
        surfaceIDs: Set(row.surfaceIDs),
        repositoryID: row.repositoryID
      )
    }
  }

  /// The live row for a task's directory, or `nil` when the directory has none
  /// (a worktree that was deleted — the task outlives it).
  func sidebarItemForTaskDirectory(_ path: String) -> SidebarItemFeature.State? {
    let target = TaskDirectoryPath.normalized(path)
    guard !target.isEmpty else { return nil }
    if let row = sidebarItems.first(where: { row in
      row.host == nil && TaskDirectoryPath.normalized(row.workingDirectory.path(percentEncoded: false)) == target
    }) {
      return row
    }
    // Fallback for a row whose own path contains a symlink: records store the
    // canonical path, so the pure comparison above misses it. Costs a `stat` per
    // row and only runs when the cheap pass already failed.
    return sidebarItems.first { row in
      row.host == nil && TaskDirectoryPath.canonical(row.workingDirectory) == target
    }
  }

  /// Whether no *other* live (non-settled) task points at the same directory.
  /// Terminal hibernation is worktree/tab-keyed in Phase 1, so a shared
  /// directory defers hibernation entirely (A6) rather than risking another
  /// task's sessions.
  func isSoleActiveTaskOwner(of record: TaskRecord) -> Bool {
    let directory = TaskDirectoryPath.normalized(record.directoryPath)
    return !taskRecords.contains { other in
      guard other.id != record.id else { return false }
      guard !TasksSidebarStructure.isSettled(other) else { return false }
      return TaskDirectoryPath.normalized(other.directoryPath) == directory
    }
  }

  /// Surfaces owned by every task except this one. The parent subtracts their
  /// tabs from the hibernation target set (A7).
  func taskSurfaceIDs(excluding id: TaskID) -> Set<UUID> {
    taskRecords.reduce(into: Set<UUID>()) { result, record in
      guard record.id != id else { return }
      result.formUnion(record.surfaceIDs)
    }
  }

  /// The hibernation request for an explicit settle, or `nil` when Phase 1
  /// refuses to hibernate: no owned surfaces, no live worktree for the
  /// directory, or the directory is shared with another live task.
  func taskHibernationDelegate(for record: TaskRecord) -> RepositoriesFeature.Delegate? {
    guard !record.surfaceIDs.isEmpty else { return nil }
    guard let row = sidebarItemForTaskDirectory(record.directoryPath) else { return nil }
    guard isSoleActiveTaskOwner(of: record) else { return nil }
    return .hibernateTaskSurfaces(
      worktreeID: row.id,
      surfaceIDs: record.surfaceIDs,
      protectedSurfaceIDs: taskSurfaceIDs(excluding: record.id)
    )
  }

  /// The focus request for opening a task, or `nil` when there is nothing to
  /// focus. A settled task is deliberately excluded: focusing wakes a dormant
  /// tab, which would undo the settle just by browsing the tail.
  func taskFocusDelegate(for id: TaskID) -> RepositoriesFeature.Delegate? {
    guard let record = taskRecords[id: id] else { return nil }
    guard !TasksSidebarStructure.isSettled(record) else { return nil }
    guard let row = sidebarItemForTaskDirectory(record.directoryPath) else { return nil }
    // Deterministic pick so the same click always lands on the same surface.
    guard let surfaceID = record.surfaceIDs.min(by: { $0.uuidString < $1.uuidString }) else {
      return nil
    }
    return .focusTaskSurface(worktreeID: row.id, surfaceID: surfaceID)
  }

  /// Drops owned surfaces that no longer exist. Returns whether anything
  /// changed, so an unchanged inbox writes no file.
  ///
  /// Only a row that has reported a terminal projection is authoritative: before
  /// that, `surfaceIDs` still holds the UUIDs seeded from the last-quit layout,
  /// and reconciling against it would erase live claims. A directory with no row
  /// at all (deleted worktree) keeps its claims untouched — the task survives
  /// either way (A10b).
  ///
  /// A surface is only pruned when it is absent from the live projection *and*
  /// from the row's persisted layout. Restore emits one projection per tab
  /// (`WorktreeTerminalState` calls `onTabCreated` inside the restore loop), and
  /// `hasTerminalProjection` latches on the first of them, so a projection-only
  /// check would prune tabs 2..n of a multi-tab restore and persist the loss.
  /// The layouts snapshot knows every tab, so it is the backstop; a genuinely
  /// closed tab drops out of both (the close path marks the layout dirty and
  /// rewrites it).
  @MainActor
  mutating func reconcileTaskSurfaceOwnership() -> Bool {
    var didChange = false
    for record in Array(taskRecords) {
      guard !record.surfaceIDs.isEmpty else { continue }
      guard let row = sidebarItemForTaskDirectory(record.directoryPath), row.hasTerminalProjection else {
        continue
      }
      var known = Set(row.surfaceIDs)
      known.formUnion(persistedLayouts[row.id.rawValue]?.allSurfaceIDs ?? [])
      let live = record.surfaceIDs.intersection(known)
      guard live != record.surfaceIDs else { continue }
      taskRecords[id: record.id]?.surfaceIDs = live
      didChange = true
    }
    return didChange
  }

  /// Claims a tab's surfaces for the directory's task. Returns whether anything
  /// changed, so a re-promotion of an already-owned tab writes no file (A21).
  ///
  /// Claims are tab-granular (plan Resolved #10): the whole split tree moves, so
  /// a tab can never hold two tasks' surfaces. The only tab-to-surface map the
  /// reducer has is the persisted layout snapshot, which also knows which tab is
  /// selected when the caller names none.
  ///
  /// Surfaces are stripped from every other record rather than shared: explicit
  /// user intent beats stale ownership (A3), and a stripped record is never
  /// deleted — losing a claim is not the end of a task (A10b).
  @MainActor
  mutating func promoteTab(worktreeID: Worktree.ID, tabID: TerminalTabID?, now: Date) -> Bool {
    guard let row = sidebarItems[id: worktreeID] else { return false }
    guard let snapshot = persistedLayouts[worktreeID.rawValue] else { return false }
    guard let tab = Self.tabSnapshot(in: snapshot, id: tabID) else { return false }
    let surfaceIDs = Set(tab.layout.leafSurfaceIDs)
    guard !surfaceIDs.isEmpty else { return false }

    let directoryPath = TaskDirectoryPath.canonical(row.workingDirectory)
    let target = newestActiveTask(inDirectory: directoryPath)
    guard target?.surfaceIDs.isSuperset(of: surfaceIDs) != true else { return false }

    for record in taskRecords where record.id != target?.id && !record.surfaceIDs.isDisjoint(with: surfaceIDs) {
      taskRecords[id: record.id]?.surfaceIDs.subtract(surfaceIDs)
    }
    guard let target else {
      taskRecords.append(
        TaskRecord(
          title: TaskActivitySeeder.title(
            for: TaskActivitySeeder.Candidate(
              directoryPath: directoryPath,
              customizationTitle: row.customTitle,
              worktreeName: row.name,
              worktreeDetail: row.subtitle
            ),
            branch: provableBranch(for: row)
          ),
          directoryPath: directoryPath,
          branch: provableBranch(for: row),
          repositoryID: row.repositoryID,
          createdAt: now,
          surfaceIDs: surfaceIDs,
          seedEvidence: TaskRecord.SeedEvidence(source: .manual, confidence: .high)
        )
      )
      return true
    }
    taskRecords[id: target.id]?.surfaceIDs.formUnion(surfaceIDs)
    return true
  }

  /// A detached or unreadable HEAD reports no branch rather than a guess (A2).
  private func provableBranch(for row: SidebarItemFeature.State) -> String? {
    row.isAttached && !row.branchName.isEmpty ? row.branchName : nil
  }

  /// Newest-created active task for the directory. Two active tasks may share a
  /// directory (plan Resolved #11), so the join target has to be deterministic;
  /// newest-created is the order the Tasks tab already puts at the top (A4).
  private func newestActiveTask(inDirectory path: String) -> TaskRecord? {
    let target = TaskDirectoryPath.normalized(path)
    return taskRecords
      .filter { !TasksSidebarStructure.isSettled($0) }
      .filter { TaskDirectoryPath.normalized($0.directoryPath) == target }
      .max { ($0.createdAt, $0.id.rawValue) < ($1.createdAt, $1.id.rawValue) }
  }

  /// The named tab, or the one the layout has selected when the caller named none.
  private static func tabSnapshot(
    in snapshot: TerminalLayoutSnapshot,
    id: TerminalTabID?
  ) -> TerminalLayoutSnapshot.TabSnapshot? {
    guard let id else {
      guard snapshot.tabs.indices.contains(snapshot.selectedTabIndex) else { return nil }
      return snapshot.tabs[snapshot.selectedTabIndex]
    }
    return snapshot.tabs.first { $0.id == id.rawValue }
  }

  /// The worktree the terminal manager should treat as selected while a task row
  /// is open. A task selection clears the worktree selection, and a nil terminal
  /// selection makes `refreshTabVisibility` arm the hibernation grace timer on
  /// every tab of the owning worktree — including the tab the user just opened.
  /// Pointing the manager at the owning worktree keeps the focused task tab
  /// visible without touching `sidebar.json` (A11).
  var taskTerminalWorktreeID: Worktree.ID? {
    guard let taskID = selection?.taskID, let record = taskRecords[id: taskID] else { return nil }
    guard !record.surfaceIDs.isEmpty, !TasksSidebarStructure.isSettled(record) else { return nil }
    return sidebarItemForTaskDirectory(record.directoryPath)?.id
  }

  // MARK: - Cache recomputes

  /// Equatable-diffs the Tasks render plan against the cache, so the panel only
  /// rebuilds when the rows it renders actually change. Mirrors
  /// `recomputeAgentDashboardStructureIfChanged()`.
  @MainActor
  mutating func recomputeTasksSidebarStructureIfChanged() {
    let new = TasksSidebarStructure.compute(
      tasks: Array(taskRecords),
      openTaskID: selection?.taskID,
      settledVisibleCount: settledTailVisibleCount,
      isSettledTailExpanded: isSettledTailExpanded
    )
    if new != tasksSidebarStructure {
      tasksSidebarStructure = new
    }
  }

  /// Refreshes the cached worktree the detail pane renders for a selected task,
  /// Equatable-diffed like every other post-reduce cache. Rides the same
  /// invalidation bits as the Tasks render plan: it reads the selection, the
  /// task records, and the row roster, nothing else.
  @MainActor
  mutating func recomputeTaskDetailWorktreeIDIfChanged() {
    let new = taskTerminalWorktreeID
    if new != taskDetailWorktreeID {
      taskDetailWorktreeID = new
    }
  }

  /// Projects per-row agent / notification / dormancy state onto the tasks that
  /// own those surfaces. Activity is never an input to the structure, so this
  /// updates a row without reordering it (A4).
  ///
  /// `RowSnapshot` carries no surface id ("callers scope by surface set"), so a
  /// task that owns only *part* of a worktree's surfaces inherits the whole
  /// row's snapshot. Exact for Phase 1, where a seeded task owns every surface
  /// in its directory; Phase 3's promote-tab claims are the case that will need
  /// per-surface presence.
  ///
  /// Rows are found by directory rather than by inverting every surface: Phase 1
  /// has exactly one row per task, and this runs on every agent tick, so a
  /// per-tick `surfaceToItemID` rebuild would be paid for nothing.
  ///
  /// Mutates `taskLeaves` per element. Replacing the container would publish a
  /// whole-array change and fan invalidation out to every row (A10).
  @MainActor
  mutating func recomputeTaskLeavesIfChanged() {
    guard !taskRecords.isEmpty || !taskLeaves.isEmpty else { return }
    var rowIDsByPath: [String: SidebarItemID] = [:]
    rowIDsByPath.reserveCapacity(sidebarItems.count)
    for row in sidebarItems where row.host == nil {
      rowIDsByPath[TaskDirectoryPath.normalized(row.workingDirectory.path(percentEncoded: false))] = row.id
    }

    var liveIDs: Set<TaskID> = []
    liveIDs.reserveCapacity(taskRecords.count)
    for record in taskRecords {
      liveIDs.insert(record.id)
      var leaf = TaskLeafState(id: record.id)
      if !record.surfaceIDs.isEmpty,
        let rowID = rowIDsByPath[TaskDirectoryPath.normalized(record.directoryPath)],
        let row = sidebarItems[id: rowID]
      {
        leaf.agentSnapshot = row.agentSnapshot
        leaf.hasUnseenNotifications = row.hasUnseenNotifications
        leaf.allSurfacesDormant = row.allTabsDormant
      }
      if taskLeaves[id: record.id] != leaf {
        taskLeaves[id: record.id] = leaf
      }
    }
    for staleID in Array(taskLeaves.ids) where !liveIDs.contains(staleID) {
      taskLeaves.remove(id: staleID)
    }
  }
}

extension RepositoriesFeature.TaskInboxAction {
  /// Which post-reduce caches each task arm touches. Exhaustive (no `default`)
  /// so a new arm has to declare it.
  var cacheInvalidations: CacheInvalidations {
    switch self {
    // Effect launchers: they mutate nothing the caches project.
    case .load, .seedIfNeeded:
      return []
    // Every arm that can change the record set, its lifecycle, or the page window.
    case .loaded, .seeded, .select, .settle, .unsettle,
      .setSettledTailExpanded, .expandSettledTail, .reconcileSurfaceOwnership, .promoteTab:
      return .sidebarStructure
    }
  }
}

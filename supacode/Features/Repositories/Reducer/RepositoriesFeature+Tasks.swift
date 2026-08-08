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
    /// `tabID == nil` means the tab the worktree currently has selected, which
    /// is what a menu command with no explicit target means.
    ///
    /// `taskID` names the task the claim belongs to. The menu path leaves it
    /// nil — "this tab belongs to whatever task is live here" — but a creation
    /// flow knows exactly which record it just minted, and two quick captures in
    /// one directory would otherwise both resolve to the newest one and hand it
    /// both tabs.
    case promoteTab(worktreeID: Worktree.ID, tabID: TerminalTabID?, taskID: TaskID? = nil)
    /// ⌘N on the Tasks tab: open the capture prompt over the live roster.
    case presentCreationPrompt
    /// Create a task in `directoryURL`. `title == nil` hands naming to the
    /// seeder's cascade, which is the fast path for an untitled capture.
    case createTask(title: String?, directoryURL: URL)
    /// The conflict sheet's "remember for this repository" toggle.
    case setConflictRemember(Bool)
    /// Answer the open conflict question and resume the parked capture.
    case resolveDirectoryConflict(TaskDirectoryIsolation)
    /// Dismiss it. A20b: no record, no worktree, no write.
    case cancelDirectoryConflict
    /// A worktree was minted for a capture. Carries the git-reported `Worktree`
    /// (not just its path) so the roster gets the real row — its kind, its
    /// creation date, its attachment — rather than one reconstructed from a
    /// string.
    case autoManagedWorktreeCreated(TaskRecord, worktree: Worktree)
    /// Both attempts failed. Nothing was persisted, so this only reports (A20b).
    case autoManagedWorktreeCreationFailed(title: String, directoryPath: String, message: String)
    /// Re-check Resolved #9's preconditions and, if they all hold, delete the
    /// worktree a settled task's marker authorizes.
    case cleanupAutoManagedWorktree(TaskID)
    case autoManagedWorktreeCleanupFinished(taskID: TaskID, didDelete: Bool)
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
        // Cleanup rides on the settle, always *after* the hibernation request:
        // deleting a directory that still has live sessions in it is how a
        // settle turns into data loss. A shared directory is nobody's to delete
        // (A6), which is the same reason it is nobody's to hibernate.
        if record.autoManagedWorktree != nil,
          state.isSoleActiveTaskOwner(of: record),
          state.autoManagedCleanupWorktree(for: record) != nil
        {
          effects.append(.send(.tasks(.cleanupAutoManagedWorktree(id))))
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

      case .tasks(.promoteTab(let worktreeID, let requestedTabID, let requestedTaskID)):
        // An unreadable tasks.json disables the inbox for the launch: a claim
        // written on top of records we failed to read would erase them.
        guard !state.isTaskPersistenceDisabled else {
          tasksLogger.debug("Promote refused: task persistence is disabled for this launch.")
          return .none
        }
        @Dependency(\.terminalClient) var terminalClient
        // The *live* selected tab, never the persisted layout's
        // `selectedTabIndex`: that snapshot is rewritten on quit / background, so
        // between saves it names whatever tab was selected last time the file was
        // written. A menu click means "the tab I am looking at now".
        guard let tabID = requestedTabID ?? terminalClient.selectedTabID(worktreeID) else {
          tasksLogger.debug("Promote refused: \(worktreeID) has no selected tab to claim.")
          return .none
        }
        let liveSurfaceIDs = terminalClient.tabSurfaceIDs(worktreeID, tabID)
        guard
          let taskID = state.promoteTab(
            worktreeID: worktreeID,
            tabID: tabID,
            taskID: requestedTaskID,
            liveSurfaceIDs: liveSurfaceIDs,
            now: now
          )
        else {
          tasksLogger.debug("Promote claimed nothing for tab \(tabID) of \(worktreeID).")
          return .none
        }
        // Bookkeeping plus navigation: the live tab keeps its sessions, its
        // scrollback and the tab selection it had (A21), and the sidebar opens
        // the task so a click has a visible result. `.select` owns the persist
        // (via `.selectionChanged`), so the claim is written exactly once.
        return .send(.tasks(.select(taskID)))

      case .tasks(.presentCreationPrompt):
        state.taskCreationPrompt = TaskCreationPromptFeature.State(
          candidates: state.taskCreationCandidates()
        )
        return .none

      case .tasks(.createTask(let title, let directoryURL)):
        // An unreadable tasks.json disables the inbox for the launch: writing a
        // new record on top of ones we failed to read would erase them.
        guard !state.isTaskPersistenceDisabled else {
          tasksLogger.debug("Task creation refused: task persistence is disabled for this launch.")
          return .none
        }
        // A19 counts interactions, and a sheet the user has to dismiss is a
        // third one, so submit closes the prompt itself.
        state.taskCreationPrompt = nil
        // Canonicalized inline, the documented one-shot exception: the directory
        // path is the record's identity, so a second spelling would fork the task.
        let directoryPath = TaskDirectoryPath.canonical(directoryURL)
        // Switched rather than compared so no answer can silently fall through
        // to the shared path — that would ship an isolation policy that shares.
        switch state.taskDirectoryConflictPolicy(forDirectory: directoryPath) {
        case .useDirectly, .share:
          return state.reduceTaskCreation(title: title, directoryPath: directoryPath, now: now)

        case .ask:
          guard let repository = state.taskCaptureRepository(forDirectory: directoryPath) else {
            // Unreachable: `.ask` is only returned when a repository answered it.
            return state.reduceTaskCreation(title: title, directoryPath: directoryPath, now: now)
          }
          state.taskDirectoryConflict = TaskDirectoryConflictPrompt(
            title: title,
            directoryURL: directoryURL,
            directoryPath: directoryPath,
            repositoryID: repository.id,
            incumbentTitle: state.newestActiveTask(inDirectory: directoryPath)?.title
          )
          // Nothing is committed while the question is open (A20b, one step
          // earlier): no record, no selection move, no write.
          return .none

        case .isolate:
          guard let repository = state.taskCaptureRepository(forDirectory: directoryPath) else {
            return state.reduceTaskCreation(title: title, directoryPath: directoryPath, now: now)
          }
          return isolatedCaptureEffect(
            state: state,
            title: title,
            directoryPath: directoryPath,
            repository: repository,
            now: now
          )
        }

      case .tasks(.setConflictRemember(let shouldRemember)):
        state.taskDirectoryConflict?.shouldRemember = shouldRemember
        return .none

      case .tasks(.cancelDirectoryConflict):
        state.taskDirectoryConflict = nil
        return .none

      case .tasks(.resolveDirectoryConflict(let isolation)):
        guard let prompt = state.taskDirectoryConflict else { return .none }
        state.taskDirectoryConflict = nil
        let repository = state.repositories[id: prompt.repositoryID]
        // Remembering is what keeps A19's budget intact past the first conflict:
        // it writes the per-repository policy, and every later busy capture
        // resolves without a sheet.
        if prompt.shouldRemember, let repository {
          @Shared(.repositorySettings(repository.rootURL, host: repository.host))
          var repositorySettings
          $repositorySettings.withLock { $0.taskDirectoryIsolation = isolation }
        }
        // A repository that vanished between question and answer cannot be
        // branched from; A20 forbids blocking creation, so it shares.
        guard isolation == .isolate, let repository else {
          return state.reduceTaskCreation(
            title: prompt.title,
            directoryPath: prompt.directoryPath,
            now: now
          )
        }
        return isolatedCaptureEffect(
          state: state,
          title: prompt.title,
          directoryPath: prompt.directoryPath,
          repository: repository,
          now: now
        )

      case .tasks(.autoManagedWorktreeCreated(let record, let worktree)):
        guard !state.isTaskPersistenceDisabled else { return .none }
        if let repositoryID = record.repositoryID {
          // The row has to reach the roster before the terminal request leaves,
          // or `taskTerminalRequestDelegate` has nothing to resolve and the
          // capture that just spent a worktree opens no terminal in it.
          state.insertWorktree(worktree, repositoryID: repositoryID)
          Self.syncSidebar(&state)
        }
        return state.reduceCreatedTask(record)

      case .tasks(.autoManagedWorktreeCreationFailed(let title, let directoryPath, let message)):
        tasksLogger.error(
          "Auto-managed worktree creation failed for '\(title)' in \(directoryPath): \(message)"
        )
        // A20b: nothing was persisted, so the failure is all there is to report —
        // on the same surface every other worktree creation failure uses.
        state.alert = messageAlert(title: "Unable to create worktree", message: message)
        return .none

      case .tasks(.cleanupAutoManagedWorktree(let id)):
        guard let record = state.taskRecords[id: id],
          let marker = record.autoManagedWorktree,
          let worktree = state.autoManagedCleanupWorktree(for: record)
        else {
          return .none
        }
        @Dependency(GitClientDependency.self) var client
        return .run { send in
          let didDelete = await Self.deleteAutoManagedWorktree(
            gitClient: client,
            worktree: worktree,
            marker: marker
          )
          await send(.tasks(.autoManagedWorktreeCleanupFinished(taskID: id, didDelete: didDelete)))
        }

      case .tasks(.autoManagedWorktreeCleanupFinished(let taskID, let didDelete)):
        // Refused: the marker survives, because the directory is still ours — we
        // just refuse to act on it right now.
        guard didDelete, state.taskRecords[id: taskID]?.autoManagedWorktree != nil else {
          return .none
        }
        // Cleared once the directory is gone, so a later settle / unsettle round
        // cannot re-authorize a delete against a path something else took over.
        state.taskRecords[id: taskID]?.autoManagedWorktree = nil
        return Self.persistTasksEffect(state: state)

      case .taskCreationPrompt(.presented(.delegate(.cancel))):
        // A20b: cancel leaves nothing behind — no record, and no write at all.
        state.taskCreationPrompt = nil
        return .none

      case .taskCreationPrompt(.presented(.delegate(.createTask(let title, let directoryURL)))):
        return .send(.tasks(.createTask(title: title, directoryURL: directoryURL)))

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

  // MARK: - Auto-managed worktrees

  /// Step 3 of the Resolved #11 cascade: mint a worktree for the capture, then
  /// create the task in it.
  ///
  /// Creation never blocks (A20). The warm attempt CoW-clones the ignored cache
  /// directories so the worktree is usable the second it exists; if that fails
  /// it is retried *cold*, under the same name, because a worktree without its
  /// `node_modules` is a slow start rather than a failed capture. Only when both
  /// fail does the capture fail — and then it leaves nothing behind (A20b),
  /// which is why nothing is written to state until the worktree exists.
  func isolatedCaptureEffect(
    state: State,
    title: String?,
    directoryPath: String,
    repository: Repository,
    now: Date
  ) -> Effect<Action> {
    // The id is minted here, not in the effect: the branch name is derived from
    // it, so a retry cannot mint a second name — and a second name would leave
    // the record's marker authorizing a directory that was never created.
    let taskID = TaskID()
    let resolvedTitle = state.resolvedTaskTitle(title: title, directoryPath: directoryPath)
    let branch = TaskAutoWorktreeNaming.branchName(title: resolvedTitle, taskID: taskID)
    @Shared(.settingsFile) var settingsFile
    @Shared(.repositorySettings(repository.rootURL, host: repository.host)) var repositorySettings
    let baseDirectory = SupacodePaths.worktreeBaseDirectory(
      for: repository.rootURL,
      globalDefaultPath: settingsFile.global.defaultWorktreeBaseDirectoryPath,
      repositoryOverridePath: repositorySettings.worktreeBaseDirectoryPath
    )
    let configuredBaseRef = repositorySettings.worktreeBaseRef ?? ""
    let copyUntracked =
      repositorySettings.copyUntrackedOnWorktreeCreate
      ?? settingsFile.global.copyUntrackedOnWorktreeCreate
    @Dependency(GitClientDependency.self) var client
    return .run { send in
      var baseRef = configuredBaseRef
      if baseRef.isEmpty {
        baseRef = await client.automaticWorktreeBaseRef(repository.rootURL) ?? ""
      }
      var lastError: (any Error)?
      for attempt in [(warm: true, copyUntracked: copyUntracked), (warm: false, copyUntracked: false)] {
        do {
          let worktree = try await Self.finishedWorktree(
            from: client.createWorktreeStream(
              branch,
              repository.rootURL,
              baseDirectory,
              attempt.warm,
              attempt.copyUntracked,
              baseRef,
              nil
            )
          )
          let directory = TaskDirectoryPath.canonical(worktree.workingDirectory)
          let record = TaskRecord(
            id: taskID,
            title: resolvedTitle,
            directoryPath: directory,
            branch: branch,
            repositoryID: repository.id,
            createdAt: now,
            // A3: a fresh task steals nothing. Its terminal arrives via the delegate.
            surfaceIDs: [],
            // A2: created, not inferred — never seeded confidence.
            seedEvidence: TaskRecord.SeedEvidence(source: .manual, confidence: .high),
            // Resolved #9's marker, stamped at creation and at no other time. It
            // is the only thing that will ever authorize deleting this directory.
            autoManagedWorktree: TaskRecord.AutoManagedWorktree(
              path: directory,
              branch: branch,
              createdAt: now
            )
          )
          await send(.tasks(.autoManagedWorktreeCreated(record, worktree: worktree)))
          return
        } catch {
          lastError = error
          tasksLogger.warning(
            "Auto-managed worktree \(branch) failed to create (warm: \(attempt.warm)): \(error)"
          )
        }
      }
      await send(
        .tasks(
          .autoManagedWorktreeCreationFailed(
            title: resolvedTitle,
            directoryPath: directoryPath,
            message: lastError?.localizedDescription ?? "Worktree creation failed."
          )
        )
      )
    }
  }

  /// The worktree a creation stream ends with. Progress lines are dropped: an
  /// auto-managed worktree has no progress sheet to feed them to, and the whole
  /// point of the isolate path is that it does not stand in the user's way.
  nonisolated static func finishedWorktree(
    from stream: AsyncThrowingStream<GitWorktreeCreateEvent, Error>
  ) async throws -> Worktree {
    for try await event in stream {
      guard case .finished(let worktree) = event else { continue }
      return worktree
    }
    throw GitClientError.commandFailed(
      command: "wt sw",
      message: "Worktree creation finished without a result."
    )
  }

  /// Every Resolved #9 precondition, re-checked immediately before the delete
  /// and in a locked order: the directory still exists, it still resolves to the
  /// branch the marker named, and it holds no uncommitted work. Any mismatch —
  /// including one we cannot *prove* either way — refuses, leaking a directory
  /// rather than destroying work git cannot give back.
  ///
  /// The branch is kept in every case: it may carry commits, and dropping it is
  /// the one part of the delete that is not recoverable.
  nonisolated static func deleteAutoManagedWorktree(
    gitClient: GitClientDependency,
    worktree: Worktree,
    marker: TaskRecord.AutoManagedWorktree
  ) async -> Bool {
    let directory = worktree.workingDirectory
    guard await gitClient.rootDirectoryExists(directory) else {
      tasksLogger.debug("Auto-managed cleanup refused: \(marker.path) no longer exists.")
      return false
    }
    guard let branch = await gitClient.branchName(directory), branch == marker.branch else {
      tasksLogger.debug("Auto-managed cleanup refused: \(marker.path) is not on \(marker.branch).")
      return false
    }
    guard let changes = await gitClient.lineChanges(directory),
      changes.added == 0,
      changes.removed == 0
    else {
      tasksLogger.debug("Auto-managed cleanup refused: \(marker.path) has uncommitted work.")
      return false
    }
    do {
      _ = try await gitClient.removeWorktree(worktree, false)
    } catch {
      tasksLogger.warning("Auto-managed cleanup of \(marker.path) failed: \(error)")
      return false
    }
    return true
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
///
/// One documented exception: a reducer arm that *writes* a record's
/// `directoryPath` must canonicalize inline, because the record is the
/// idempotency key and a second spelling of one directory would create a second
/// task. Those arms are user-initiated one-shots (promote-tab), so the cost is a
/// single `stat` per click — not a per-row or per-tick walk, which stays in an
/// effect.
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
        currentBranch: row.provableBranch,
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

  // MARK: - The Resolved #11 cascade

  /// The repository a capture in `directoryPath` would branch from, or `nil`
  /// when the directory belongs to no registered local repository. A directory
  /// with no repository has nothing to branch from, so the cascade cannot reach
  /// step 3 there.
  func taskCaptureRepository(forDirectory directoryPath: String) -> Repository? {
    guard let row = sidebarItemForTaskDirectory(directoryPath) else { return nil }
    guard let repository = repositories[id: row.repositoryID], repository.host == nil else {
      return nil
    }
    return repository
  }

  /// Steps 1–3 of Resolved #11, resolved against live state. A directory with no
  /// repository answers `.useDirectly` however busy it is: A20 forbids blocking
  /// creation, and sharing is the only honest fallback.
  func taskDirectoryConflictPolicy(forDirectory directoryPath: String) -> TaskDirectoryConflictPolicy {
    guard let repository = taskCaptureRepository(forDirectory: directoryPath) else {
      return .useDirectly
    }
    @Shared(.repositorySettings(repository.rootURL, host: repository.host)) var repositorySettings
    return TaskDirectoryConflictPolicy.resolve(
      isDirectoryBusy: newestActiveTask(inDirectory: directoryPath) != nil,
      repositoryIsolation: repositorySettings.taskDirectoryIsolation
    )
  }

  /// The title a capture lands with: what the user typed, or the seeder's naming
  /// cascade over the directory's row when the capture was untitled.
  func resolvedTaskTitle(title: String?, directoryPath: String) -> String {
    let typed = title?.trimmingCharacters(in: .whitespacesAndNewlines)
    if let typed, !typed.isEmpty { return typed }
    let row = sidebarItemForTaskDirectory(directoryPath)
    return TaskActivitySeeder.title(
      for: TaskActivitySeeder.Candidate(
        directoryPath: directoryPath,
        customizationTitle: row?.customTitle,
        worktreeName: row?.name,
        worktreeDetail: row?.subtitle
      ),
      branch: row?.provableBranch
    )
  }

  /// Creates a task in a directory that already exists (steps 1 and 2).
  @MainActor
  mutating func reduceTaskCreation(
    title: String?,
    directoryPath: String,
    now: Date
  ) -> Effect<RepositoriesFeature.Action> {
    let row = sidebarItemForTaskDirectory(directoryPath)
    return reduceCreatedTask(
      TaskRecord(
        title: resolvedTaskTitle(title: title, directoryPath: directoryPath),
        directoryPath: directoryPath,
        branch: row?.provableBranch,
        repositoryID: row?.repositoryID,
        createdAt: now,
        // A3: a fresh task steals nothing. Its terminal arrives via the delegate.
        surfaceIDs: [],
        // A2: created, not inferred — the row must never render seeded confidence.
        seedEvidence: TaskRecord.SeedEvidence(source: .manual, confidence: .high)
      )
    )
  }

  /// Lands a freshly created record: append, open it, ask for its terminal.
  ///
  /// Selection is applied inline rather than routed through `.tasks(.select)`:
  /// the terminal request has to leave with the new task already open (A4), and
  /// a `.select` round-trip would land the selection one hop *after* the
  /// delegate the parent acts on. `reduceSelectionChangedEffect` is the same code
  /// `.selectionChanged` runs, so the stamp and the persist are identical — which
  /// is also the only write here: the new record reaches `tasks.json` on the back
  /// of that selection stamp, not a separate save.
  @MainActor
  mutating func reduceCreatedTask(_ record: TaskRecord) -> Effect<RepositoriesFeature.Action> {
    taskRecords.append(record)
    var effects: [Effect<RepositoriesFeature.Action>] = [
      reduceSelectionChangedEffect(selections: [.task(record.id)], focusTerminal: false)
    ]
    if let terminal = taskTerminalRequestDelegate(for: record) {
      effects.append(.send(.delegate(terminal)))
    }
    return .merge(effects)
  }

  /// The worktree a settled task's marker authorizes deleting, or `nil` when
  /// nothing may be deleted.
  ///
  /// A marker pointing at a registered repository root is a marker that is
  /// wrong, whatever it says: main checkouts are never deletable (A20), and that
  /// check is made here rather than in the effect so a bad marker never even
  /// reaches the git client.
  func autoManagedCleanupWorktree(for record: TaskRecord) -> Worktree? {
    guard let marker = record.autoManagedWorktree else { return nil }
    let path = TaskDirectoryPath.normalized(marker.path)
    guard !path.isEmpty else { return nil }
    guard !repositories.contains(where: { Self.directory($0.rootURL, matches: path) }) else {
      return nil
    }
    return repositories.lazy
      .flatMap(\.worktrees)
      .first { $0.host == nil && Self.directory($0.workingDirectory, matches: path) }
  }

  /// Cheap pure comparison first, symlink-resolving fallback second — records
  /// store canonical paths and rows do not, so the pure pass alone would miss a
  /// row whose own path contains a symlink (`sidebarItemForTaskDirectory`'s rule).
  private static func directory(_ url: URL, matches path: String) -> Bool {
    if TaskDirectoryPath.normalized(url.path(percentEncoded: false)) == path { return true }
    return TaskDirectoryPath.canonical(url) == path
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

  /// The terminal request for a freshly created task, or `nil` when its
  /// directory has no live worktree row — the inbox outlives worktrees (A10b),
  /// so the task is still created, but there is nothing to open a terminal in
  /// and guessing one would be worse than skipping it. What a row-less directory
  /// deserves is Phase 3c's call.
  ///
  /// Payload-level lock mirroring `taskHibernationDelegate`: the request names
  /// the row that owns the directory and the task it is for, so the parent never
  /// re-resolves either.
  func taskTerminalRequestDelegate(for record: TaskRecord) -> RepositoriesFeature.Delegate? {
    guard let row = sidebarItemForTaskDirectory(record.directoryPath) else { return nil }
    return .openTaskTerminal(worktreeID: row.id, taskID: record.id)
  }

  /// Pickable directories for the ⌘N capture prompt, straight from the live rows,
  /// with the directory the user is standing in first — an empty query renders
  /// the list verbatim, so ⌘N ↩ captures work where the user already is instead
  /// of wherever the roster happens to start.
  ///
  /// Remote rows are excluded for the same reason seeding excludes them: a task
  /// is a local directory lifecycle, and reading a remote path as a local one
  /// reads the wrong directory. Rows on their way out (archiving, deleting) are
  /// excluded too: capture would aim a task at a directory about to disappear.
  /// `.pending` stays — a worktree still running its setup script is a perfectly
  /// good place to line up the next piece of work.
  ///
  /// Symlinks are resolved here rather than inside the prompt: the candidate's
  /// id has to be comparable with `TaskRecord.directoryPath` (canonical), and a
  /// child reducer must not touch the filesystem. One `stat` per row on a
  /// user-initiated one-shot, which is the documented exception.
  func taskCreationCandidates() -> [TaskCreationPromptFeature.Candidate] {
    let busyPaths = Set(
      taskRecords
        .filter { !TasksSidebarStructure.isSettled($0) }
        .map { TaskDirectoryPath.normalized($0.directoryPath) }
    )
    let defaultRowID = taskCaptureDefaultRowID
    var preferred: TaskCreationPromptFeature.Candidate?
    var rest: [TaskCreationPromptFeature.Candidate] = []
    rest.reserveCapacity(sidebarItems.count)
    for row in sidebarItems {
      guard row.host == nil, !row.isMissing, !row.lifecycle.isTerminating else { continue }
      let directoryURL = row.workingDirectory.resolvingSymlinksInPath()
      let path = TaskDirectoryPath.normalized(directoryURL.path(percentEncoded: false))
      let candidate = TaskCreationPromptFeature.Candidate(
        directoryURL: directoryURL,
        repositoryName: repositories[id: row.repositoryID]?.name ?? "",
        branch: row.provableBranch,
        worktreeID: row.id,
        isBusy: busyPaths.contains(path)
      )
      if row.id == defaultRowID {
        preferred = candidate
      } else {
        rest.append(candidate)
      }
    }
    guard let preferred else { return rest }
    return [preferred] + rest
  }

  /// Where a capture defaults to. The selected worktree when there is one; on
  /// the Tasks tab there never is (a task selection is exclusive and clears it),
  /// so the row behind the open task stands in. Both answer the same question —
  /// which directory is the user looking at right now.
  private var taskCaptureDefaultRowID: Worktree.ID? {
    if let selectedWorktreeID { return selectedWorktreeID }
    guard let taskID = selection?.taskID, let record = taskRecords[id: taskID] else { return nil }
    return sidebarItemForTaskDirectory(record.directoryPath)?.id
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

  /// Claims a tab's surfaces for the directory's task. Returns the owning task,
  /// or `nil` when nothing changed — so a re-promotion of an already-owned tab
  /// writes no file (A21).
  ///
  /// Claims are tab-granular (plan Resolved #10): the whole split tree moves, so
  /// a tab can never hold two tasks' surfaces.
  ///
  /// `liveSurfaceIDs` is the tab's current split tree, read from the terminal.
  /// The persisted layout is unioned on top rather than used alone: it is
  /// rewritten only on background / quit, so between saves it misses panes split
  /// since (and knows nothing at all about a tab created since). Unioning also
  /// keeps a hibernated tab's frozen leaves in the claim.
  ///
  /// Surfaces are stripped from every other record rather than shared: explicit
  /// user intent beats stale ownership (A3), and a stripped record is never
  /// deleted — losing a claim is not the end of a task (A10b).
  ///
  /// `taskID` is the claim's target when the caller knows it. Creation does: the
  /// tab was minted *for* that record, and resolving by "newest active task in
  /// the directory" instead would let a second capture that lands mid-flight
  /// take the first one's tab. A named target is honored even when the record is
  /// already settled — the caller is naming a record it just acted on, and
  /// second-guessing that would silently claim for someone else. `nil` (the menu
  /// path, which only means "this tab") falls back to the newest active task.
  @MainActor
  mutating func promoteTab(
    worktreeID: Worktree.ID,
    tabID: TerminalTabID,
    taskID: TaskID? = nil,
    liveSurfaceIDs: Set<UUID>,
    now: Date
  ) -> TaskID? {
    guard let row = sidebarItems[id: worktreeID] else { return nil }
    var surfaceIDs = liveSurfaceIDs
    if let tab = persistedLayouts[worktreeID.rawValue]?.tabs.first(where: { $0.id == tabID.rawValue }) {
      surfaceIDs.formUnion(tab.layout.leafSurfaceIDs)
    }
    guard !surfaceIDs.isEmpty else { return nil }

    let directoryPath = TaskDirectoryPath.canonical(row.workingDirectory)
    // A named target that no longer exists (the record was deleted while the tab
    // was materializing) falls back rather than dropping the claim: the tab is
    // real either way, and the directory's live task is the honest owner.
    let target = taskID.flatMap { taskRecords[id: $0] } ?? newestActiveTask(inDirectory: directoryPath)
    guard target?.surfaceIDs.isSuperset(of: surfaceIDs) != true else { return nil }

    for record in taskRecords where !record.surfaceIDs.isDisjoint(with: surfaceIDs) {
      taskRecords[id: record.id]?.surfaceIDs.subtract(surfaceIDs)
    }
    guard let target else {
      let branch = row.provableBranch
      let record = TaskRecord(
        title: TaskActivitySeeder.title(
          for: TaskActivitySeeder.Candidate(
            directoryPath: directoryPath,
            customizationTitle: row.customTitle,
            worktreeName: row.name,
            worktreeDetail: row.subtitle
          ),
          branch: branch
        ),
        directoryPath: directoryPath,
        branch: branch,
        repositoryID: row.repositoryID,
        createdAt: now,
        surfaceIDs: surfaceIDs,
        seedEvidence: TaskRecord.SeedEvidence(source: .manual, confidence: .high)
      )
      taskRecords.append(record)
      return record.id
    }
    taskRecords[id: target.id]?.surfaceIDs.formUnion(surfaceIDs)
    return target.id
  }

  /// Newest-created active task for the directory. Two active tasks may share a
  /// directory (plan Resolved #11), so the join target has to be deterministic;
  /// newest-created is the order the Tasks tab already puts at the top (A4).
  func newestActiveTask(inDirectory path: String) -> TaskRecord? {
    let target = TaskDirectoryPath.normalized(path)
    return taskRecords
      .filter { !TasksSidebarStructure.isSettled($0) }
      .filter { TaskDirectoryPath.normalized($0.directoryPath) == target }
      .max { ($0.createdAt, $0.id.rawValue) < ($1.createdAt, $1.id.rawValue) }
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
    // Presentation only: the prompts are state no cache projects.
    case .presentCreationPrompt, .setConflictRemember, .cancelDirectoryConflict:
      return []
    // Effect launcher / reporter: neither touches a record or the roster. The
    // failure arm only raises an alert, which no cache projects (A20b: nothing
    // was persisted, so there is nothing to recompute).
    case .cleanupAutoManagedWorktree, .autoManagedWorktreeCreationFailed:
      return []
    // Clearing a spent delete marker changes the record set, nothing else.
    case .autoManagedWorktreeCleanupFinished:
      return .sidebarStructure
    // Every arm that can change the record set, its lifecycle, or the page window.
    case .loaded, .seeded, .select, .settle, .unsettle,
      .setSettledTailExpanded, .expandSettledTail, .reconcileSurfaceOwnership, .promoteTab:
      return .sidebarStructure
    // Creation also moves the selection inline, so it owes the two
    // selection-derived caches on top of the record set. `autoManagedWorktreeCreated`
    // adds a row to the roster on top of that, which is the same set
    // `.createRandomWorktreeSucceeded` declares.
    case .createTask, .resolveDirectoryConflict, .autoManagedWorktreeCreated:
      return [.sidebarStructure, .selectedWorktreeSlice, .sidebarSelectionSlice]
    }
  }
}

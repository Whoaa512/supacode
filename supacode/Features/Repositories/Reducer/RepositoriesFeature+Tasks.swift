import AppKit
import ComposableArchitecture
import Foundation
import IdentifiedCollections
import SupacodeSettingsShared

/// Task-inbox reducer arms, kept out of `RepositoriesFeature.swift` (already
/// ~6,300 lines) so the whole lifecycle reads in one place.
///
/// Phase 1 lifecycle, per `plans/task-inbox-sidebar-plan.md`: load, day-one
/// seed, select, explicit settle (surface-scoped hibernate since Phase 7),
/// unsettle as the recovery path, settled-tail paging, and surface-ownership
/// reconciliation. Snooze, pin, auto-settle and the classification cascade are
/// Phase 2/4.
private nonisolated let tasksLogger = SupaLogger("Tasks")

private enum TaskCancelID {
  /// Every save writes the whole file, so a newer save fully supersedes an
  /// in-flight one and cancelling it can never drop state.
  static let persist = "repositories.tasks.persist"
  /// The coarse 60s re-classification loop, armed once by the load that
  /// populates the inbox.
  static let classificationTick = "repositories.tasks.classificationTick"
  /// The one-shot sleep to the earliest wake instant. Re-armed (never stacked)
  /// whenever that instant moves, so exactly one alarm is ever pending.
  static let wakeBoundary = "repositories.tasks.wakeBoundary"
  /// Per capture, never shared: two captures in flight are two different
  /// worktrees being minted, and cancelling one because the other started would
  /// strand a half-created directory nothing is left to roll back.
  nonisolated struct AutoManagedWorktreeCreation: Hashable {
    var taskID: TaskID
  }
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
    /// Open a task: stamp `lastVisitedAt`, make it the sidebar selection, and
    /// pre-position its owning worktree on an owned surface.
    case select(TaskID)
    /// Explicit settle. The only settle path in Phase 1 (no cascade yet).
    case settle(TaskID)
    case unsettle(TaskID)
    /// Park a task until `until`. `hibernate` overrides the global default for
    /// this one snooze: `nil` means "whatever the setting says" (Resolved #13),
    /// which is off — a snooze you can undo for free is the common case.
    case snooze(TaskID, until: Date, hibernate: Bool? = nil)
    case unsnooze(TaskID)
    case pin(TaskID)
    case unpin(TaskID)
    /// ⌃⌘J: open the next visible row that is asking for a person (A33).
    /// Tab-gated like every other chord that *moves the selection*, so it can
    /// never reach across from a panel the user isn't looking at.
    case jumpToNextNeedingAttention
    /// The three mouseless lifecycle chords (A34). They resolve the focused
    /// task here rather than carrying an id, so the menu item, the chord and
    /// the reducer can only ever act on the row the panel says is open — and
    /// the settle/pin direction is read from the same cached structure the menu
    /// item's title is, which is what stops the label and the effect diverging.
    ///
    /// Not tab-gated, unlike the jump: these act on the focused task by id and
    /// their menu items are already inert off the Tasks panel, because only
    /// `TasksSidebarView` publishes the focused values that enable them.
    case settleSelected
    case snoozeSelected
    case togglePinSelected
    /// The bare-→ escape hatch: move focus off the row and into the task's
    /// terminal. Deliberately not `.select`: leaving the sidebar is not a fresh
    /// visit, and re-stamping `lastVisitedAt` here would clear a Done pill the
    /// user never read.
    case focusSelectedSurface
    /// ⌘⇧E's return half (A34): come back from the terminal to the open task's
    /// row. The counterpart of `.focusSelectedSurface`, so the round trip is
    /// one key out and one key back rather than one key out and a mouse back.
    case revealSelectedInSidebar
    /// The panel has scrolled to and focused the revealed row. Carries the id so
    /// a stale consumer cannot clear a newer request.
    case consumeSidebarReveal(Int)
    /// The explicit "stop auto-settling this" pin the Phase 5 cascade reads (A15).
    case keepActive(TaskID)
    /// The panel's title filter (A37). Presentation only: it narrows the cached
    /// render plan and touches no record, so clearing it restores the list the
    /// user had — including the selection, which the filter never drops (A8).
    case setSearchQuery(String)
    case setSettledTailExpanded(Bool)
    case setSnoozedShelfExpanded(Bool)
    case expandSettledTail
    /// The coarse safety net (A23): re-samples the clock so a wake the boundary
    /// missed — a re-arm that raced, a machine that slept through its alarm — is
    /// at most one tick late instead of never.
    case classificationTick
    /// The boundary-armed wake fired. Classification only: the record keeps the
    /// stamps the user wrote, so a re-snooze never has to ask for the time again.
    case wakeBoundaryReached
    /// Per-task agent presence, projected by `AppFeature` across exactly the
    /// surfaces this task owns. Deliberately not the worktree row's snapshot:
    /// that one carries no surface id, so it could only ever be the union of
    /// every agent in the directory — and two tasks in one directory are a
    /// supported shape (Resolved #11).
    case agentSnapshotChanged(taskID: TaskID, snapshot: AgentPresenceFeature.RowSnapshot)
    /// An auto-settle setting changed. Fired by the panel's `.onChange`, the
    /// way `.sidebarGroupingTogglesChanged` is: waiting for the next coarse
    /// classification tick would leave the user staring at a list that
    /// disagrees with the switch they just flipped (A30).
    case autoSettleSettingsChanged
    /// Tear both clocks down (scene teardown, and every test that armed one).
    case stopTimers
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
    /// Give a task a terminal of its own in its directory. The escape hatch for
    /// the two dead ends a row can reach: a task that owns no surface (its tab
    /// was closed, or it was seeded for a directory nobody has opened yet), and
    /// a settled row, which is deliberately un-focusable — selecting one shows
    /// it but leads nowhere. A settled task is unsettled on the way, because
    /// asking for its terminal is saying it is not finished after all.
    case openTerminal(TaskID)
    /// Ask before forgetting a task. The confirmation is not ceremony: the row
    /// looks like a worktree, so "Delete" has to say what it does *not* touch.
    case requestDelete(TaskID)
    /// Open the rename question for a task row.
    case presentRenamePrompt(TaskID)
    case cancelRenamePrompt
    /// Commit a rename. An empty (or whitespace-only) title is refused rather
    /// than applied: the title is the only thing a row is identified by in the
    /// panel, so clearing it would leave a task nobody can name or search for.
    case renameTask(TaskID, title: String)
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
    /// Both attempts failed. Nothing was persisted, so there is no record to
    /// undo — but a failed `wt sw` can still leave a directory and a branch
    /// behind, so this carries what it takes to remove them (A20b: the capture
    /// leaves *nothing*, not just no record).
    ///
    /// `orphanedBranch` names the attempt whose leftovers must be removed, and
    /// is `nil` when nothing was ever attempted — a rollback then would delete a
    /// branch somebody else owns.
    case autoManagedWorktreeCreationFailed(
      title: String,
      directoryPath: String,
      message: String,
      repositoryID: Repository.ID,
      orphanedBranch: String?,
      baseDirectory: URL
    )
    /// Re-check Resolved #9's preconditions and, if they all hold, delete the
    /// worktree a settled task's marker authorizes.
    case cleanupAutoManagedWorktree(TaskID)
    case autoManagedWorktreeCleanupFinished(taskID: TaskID, didDelete: Bool)
  }

  var tasksReducer: some Reducer<State, Action> {
    Reduce { state, action in
      @Dependency(\.date.now) var now
      // Time only moves when an action says it did (A23). Stamped for exactly
      // the arms that declare `.sidebarStructure` — *every* such arm, not only
      // the `.tasks` ones — so the post-reduce hook and this sample can never
      // disagree about whether the cache needed rebuilding. A taskNow written by
      // an arm that declares nothing would leave a stale structure behind it;
      // a taskNow *not* written by an arm that does is the mirror bug, and the
      // expensive one: a PR landing via `.sidebarItems(.pullRequestChanged)`
      // would stamp `pullRequestChangedAt` from whatever instant the last task
      // arm sampled, so a PR that changed after a snooze would look older than
      // the snooze and never raise its hand (A29b).
      //
      // An empty inbox is the one exception, and only for the non-task arms:
      // there is nothing for the sample to classify (every task recompute below
      // already early-outs on it), and sampling anyway would make the whole app
      // read the clock on every sidebar mutation. The `.tasks` arms stamp
      // unconditionally, because `.loaded` is what *creates* the inbox and runs
      // while `taskRecords` is still empty.
      //
      // The presentation-only arms are the other exception: they owe a rebuild
      // (the structure they project narrowed or expanded) but not a re-timing,
      // so `samplesClock` holds the clock still while the user types in the
      // search field or opens a shelf.
      if action.cacheInvalidations.contains(.sidebarStructure) {
        if case .tasks(let taskAction) = action {
          if taskAction.samplesClock {
            state.taskNow = now
          }
        } else if !state.taskRecords.isEmpty {
          state.taskNow = now
        }
      }
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
        // Both clocks start here, not at the first snooze: a relaunch with
        // parked tasks has to re-evaluate them (A23) without waiting for the
        // user to touch anything, and a wake that passed while the app was
        // closed has to land on this very reduce.
        return .merge(
          .send(.tasks(.reconcileSurfaceOwnership)),
          .send(.tasks(.seedIfNeeded)),
          Self.taskClassificationTickEffect(),
          state.armTaskWakeBoundaryEffect()
        )

      case .tasks(.seedIfNeeded):
        // Day-one bulk seeding is off on purpose: joining the inbox is a choice
        // made per tab (promote) or per task (⌘N), never a sweep of whatever
        // happened to be open. The flag still flips and persists so the dormant
        // seeder in an older build cannot mint a wall of tasks on a downgrade.
        guard state.hasLoadedTasks, !state.didSeedTasks, !state.isTaskPersistenceDisabled else {
          return .none
        }
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
        // A18b, reducer-side. The affordance is disabled, but a settle that
        // arrives anyway (hotkey, menu race, script) must no-op rather than park
        // a task that is asking the user a question.
        guard TaskSettlement.canSettle(state.taskSettlementInput(for: id)) else { return .none }
        // Computed before the mutation, over the order the user could see (A26).
        let forwardTarget = state.taskForwardNavigationTarget(leaving: id)
        let hibernation = state.taskHibernationDelegate(for: record)
        // Always stamped, never derived: the settled tail sorts and labels by
        // this one timestamp (A17), and an explicit `.active` override would
        // otherwise beat the settle the user just asked for.
        state.taskRecords[id: id]?.settledAt = now
        if record.settledOverride == .active {
          state.taskRecords[id: id]?.settledOverride = nil
        }
        // A16: an explicit settle CLEARS the pin. Pinning says "keep this in
        // front of me" and settling says "I am done with it" — the later
        // instruction wins, and a pinned row surviving in the settled tail would
        // be a row nobody can get rid of.
        state.taskRecords[id: id]?.pinnedAt = nil
        // Cleanup rides on the settle, always *after* the hibernation request —
        // `.concatenate`, not `.merge`: deleting a directory that still has live
        // sessions in it is how a settle turns into data loss, and the two are
        // otherwise dispatched in whatever order the merge happens to pick. A
        // shared directory is still nobody's to *delete* — that is what the
        // sole-owner guard below is for — even though hibernation is now
        // surface-scoped and happily runs there (A6 full form).
        //
        // Ordering the dispatch only orders the teardown because the parent
        // hibernates synchronously in its delegate arm (main-actor terminal
        // state, no effect hop), so by the time the cleanup action lands the
        // tabs are already dormant. The delete still re-checks for itself and
        // refuses while any *awake* tab is standing in the directory.
        var settleSteps: [Effect<Action>] = []
        if let hibernation {
          settleSteps.append(.send(.delegate(hibernation)))
        }
        if record.autoManagedWorktree != nil,
          state.isSoleActiveTaskOwner(of: record),
          state.autoManagedCleanupWorktree(for: record) != nil
        {
          settleSteps.append(.send(.tasks(.cleanupAutoManagedWorktree(id))))
        }
        var settleEffects: [Effect<Action>] = [
          Self.persistTasksEffect(state: state),
          .concatenate(settleSteps),
        ]
        if let forwardTarget {
          settleEffects.append(.send(.tasks(.select(forwardTarget))))
        }
        return .merge(settleEffects)

      case .tasks(.unsettle(let id)):
        guard state.taskRecords[id: id] != nil else { return .none }
        state.taskRecords[id: id]?.settledAt = nil
        // Cleared rather than set to `.active`: Phase 1 has no auto-settle to
        // defend against, and a sticky override would block Phase 2's cascade
        // forever. Sessions are not woken here — opening the task does that.
        state.taskRecords[id: id]?.settledOverride = nil
        return Self.persistTasksEffect(state: state)

      case .tasks(.snooze(let id, let until, let hibernate)):
        guard let record = state.taskRecords[id: id] else { return .none }
        guard TaskSettlement.canSnooze(state.taskSettlementInput(for: id)) else { return .none }
        // Re-snoozing to the same instant must not re-stamp `snoozedAt`: that
        // would silently reset every raised-hand freshness comparison and
        // un-raise a hand the user already saw go up (A25).
        guard record.snoozedUntil != until else { return .none }
        let forwardTarget = state.taskForwardNavigationTarget(leaving: id)
        state.taskRecords[id: id]?.snoozedUntil = until
        // Stamped separately and never derived from `until`: it is what every
        // freshness rule measures against, and the two move independently.
        state.taskRecords[id: id]?.snoozedAt = now
        // Snooze un-settles what it parks (A16: snooze outranks settled). The
        // user is saying "bring this back later", which is only true if it comes
        // back to the active section rather than to the tail it was already in —
        // and the explicit `.active` override is what stops the inactivity
        // cascade re-settling it the moment it wakes. The pin is untouched: "not
        // now" and "always up top" are orthogonal instructions.
        //
        // The override is only for tasks that were actually *in* the tail:
        // stamping it on every snooze pins a permanent "keep active" onto tasks
        // the user never settled, which then immunizes them against Phase 5's
        // inactivity cascade forever. Records already persisted with the
        // spurious override keep it: it is a user-visible, user-clearable
        // keep-active flag, not corruption, and a migration for dogfood-stage
        // data would cost more than it repairs.
        let wasSettled = TasksSidebarStructure.isSettled(record)
        state.taskRecords[id: id]?.settledAt = nil
        if wasSettled {
          state.taskRecords[id: id]?.settledOverride = .active
        }
        @Shared(.settingsFile) var settingsFile
        var snoozeEffects: [Effect<Action>] = [Self.persistTasksEffect(state: state)]
        // Same delegate a settle sends, so the parent has one hibernation path,
        // not two. The claim survives it (A10b): waking has to find the surfaces
        // it put to sleep.
        if hibernate ?? settingsFile.global.snoozeHibernatesSessions,
          let hibernation = state.taskHibernationDelegate(for: record)
        {
          snoozeEffects.append(.send(.delegate(hibernation)))
        }
        if let forwardTarget {
          snoozeEffects.append(.send(.tasks(.select(forwardTarget))))
        }
        snoozeEffects.append(state.armTaskWakeBoundaryEffect())
        return .merge(snoozeEffects)

      case .tasks(.unsnooze(let id)):
        guard let record = state.taskRecords[id: id] else { return .none }
        guard record.snoozedUntil != nil || record.snoozedAt != nil else { return .none }
        state.taskRecords[id: id]?.snoozedUntil = nil
        state.taskRecords[id: id]?.snoozedAt = nil
        // No Woke pill: the user did the waking, so nothing is owed a look.
        return .merge(Self.persistTasksEffect(state: state), state.armTaskWakeBoundaryEffect())

      case .tasks(.pin(let id)):
        guard let record = state.taskRecords[id: id] else { return .none }
        // Idempotent: a second pin must not re-stamp, or a pinned row would jump
        // inside the pinned block every time the menu item is clicked twice.
        guard record.pinnedAt == nil else { return .none }
        state.taskRecords[id: id]?.pinnedAt = now
        return Self.persistTasksEffect(state: state)

      case .tasks(.unpin(let id)):
        guard let record = state.taskRecords[id: id], record.pinnedAt != nil else { return .none }
        state.taskRecords[id: id]?.pinnedAt = nil
        return Self.persistTasksEffect(state: state)

      case .tasks(.jumpToNextNeedingAttention):
        guard state.activeSidebarTab == .tasks else { return .run { _ in NSSound.beep() } }
        // §4.6: a prompt on screen owns the keyboard. Silently, not with a beep
        // — the sheet has a text field in it, and a beep on every chord-shaped
        // keystroke someone types there is noise rather than feedback.
        guard !state.hasBlockingSheet else { return .none }
        guard let target = state.nextTaskNeedingAttention() else {
          // Nothing is owed a person, or the only row that is, is already open.
          // Beep rather than re-select: a chord that silently re-opens what you
          // are looking at reads as broken.
          return .run { _ in NSSound.beep() }
        }
        return .send(.tasks(.select(target)))

      case .tasks(.settleSelected):
        guard !state.hasBlockingSheet else { return .none }
        guard let commands = state.tasksSidebarStructure.openTaskCommands else { return .none }
        // One key, both directions, matching the row's own context menu — and
        // the direction comes from the structure the menu item titled itself
        // from, so "Unsettle" can never fire a settle.
        return .send(.tasks(commands.isSettled ? .unsettle(commands.id) : .settle(commands.id)))

      case .tasks(.snoozeSelected):
        guard !state.hasBlockingSheet else { return .none }
        guard let commands = state.tasksSidebarStructure.openTaskCommands else { return .none }
        // Both directions on one key, exactly like ⌃⌘S: a parked row's chord is
        // Wake Now. Without this the chord is a one-way door — re-snoozing an
        // already-snoozed task just rewrites the same hour — and the only undo
        // is a right-click, which is the mouse A34 exists to avoid.
        guard !commands.isSnoozed else { return .send(.tasks(.unsnooze(commands.id))) }
        // A chord cannot express a duration and cannot open a submenu, so it
        // takes the cheapest, most reversible preset. Wake Now is the same key
        // again, which is what makes picking for the user acceptable here.
        guard
          let preset = TaskSnooze.resolveSnoozePresets(now: now, calendar: .autoupdatingCurrent)
            .first(where: { $0.preset == .oneHour })
        else { return .none }
        return .send(.tasks(.snooze(commands.id, until: preset.wakeAt)))

      case .tasks(.togglePinSelected):
        guard !state.hasBlockingSheet else { return .none }
        guard let commands = state.tasksSidebarStructure.openTaskCommands else { return .none }
        // A16: settling clears the pin, so a pin on a settled row is a write
        // that immediately means nothing. Refused here as well as greyed in the
        // menu, so the chord and the item agree about one rule.
        guard !commands.isSettled else { return .none }
        return .send(.tasks(commands.isPinned ? .unpin(commands.id) : .pin(commands.id)))

      case .tasks(.focusSelectedSurface):
        guard let id = state.selection?.taskID, let focus = state.taskFocusDelegate(for: id) else {
          return .run { _ in NSSound.beep() }
        }
        return .send(.delegate(focus))

      case .tasks(.revealSelectedInSidebar):
        guard let id = state.selection?.taskID else { return .none }
        // The panel may not even be the one on screen — ⌘⇧E from a terminal is
        // "show me where I am", and where the user is, is a task. The tab flip
        // has to happen here rather than in the view, because the view that
        // would do it is the one that is not mounted yet.
        @Shared(.sidebarTab) var sidebarTabRawValue
        $sidebarTabRawValue.withLock { $0 = SidebarTab.tasks.rawValue }
        // No section to uncollapse, unlike the worktree reveal: A8 already
        // pulls the open task into the visible order whatever shelf it lives
        // on, so the row the panel is about to scroll to is always rendered.
        state.nextPendingTaskRevealID += 1
        state.pendingTaskReveal = .init(id: state.nextPendingTaskRevealID, taskID: id)
        return .none

      case .tasks(.consumeSidebarReveal(let revealID)):
        guard state.pendingTaskReveal?.id == revealID else { return .none }
        state.pendingTaskReveal = nil
        return .none

      case .tasks(.keepActive(let id)):
        guard let record = state.taskRecords[id: id] else { return .none }
        guard record.settledOverride != .active || record.settledAt != nil else { return .none }
        state.taskRecords[id: id]?.settledOverride = .active
        state.taskRecords[id: id]?.settledAt = nil
        return Self.persistTasksEffect(state: state)

      case .tasks(.setSnoozedShelfExpanded(let isExpanded)):
        guard state.isSnoozedShelfExpanded != isExpanded else { return .none }
        state.isSnoozedShelfExpanded = isExpanded
        return .none

      case .tasks(.agentSnapshotChanged(let taskID, let snapshot)):
        guard state.taskRecords[id: taskID] != nil else { return .none }
        guard state.taskAgentSnapshots[taskID] != snapshot else { return .none }
        state.taskAgentSnapshots[taskID] = snapshot
        return .none

      case .tasks(.autoSettleSettingsChanged):
        // Pure re-classification off the freshly-read settings: `taskNow` was
        // stamped above and the post-reduce hook rebuilds the partition, so the
        // list agrees with the toggle before the sheet even closes.
        return .none

      case .tasks(.classificationTick), .tasks(.wakeBoundaryReached):
        // Both are pure re-classification: `taskNow` was stamped above, the
        // post-reduce hook rebuilds the structure off it, and no record is
        // written. All that is left is to point the alarm at whatever is still
        // parked.
        return state.armTaskWakeBoundaryEffect()

      case .tasks(.stopTimers):
        state.armedTaskWakeBoundary = nil
        return .merge(
          .cancel(id: TaskCancelID.classificationTick),
          .cancel(id: TaskCancelID.wakeBoundary)
        )

      case .tasks(.setSearchQuery(let query)):
        guard state.taskSearchQuery != query else { return .none }
        state.taskSearchQuery = query
        return .none

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

      case .tasks(.openTerminal(let id)):
        guard let record = state.taskRecords[id: id] else { return .none }
        // The directory has no live row, so there is nothing to open a terminal
        // in and guessing one would be worse than refusing (A10b). The menu item
        // is disabled for the same condition, off the leaf's `hasDirectoryRow`.
        guard let terminal = state.taskTerminalRequestDelegate(for: record) else {
          tasksLogger.debug("Open terminal refused: \(record.directoryPath) has no live row.")
          return .none
        }
        // Unsettled inline rather than by sending `.unsettle`: the selection and
        // the terminal request leave in the same reduce, and a settled record is
        // deliberately un-focusable — one hop later the request would race the
        // lifecycle it depends on. `.select` owns the persist that writes this.
        //
        // Gated on actually being settled, so opening a terminal for a live task
        // never clears a `.active` override the user set with Keep Active.
        if TasksSidebarStructure.isSettled(record) {
          state.taskRecords[id: id]?.settledAt = nil
          state.taskRecords[id: id]?.settledOverride = nil
        }
        // `.concatenate`, not `.merge`, for the reason creation applies its
        // selection inline (A4): the terminal request has to leave with the task
        // already open, or the tab arrives behind a row the user is not on.
        return .concatenate(
          .send(.tasks(.select(id))),
          .send(.delegate(terminal))
        )

      case .tasks(.requestDelete(let id)):
        guard let record = state.taskRecords[id: id] else { return .none }
        state.alert = Self.taskDeletionAlert(for: record)
        return .none

      case .alert(.presented(.confirmDeleteTask(let id))):
        guard let record = state.taskRecords[id: id] else {
          state.alert = nil
          return .none
        }
        state.alert = nil
        // Computed before the removal, over the order the user could see — the
        // same rule a settle follows (A26), so a delete leaves the selection on
        // the row below rather than on nothing.
        let forwardTarget = state.taskForwardNavigationTarget(leaving: id)
        let wasOpen = state.selection?.taskID == id
        // The record is all that goes. Its worktree, its sessions and its
        // scrollback are somebody else's property — an auto-managed worktree
        // included, which is why the alert says the directory is left behind
        // rather than quietly deleting it on the way out (Resolved #9 only ever
        // authorizes that delete on a *settle*, where the preconditions are
        // re-checked).
        state.taskRecords.remove(id: id)
        var effects: [Effect<Action>] = [Self.persistTasksEffect(state: state)]
        if let forwardTarget {
          effects.append(.send(.tasks(.select(forwardTarget))))
        } else if wasOpen {
          // Nowhere to go: the inbox is empty, or the deleted row was the last
          // one. A selection left pointing at a record that is gone renders a
          // detail pane for nothing.
          state.selection = nil
        }
        return .merge(effects)

      case .tasks(.presentRenamePrompt(let id)):
        guard let record = state.taskRecords[id: id] else { return .none }
        state.taskRenamePrompt = TaskRenamePrompt(taskID: id, startingTitle: record.title)
        return .none

      case .tasks(.cancelRenamePrompt):
        state.taskRenamePrompt = nil
        return .none

      case .tasks(.renameTask(let id, let title)):
        guard state.taskRecords[id: id] != nil else { return .none }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        // Refused, and the sheet stays open with what the user typed: silently
        // keeping the old title while dismissing would read as a rename that
        // worked. Save is disabled for the same input, so this is the reducer
        // half of one rule.
        guard !trimmed.isEmpty else { return .none }
        state.taskRenamePrompt = nil
        guard state.taskRecords[id: id]?.title != trimmed else { return .none }
        state.taskRecords[id: id]?.title = trimmed
        return Self.persistTasksEffect(state: state)

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
        switch state.taskCaptureRoute(forDirectory: directoryPath) {
        case .createHere:
          return state.reduceTaskCreation(title: title, directoryPath: directoryPath, now: now)

        case .ask(let repository):
          // The prompt is keyed by directory, so a second capture landing while
          // the question is open would retarget the sheet in place and apply the
          // user's answer — including a remembered one — to a directory they
          // were never asked about. The capture in front of the user wins.
          guard state.taskDirectoryConflict == nil else {
            tasksLogger.debug(
              "Task creation refused: a directory conflict question is already open."
            )
            return .none
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

        case .isolate(let repository):
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
        } else if prompt.shouldRemember {
          // Ticked, and going nowhere: the repository was removed between
          // question and answer, so there is no settings file to write it to and
          // the next capture in that directory will ask again.
          tasksLogger.debug(
            "Task isolation choice not remembered: repository \(prompt.repositoryID) is gone."
          )
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
        guard !state.isTaskPersistenceDisabled else {
          // Only reachable if the file turned unreadable while the worktree was
          // being minted. Loud, because a worktree now exists that no record
          // will ever point at — the one leak the inbox cannot see.
          tasksLogger.error(
            """
            Task creation dropped after its worktree was created: persistence was disabled \
            mid-flight. \(worktree.workingDirectory.path(percentEncoded: false)) is orphaned.
            """
          )
          return .none
        }
        guard let repositoryID = record.repositoryID else {
          // Unreachable: only the isolate path sends this, and it resolves a
          // repository before it mints anything.
          return state.reduceCreatedTask(record)
        }
        // The row has to reach the roster before the terminal request leaves,
        // or `taskTerminalRequestDelegate` has nothing to resolve and the
        // capture that just spent a worktree opens no terminal in it.
        state.insertWorktree(worktree, repositoryID: repositoryID)
        Self.syncSidebar(&state)
        // `.pending` is what makes the setup script run: `openTaskTerminal`
        // passes `runSetupScriptIfNew` off this row's lifecycle, so a worktree
        // minted for a task would otherwise start without the `.env` / install
        // step every manually created one gets. Set synchronously, exactly as
        // `.createRandomWorktreeSucceeded` does, so no body observes a brief
        // `.idle`.
        state.sidebarItems[id: worktree.id]?.lifecycle = .pending
        // `.concatenate`, not `.merge`: the parent resolves `openTaskTerminal`
        // against *its own* copy of the roster, which only this delegate
        // updates. Arriving second, the terminal request would find no worktree
        // and the capture would open nothing.
        return .concatenate(
          .send(.delegate(.repositoriesChanged(state.repositories))),
          .send(.delegate(.worktreeCreated(worktree))),
          state.reduceCreatedTask(record)
        )

      case .tasks(
        .autoManagedWorktreeCreationFailed(
          let title, let directoryPath, let message, let repositoryID, let orphanedBranch,
          let baseDirectory
        )
      ):
        tasksLogger.error(
          "Auto-managed worktree creation failed for '\(title)' in \(directoryPath): \(message)"
        )
        // A20b is about what is *left behind*, not just about what was written:
        // `wt sw` can fail after creating the directory and the branch, and an
        // orphan the inbox has no record of is one nothing will ever clean up.
        // Same rollback the manual path runs (`createRandomWorktreeFailed`), for
        // the same reason and with the same authority — this name was minted by
        // the attempt that just failed, so its branch can carry no commits.
        let cleanup = state.cleanupFailedWorktree(
          repositoryID: repositoryID,
          name: orphanedBranch,
          baseDirectory: baseDirectory
        )
        state.alert = messageAlert(title: "Unable to create worktree", message: message)
        var effects: [Effect<Action>] = []
        if cleanup.didRemoveWorktree {
          effects.append(.send(.delegate(.repositoriesChanged(state.repositories))))
        }
        if let cleanupWorktree = cleanup.worktree {
          @Dependency(GitClientDependency.self) var cleanupClient
          // No `.reloadRepositories` chaser, unlike the manual path: nothing was
          // ever inserted for this capture, so `cleanupFailedWorktree` has
          // already taken the roster back to where it started and a reload would
          // only be a round trip to disk to learn that.
          effects.append(.run { _ in _ = try? await cleanupClient.removeWorktree(cleanupWorktree, true) })
        }
        return .merge(effects)

      case .tasks(.cleanupAutoManagedWorktree(let id)):
        guard let record = state.taskRecords[id: id],
          let marker = record.autoManagedWorktree,
          let worktree = state.autoManagedCleanupWorktree(for: record)
        else {
          return .none
        }
        @Dependency(\.terminalClient) var terminalClient
        // The precondition no git read can answer: an awake tab on this worktree
        // means a live session is standing in the directory, and deleting it out
        // from under one is exactly the data loss Resolved #9 refuses. The bias
        // is unchanged — leak a directory rather than destroy work — but dormant
        // tabs are exempt: hibernation already tore their surfaces down, so
        // nothing holds the directory, and counting them would mean every task
        // that ever opened a terminal refuses cleanup forever (A20 asks for
        // exactly the opposite: clean up on settle, *after* safe hibernation).
        //
        // Read here rather than in the effect because the terminal is main-actor
        // state, and read *last* so the settle's hibernation — which runs
        // synchronously in the parent's delegate arm, ahead of this action — has
        // already brought the count down.
        let awakeTabCount = terminalClient.awakeTabCount(worktree.id)
        guard awakeTabCount == 0 else {
          tasksLogger.debug(
            "Auto-managed cleanup refused: \(marker.path) still has \(awakeTabCount) awake tab(s)."
          )
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
        guard didDelete, let record = state.taskRecords[id: taskID],
          record.autoManagedWorktree != nil
        else {
          return .none
        }
        // Resolved before the marker is cleared: the marker is what identifies
        // the row, and clearing it first would leave the roster holding a row
        // for a directory that no longer exists — one the sidebar still renders
        // and the terminal still counts as an allowed worktree.
        let deleted = state.autoManagedCleanupWorktree(for: record)
        // Cleared once the directory is gone, so a later settle / unsettle round
        // cannot re-authorize a delete against a path something else took over.
        state.taskRecords[id: taskID]?.autoManagedWorktree = nil
        var effects: [Effect<Action>] = [Self.persistTasksEffect(state: state)]
        if let deleted,
          let repositoryID = state.repositories.first(where: { $0.worktrees[id: deleted.id] != nil })?.id
        {
          // A settle usually runs with the *task* selected, but the worktree row
          // can be the selection too, and a selection pointing at a deleted
          // worktree renders a detail pane for nothing. Re-picked *after* the
          // prune, or the row on its way out is the first one available.
          let wasSelected = state.selection == .worktree(deleted.id)
          state.cleanupWorktreeState(deleted.id, repositoryID: repositoryID)
          if wasSelected {
            state.selection = state.firstAvailableWorktreeID(in: repositoryID).map(SidebarSelection.worktree)
          }
          effects.append(.send(.delegate(.repositoriesChanged(state.repositories))))
        }
        return .merge(effects)

      case .taskCreationPrompt(.presented(.delegate(.cancel))):
        // A20b: cancel leaves nothing behind — no record, and no write at all.
        state.taskCreationPrompt = nil
        return .none

      case .taskCreationPrompt(.presented(.delegate(.createTask(let title, let directoryURL)))):
        return .send(.tasks(.createTask(title: title, directoryURL: directoryURL)))

      case .taskCreationPrompt(.presented(.delegate(.openRepository))):
        // A36: adding a repository never requires the Worktrees tab. The prompt
        // steps aside first — the browse flow wants the keyboard, and a capture
        // prompt left over one would be ranking a roster about to change.
        state.taskCreationPrompt = nil
        return .send(.requestOpenRepository)

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
    let requestedBranch = TaskAutoWorktreeNaming.branchName(title: resolvedTitle, taskID: taskID)
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
      // Checked up front rather than discovered by failing: a name git refuses
      // fails *both* attempts identically, so the cold retry is spent on a
      // certainty and the user gets an alert about a branch they never named.
      // An unreadable branch list is not a reason to block (A20) — the creation
      // itself is then the check.
      let existingBranches = (try? await client.localBranchNames(repository.rootURL)) ?? []
      guard let branch = TaskAutoWorktreeNaming.availableBranchName(requestedBranch, existing: existingBranches)
      else {
        await send(
          .tasks(
            .autoManagedWorktreeCreationFailed(
              title: resolvedTitle,
              directoryPath: directoryPath,
              message: "A branch named \(requestedBranch) already exists.",
              repositoryID: repository.id,
              // Nothing was attempted, so there is nothing to roll back — and a
              // rollback here would remove the *existing* branch that caused
              // this, which is somebody's work.
              orphanedBranch: nil,
              baseDirectory: baseDirectory
            )
          )
        )
        return
      }
      var lastError: (any Error)?
      let attempts = [(warm: true, copyUntracked: copyUntracked), (warm: false, copyUntracked: false)]
      for (index, attempt) in attempts.enumerated() {
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
          // The retry runs under the *same* name (a second name would leave the
          // record's marker authorizing a directory that was never created), so
          // whatever the failed attempt already put on disk has to go first —
          // otherwise the cold attempt fails on "directory already exists" and
          // the degrade path that exists to save the capture never gets to run.
          // The last attempt's leftovers are the failure arm's to remove, so
          // they are not touched twice.
          guard index < attempts.count - 1 else { break }
          await Self.removeOrphanedWorktreeAttempt(
            gitClient: client,
            repositoryRootURL: repository.rootURL,
            baseDirectory: baseDirectory,
            branch: branch
          )
        }
      }
      await send(
        .tasks(
          .autoManagedWorktreeCreationFailed(
            title: resolvedTitle,
            directoryPath: directoryPath,
            message: lastError?.localizedDescription ?? "Worktree creation failed.",
            repositoryID: repository.id,
            orphanedBranch: branch,
            baseDirectory: baseDirectory
          )
        )
      )
    }
    .cancellable(id: TaskCancelID.AutoManagedWorktreeCreation(taskID: taskID))
  }

  /// Removes what a failed creation attempt left on disk, so the next attempt
  /// can use the same name. Best-effort by design: the common case is that
  /// nothing was created at all and there is nothing to remove, which git
  /// reports as an error and this deliberately swallows.
  ///
  /// `deleteBranch: true`, unlike every other delete in the task inbox: this
  /// branch was minted seconds ago by the attempt that just failed, so it cannot
  /// carry work — which is exactly what `createRandomWorktreeFailed` concluded
  /// about the manual path's rollback.
  nonisolated static func removeOrphanedWorktreeAttempt(
    gitClient: GitClientDependency,
    repositoryRootURL: URL,
    baseDirectory: URL,
    branch: String
  ) async {
    guard let directory = Self.failedWorktreeURL(baseDirectory: baseDirectory, name: branch) else {
      return
    }
    let worktree = Worktree(
      id: WorktreeID(directory.path(percentEncoded: false)),
      kind: .git,
      name: branch,
      detail: "",
      workingDirectory: directory,
      repositoryRootURL: repositoryRootURL
    )
    _ = try? await gitClient.removeWorktree(worktree, true)
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
  /// branch the marker named, it holds no files git has never seen, and it holds
  /// no uncommitted changes to the ones it has. Any mismatch — including one we
  /// cannot *prove* either way — refuses, leaking a directory rather than
  /// destroying work git cannot give back.
  ///
  /// Untracked files are checked *separately* from `lineChanges`, and before it:
  /// `lineChanges` diffs tracked content only, so a worktree holding nothing but
  /// a brand-new file — a scratch script, an uncommitted first draft, a `.env` —
  /// reports `(0, 0)` and would otherwise pass the dirty check on its way to an
  /// unrecoverable `rm -rf`. A count we cannot read at all refuses for the same
  /// reason an unprovable branch does.
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
    guard let untracked = try? await gitClient.untrackedFileCount(directory), untracked == 0 else {
      tasksLogger.debug(
        "Auto-managed cleanup refused: \(marker.path) holds untracked files, or the count is unreadable."
      )
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

  /// The confirmation for forgetting a task.
  ///
  /// The message spends its words on what is *not* removed: a task row looks
  /// like a worktree row, and "Delete" beside one reads as a directory delete
  /// until it says otherwise. An auto-managed worktree is named explicitly —
  /// deleting the record orphans that directory by design (nothing else will
  /// ever authorize removing it), and the user deserves to hear that before
  /// rather than to find it later.
  static func taskDeletionAlert(for record: TaskRecord) -> AlertState<Alert> {
    let orphaned =
      record.autoManagedWorktree != nil
      ? " Its auto-created worktree will be left in place." : ""
    return AlertState {
      TextState("Delete “\(record.title)”?")
    } actions: {
      ButtonState(role: .destructive, action: .confirmDeleteTask(record.id)) {
        TextState("Delete Task")
      }
      ButtonState(role: .cancel) {
        TextState("Cancel")
      }
    } message: {
      TextState(
        "Removes this task from the inbox. Its terminal sessions, files and directory stay "
          + "exactly as they are.\(orphaned)"
      )
    }
  }

  // MARK: - Wake clocks

  /// How often the coarse net re-classifies everything. Deliberately blunt: it
  /// exists to catch what the precise alarm missed, not to be the alarm.
  nonisolated static let taskClassificationInterval: Duration = .seconds(60)
  /// The boundary sleep overshoots its target so the effect always lands on the
  /// wake side of an inclusive boundary rather than one tick short of it (A23).
  static let taskWakeBoundaryOvershoot: Duration = .milliseconds(50)

  static func taskClassificationTickEffect() -> Effect<Action> {
    @Dependency(\.continuousClock) var clock
    return .run { send in
      for await _ in clock.timer(interval: Self.taskClassificationInterval) {
        await send(.tasks(.classificationTick))
      }
    }
    .cancellable(id: TaskCancelID.classificationTick, cancelInFlight: true)
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

}

/// Where a capture in one directory goes: create the task right there (nobody
/// else is in it, or it belongs to no repository, or the repository already
/// answered "share"), ask the user, or mint a worktree.
///
/// The repository rides along on the two routes that need one, so the caller
/// never has to unwrap — and never has to invent a fallback for a combination
/// the cascade cannot produce.
enum TaskCaptureRoute: Equatable {
  case createHere
  case ask(Repository)
  case isolate(Repository)
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

  /// Steps 1–3 of Resolved #11, resolved against live state, with the repository
  /// the answer needs carried *inside* the answer.
  ///
  /// The two routes that act on a repository can only be reached through one,
  /// which is what this shape says out loud: resolving the policy and the
  /// repository separately left the caller writing fallbacks for a nil that the
  /// cascade cannot produce — dead branches that would quietly turn "isolate"
  /// into "share" the day one of them stopped being dead.
  ///
  /// A directory with no repository routes to `.createHere` however busy it is:
  /// A20 forbids blocking creation, and there is nothing to branch from.
  func taskCaptureRoute(forDirectory directoryPath: String) -> TaskCaptureRoute {
    guard let repository = taskCaptureRepository(forDirectory: directoryPath) else {
      return .createHere
    }
    @Shared(.repositorySettings(repository.rootURL, host: repository.host)) var repositorySettings
    switch TaskDirectoryConflictPolicy.resolve(
      isDirectoryBusy: newestActiveTask(inDirectory: directoryPath) != nil,
      repositoryIsolation: repositorySettings.taskDirectoryIsolation
    ) {
    case .useDirectly, .share:
      return .createHere
    case .ask:
      return .ask(repository)
    case .isolate:
      return .isolate(repository)
    }
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
  ///
  /// Hibernation no longer asks this — it is surface-scoped now (A6 full form).
  /// What still does is the auto-managed *delete*: removing a directory another
  /// live task is standing in is data loss, and unlike a hibernation it cannot
  /// be undone by waking a tab back up.
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

  /// The hibernation request for an explicit settle, or `nil` when there is
  /// nothing to put to sleep: no owned surfaces, or no live worktree row for the
  /// directory to name them in.
  ///
  /// A shared directory is *not* a refusal any more (A6 full form): the request
  /// is keyed by the surfaces this task owns, never by the directory.
  ///
  /// Ownership comes in two granularities on purpose. A *seeded* task claims its
  /// whole directory — it stands for that directory's entire working state, so
  /// `seedRecords` gives it every surface open there. A *capture-created* task
  /// (promote-tab, ⌘N) claims one tab, and the claim takes that tab away from
  /// whoever held it before. So a seeded task and a later capture in the same
  /// directory both own real, disjoint surface sets.
  ///
  /// A6's consequence: settling a seeded task sleeps its directory *minus* the
  /// tabs other tasks have since claimed. `protectedSurfaceIDs` carries those
  /// co-tenant tabs so the parent subtracts them before hibernating anything
  /// (A7) — that is the mechanism that makes the split hold, not just a
  /// belt-and-braces check.
  func taskHibernationDelegate(for record: TaskRecord) -> RepositoriesFeature.Delegate? {
    guard !record.surfaceIDs.isEmpty else { return nil }
    guard let row = sidebarItemForTaskDirectory(record.directoryPath) else { return nil }
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
  /// ⌃1–9 on the Tasks panel: the nth row of the visible order. The analogue of
  /// `agentDashboardEntryID(atSlot:)`, reading the same list the hint pills are
  /// numbered from, so a badge and what it opens cannot disagree (A32).
  func taskID(atSlot index: Int) -> TaskID? {
    let ids = tasksSidebarStructure.visibleTaskIDs
    guard ids.indices.contains(index) else { return nil }
    return ids[index]
  }

  /// ⌃⌘↓ / ⌃⌘↑ on the Tasks panel: cycle the visible list with a modulo wrap,
  /// the direct analogue of `worktreeID(byOffset:)` and
  /// `agentDashboardEntryID(byOffset:)`.
  ///
  /// Deliberately *not* `TaskForwardNavigation`: that one answers "what should I
  /// look at now that this task is gone", which is a different question with a
  /// different answer (it prefers active rows over the tail). Merging them would
  /// make ⌃⌘↓ skip rows the user can plainly see.
  func taskID(byOffset offset: Int) -> TaskID? {
    let ids = tasksSidebarStructure.visibleTaskIDs
    guard !ids.isEmpty else { return nil }
    guard let current = selection?.taskID, let index = ids.firstIndex(of: current) else {
      // No task open yet (or one that just settled out of view): enter the list
      // from the end the user is travelling towards.
      return offset < 0 ? ids[ids.count - 1] : ids[0]
    }
    return ids[(index + offset + ids.count) % ids.count]
  }

  /// ⌃⌘J: the next visible row asking for a person (A33).
  ///
  /// The predicate is the leaf's own `needsHuman` — the same one the row's fade
  /// reads — so the jump can never land on a row that looks quiet, or skip one
  /// that looks urgent.
  func nextTaskNeedingAttention() -> TaskID? {
    TaskAttention.nextNeedingHuman(
      in: tasksSidebarStructure.visibleTaskIDs,
      after: selection?.taskID
    ) { taskLeaves[id: $0]?.needsHuman == true }
  }

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
    return
      taskRecords
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

  // MARK: - Lifecycle classification

  /// Per-task classification inputs, straight off the leaves. Built fresh on
  /// each recompute rather than cached: it is a projection of a projection, and
  /// a third copy is a third thing that can disagree.
  var taskSignals: [TaskID: TasksSidebarStructure.Signals] {
    taskLeaves.reduce(into: [:]) { result, leaf in
      result[leaf.id] = leaf.signals
    }
  }

  /// What the user's settings let the auto paths do (A15, A30).
  ///
  /// Read fresh on every recompute rather than cached: `@Shared` app storage is
  /// the store of record, and a mirrored copy is a second thing that can be
  /// stale the moment a toggle flips in another window.
  ///
  /// A window of zero days or less is not "settle everything instantly", it is
  /// the inactivity path turned off — the finished-PR path stays independent.
  var taskSettlementPolicy: TaskSettlement.Policy {
    @Shared(.taskAutoSettleEnabled) var isAutoSettleEnabled
    @Shared(.taskAutoSettleOnFinishedPullRequest) var settlesOnFinishedPullRequest
    @Shared(.taskInactivityWindowDays) var inactivityWindowDays
    return TaskSettlement.Policy(
      inactivityWindow: inactivityWindowDays > 0
        ? TimeInterval(inactivityWindowDays) * 24 * 60 * 60 : nil,
      isAutoSettleEnabled: isAutoSettleEnabled,
      settlesOnFinishedPullRequest: settlesOnFinishedPullRequest
    )
  }

  /// The settlement question for one task, assembled the same way the cached
  /// structure assembles it — one spelling, so the row's affordance gating and
  /// the partition can never disagree about the same task.
  func taskSettlementInput(for id: TaskID) -> TaskSettlement.Input {
    guard let record = taskRecords[id: id] else {
      return TaskSettlement.Input(now: taskNow)
    }
    return TasksSidebarStructure.settlementInput(
      for: record,
      now: taskNow,
      signals: taskLeaves[id: id]?.signals ?? TasksSidebarStructure.Signals(),
      policy: taskSettlementPolicy
    )
  }

  /// The soonest wake instant among the tasks that are *currently* parked, or
  /// `nil` when nothing is. A row held out of the shelf by a raised hand is not
  /// parked, so it never arms an alarm nobody is waiting for.
  var earliestTaskWake: Date? {
    let signals = taskSignals
    return taskRecords.compactMap { record -> Date? in
      let input = TasksSidebarStructure.snoozeInput(
        for: record,
        now: taskNow,
        signals: signals[record.id] ?? TasksSidebarStructure.Signals()
      )
      guard TaskSnooze.effectiveSnoozed(input) else { return nil }
      return TaskTimestamps.read(record.snoozedUntil).date
    }
    .min()
  }

  /// Where the selection goes when `id` leaves the active list (A26).
  ///
  /// Computed over the *cached* structure, which is the pre-mutation snapshot —
  /// the reducer has not recomputed it yet — so the answer is the row the user
  /// could actually see below the one they just cleared. `nil` means stay put:
  /// either the mutated task is not the open one (background bookkeeping must
  /// never yank the user off their row), or there is nowhere to go.
  func taskForwardNavigationTarget(leaving id: TaskID) -> TaskID? {
    guard selection?.taskID == id else { return nil }
    let snoozedIDs = Set(tasksSidebarStructure.visibleSnoozedEntries.map(\.id))
    let settledIDs = Set(tasksSidebarStructure.visibleSettledTail.map(\.id))
    let ordered = tasksSidebarStructure.visibleTaskIDs.map { taskID in
      TaskForwardNavigation.Candidate(
        id: taskID,
        isSettled: settledIDs.contains(taskID),
        isSnoozed: snoozedIDs.contains(taskID)
      )
    }
    return TaskForwardNavigation.planForwardNavigation(orderedTasks: ordered, currentTaskID: id)
  }

  /// Points the one-shot alarm at the earliest wake still pending, or cancels it
  /// when nothing is parked.
  ///
  /// A no-op when the horizon has not moved: a *further* snooze landing behind
  /// the current alarm must not push it out, and re-arming on every mutation
  /// would restart a sleep that is already counting down correctly. An alarm
  /// left on a wake time nobody is waiting for is the worse half of the same
  /// bug — it fires a pointless recompute and, worse, leaves the real next wake
  /// unarmed — which is why un-snoozing the earliest row re-arms too.
  @MainActor
  mutating func armTaskWakeBoundaryEffect() -> Effect<RepositoriesFeature.Action> {
    let next = earliestTaskWake
    guard next != armedTaskWakeBoundary else { return .none }
    armedTaskWakeBoundary = next
    guard let next, let now = TaskTimestamps.read(taskNow).date else {
      return .cancel(id: TaskCancelID.wakeBoundary)
    }
    let delay =
      Duration.seconds(max(0, next.timeIntervalSince(now)))
      + RepositoriesFeature.taskWakeBoundaryOvershoot
    @Dependency(\.continuousClock) var clock
    return .run { send in
      try await clock.sleep(for: delay)
      await send(.tasks(.wakeBoundaryReached))
    }
    .cancellable(id: TaskCancelID.wakeBoundary, cancelInFlight: true)
  }

  // MARK: - Cache recomputes

  /// Equatable-diffs the Tasks render plan against the cache, so the panel only
  /// rebuilds when the rows it renders actually change. Mirrors
  /// `recomputeAgentDashboardStructureIfChanged()`.
  @MainActor
  mutating func recomputeTasksSidebarStructureIfChanged() {
    // An empty inbox has nothing to classify, and the three app-storage reads
    // behind the policy are not free on an app that never opened the Tasks tab.
    // Same early-out `recomputeTaskLeavesIfChanged` takes, for the same reason.
    guard !taskRecords.isEmpty || tasksSidebarStructure != .empty else { return }
    let new = TasksSidebarStructure.compute(
      tasks: Array(taskRecords),
      now: taskNow,
      signals: taskSignals,
      openTaskID: selection?.taskID,
      settledVisibleCount: settledTailVisibleCount,
      isSettledTailExpanded: isSettledTailExpanded,
      isSnoozedShelfExpanded: isSnoozedShelfExpanded,
      policy: taskSettlementPolicy,
      searchQuery: taskSearchQuery
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

  /// Projects everything a task row reports — presence, notifications,
  /// dormancy, the PR, and the three derived pills — onto its leaf. Activity is
  /// never an input to the structure's *ordering*, so this updates a row
  /// without reordering it (A4).
  ///
  /// A pure function of reducer state, deliberately: presence comes from
  /// `taskAgentSnapshots` (what `AppFeature` fanned in), never from a push
  /// straight onto the leaf, so running this twice is a no-op and no recompute
  /// can clobber something only the push knew. `pullRequestChangedAt` is the
  /// one field that reads its own previous value, and it is idempotent for the
  /// same reason: the second pass sees the projection it just wrote.
  ///
  /// Rows are found by directory rather than by inverting every surface: there
  /// is exactly one row per task directory, and this runs on every agent tick,
  /// so a per-tick `surfaceToItemID` rebuild would be paid for nothing.
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
      let previous = taskLeaves[id: record.id]
      var leaf = TaskLeafState(id: record.id)
      let row = rowIDsByPath[TaskDirectoryPath.normalized(record.directoryPath)]
        .flatMap { sidebarItems[id: $0] }
      leaf.hasDirectoryRow = row != nil
      leaf.agentSnapshot = Self.taskAgentSnapshot(
        for: record, projected: taskAgentSnapshots[record.id], row: row)
      leaf.errorAt = leaf.agentSnapshot.errorAt
      leaf.completedTurnAt = leaf.agentSnapshot.completedTurnAt
      leaf.workingSince = leaf.agentSnapshot.workingSince
      if let row, !record.surfaceIDs.isEmpty {
        leaf.allSurfacesDormant = row.allTabsDormant
        // Scoped to the surfaces this task owns: a sibling task's terminal in
        // the same directory must not light this row (Resolved #7).
        leaf.hasUnseenNotifications = row.unseenSurfaces.contains {
          record.surfaceIDs.contains($0.id)
        }
        let unreadOnOwnedSurfaces: [Date?] = row.notifications
          .filter { !$0.isRead && record.surfaceIDs.contains($0.surfaceID) }
          .map(\.createdAt)
        leaf.notifiedAt = TaskTimestamps.latestValid(unreadOnOwnedSurfaces)
      }
      // The PR belongs to the directory's branch, not to a surface claim, so it
      // is read even for a task that currently owns no terminal.
      leaf.pullRequest = Self.taskPullRequestState(row: row)
      leaf.pullRequestChangedAt = Self.taskPullRequestChangedAt(
        previous: previous, current: leaf.pullRequest, now: taskNow)
      // Creation counts: a task that has never done anything is still as old as
      // it looks, which is exactly what the inactivity window is measuring.
      leaf.lastActivityAt = TaskTimestamps.latestValid([
        record.createdAt, record.lastVisitedAt, leaf.completedTurnAt, leaf.errorAt, leaf.notifiedAt,
      ])
      leaf.isWoke = TaskSnooze.isWoke(
        TasksSidebarStructure.snoozeInput(for: record, now: taskNow, signals: leaf.signals),
        lastVisitedAt: record.lastVisitedAt
      )
      // Never-visited reads as *read* (A28): `isStrictlyOlder` answers `false`
      // for a missing stamp, which is what keeps a fresh seed of fifty stale
      // directories from opening on fifty unread badges.
      leaf.isDoneUnread =
        leaf.completedTurnAt.map {
          TaskTimestamps.isStrictlyOlder(record.lastVisitedAt, than: $0)
        } ?? false
      if previous != leaf {
        taskLeaves[id: record.id] = leaf
      }
    }
    for staleID in Array(taskLeaves.ids) where !liveIDs.contains(staleID) {
      taskLeaves.remove(id: staleID)
    }
    // A snapshot for a task that is gone is a leak nothing else prunes, and it
    // would be handed straight back to a task that later reuses the id.
    if taskAgentSnapshots.contains(where: { !liveIDs.contains($0.key) }) {
      taskAgentSnapshots = taskAgentSnapshots.filter { liveIDs.contains($0.key) }
    }
  }

  /// Presence for one task: what `AppFeature` projected across the surfaces the
  /// record owns, or — until it has spoken — the owning row's snapshot, but
  /// *only* when the task owns every surface that row has.
  ///
  /// That condition is the whole honesty of the fallback: when it holds, the
  /// row's union over its surfaces IS this task's projection, so the seed is
  /// exact. When it does not, the union is somebody else's news too, and there
  /// is no way to narrow it here — the per-surface records live in
  /// `AppFeature`, which is why the projection does.
  private static func taskAgentSnapshot(
    for record: TaskRecord,
    projected: AgentPresenceFeature.RowSnapshot?,
    row: SidebarItemFeature.State?
  ) -> AgentPresenceFeature.RowSnapshot {
    if let projected { return projected }
    guard let row, !record.surfaceIDs.isEmpty, record.surfaceIDs == Set(row.surfaceIDs) else {
      return AgentPresenceFeature.RowSnapshot()
    }
    return row.agentSnapshot
  }

  /// A29's three-way distinction, read off the query the worktree row already
  /// runs — no second poller, and no way for the two to disagree about one
  /// branch. "No PR" and "we have not asked yet" are different answers, and
  /// neither may be mistaken for a finished one.
  ///
  /// `.failed` outranks a stale `pullRequest` on purpose: once the query has
  /// started failing, the last value we hold is a claim we can no longer stand
  /// behind, and settling on it (A29's finished-PR path) would file a task away
  /// on evidence we know is unverified.
  private static func taskPullRequestState(row: SidebarItemFeature.State?) -> TaskPullRequestState {
    guard let row else { return .none }
    if row.pullRequestQueryDidFail { return .failed }
    guard let pullRequest = row.pullRequest else {
      return row.pullRequestBranchAtQueryTime != nil ? .loading : .none
    }
    switch pullRequest.state.uppercased() {
    case "OPEN": return .open
    case "MERGED": return .merged
    case "CLOSED": return .closed
    default: return .unknown
    }
  }

  /// When the projection last moved between two *known* states (A29b).
  ///
  /// Known → known only. Learning that a PR exists is not the PR changing: a
  /// batch refresh after a relaunch observes every task's PR for the first
  /// time, and counting that as news would pop every snoozed row in the app
  /// back into Active on launch.
  private static func taskPullRequestChangedAt(
    previous: TaskLeafState?,
    current: TaskPullRequestState,
    now: Date
  ) -> Date? {
    guard let previous else { return nil }
    guard previous.pullRequest.isKnown, current.isKnown, previous.pullRequest != current else {
      return previous.pullRequestChangedAt
    }
    return now
  }
}

extension RepositoriesFeature.TaskInboxAction {
  /// Whether this arm can move a surface between tasks (or into or out of one).
  ///
  /// A task's agent snapshot is projected across the surfaces the record owns,
  /// and that projection lives in `AppFeature` because only it holds the
  /// per-`(agent, surfaceID)` presence records. The surface-keyed fan-out cannot
  /// see an ownership move at all: the surfaces did not change, the *claim* did.
  /// Without a re-projection, a promoted tab keeps whatever the task knew before
  /// it owned the tab — a subset promote of an already-awaiting agent shows
  /// nothing until the next hook event, and a task that just lost its last
  /// surface keeps reporting work it no longer owns.
  ///
  /// Exhaustive (no `default`) for the same reason `cacheInvalidations` is: a new
  /// arm that claims surfaces has to say so rather than silently skip the seam.
  var movesTaskSurfaceOwnership: Bool {
    switch self {
    case .promoteTab, .reconcileSurfaceOwnership,
      .createTask, .resolveDirectoryConflict, .autoManagedWorktreeCreated,
      .loaded:
      return true
    // Everything else moves stamps, placement or presentation — never a claim.
    case .load, .seedIfNeeded, .select, .settle, .unsettle,
      .snooze, .unsnooze, .pin, .unpin, .keepActive,
      .jumpToNextNeedingAttention, .settleSelected, .snoozeSelected, .togglePinSelected,
      .focusSelectedSurface, .revealSelectedInSidebar, .consumeSidebarReveal,
      .setSearchQuery, .setSettledTailExpanded, .setSnoozedShelfExpanded, .expandSettledTail,
      .classificationTick, .wakeBoundaryReached, .agentSnapshotChanged,
      .autoSettleSettingsChanged, .stopTimers,
      .presentCreationPrompt, .setConflictRemember, .cancelDirectoryConflict,
      .presentRenamePrompt, .cancelRenamePrompt, .renameTask, .openTerminal, .requestDelete,
      .autoManagedWorktreeCreationFailed, .cleanupAutoManagedWorktree,
      .autoManagedWorktreeCleanupFinished:
      return false
    }
  }

  /// Which post-reduce caches each task arm touches. Exhaustive (no `default`)
  /// so a new arm has to declare it.
  var cacheInvalidations: CacheInvalidations {
    switch self {
    // Effect launchers: they mutate nothing the caches project.
    case .load, .seedIfNeeded:
      return []
    // Keyboard entry points. Each one resolves a target and forwards to the arm
    // that does the work, which is where the invalidation is declared; declaring
    // it here too would stamp `taskNow` twice for one keystroke.
    case .jumpToNextNeedingAttention, .settleSelected, .snoozeSelected,
      .togglePinSelected, .focusSelectedSurface:
      return []
    // Presentation only: a reveal moves the scroll offset and the focus ring,
    // never a record or a placement.
    case .revealSelectedInSidebar, .consumeSidebarReveal:
      return []
    // Presentation only: the prompts are state no cache projects.
    case .presentCreationPrompt, .setConflictRemember, .cancelDirectoryConflict,
      .presentRenamePrompt, .cancelRenamePrompt,
      // Opens the confirmation and nothing else; the removal itself rides the
      // alert action, which declares its own bits.
      .requestDelete:
      return []
    // Effect launcher: it touches neither a record nor the roster.
    case .cleanupAutoManagedWorktree:
      return []
    // Pure teardown. Deliberately declares nothing, which is also what keeps it
    // from stamping `taskNow` and moving a row on the way out.
    case .stopTimers:
      return []
    // No record was written (A20b), but the rollback prunes the roster and the
    // sidebar buckets, which is the same set `.createRandomWorktreeFailed`
    // declares for the same `cleanupFailedWorktree` call.
    case .autoManagedWorktreeCreationFailed:
      return [.sidebarStructure, .selectedWorktreeSlice, .sidebarSelectionSlice]
    // Clears a spent delete marker and, on a delete that happened, prunes the
    // row whose directory is now gone — which can move the selection too.
    case .autoManagedWorktreeCleanupFinished:
      return [.sidebarStructure, .selectedWorktreeSlice, .sidebarSelectionSlice]
    // Every arm that can change the record set, its lifecycle, the page window,
    // or the clock sample the placement rules are evaluated against.
    case .loaded, .select, .settle, .unsettle,
      .snooze, .unsnooze, .pin, .unpin, .keepActive,
      .setSearchQuery, .setSettledTailExpanded, .setSnoozedShelfExpanded, .expandSettledTail,
      .classificationTick, .wakeBoundaryReached, .agentSnapshotChanged, .autoSettleSettingsChanged,
      .reconcileSurfaceOwnership, .promoteTab,
      // Can unsettle the task it opens, which moves it out of the settled tail.
      .openTerminal,
      // A rename is a record write the title filter reads (A37), so the render
      // plan has to be rebuilt against it.
      .renameTask:
      return .sidebarStructure
    // Creation also moves the selection inline, so it owes the two
    // selection-derived caches on top of the record set. `autoManagedWorktreeCreated`
    // adds a row to the roster on top of that, which is the same set
    // `.createRandomWorktreeSucceeded` declares.
    case .createTask, .resolveDirectoryConflict, .autoManagedWorktreeCreated:
      return [.sidebarStructure, .selectedWorktreeSlice, .sidebarSelectionSlice]
    }
  }

  /// Whether this arm may move `taskNow`, the instant every placement rule is
  /// evaluated against (A23).
  ///
  /// Rebuilding the structure and *re-timing* it are two different things. A few
  /// arms owe a rebuild for presentation reasons alone — typing in the search
  /// field, opening a shelf — and stamping the clock for them would age the whole
  /// inbox on every keystroke: rows would recede, "snoozed until" countdowns
  /// would tick, and a task could cross a settle boundary because someone
  /// searched for it.
  ///
  /// Exhaustive (no `default`) for the same reason `cacheInvalidations` is, and
  /// defaulting to true: a new arm that writes a stamp has to be able to
  /// classify against the instant it wrote.
  var samplesClock: Bool {
    switch self {
    // Presentation only: these change what the user is looking at, never when
    // it happened.
    case .setSearchQuery, .setSettledTailExpanded, .expandSettledTail,
      .setSnoozedShelfExpanded, .setConflictRemember, .requestDelete,
      // A rename writes no stamp and moves no row: re-timing the inbox because
      // someone retitled a task would age every other row for free.
      .presentRenamePrompt, .cancelRenamePrompt, .renameTask:
      return false
    case .load, .loaded, .seedIfNeeded, .select, .settle, .unsettle,
      .snooze, .unsnooze, .pin, .unpin, .keepActive,
      .jumpToNextNeedingAttention, .settleSelected, .snoozeSelected, .togglePinSelected,
      .focusSelectedSurface, .revealSelectedInSidebar, .consumeSidebarReveal,
      .classificationTick, .wakeBoundaryReached, .agentSnapshotChanged,
      .autoSettleSettingsChanged, .stopTimers,
      .presentCreationPrompt, .cancelDirectoryConflict, .createTask,
      .resolveDirectoryConflict, .promoteTab, .reconcileSurfaceOwnership, .openTerminal,
      .autoManagedWorktreeCreated, .autoManagedWorktreeCreationFailed,
      .cleanupAutoManagedWorktree, .autoManagedWorktreeCleanupFinished:
      return true
    }
  }
}

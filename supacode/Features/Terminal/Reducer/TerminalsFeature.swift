import ComposableArchitecture
import Foundation
import SupacodeSettingsShared

/// App-shell side effects of a layout change (persistence debounce, sidebar
/// projection, dormant watchers); the integration layer injects the live hook.
nonisolated struct LayoutChangeObserver: Sendable {
  var layoutChanged: @MainActor @Sendable (LayoutID) -> Void
  /// A directory now resolves to another task; `nil` means the task stored
  /// under the directory's own key.
  var activeTaskChanged: @MainActor @Sendable (Worktree.ID, LayoutID?) -> Void = { _, _ in }
  /// A task's stored sessions changed; its tabs did not.
  var sessionsChanged: @MainActor @Sendable (LayoutID) -> Void = { _ in }
}

extension LayoutChangeObserver: DependencyKey {
  static let liveValue = LayoutChangeObserver(layoutChanged: { _ in })
  static let testValue = liveValue
}

/// Owns the per-worktree `LayoutFeature` collection and the visibility-driven
/// hibernation sweep. Views scope through
/// `store.scope(state: \.terminals, action: \.terminals)` so terminal surface
/// area stays bounded to terminal state instead of the whole app.
@Reducer
struct TerminalsFeature {
  /// Grace window a tab must stay hidden before it hibernates.
  static let hibernationGraceWindow: Duration = .seconds(5 * 60)

  /// How many most-recently-selected worktrees keep their visible tabs live no
  /// matter how long they stay deselected, so flipping back among that set never
  /// pays a rewake.
  static let liveWorktreeLimit = 3

  /// Per-tab cancellation key for the hibernation grace timer.
  nonisolated enum HibernationTimerID: Hashable, Sendable {
    case tab(TabID)
  }

  /// Cancellation key for the process-wide memory-pressure subscription.
  nonisolated enum CancelID: Hashable, Sendable {
    case memoryPressure
  }

  @ObservableState
  struct State: Equatable {
    /// Per-task pane and tab topology, hydrated from the persisted layouts.
    var layouts: IdentifiedArrayOf<LayoutFeature.State> = []
    /// Each layout's directory: a hydrated one's as its task record names
    /// it, any other's as its host was created with.
    var directories: [LayoutID: TaskRecord.Directory] = [:]
    /// Each directory's most recently selected task. A directory with no
    /// entry resolves to the layout stored under its own key.
    var activeTasks: [Worktree.ID: LayoutID] = [:]
    /// Each task's agents, primary first. Stored sessions load at hydration;
    /// an agent that has not reported its session yet is held provisionally.
    var members: [LayoutID: [TaskMember]] = [:]
    /// What is known of the sessions the store lists. Until they load,
    /// `members` holds only what this run has seen and is not written.
    var storedSessions = TaskMembership.StoredSessions.pending
    /// Every change to `members` made while the stored sessions are pending,
    /// in order. Hydration applies them again to each stored list, so the
    /// result is the one the run would have reached had it loaded first.
    var pendingMembership: [TaskMembership.Change] = []
    /// Tasks removed this run. The stored layouts are read once at launch and
    /// still list them, so anything that falls back to a stored record skips
    /// these or a removed task comes back as a dormant one.
    var removedLayoutIDs: Set<LayoutID> = []
    /// Every layout selected this run, oldest first. A selection can precede
    /// both its directory (the host attaches later) and the stored entries
    /// (the file loads later), and still has to outrank them once known.
    var selectionOrder: [LayoutID] = []
    /// True when the persisted file was written by a newer schema; its records
    /// are served but must never be written back.
    var layoutsAreReadOnly = false
    /// True once the stored layouts have hydrated. Before that a hydration
    /// could still re-add a tab or a session a transfer moved away.
    var layoutsLoaded = false
    /// Tasks merged away this run or before, removed task → the task that
    /// took its tabs. A shell started in a merged task still names the old id.
    var mergedTasks: [LayoutID: LayoutID] = [:]
    /// The selected worktree; only its panes' selected tabs are visible, so
    /// everything else is a hibernation candidate.
    var selectedLayoutID: LayoutID?
    /// Most-recently-selected worktrees, newest first, capped at
    /// `liveWorktreeLimit`. Their visible panes' selected tabs never arm a grace
    /// timer, so flipping back among them is instant.
    var recentLayoutIDs: [LayoutID] = []
    /// Tabs with an armed hibernation grace timer.
    var hibernationArmedTabs: Set<TabID> = []
    /// Hidden-but-ineligible tabs already logged, so a permanently ineligible
    /// tab does not spam every grace-window re-fire.
    var hibernationDeferralLogged: Set<TabID> = []
    /// Visible tabs already sent a wake; cleared when the renderer appears or
    /// the tab hides again, so a failed wake cannot loop.
    var wakeRequestedTabs: Set<TabID> = []
  }

  enum Action {
    case layouts(IdentifiedActionOf<LayoutFeature>)
    /// Subscribes the memory-pressure source the hibernation policy reacts to.
    case task
    /// The migrated layouts file finished loading. Consistent records become
    /// `LayoutFeature` states; inconsistent ones fall back to a fresh layout
    /// on first use.
    case layoutsHydrated(TaskLayoutsFile)
    /// Ensures a layout exists for a worktree and carries its display name for
    /// minted tab titles. Never replaces a live layout.
    case attachLayout(worktreeID: LayoutID, directory: TaskRecord.Directory, titlePrefix: String)
    /// Replaces a not-yet-hosted launch restore after bare-shell pruning.
    case replaceRestoredLayout(worktreeID: LayoutID, layout: PaneLayout)
    /// Drops a pruned worktree's layout and bookkeeping.
    case detachLayout(worktreeID: LayoutID)
    /// Moves tabs and members from one task's layout to another's in one
    /// turn, both or neither. Sent only by the terminal manager, which moves
    /// the per-task surface bookkeeping around it; nothing is closed.
    case transferTabs(from: LayoutID, into: LayoutID, scope: TabTransferScope)
    /// The agents presence reports changed which sessions belong to which task.
    case membersChanged([LayoutID: [TaskMember]], agents: [TaskAgent] = [])
    /// The stored layouts cannot be read this run, so no hydration follows.
    case storedSessionsUnreadable
    /// The sessions the store lists for its tasks, read at launch ahead of
    /// the layouts (which wait for the live zmx sessions), so every write
    /// from then on, a quit's included, carries the run's members.
    case storedSessionsLoaded(TaskLayoutsFile)
    /// The agent on one of the task's surfaces switched sessions (`/new`,
    /// `/fork`): `new` takes `old`'s slot and `old` stays a member after it.
    case sessionReplaced(LayoutID, old: SessionKey, new: SessionKey)
    /// Worktree selection moved; visibility-driven hibernation re-diffs and
    /// the newly visible selection wakes.
    case selectedLayoutChanged(LayoutID?)
    /// The hibernation Beta flag flipped: enabling re-arms hidden tabs,
    /// disabling cancels every pending timer.
    case hibernationPolicyChanged
    /// A tab's grace timer fired; re-verify and hibernate or re-arm.
    case hibernationGraceElapsed(worktreeID: LayoutID, tabID: TabID)
    /// The system reported memory pressure: drop the recency budget to the
    /// selection and hibernate the hidden tabs now, skipping the grace window.
    case memoryPressureWarning
  }

  private static let logger = SupaLogger("TerminalsFeature")

  // Ratio drags, the inline rename begin/end toggles, and a teardown title
  // commit never flip tab visibility, so skip the layout-wide re-diff for them.
  private static func canAffectVisibility(_ action: LayoutFeature.Action) -> Bool {
    switch action {
    case .resizePane, .beginTabRename, .endTabRename, .runtime(.titleCommitted):
      return false
    case .newTab, .splitPane, .closeTab, .closePane, .selectTab, .renameTab, .focusPane,
      .moveTab, .moveTabToSplit, .moveTabToSpanningSplit, .enterWindowMode, .exitWindowMode,
      .equalizePanes, .toggleZoom, .hibernateTab, .wakeTab, .runtime(.killConfirmed),
      .contentRequestedClose, .closeAllTabsRequested, .contentRequestedNewTab, .contentRequestedSplit,
      .contentRequestedFocus, .contentRequestedFocusSplit, .contentRequestedToggleZoom,
      .contentRequestedResize, .contentRequestedGotoTab, .contentRequestedMoveTab, .alert:
      return true
    }
  }

  @Dependency(ContentRuntime.self) private var contentRuntime
  @Dependency(LayoutChangeObserver.self) private var layoutChangeObserver
  @Dependency(MemoryPressureClient.self) private var memoryPressure
  @Dependency(\.continuousClock) private var clock
  @Dependency(\.uuid) private var uuid

  var body: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .layouts(.element(let worktreeID, let action)):
        // The element reducer already ran; any topology change may flip tab
        // visibility, so re-diff the grace timers and fire the app-shell
        // hooks (persistence debounce, sidebar projection).
        let hibernation = Self.canAffectVisibility(action) ? reconcileHibernation(&state) : .none
        return .merge(
          hibernation,
          .run { _ in await layoutChangeObserver.layoutChanged(worktreeID) }
        )

      case .layouts:
        return reconcileHibernation(&state)

      case .task:
        return .run { [memoryPressure] send in
          for await _ in memoryPressure.warnings() {
            await send(.memoryPressureWarning)
          }
        }
        .cancellable(id: CancelID.memoryPressure, cancelInFlight: true)

      case .attachLayout(let worktreeID, let directory, let titlePrefix):
        if state.layouts[id: worktreeID] == nil {
          state.layouts.append(LayoutFeature.State(id: worktreeID, layout: PaneLayout()))
        }
        state.removedLayoutIDs.remove(worktreeID)
        // A task again, not a forward to the one it was merged into.
        state.mergedTasks.removeValue(forKey: worktreeID)
        state.layouts[id: worktreeID]?.titlePrefix = titlePrefix
        guard state.directories[worktreeID] == nil else { return .none }
        state.directories[worktreeID] = directory
        // The selection can land before the host that names the directory,
        // and the user may have moved on to another directory since.
        guard state.latestSelection(onDirectory: directory.worktreeID) == worktreeID else { return .none }
        return recordActiveTask(worktreeID, in: &state)

      case .replaceRestoredLayout(let worktreeID, let layout):
        guard state.layouts[id: worktreeID] != nil else { return .none }
        state.layouts[id: worktreeID]?.layout = layout
        return reconcileHibernation(&state)

      case .detachLayout(let worktreeID):
        // Bookkeeping is NOT pre-cleared: the reconcile below must still see
        // the armed entries to emit their timer cancellations.
        state.layouts.remove(id: worktreeID)
        state.removedLayoutIDs.insert(worktreeID)
        state.directories.removeValue(forKey: worktreeID)
        state.members.removeValue(forKey: worktreeID)
        state.pendingMembership = state.pendingMembership.compactMap { $0.dropping(worktreeID) }
        state.activeTasks = state.activeTasks.filter { $0.value != worktreeID }
        state.recentLayoutIDs.removeAll { $0 == worktreeID }
        state.selectionOrder.removeAll { $0 == worktreeID }
        state.mergedTasks = state.mergedTasks.filter { $0.value != worktreeID }
        return reconcileHibernation(&state)

      case .transferTabs(let from, let target, let scope):
        return reduceTransferTabs(&state, from: from, into: target, scope: scope)

      case .membersChanged(let members, let agents):
        // Only a change in stored sessions is worth a write; a provisional
        // member coming or going is runtime only.
        let changed = Set(state.members.keys).union(members.keys).filter {
          state.members[$0]?.compactMap(\.sessionKey) ?? [] != members[$0]?.compactMap(\.sessionKey) ?? []
        }
        state.members = members
        if state.storedSessions == .pending { state.pendingMembership.append(.agents(agents)) }
        return sessionsChanged(Array(changed))

      case .sessionReplaced(let layoutID, let old, let new):
        // Queued even when it moves nothing here: the replaced session may
        // be one only the stored list names.
        if state.storedSessions == .pending {
          state.pendingMembership.append(.replaced(layoutID, old: old, new: new))
        }
        guard
          let members = TaskMembership.replacing(old, with: new, in: state.members[layoutID] ?? [])
        else { return .none }
        state.members[layoutID] = members
        return .run { _ in await layoutChangeObserver.sessionsChanged(layoutID) }

      case .storedSessionsUnreadable:
        guard state.storedSessions == .pending else { return .none }
        state.storedSessions = .unreadable
        state.pendingMembership = []
        return sessionsChanged(Array(state.members.keys))

      case .storedSessionsLoaded(let file):
        return sessionsChanged(state.loadStoredSessions(from: file))

      case .selectedLayoutChanged(let layoutID):
        state.selectedLayoutID = layoutID
        Self.recordSelection(layoutID, in: &state.recentLayoutIDs)
        if let layoutID {
          state.selectionOrder.removeAll { $0 == layoutID }
          state.selectionOrder.append(layoutID)
        }
        let activeTask = layoutID.map { recordActiveTask($0, in: &state) } ?? .none
        return .merge(reconcileHibernation(&state), activeTask)

      case .hibernationPolicyChanged:
        return reconcileHibernation(&state)

      case .hibernationGraceElapsed(let worktreeID, let tabID):
        return reduceHibernationGraceElapsed(&state, worktreeID: worktreeID, tabID: tabID)

      case .memoryPressureWarning:
        return reduceMemoryPressureWarning(&state)

      case .layoutsHydrated(let file):
        state.layoutsAreReadOnly = file.schemaVersion > TaskLayoutsFile.currentSchemaVersion
        state.layoutsLoaded = true
        for (key, destinationKey) in file.mergedTasks {
          let merged = LayoutID(legacyWorktreeKey: key)
          guard let destination = file.tasks[destinationKey]?.id, state.mergedTasks[merged] == nil,
            state.layouts[id: merged] == nil
          else { continue }
          state.mergedTasks[merged] = destination
        }
        // The runtime keys globally by content id and hibernation by tab id, so
        // seed from what is already hydrated and refuse any record that reuses an
        // id from another worktree (possible in pre-creation-gate layouts).
        var seenContentIDs = Set(state.layouts.flatMap { $0.layout.allContentIDs })
        var seenTabIDs = Set(state.layouts.flatMap { $0.layout.panes.flatMap(\.tabs.ids) })
        // Membership is the record's whether or not its layout is usable.
        let unwritten = state.loadStoredSessions(from: file)
        for (key, record) in file.tasks.sorted(by: { $0.key < $1.key }) {
          guard record.layout.isConsistent else {
            Self.logger.error("Dropping inconsistent persisted layout for \(key)")
            continue
          }
          let contentIDs = record.layout.allContentIDs
          let tabIDs = record.layout.panes.flatMap(\.tabs.ids)
          guard seenContentIDs.isDisjoint(with: contentIDs), seenTabIDs.isDisjoint(with: tabIDs) else {
            Self.logger.error("Dropping persisted layout for \(key): an id collides with another layout")
            continue
          }
          guard state.layouts[id: record.id] == nil else { continue }
          state.layouts.append(LayoutFeature.State(id: record.id, layout: record.layout))
          state.directories[record.id] = record.directory
          seenContentIDs.formUnion(contentIDs)
          seenTabIDs.formUnion(tabIDs)
        }
        // A selection made this run is more recent than anything stored, and
        // hydration may be what first names its directory. Applied before the
        // stored entries so a directory gets one write, not a clear racing it.
        let selectedDirectories = Set(state.selectionOrder.compactMap { state.directories[$0]?.worktreeID })
        let activeTask = Effect<Action>.merge(
          selectedDirectories.compactMap { state.latestSelection(onDirectory: $0) }
            .map { recordActiveTask($0, in: &state) }
        )
        // Selected on its own key this run: the stored entry is older, and
        // nothing has told the file so.
        var staleDirectories: [Worktree.ID] = []
        for (directory, key) in file.activeTasks {
          let directoryID = Worktree.ID(directory)
          guard let id = file.tasks[key]?.id, state.directories[id]?.worktreeID == directoryID,
            state.activeTasks[directoryID] == nil
          else { continue }
          guard !selectedDirectories.contains(directoryID) else {
            staleDirectories.append(directoryID)
            continue
          }
          state.activeTasks[directoryID] = id
        }
        // Hydration can land after the first selection; re-diff so the
        // restored hidden tabs arm and the visible selection wakes.
        let clearStale: Effect<Action> =
          staleDirectories.isEmpty
          ? .none
          : .run { [staleDirectories] _ in
            for directoryID in staleDirectories {
              await layoutChangeObserver.activeTaskChanged(directoryID, nil)
            }
          }
        return .merge(reconcileHibernation(&state), clearStale, activeTask, sessionsChanged(unwritten))
      }
    }
    .forEach(\.layouts, action: \.layouts) {
      LayoutFeature()
    }
  }
}

// MARK: - Membership.

extension TerminalsFeature {
  /// Asks for a write of each task's sessions, in a fixed order.
  fileprivate func sessionsChanged(_ layoutIDs: [LayoutID]) -> Effect<Action> {
    guard !layoutIDs.isEmpty else { return .none }
    return .run { _ in
      for layoutID in layoutIDs.sorted(by: { $0.persistenceKey < $1.persistenceKey }) {
        await layoutChangeObserver.sessionsChanged(layoutID)
      }
    }
  }
}

extension TerminalsFeature.Action {
  /// What the launch-time read of the store says about its sessions. Nothing
  /// stored is loaded too: the run's order of a task's sessions is all there is.
  static func storedSessions(_ disk: TaskLayoutsFile.DiskState) -> Self {
    switch disk {
    case .file(let file): .storedSessionsLoaded(file)
    case .absent: .storedSessionsLoaded(TaskLayoutsFile())
    case .unreadable: .storedSessionsUnreadable
    }
  }
}

extension TerminalsFeature.State {
  /// Merges the sessions `file` lists into `members` and returns the tasks
  /// whose stored sessions now differ from the run's. Nothing was written
  /// from `members` while the stored sessions were pending, so the first
  /// read also returns every task the file does not hold yet.
  fileprivate mutating func loadStoredSessions(from file: TaskLayoutsFile) -> [LayoutID] {
    var unwritten =
      storedSessions == .pending
      ? members.filter { file.tasks[$0.key.persistenceKey] == nil }.map(\.key) : []
    for (_, record) in file.tasks.sorted(by: { $0.key < $1.key }) {
      let merged = hydratedMembers(of: record)
      if !merged.isEmpty { members[record.id] = merged }
      if merged.compactMap(\.sessionKey) != record.sessions { unwritten.append(record.id) }
    }
    storedSessions = .loaded
    pendingMembership = []
    return unwritten
  }

  /// A stored task's members once its record is read. The first read
  /// applies everything queued since launch to the stored list, so the
  /// primary is the one the stored order and those changes give, whichever
  /// agent reported first. A task stored with no session has nothing the
  /// run's list lacks, and a later read only adds what the run does not list.
  fileprivate func hydratedMembers(of record: TaskRecord) -> [TaskMember] {
    let runtime = members[record.id] ?? []
    guard storedSessions == .pending, !record.sessions.isEmpty else {
      return runtime + record.sessions.map(TaskMember.session).filter { !runtime.contains($0) }
    }
    let replayed = TaskMembership.replaying(pendingMembership, for: record.id, onto: record.sessions)
    return replayed + runtime.filter { !replayed.contains($0) }
  }
}

// MARK: - Transfer between tasks.

extension TerminalsFeature.State {
  /// The tabs a transfer would move, in landing order. Nil when the source
  /// or the named tab does not exist.
  func tabsToTransfer(from: LayoutID, scope: TabTransferScope) -> [TabItem]? {
    guard let layout = layouts[id: from]?.layout else { return nil }
    switch scope {
    case .all:
      return layout.tree.leaves().compactMap { layout.panes[id: $0] }.flatMap { Array($0.tabs) }
    case .tab(let tabID, _):
      return layout.pane(containingTab: tabID)?.tabs[id: tabID].map { [$0] }
    }
  }

  /// Why a transfer cannot run, or nil. Pure: everything the state alone
  /// decides, in a fixed order.
  func transferRefusal(
    from: LayoutID, into target: LayoutID, scope: TabTransferScope, destination: TaskRecord.Directory
  ) -> TabTransferRefusal? {
    guard from != target else { return .sameTask }
    // Until both loads land, a hydration would re-add what the transfer moved.
    guard layoutsLoaded, storedSessions == .loaded, !layoutsAreReadOnly else { return .notReady }
    guard let source = layouts[id: from] else { return .unknownSource }
    switch scope {
    case .all:
      guard layouts[id: target] != nil else { return .unknownDestination }
    case .tab(let tabID, let moving):
      guard layouts[id: target] == nil else { return .destinationExists }
      guard source.layout.pane(containingTab: tabID) != nil else { return .unknownTab }
      let listed = members[from] ?? []
      guard moving.allSatisfy(listed.contains) else { return .memberNotInSource }
    }
    guard source.alert == nil, layouts[id: target]?.alert == nil else { return .confirmationPending }
    // A relaunch rebuilds a tab against its task's host: on another machine
    // its session would be lost, and a close would kill on the wrong side.
    guard directories[from]?.host == destination.host else { return .differentMachine }
    return nil
  }
}

extension TerminalsFeature {
  /// Both layouts and both member lists change, or nothing does. No tab is
  /// closed, so nothing here reaps a content or reports a layout change: the
  /// manager, which sent this, moves the per-task bookkeeping around it.
  fileprivate func reduceTransferTabs(
    _ state: inout State, from: LayoutID, into target: LayoutID, scope: TabTransferScope
  ) -> Effect<Action> {
    guard from != target, let source = state.layouts[id: from], let destination = state.layouts[id: target],
      let moving = state.tabsToTransfer(from: from, scope: scope)
    else { return .none }
    let makePaneID = { [uuid] in PaneID(rawValue: uuid()) }
    let remaining: PaneLayout
    let grown: PaneLayout
    do {
      switch scope {
      case .all:
        remaining = PaneLayout()
        grown = try LayoutTransfer.flatten(source.layout, into: destination.layout, makePaneID: makePaneID).layout
      case .tab(let tabID, _):
        let extraction = try LayoutTransfer.extract(tabID, from: source.layout, makePaneID: makePaneID)
        remaining = extraction.remainder
        grown = try LayoutTransfer.flatten(extraction.extracted, into: destination.layout, makePaneID: makePaneID)
          .layout
      }
    } catch {
      Self.logger.error("Refused to move tabs from \(from) to \(target): \(error)")
      return .none
    }
    let movedTabIDs = Set(moving.map(\.id))
    state.layouts[id: from]?.layout = remaining
    state.layouts[id: from]?.windowedPaneIDs.formIntersection(remaining.panes.ids)
    if let editing = source.editingTabID, movedTabIDs.contains(editing) {
      state.layouts[id: from]?.editingTabID = nil
    }
    state.layouts[id: target]?.layout = grown

    // The destination's first member stays primary; a task with no member
    // takes the arriving order whole.
    let sourceMembers = state.members[from] ?? []
    let moved: [TaskMember]
    switch scope {
    case .all: moved = sourceMembers
    case .tab(_, let members): moved = sourceMembers.filter(members.contains)
    }
    let kept = sourceMembers.filter { !moved.contains($0) }
    state.members[from] = kept.isEmpty ? nil : kept
    let listed = state.members[target] ?? []
    let joined = listed + moved.filter { !listed.contains($0) }
    state.members[target] = joined.isEmpty ? nil : joined

    if scope == .all {
      for (earlier, pointed) in state.mergedTasks where pointed == from {
        state.mergedTasks[earlier] = target
      }
      state.mergedTasks[from] = target
    }

    // A timer armed for a moved tab carries the source's id; drop it and let
    // the re-diff arm one under the task that holds the tab now.
    var cancels: [Effect<Action>] = []
    for tab in moving {
      if state.hibernationArmedTabs.remove(tab.id) != nil {
        cancels.append(.cancel(id: HibernationTimerID.tab(tab.id)))
      }
      state.hibernationDeferralLogged.remove(tab.id)
      state.wakeRequestedTabs.remove(tab.id)
    }
    return .concatenate(.merge(cancels), reconcileHibernation(&state))
  }
}

// MARK: - Directory resolution.

extension TerminalsFeature.State {
  /// The layout a directory resolves to: the task its row shows, or, when it
  /// has none, where its first tab lands.
  func layoutID(forDirectory directoryID: Worktree.ID) -> LayoutID {
    task(forDirectory: directoryID) ?? recordedLayoutID(forDirectory: directoryID)
  }

  /// The task a directory's row shows: one that holds a tab and sits on that
  /// directory. The recorded one when it still is such a task (the usual
  /// case, no scan), else the one selected most recently this run, else the
  /// own-key one, else the first by key. Nil when the directory has no task
  /// to show. No recorded entry is not a vote for the own-key task: removing
  /// the active task clears the entry too.
  func task(forDirectory directoryID: Worktree.ID) -> LayoutID? {
    if let recorded = activeTasks[directoryID], isTask(recorded, onDirectory: directoryID) { return recorded }
    if let recent = selectionOrder.last(where: { isTask($0, onDirectory: directoryID) }) { return recent }
    let ownKey = Self.ownKeyLayoutID(forDirectory: directoryID)
    if isTask(ownKey, onDirectory: directoryID) { return ownKey }
    return layoutIDs(onDirectory: directoryID).first(where: holdsTabs)
  }

  /// The layout a directory-addressed command means. A pane, tab or surface id
  /// the command carries decides first: ids are unique across tasks, so the
  /// task that holds one is the target whichever task the directory shows.
  /// Then the task the command names, which has to sit on this directory.
  /// Then the directory's own answer: `shown` when the caller knows a task
  /// selection the terminal has not recorded yet, else the recorded one. Nil
  /// only for a named task that is not one of this directory's.
  func commandLayoutID(
    forDirectory directoryID: Worktree.ID, task: LayoutID? = nil, holding ids: [UUID] = [], shown: LayoutID? = nil
  ) -> LayoutID? {
    // A task merged away is the task that took its tabs.
    let task = task.map { mergedTasks[$0] ?? $0 }
    let resolved = shown ?? layoutID(forDirectory: directoryID)
    if !ids.isEmpty {
      // The resolved layout first: it is the usual owner, and the only
      // candidate nothing names yet.
      let candidates = [resolved] + layoutIDs(onDirectory: directoryID).filter { $0 != resolved }
      for id in ids {
        if let owner = candidates.first(where: { layouts[id: $0]?.layout.pane(forToken: id) != nil }) {
          return owner
        }
      }
    }
    guard let task else { return resolved }
    return directories[task]?.worktreeID == directoryID ? task : nil
  }

  /// The task whose layout holds a content. A scan: for spawn, wake and
  /// unexpected close, never for rendering.
  func layoutID(holdingContent id: ContentID) -> LayoutID? {
    layouts.first { $0.layout.tab(containingContent: id) != nil }?.id
  }

  /// Whether a layout holds a tab and sits on this directory.
  func isTask(_ layoutID: LayoutID, onDirectory directoryID: Worktree.ID) -> Bool {
    guard holdsTabs(layoutID) else { return false }
    // A layout no record or host names yet is the one the directory was sent to.
    return directories[layoutID].map { $0.worktreeID == directoryID }
      ?? (layoutID == recordedLayoutID(forDirectory: directoryID))
  }

  /// What a directory's detail mounts: the task its row shows, else the layout
  /// its first tab lands in. Nil when that layout is another directory's
  /// task, which is never shown or selected as this directory's.
  func displayLayoutID(forDirectory directoryID: Worktree.ID) -> LayoutID? {
    if let task = task(forDirectory: directoryID) { return task }
    let landing = recordedLayoutID(forDirectory: directoryID)
    return directories[landing].map { $0.worktreeID == directoryID } ?? true ? landing : nil
  }

  /// The directory's most recently selected task as recorded, unchecked: the
  /// entry may name nothing that exists, and no entry means its own key.
  private func recordedLayoutID(forDirectory directoryID: Worktree.ID) -> LayoutID {
    activeTasks[directoryID] ?? Self.ownKeyLayoutID(forDirectory: directoryID)
  }

  private func holdsTabs(_ layoutID: LayoutID) -> Bool {
    layouts[id: layoutID]?.layout.panes.contains { !$0.tabs.isEmpty } == true
  }

  /// The layout stored under the directory's own key: the one task every
  /// directory had before tasks, and where a first tab still lands.
  static func ownKeyLayoutID(forDirectory directoryID: Worktree.ID) -> LayoutID {
    LayoutID(legacyWorktreeKey: directoryID.rawValue)
  }

  /// The layout on a directory selected most recently this run, if any.
  func latestSelection(onDirectory directoryID: Worktree.ID) -> LayoutID? {
    selectionOrder.last { directories[$0]?.worktreeID == directoryID }
  }

  /// Every layout on a directory, in key order.
  func layoutIDs(onDirectory directoryID: Worktree.ID) -> [LayoutID] {
    directories.filter { $0.value.worktreeID == directoryID }.map(\.key)
      .sorted { $0.persistenceKey < $1.persistenceKey }
  }
}

extension TerminalsFeature {
  /// Makes `layoutID` the task its directory resolves to. Storing nothing for
  /// the directory's own-key layout keeps a one-task directory out of the map,
  /// so selecting it never writes.
  private func recordActiveTask(_ layoutID: LayoutID, in state: inout State) -> Effect<Action> {
    guard let directoryID = state.directories[layoutID]?.worktreeID else { return .none }
    let active: LayoutID? = layoutID == State.ownKeyLayoutID(forDirectory: directoryID) ? nil : layoutID
    guard state.activeTasks[directoryID] != active else { return .none }
    state.activeTasks[directoryID] = active
    return .run { _ in await layoutChangeObserver.activeTaskChanged(directoryID, active) }
  }
}

// MARK: - Hibernation.

extension TerminalsFeature {
  /// Whether a tab is hidden: everything except the selected tab of a pane
  /// that shows content somewhere.
  private static func isTabHidden(_ tab: TabItem, pane: Pane, paneShowsContent: Bool) -> Bool {
    !(paneShowsContent && pane.selectedTabID == tab.id)
  }

  /// Whether a pane's area renders: the selected worktree's visible panes
  /// (zoom hides the rest), or any windowed pane, whose window stays open
  /// even when miniaturized.
  private static func paneShowsContent(
    _ pane: Pane,
    in layout: LayoutFeature.State,
    visiblePanes: Set<PaneID>,
    selectedLayoutID: LayoutID?
  ) -> Bool {
    if layout.windowedPaneIDs.contains(pane.id) {
      return true
    }
    return layout.id == selectedLayoutID && visiblePanes.contains(pane.id)
  }

  /// Moves a selection to the front of the recency list, capped at
  /// `liveWorktreeLimit`. Deselecting keeps the list, so the worktree just left
  /// stays the most recent.
  private static func recordSelection(_ worktreeID: LayoutID?, in recents: inout [LayoutID]) {
    guard let worktreeID else { return }
    recents.removeAll { $0 == worktreeID }
    recents.insert(worktreeID, at: 0)
    if recents.count > liveWorktreeLimit {
      recents.removeLast(recents.count - liveWorktreeLimit)
    }
  }

  /// Whether recency alone keeps this hidden tab live: it is the selected tab of
  /// a visible pane (so stacked background tabs never qualify) and its worktree
  /// is still inside the recency window.
  private static func recencyRetains(
    _ tab: TabItem,
    pane: Pane,
    in layout: LayoutFeature.State,
    visiblePanes: Set<PaneID>,
    recentLayoutIDs: [LayoutID]
  ) -> Bool {
    guard pane.selectedTabID == tab.id, visiblePanes.contains(pane.id) else { return false }
    return recentLayoutIDs.contains(layout.id)
  }

  /// Diffs the hidden set against armed timers and wakes newly visible
  /// hibernated tabs. Cheap enough to run after every layout action.
  private func reconcileHibernation(_ state: inout State) -> Effect<Action> {
    @Shared(.settingsFile) var settingsFile: SettingsFile
    let enabled = settingsFile.global.terminalHibernationEnabled
    // Tabs that should hold an armed grace timer this pass; anything armed and
    // absent here is cancelled below.
    var keepArmed: Set<TabID> = []
    var allTabs: Set<TabID> = []
    var effects: [Effect<Action>] = []
    for layout in state.layouts {
      let visiblePanes = Set(layout.layout.tree.visibleLeaves())
      for pane in layout.layout.panes {
        let showsContent = Self.paneShowsContent(
          pane,
          in: layout,
          visiblePanes: visiblePanes,
          selectedLayoutID: state.selectedLayoutID
        )
        for tab in pane.tabs {
          allTabs.insert(tab.id)
          let isHidden = Self.isTabHidden(tab, pane: pane, paneShowsContent: showsContent)
          if isHidden {
            state.wakeRequestedTabs.remove(tab.id)
            // Recency keeps the top worktrees' visible tabs live, so a flip back
            // among them never pays a rewake; they never arm.
            if Self.recencyRetains(
              tab, pane: pane, in: layout,
              visiblePanes: visiblePanes, recentLayoutIDs: state.recentLayoutIDs
            ) {
              continue
            }
            // Only a hidden, enabled tab with a live renderer keeps a timer; a
            // hibernated tab (renderer gone) has nothing left to tear down, so
            // it falls out of `keepArmed` and any stale timer is cancelled.
            guard enabled, contentRuntime.content(for: tab.content.id)?.renderer != nil else { continue }
            keepArmed.insert(tab.id)
            if !state.hibernationArmedTabs.contains(tab.id) {
              state.hibernationArmedTabs.insert(tab.id)
              effects.append(armGraceTimer(worktreeID: layout.id, tabID: tab.id))
            }
          } else if contentNeedsWake(tab) {
            // The selection landed on a hibernated tab; wake it at its frozen
            // geometry, once per visibility spell so a failed wake can't loop.
            guard !state.wakeRequestedTabs.contains(tab.id) else { continue }
            state.wakeRequestedTabs.insert(tab.id)
            effects.append(.send(.layouts(.element(id: layout.id, action: .wakeTab(id: tab.id)))))
          } else {
            state.wakeRequestedTabs.remove(tab.id)
          }
        }
      }
    }
    // Cancel any armed tab no longer eligible: visible, vanished, recency-covered,
    // renderer gone (hibernated), or the flag flipped off.
    for armed in state.hibernationArmedTabs where !keepArmed.contains(armed) {
      state.hibernationArmedTabs.remove(armed)
      state.hibernationDeferralLogged.remove(armed)
      effects.append(.cancel(id: HibernationTimerID.tab(armed)))
    }
    state.wakeRequestedTabs.formIntersection(allTabs)
    state.hibernationDeferralLogged.formIntersection(allTabs)
    return effects.isEmpty ? .none : .merge(effects)
  }

  /// True when a visible tab's content has no live renderer to show.
  private func contentNeedsWake(_ tab: TabItem) -> Bool {
    guard let content = contentRuntime.content(for: tab.content.id) else { return true }
    return content.renderer == nil
  }

  private func armGraceTimer(worktreeID: LayoutID, tabID: TabID) -> Effect<Action> {
    .run { send in
      try await clock.sleep(for: Self.hibernationGraceWindow)
      await send(.hibernationGraceElapsed(worktreeID: worktreeID, tabID: tabID))
    }
    .cancellable(id: HibernationTimerID.tab(tabID), cancelInFlight: true)
  }

  /// One synchronous turn: re-check hidden and eligible, then hibernate or
  /// re-arm, so a concurrent selection cannot slip a visible tab into
  /// hibernation.
  private func reduceHibernationGraceElapsed(
    _ state: inout State,
    worktreeID: LayoutID,
    tabID: TabID
  ) -> Effect<Action> {
    state.hibernationArmedTabs.remove(tabID)
    @Shared(.settingsFile) var settingsFile: SettingsFile
    // Re-check at fire time so a flip to off mid-window never hibernates.
    guard settingsFile.global.terminalHibernationEnabled else { return .none }
    guard let layout = state.layouts[id: worktreeID],
      let pane = layout.layout.pane(containingTab: tabID),
      let tab = pane.tabs[id: tabID]
    else { return .none }
    let visiblePanes = Set(layout.layout.tree.visibleLeaves())
    guard
      Self.isTabHidden(
        tab,
        pane: pane,
        paneShowsContent: Self.paneShowsContent(
          pane,
          in: layout,
          visiblePanes: visiblePanes,
          selectedLayoutID: state.selectedLayoutID
        )
      ),
      // Recency can cover a tab after its timer armed; the fire-time gate must
      // agree with the arm-time one or a protected tab still hibernates.
      !Self.recencyRetains(
        tab,
        pane: pane,
        in: layout,
        visiblePanes: visiblePanes,
        recentLayoutIDs: state.recentLayoutIDs
      )
    else { return .none }
    guard layout.alert == nil else {
      // A pending close confirmation must keep its target live; re-arm.
      state.hibernationArmedTabs.insert(tabID)
      return armGraceTimer(worktreeID: worktreeID, tabID: tabID)
    }
    let content = contentRuntime.content(for: tab.content.id)
    guard content?.isHibernatable == true else {
      // Nothing left to hibernate (the renderer is already gone, e.g. a
      // concurrent pressure sweep hibernated it after this timer fired): settle
      // instead of re-arming a dead tab into a forever loop.
      guard content?.renderer != nil else {
        state.hibernationDeferralLogged.remove(tabID)
        return .none
      }
      // Still hidden but momentarily ineligible; re-arm so a later
      // eligibility flip still hibernates instead of wedging forever.
      if state.hibernationDeferralLogged.insert(tabID).inserted {
        Self.logger.debug("Hibernation for tab \(tabID.rawValue) deferred: not currently eligible; re-armed.")
      }
      state.hibernationArmedTabs.insert(tabID)
      return armGraceTimer(worktreeID: worktreeID, tabID: tabID)
    }
    state.hibernationDeferralLogged.remove(tabID)
    return .send(.layouts(.element(id: worktreeID, action: .hibernateTab(id: tabID))))
  }

  /// Under pressure the recency budget is the first thing to go: keep only the
  /// selection live and hibernate every hidden hibernatable tab now instead of
  /// waiting out the grace window. Gated on the hibernation Beta flag.
  private func reduceMemoryPressureWarning(_ state: inout State) -> Effect<Action> {
    @Shared(.settingsFile) var settingsFile: SettingsFile
    guard settingsFile.global.terminalHibernationEnabled else { return .none }
    state.recentLayoutIDs = state.selectedLayoutID.map { [$0] } ?? []
    var effects: [Effect<Action>] = []
    for layout in state.layouts {
      // A pending close confirmation keeps its worktree's tabs live; the grace
      // path already exempts it, so the sweep must too.
      guard layout.alert == nil else { continue }
      let visiblePanes = Set(layout.layout.tree.visibleLeaves())
      for pane in layout.layout.panes {
        let showsContent = Self.paneShowsContent(
          pane, in: layout, visiblePanes: visiblePanes, selectedLayoutID: state.selectedLayoutID)
        for tab in pane.tabs where Self.isTabHidden(tab, pane: pane, paneShowsContent: showsContent) {
          guard contentRuntime.content(for: tab.content.id)?.isHibernatable == true else { continue }
          // Cancel the pending grace timer and hibernate through the fire-time
          // action, which re-checks visibility just before teardown so a tab the
          // user selects between this sweep and the hibernate is spared.
          if state.hibernationArmedTabs.remove(tab.id) != nil {
            effects.append(.cancel(id: HibernationTimerID.tab(tab.id)))
          }
          state.hibernationDeferralLogged.remove(tab.id)
          effects.append(.send(.hibernationGraceElapsed(worktreeID: layout.id, tabID: tab.id)))
        }
      }
    }
    return effects.isEmpty ? .none : .merge(effects)
  }
}

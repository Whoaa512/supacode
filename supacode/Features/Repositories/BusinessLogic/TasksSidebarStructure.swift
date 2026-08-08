import Foundation

/// The Tasks tab's cached render plan: IDs, order and sections only.
///
/// Built by the reducer's post-reduce hook and Equatable-diffed before publish,
/// exactly like `SidebarStructure` / `AgentDashboardStructure`. The view renders
/// this value and nothing else — it never reads the task dictionary or a task
/// leaf out of a body — so a per-leaf mutation (agent tick, notification,
/// running script) invalidates only that leaf instead of fanning out across
/// every sibling row.
///
/// Ordering is *static* on purpose (assertion A4). Phase 4 adds `now` and
/// `signals` to the signature, and they buy exactly one thing: a row can move
/// *between sections* — a wake expiring (A24), a raised hand outranking the
/// user's earlier "not now" (A25). Neither ever reorders a section, which is why
/// `activityNeverReordersTheActiveSection` asserts the property directly rather
/// than leaning on a signature that no longer proves it.
///
/// Pure logic — Foundation only, no ComposableArchitecture, no SwiftUI, no
/// ambient clock (A18). `nonisolated` because the target compiles with
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, which would otherwise pin this
/// to the main actor (`TaskActivitySeeder` precedent).
nonisolated struct TasksSidebarStructure: Equatable, Sendable {
  /// One row of the settled tail. Carries the resolved timestamp the row sorts
  /// by so the view *labels* with the same value it was ordered by — A17's
  /// "settled sort key and displayed label use the same resolved timestamp"
  /// cannot drift if the view has no other candidate to reach for.
  ///
  /// `nil` means no usable timestamp was provable: the row still renders (a
  /// malformed timestamp must never hide a task) with no relative-time label.
  nonisolated struct SettledEntry: Equatable, Sendable, Identifiable {
    let id: TaskID
    let settledTimestamp: Date?
  }

  /// One row of the snoozed shelf, carrying the wake instant it sorts by so the
  /// row's countdown and the shelf's ordering read the same value — the settled
  /// tail's rule (A17) applied to snooze.
  nonisolated struct SnoozedEntry: Equatable, Sendable, Identifiable {
    let id: TaskID
    let wakeAt: Date?
  }

  /// The live signals a task's placement can depend on, projected from its leaf.
  ///
  /// Everything here is *classification input only*: a raised hand moves a row
  /// out of the shelf without touching `snoozedUntil` / `snoozedAt`, so the
  /// moment the hand goes down the row returns to the shelf with the wake time
  /// the user originally wrote (A25).
  nonisolated struct Signals: Equatable, Sendable {
    var activity: TaskSettlement.ActivitySnapshot = .idle
    var errorAt: Date?
    var completedTurnAt: Date?
    var notifiedAt: Date?
    /// What the owning worktree row learned about this task's pull request. An
    /// open PR is live review work and blocks the inactivity path; a finished
    /// one is the finished-PR auto-settle's whole trigger (A29).
    var pullRequest: TaskPullRequestState = .none
    /// Newest real activity on the task, which is what the inactivity window
    /// measures. Resolved on the leaf so the structure takes a decision rather
    /// than re-deriving the evidence behind it.
    var lastActivityAt: Date?
    /// When the PR state last changed under a live snooze (A29b).
    var pullRequestChangedAt: Date?
  }

  /// Recent history is the common lookup, so the deep tail stays behind an
  /// explicit "Show more" (t3's `SETTLED_TAIL_INITIAL_COUNT` / `_PAGE_COUNT`).
  static let settledTailInitialCount = 10
  static let settledTailPageCount = 25

  /// Active rows: the pinned block first, then the rest, each newest-created
  /// first with a deterministic ID tie-break. Pinning never introduces a second
  /// sort order, it only splits the section in two.
  var activeTaskIDs: [TaskID] = []
  /// Which of those rows carry a pin, for the glyph. A `Set` because it is a
  /// membership question — `activeTaskIDs` already carries the order, and two
  /// orderings would eventually disagree.
  var pinnedTaskIDs: Set<TaskID> = []
  /// How many tasks are parked in total, for the collapsed shelf header.
  var snoozedTotalCount: Int = 0
  /// Every task carrying a live `snoozedUntil`, regardless of where it ended up
  /// rendering. A raised hand (A25) pulls a parked row back into Active without
  /// touching the record, so placement alone can't answer "is this snoozed" —
  /// and a row whose menu offers "Snooze" while the task is already snoozed
  /// leaves the user no way to take the snooze back.
  var snoozedTaskIDs: Set<TaskID> = []
  /// The snoozed rows the view renders, soonest-wake-first: the shelf reads as a
  /// ramp of what comes back next, not as a second inbox. Empty while the shelf
  /// is collapsed — except the open task, which is still pulled in (A8).
  var visibleSnoozedEntries: [SnoozedEntry] = []
  /// Rows whose snooze has ended (timer expiry or a raised hand) and that the
  /// user has not visited since. Derived, never stored: a relaunch re-derives
  /// the same answer, so no acknowledgement field can drift out of sync with the
  /// visit that cleared it (A24, A28).
  var wokeTaskIDs: Set<TaskID> = []
  /// How many tasks are settled in total. A count, not the entries: the
  /// collapsed shelf header is the only thing that needs the whole-tail number,
  /// and carrying N entries here would double every Equatable diff.
  var settledTotalCount: Int = 0
  /// The settled rows the view actually renders, newest-*ended* first (settled
  /// rows are history and read as "how long ago did this wrap up"): the page
  /// window, plus the open task when it would otherwise be paged or collapsed
  /// away.
  var visibleSettledTail: [SettledEntry] = []
  /// Rows behind "Show more". Zero when everything settled is on screen, and
  /// zero while the shelf is collapsed — there is no "Show more" affordance
  /// then, and the collapsed header reads `settledTotalCount` instead.
  var hiddenSettledCount: Int = 0
  /// Top-down render order of every visible row: active (pinned first), then the
  /// snoozed shelf, then the settled tail. Hotkey slots, keyboard navigation and
  /// forward navigation (A26) all key off this list, so it is contract.
  var visibleTaskIDs: [TaskID] = []

  static let empty = TasksSidebarStructure()

  /// Next page window after a "Show more" tap.
  static func expandedSettledVisibleCount(from current: Int) -> Int {
    current + settledTailPageCount
  }

  /// Deterministic projection of the task collection.
  ///
  /// - Parameters:
  ///   - tasks: every known task record, in any order.
  ///   - now: the reducer's clock sample. Only ever used to expire a wake time;
  ///     nothing about ordering reads it.
  ///   - signals: per-task live signals. A task with no entry reads as idle,
  ///     which is *not* the same as an agent that cannot report (Resolved #1).
  ///   - openTaskID: the currently open/selected task, which is never allowed to
  ///     be hidden (A8).
  ///   - settledVisibleCount: how many settled rows the page window shows.
  ///   - isSettledTailExpanded: when false the tail is collapsed and renders
  ///     nothing — except the open task, which is still pulled in.
  ///   - isSnoozedShelfExpanded: same rule for the snoozed shelf.
  ///   - policy: what the user's settings let the auto-settle paths do. It
  ///     defaults to `.manualOnly` in the one safe direction: a caller that
  ///     forgets to thread it through files nothing away by itself, rather than
  ///     shipping an auto-settle policy nobody wrote.
  static func compute(
    tasks: [TaskRecord],
    now: Date,
    signals: [TaskID: Signals] = [:],
    openTaskID: TaskID? = nil,
    settledVisibleCount: Int,
    isSettledTailExpanded: Bool,
    isSnoozedShelfExpanded: Bool,
    policy: TaskSettlement.Policy = .manualOnly
  ) -> TasksSidebarStructure {
    var pinned: [TaskRecord] = []
    var active: [TaskRecord] = []
    var settled: [TaskRecord] = []
    var snoozed: [SnoozedEntry] = []
    var pinnedTaskIDs: Set<TaskID> = []
    var wokeTaskIDs: Set<TaskID> = []
    var snoozedTaskIDs: Set<TaskID> = []

    for task in tasks {
      let taskSignals = signals[task.id] ?? Signals()
      let input = snoozeInput(for: task, now: now, signals: taskSignals)
      let isSnoozed = TaskSnooze.effectiveSnoozed(input)
      if TaskSnooze.timerIsLive(input) { snoozedTaskIDs.insert(task.id) }
      let isPinned = task.pinnedAt != nil
      if isPinned { pinnedTaskIDs.insert(task.id) }
      if TaskSnooze.isWoke(input, lastVisitedAt: task.lastVisitedAt) {
        wokeTaskIDs.insert(task.id)
      }
      let isSettled = TaskSettlement.effectiveSettled(
        settlementInput(for: task, now: now, signals: taskSignals, policy: policy)
      )
      switch TaskSnooze.placement(isSnoozed: isSnoozed, isPinned: isPinned, isSettled: isSettled) {
      case .snoozed:
        snoozed.append(SnoozedEntry(id: task.id, wakeAt: TaskTimestamps.read(task.snoozedUntil).date))
      case .pinned:
        pinned.append(task)
      case .settled:
        settled.append(task)
      case .active:
        active.append(task)
      }
    }

    let settledTail = settled
      .map { SettledEntry(id: $0.id, settledTimestamp: resolvedSettledTimestamp(for: $0)) }
      .sorted(by: settledOrdersBefore)
    let visibleSettledTail = visibleSettled(
      in: settledTail,
      openTaskID: openTaskID,
      settledVisibleCount: settledVisibleCount,
      isSettledTailExpanded: isSettledTailExpanded
    )
    let snoozedShelf = snoozed.sorted(by: snoozedOrdersBefore)
    let visibleSnoozedEntries = visibleSnoozed(
      in: snoozedShelf,
      openTaskID: openTaskID,
      isSnoozedShelfExpanded: isSnoozedShelfExpanded
    )
    let activeTaskIDs =
      pinned.sorted(by: activeOrdersBefore).map(\.id) + active.sorted(by: activeOrdersBefore).map(\.id)

    return TasksSidebarStructure(
      activeTaskIDs: activeTaskIDs,
      pinnedTaskIDs: pinnedTaskIDs,
      snoozedTotalCount: snoozedShelf.count,
      snoozedTaskIDs: snoozedTaskIDs,
      visibleSnoozedEntries: visibleSnoozedEntries,
      wokeTaskIDs: wokeTaskIDs,
      settledTotalCount: settledTail.count,
      visibleSettledTail: visibleSettledTail,
      hiddenSettledCount: isSettledTailExpanded ? settledTail.count - visibleSettledTail.count : 0,
      visibleTaskIDs: activeTaskIDs + visibleSnoozedEntries.map(\.id) + visibleSettledTail.map(\.id)
    )
  }

  /// The snooze question for one record, assembled in the one place so the
  /// structure, the reducer's wake-boundary arithmetic and the row's countdown
  /// can never ask it three slightly different ways.
  static func snoozeInput(for task: TaskRecord, now: Date, signals: Signals) -> TaskSnooze.Input {
    TaskSnooze.Input(
      now: now,
      snoozedUntil: task.snoozedUntil,
      snoozedAt: task.snoozedAt,
      activity: signals.activity,
      errorAt: signals.errorAt,
      completedTurnAt: signals.completedTurnAt,
      notifiedAt: signals.notifiedAt,
      pullRequestChangedAt: signals.pullRequestChangedAt
    )
  }

  /// The settle question for one record, assembled here for the same reason the
  /// snooze one is: the structure's partition, the row's affordance gating and
  /// the reducer's settle arm must all ask `TaskSettlement` the same way.
  static func settlementInput(
    for task: TaskRecord,
    now: Date,
    signals: Signals,
    policy: TaskSettlement.Policy
  ) -> TaskSettlement.Input {
    TaskSettlement.Input(
      now: now,
      activity: signals.activity,
      settledOverride: task.settledOverride,
      settledAt: task.settledAt,
      pullRequest: signals.pullRequest,
      lastActivityAt: signals.lastActivityAt,
      policy: policy
    )
  }

  /// Settled-ness from the record alone: a stamped `settledAt` (or an explicit
  /// `.settled` override), with an explicit `.active` override winning over a
  /// stale stamp in either direction.
  ///
  /// Deliberately *not* the placement predicate any more — that is
  /// `TaskSettlement.effectiveSettled`, which also reads activity, the PR and
  /// the user's auto-settle settings. What survives here is the record-only
  /// question the ownership rules ask: "did the user put this away", asked
  /// where there is no leaf and no clock to ask the full cascade with
  /// (`isSoleActiveTaskOwner`, `newestActiveTask`, capture candidates). Those
  /// are all "is another task live in this directory" questions, and answering
  /// them from a setting would make a capture route change when a toggle flips.
  ///
  /// The `nil` branch covers the explicit settle arm, which stamps `settledAt`
  /// alone. The seeder no longer relies on it: a stale seed writes the `.settled`
  /// override too, so its intent survives A30's off-switch instead of hinging on
  /// how a bare timestamp is read here.
  static func isSettled(_ task: TaskRecord) -> Bool {
    switch task.settledOverride {
    case .active: return false
    case .settled: return true
    case nil: return task.settledAt != nil
    }
  }

  /// The timestamp a settled row both sorts and labels by: the explicit settle
  /// stamp when there is one, otherwise the last visit, with `createdAt` as the
  /// final net.
  ///
  /// Resolution lives in `TaskTimestamps` so the sort key and the displayed
  /// label cannot drift (A17); this is only the `TaskRecord` adapter.
  ///
  /// `lastVisitedAt` is *not* activity — it is when the user last opened the
  /// task, and it is the only persisted proxy for "when did this stop moving"
  /// until real activity stamps land. Because it is a proxy, the settle arm must
  /// always stamp `settledAt` so a settled row sorts by a real end time.
  static func resolvedSettledTimestamp(for task: TaskRecord) -> Date? {
    TaskTimestamps.resolvedSettledTimestamp(
      settledAt: task.settledAt,
      activityCandidates: [task.lastVisitedAt],
      createdAt: task.createdAt
    )
  }

  /// Newest-created-first; equal creation times fall back to the opaque ID so
  /// two tasks seeded in the same millisecond still have one stable order.
  private static func activeOrdersBefore(_ lhs: TaskRecord, _ rhs: TaskRecord) -> Bool {
    if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
    return lhs.id.rawValue < rhs.id.rawValue
  }

  /// Newest-ended-first. A row with no provable timestamp sorts to the bottom of
  /// the tail rather than disappearing.
  private static func settledOrdersBefore(_ lhs: SettledEntry, _ rhs: SettledEntry) -> Bool {
    let left = lhs.settledTimestamp ?? .distantPast
    let right = rhs.settledTimestamp ?? .distantPast
    if left != right { return left > right }
    return lhs.id.rawValue < rhs.id.rawValue
  }

  /// Soonest-wake-first, with the same opaque-ID tie-break the other two
  /// orderings use. A row whose wake instant is unreadable sorts last rather
  /// than jumping the queue.
  private static func snoozedOrdersBefore(_ lhs: SnoozedEntry, _ rhs: SnoozedEntry) -> Bool {
    let left = lhs.wakeAt ?? .distantFuture
    let right = rhs.wakeAt ?? .distantFuture
    if left != right { return left < right }
    return lhs.id.rawValue < rhs.id.rawValue
  }

  /// A8 applied to snooze: parking the task you are looking at must not make it
  /// vanish out from under you, so a collapsed shelf still renders that one row.
  /// No page window — the shelf is bounded by how much a person is willing to
  /// park, not by history.
  private static func visibleSnoozed(
    in shelf: [SnoozedEntry],
    openTaskID: TaskID?,
    isSnoozedShelfExpanded: Bool
  ) -> [SnoozedEntry] {
    guard !isSnoozedShelfExpanded else { return shelf }
    guard let open = shelf.first(where: { $0.id == openTaskID }) else { return [] }
    return [open]
  }

  /// The open task is never hidden (A8): navigating into a deep settled task
  /// (search, forward navigation, a deep link) pulls its row into the visible
  /// tail so the highlight and the un-settle affordance stay reachable, and a
  /// collapsed shelf still renders that one row.
  private static func visibleSettled(
    in settledTail: [SettledEntry],
    openTaskID: TaskID?,
    settledVisibleCount: Int,
    isSettledTailExpanded: Bool
  ) -> [SettledEntry] {
    guard isSettledTailExpanded else {
      guard let open = settledTail.first(where: { $0.id == openTaskID }) else { return [] }
      return [open]
    }
    guard settledTail.count > settledVisibleCount else { return settledTail }
    var visible = Array(settledTail.prefix(settledVisibleCount))
    if let open = settledTail.dropFirst(settledVisibleCount).first(where: { $0.id == openTaskID }) {
      visible.append(open)
    }
    return visible
  }
}

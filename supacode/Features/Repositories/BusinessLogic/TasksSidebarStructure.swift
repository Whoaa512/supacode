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
/// Ordering is *static* on purpose (assertion A4): the compute function takes
/// records and the open-task selection, and nothing else. Activity is not an
/// input, so no amount of agent or terminal churn can reorder a row — that is
/// true by construction here, not by a runtime check.
///
/// Pure logic — Foundation only, no ComposableArchitecture, no SwiftUI, no
/// `Date()` (A18). `nonisolated` because the target compiles with
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

  /// Recent history is the common lookup, so the deep tail stays behind an
  /// explicit "Show more" (t3's `SETTLED_TAIL_INITIAL_COUNT` / `_PAGE_COUNT`).
  static let settledTailInitialCount = 10
  static let settledTailPageCount = 25

  /// Active rows, newest-created-first with a deterministic ID tie-break.
  var activeTaskIDs: [TaskID] = []
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
  /// Top-down render order of every visible row (active, then visible settled).
  /// Hotkey slots and keyboard navigation key off this in later phases.
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
  ///   - openTaskID: the currently open/selected task, which is never allowed to
  ///     be hidden (A8).
  ///   - settledVisibleCount: how many settled rows the page window shows.
  ///   - isSettledTailExpanded: when false the shelf is collapsed and renders
  ///     nothing — except the open task, which is still pulled in.
  static func compute(
    tasks: [TaskRecord],
    openTaskID: TaskID? = nil,
    settledVisibleCount: Int,
    isSettledTailExpanded: Bool
  ) -> TasksSidebarStructure {
    var active: [TaskRecord] = []
    var settled: [TaskRecord] = []
    for task in tasks {
      if isSettled(task) {
        settled.append(task)
      } else {
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
    let activeTaskIDs = active.sorted(by: activeOrdersBefore).map(\.id)

    return TasksSidebarStructure(
      activeTaskIDs: activeTaskIDs,
      settledTotalCount: settledTail.count,
      visibleSettledTail: visibleSettledTail,
      hiddenSettledCount: isSettledTailExpanded ? settledTail.count - visibleSettledTail.count : 0,
      visibleTaskIDs: activeTaskIDs + visibleSettledTail.map(\.id)
    )
  }

  /// Phase-1 lifecycle split: settling is explicit only, so a stamped
  /// `settledAt` (or an explicit `.settled` override) is the whole rule, and an
  /// explicit `.active` override wins over a stale stamp in either direction.
  /// Phase 2's `effectiveSettled` cascade (inactivity window, PR state, activity
  /// blockers) replaces this predicate; the structure keeps taking a partition
  /// decision, not the evidence behind it.
  ///
  /// Fields a later build writes but Phase 1 doesn't read — a `pinnedAt`, a
  /// `snoozedUntil` — have no effect here: such a task renders as a plain active
  /// row, which is the safe degrade (visible and unstyled beats hidden).
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
  /// `lastVisitedAt` is *not* activity — it is when the user last opened the
  /// task, and it is Phase 1's only persisted proxy for "when did this stop
  /// moving". Phase 2's `TaskTimestamps` replaces it with real activity stamps
  /// and becomes the single resolver shared by sort key and label; the shape
  /// stays the same. Because the fallbacks are proxies, the settle arm must
  /// always stamp `settledAt` so a settled row sorts by a real end time.
  static func resolvedSettledTimestamp(for task: TaskRecord) -> Date? {
    if let settledAt = validTimestamp(task.settledAt) { return settledAt }
    if let lastVisitedAt = validTimestamp(task.lastVisitedAt) { return lastVisitedAt }
    return validTimestamp(task.createdAt)
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

  /// Guards against a timestamp that survived decoding but can't be reasoned
  /// about (a non-finite interval). Such a value must never sort a row into a
  /// surprising position or hide it.
  private static func validTimestamp(_ date: Date?) -> Date? {
    guard let date, date.timeIntervalSince1970.isFinite else { return nil }
    return date
  }
}

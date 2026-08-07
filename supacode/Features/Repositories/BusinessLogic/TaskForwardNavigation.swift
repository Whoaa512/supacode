import Foundation

/// Where the selection goes when the open task leaves the active list (A18, A26).
///
/// Everything here is a *plan*: a value computed from an ordered snapshot taken
/// before the mutation. The reducer applies it only if the open task is still the
/// one the plan was made for.
///
/// `nonisolated` on purpose: the target compiles with
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, which would otherwise pin this
/// pure logic to the main actor.
nonisolated enum TaskForwardNavigation {
  nonisolated struct Candidate: Equatable, Sendable {
    var id: TaskID
    var isSettled: Bool = false
    var isSnoozed: Bool = false
  }

  /// Scans forward from the row after `currentTaskID`, wrapping once, and answers
  /// the first eligible row.
  ///
  /// `coParkingTaskIDs` is the batch case: rows being parked in the same operation
  /// are leaving too, so landing on one would put the user on a row that vanishes
  /// a tick later. They are still `isSettled: false` in the pre-mutation snapshot,
  /// which is exactly why the set is a separate input and not a flag.
  ///
  /// `nil` means stay put. An unknown or absent current row scans from the top
  /// instead of refusing — the user's intent was "move me forward", and there is
  /// still somewhere to go. Order in, order out: this never re-sorts, or the user
  /// would land somewhere other than the row below the one they were on.
  static func planForwardNavigation(
    orderedTasks: [Candidate],
    currentTaskID: TaskID?,
    coParkingTaskIDs: Set<TaskID> = []
  ) -> TaskID? {
    guard !orderedTasks.isEmpty else { return nil }

    let currentIndex = currentTaskID.flatMap { id in orderedTasks.firstIndex { $0.id == id } }
    let start = currentIndex.map { $0 + 1 } ?? 0

    for offset in 0..<orderedTasks.count {
      let candidate = orderedTasks[(start + offset) % orderedTasks.count]
      guard candidate.id != currentTaskID else { continue }
      guard !candidate.isSettled, !candidate.isSnoozed else { continue }
      guard !coParkingTaskIDs.contains(candidate.id) else { continue }
      return candidate.id
    }
    return nil
  }
}

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
  /// `nil` means stay put. An unknown or absent current row scans from the top
  /// instead of refusing — the user's intent was "move me forward", and there is
  /// still somewhere to go. Order in, order out: this never re-sorts, or the user
  /// would land somewhere other than the row below the one they were on.
  ///
  /// There is deliberately no batch/co-parking exclusion set. Every caller parks
  /// exactly one task per action, so the pre-mutation snapshot already tells the
  /// truth about which rows are leaving; a set that no caller can populate is a
  /// second, untested code path pretending to be a feature.
  static func planForwardNavigation(
    orderedTasks: [Candidate],
    currentTaskID: TaskID?
  ) -> TaskID? {
    guard !orderedTasks.isEmpty else { return nil }

    let currentIndex = currentTaskID.flatMap { id in orderedTasks.firstIndex { $0.id == id } }
    let start = currentIndex.map { $0 + 1 } ?? 0

    for offset in 0..<orderedTasks.count {
      let candidate = orderedTasks[(start + offset) % orderedTasks.count]
      guard candidate.id != currentTaskID else { continue }
      guard !candidate.isSettled, !candidate.isSnoozed else { continue }
      return candidate.id
    }
    return nil
  }
}

import Foundation

/// The one status a task row shows (A18, A27).
///
/// Pure logic — Foundation only, and deliberately without a `now`: every input is
/// already a recorded fact, so the status is a function of the record alone and
/// cannot drift between two renders of the same snapshot.
///
/// `nonisolated` on purpose: the target compiles with
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, which would otherwise pin this
/// pure logic to the main actor.
nonisolated enum TaskStatusModel {
  /// The whole vocabulary. A sixth state would break the "exactly one state per
  /// task" contract the status strip and the jump-to-next-needs-me predicate both
  /// depend on. Declaration order is the ladder order.
  nonisolated enum Status: Hashable, Sendable, CaseIterable {
    case approval
    case input
    case working
    case failed
    case ready

    /// Lives on the status rather than being re-derived at each call site, so the
    /// hint pill and the jump target can never disagree (A33).
    var needsHuman: Bool {
      switch self {
      case .approval, .input, .failed: true
      case .working, .ready: false
      }
    }
  }

  nonisolated struct Input: Equatable, Sendable {
    var activity: TaskSettlement.ActivitySnapshot = .idle
    var errorAt: Date?
    var lastActivityAt: Date?
  }

  /// Ladder: approval → input → working → failed → ready. The order is the
  /// contract, not an implementation detail — a task blocking on a human outranks
  /// one that is merely busy, and both outrank a standing error, because a re-run
  /// after a crash is already doing something about that error.
  ///
  /// `isAwaitingApproval == nil` means THIS AGENT CANNOT REPORT IT (Resolved #1),
  /// so it reads exactly like an explicit `false`; treating it as pending would
  /// put a fake gate badge on every non-emitting agent's row.
  static func resolve(_ input: Input) -> Status {
    if input.activity.isAwaitingApproval == true { return .approval }
    if input.activity.isAwaitingInput { return .input }
    if input.activity.isWorking { return .working }
    return failureReading(input)
  }

  /// An error counts only while it is the newest thing that happened: activity
  /// after it means the agent kept going, so the row is `ready` rather than
  /// permanently red. Ties go to the error — the two stamps come from different
  /// second-granularity writers, and the failure is the more actionable reading of
  /// the same moment.
  ///
  /// A malformed *error* stamp shows no failure nobody can date (A17); a malformed
  /// *activity* stamp must not suppress a real error, or a garbage write would
  /// silently hide failures.
  private static func failureReading(_ input: Input) -> Status {
    guard let errorAt = TaskTimestamps.read(input.errorAt).date else { return .ready }
    guard let lastActivityAt = TaskTimestamps.read(input.lastActivityAt).date else { return .failed }
    return errorAt >= lastActivityAt ? .failed : .ready
  }
}

import Foundation

/// The one status a task row shows (A18, A27).
///
/// Pure logic — Foundation only, and deliberately without a `now` or any
/// timestamp: the status is a function of the current presence snapshot alone,
/// so it cannot drift between two renders of the same snapshot.
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

    /// The status half of A33's jump predicate, which is
    /// `needsHuman || unread-done || woke`. Lives on the status rather than
    /// being re-derived at each call site, so the hint pill and the jump target
    /// can never disagree about the part this type owns; the other two
    /// disjuncts are not status readings and are combined by the caller.
    var needsHuman: Bool {
      switch self {
      case .approval, .input, .failed: true
      case .working, .ready: false
      }
    }
  }

  /// One field, because the status is one reading of the presence snapshot.
  /// There is no timestamp input: `failed` is whatever the agent currently
  /// reports, exactly like the other four.
  nonisolated struct Input: Equatable, Sendable {
    var activity: TaskSettlement.ActivitySnapshot = .idle
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
    if input.activity.isErrored { return .failed }
    return .ready
  }
}

import Foundation

/// What we know about a task's pull request.
///
/// Tri-partite on purpose: "no PR", "we could not ask", and a real state have
/// different settle consequences, so `loading`/`failed`/`unknown` are never
/// collapsed into `none` (A29).
///
/// Top-level rather than nested in `TaskSettlement`: settlement is only the
/// first consumer — the row badge, the PR fetch arm and the filter chips all
/// name this state too, and none of them are settlement concerns.
///
/// `nonisolated` on purpose: the target compiles with
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, which would otherwise pin this
/// pure logic to the main actor.
nonisolated enum TaskPullRequestState: Equatable, Sendable {
  case none, loading, failed, unknown, open, merged, closed

  var isFinished: Bool { self == .merged || self == .closed }

  /// GitHub told us what this PR is. `loading` / `failed` / `unknown` / `none`
  /// are all readings of our own pipeline rather than of the PR, so a
  /// *transition* between two of them is news about us, not about the work —
  /// which is why the A29b raised-hand trigger only fires known → known.
  var isKnown: Bool { self == .open || self == .merged || self == .closed }
}

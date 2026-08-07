import Foundation

/// Decides whether a task belongs in the settled tail, and whether the settle /
/// snooze affordances are offered at all (A14, A15, A18b).
///
/// Pure logic — Foundation only, `now` injected, no ambient clock (A18) — so the
/// full precedence matrix is testable without a repo, a socket, or a reducer.
///
/// `nonisolated` on purpose: the target compiles with
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, which would otherwise pin this
/// pure logic to the main actor.
nonisolated enum TaskSettlement {
  /// What the agent signals say right now.
  nonisolated struct ActivitySnapshot: Equatable, Sendable {
    /// `AgentPresenceFeature.Activity.busy || .compacting`: compaction happens
    /// inside a live turn, so it blocks exactly like busy.
    var isWorking: Bool = false
    var isAwaitingInput: Bool = false
    /// `Bool?` because the hook wire protocol only grows an approval
    /// discriminator in this phase: `nil` means THIS AGENT CANNOT REPORT IT,
    /// never "no approval pending" (Resolved #1). Reading `nil` as pending would
    /// pin every non-emitting agent's task permanently active.
    var isAwaitingApproval: Bool?
    /// `AgentPresenceFeature.Activity.error` — the live failure signal, and the
    /// only one there is. A `failed` reading is a *state* the presence layer
    /// reports, not something derived from an error timestamp: no writer in the
    /// app records one.
    var isErrored: Bool = false

    static let idle = ActivitySnapshot()
  }

  nonisolated struct Input: Equatable, Sendable {
    var now: Date
    var activity: ActivitySnapshot = .idle
    var settledOverride: TaskRecord.SettledOverride?
    var pullRequest: TaskPullRequestState = .none
    var lastActivityAt: Date?
    /// `nil` disables the inactivity path entirely.
    var inactivityWindow: TimeInterval?
    var isAutoSettleEnabled: Bool = true
    var settlesOnFinishedPullRequest: Bool = true
  }

  /// A merged/closed PR settles its task only once the task has been idle this
  /// long. The merge signal never clears, so without the guard a follow-up
  /// message would un-settle the row only until its turn ended, then snap it
  /// straight back into the tail.
  static let finishedPullRequestIdleWindow: TimeInterval = 60 * 60

  /// Cascade: activity blockers → explicit override → finished-PR auto-settle →
  /// inactivity auto-settle. The global switch kills only the two auto paths;
  /// the user's explicit intent is never overridden by a setting.
  static func effectiveSettled(_ input: Input) -> Bool {
    guard canSettle(input) else { return false }
    if let settledOverride = input.settledOverride { return settledOverride == .settled }
    guard input.isAutoSettleEnabled else { return false }
    // A malformed `now` makes every age comparison meaningless, so no auto path
    // may fire off it.
    guard TaskTimestamps.read(input.now).date != nil else { return false }
    return settlesOnFinishedPullRequest(input) || settlesOnInactivity(input)
  }

  /// The same blocker list the cascade checks first: anything that cannot be
  /// classified settled must not be offered as a settle target either, so the
  /// affordance is disabled rather than invoked and failed. An open PR is a
  /// display signal, not a blocker — settling review-pending work is intentional.
  static func canSettle(_ input: Input) -> Bool {
    let activity = input.activity
    return !activity.isWorking && !activity.isAwaitingInput && activity.isAwaitingApproval != true
  }

  // Phase 4 open question (critic 2a-9): a task auto-settled by inactivity also
  // reads as "already settled" here, so snooze is refused for a row the user may
  // still want to park before it re-activates. Decide whether snooze should be
  // offered for auto-settled (as opposed to explicitly settled) rows.
  //
  /// Snoozing something that is asking you a question is a no-op affordance (the
  /// raised-hand rule resurfaces it immediately), and an already-settled row has
  /// nothing to hide from. Working *is* snoozable — parking a long-running agent
  /// until it needs you is the point.
  static func canSnooze(_ input: Input) -> Bool {
    let activity = input.activity
    guard !activity.isAwaitingInput, activity.isAwaitingApproval != true else { return false }
    return !effectiveSettled(input)
  }

  /// Malformed refuses where missing settles: a task that never recorded
  /// activity is idle by definition, but an unreadable stamp gives the user no
  /// defensible reason the row moved (A17).
  private static func settlesOnFinishedPullRequest(_ input: Input) -> Bool {
    guard input.settlesOnFinishedPullRequest, input.pullRequest.isFinished else { return false }
    switch TaskTimestamps.read(input.lastActivityAt) {
    case .malformed:
      return false
    case .missing:
      return true
    case .valid(let lastActivityAt):
      return TaskTimestamps.isStrictlyOlder(
        lastActivityAt,
        than: input.now.addingTimeInterval(-finishedPullRequestIdleWindow)
      )
    }
  }

  /// Absent activity is not evidence of staleness, so this path refuses it —
  /// `isStrictlyOlder` already answers `false` for missing and malformed alike.
  private static func settlesOnInactivity(_ input: Input) -> Bool {
    guard input.pullRequest != .open, let window = input.inactivityWindow else { return false }
    return TaskTimestamps.isStrictlyOlder(
      input.lastActivityAt,
      than: input.now.addingTimeInterval(-window)
    )
  }
}

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

  /// What the user's settings say the auto paths may do, as one value the
  /// reducer threads through instead of three booleans every call site
  /// re-derives from app storage (A15, A30).
  nonisolated struct Policy: Equatable, Sendable {
    /// `nil` disables the inactivity path entirely.
    var inactivityWindow: TimeInterval?
    var isAutoSettleEnabled: Bool
    var settlesOnFinishedPullRequest: Bool

    /// Every auto path off: nothing settles unless the user said so. A30's
    /// off-switch, and the default the pure tests reason against.
    static let manualOnly = Policy(
      inactivityWindow: nil,
      isAutoSettleEnabled: false,
      settlesOnFinishedPullRequest: false
    )
  }

  nonisolated struct Input: Equatable, Sendable {
    var now: Date
    var activity: ActivitySnapshot = .idle
    var settledOverride: TaskRecord.SettledOverride?
    /// When the user (or a settle the user asked for) stamped this task done.
    /// The settle arm writes it *without* a `.settled` override, so reading it
    /// as anything less than explicit intent would let A30's off-switch
    /// silently un-settle every row the user settled by hand.
    var settledAt: Date?
    var pullRequest: TaskPullRequestState = .none
    var lastActivityAt: Date?
    /// What the user's settings let the auto paths do, carried as the one value
    /// the reducer already assembles rather than unpacked into three fields
    /// every call site has to re-spread (and can re-spread wrongly).
    ///
    /// Defaults to `.manualOnly`, which is the safe direction: an input built
    /// without a policy settles nothing on its own, instead of quietly
    /// inheriting an auto path nobody asked for.
    var policy: Policy = .manualOnly
  }

  /// A merged/closed PR settles its task only once the task has been idle this
  /// long. The merge signal never clears, so without the guard a follow-up
  /// message would un-settle the row only until its turn ended, then snap it
  /// straight back into the tail.
  static let finishedPullRequestIdleWindow: TimeInterval = 60 * 60

  /// Cascade: activity blockers → explicit override → explicit settle stamp →
  /// finished-PR auto-settle → inactivity auto-settle. The global switch kills
  /// only the two auto paths; the user's explicit intent is never overridden by
  /// a setting.
  static func effectiveSettled(_ input: Input) -> Bool {
    guard canSettle(input) else { return false }
    if let settledOverride = input.settledOverride { return settledOverride == .settled }
    if TaskTimestamps.read(input.settledAt).date != nil { return true }
    guard input.policy.isAutoSettleEnabled else { return false }
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
    canSettle(input.activity)
  }

  /// Activity-only spelling, for the callers that have a projection but no
  /// cascade input to build — a sidebar row gating its context menu reads the
  /// leaf and nothing else, and handing it a fabricated `now` just to ask an
  /// activity question would be a lie the compiler can't catch.
  static func canSettle(_ activity: ActivitySnapshot) -> Bool {
    !activity.isWorking && !activity.isAwaitingInput && activity.isAwaitingApproval != true
  }

  /// Snoozing something that is asking you a question is a no-op affordance: the
  /// raised-hand rule resurfaces it immediately, so the menu item must be
  /// disabled rather than lie. Working *is* snoozable — parking a long-running
  /// agent until it needs you is the point.
  ///
  /// Settled-ness is deliberately *not* read. A task the inactivity window
  /// parked reads as settled, and that is exactly the row a user most wants to
  /// say "later, and stay quiet" about; A16 also puts snooze above settled in
  /// placement, so settled-ness cannot be a reason to refuse. The reducer's
  /// snooze arm un-settles the record it parks, which is what keeps this honest.
  static func canSnooze(_ input: Input) -> Bool {
    canSnooze(input.activity)
  }

  static func canSnooze(_ activity: ActivitySnapshot) -> Bool {
    !activity.isAwaitingInput && activity.isAwaitingApproval != true
  }

  /// Malformed refuses where missing settles: a task that never recorded
  /// activity is idle by definition, but an unreadable stamp gives the user no
  /// defensible reason the row moved (A17).
  private static func settlesOnFinishedPullRequest(_ input: Input) -> Bool {
    guard input.policy.settlesOnFinishedPullRequest, input.pullRequest.isFinished else {
      return false
    }
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
    guard input.pullRequest != .open, let window = input.policy.inactivityWindow else {
      return false
    }
    return TaskTimestamps.isStrictlyOlder(
      input.lastActivityAt,
      than: input.now.addingTimeInterval(-window)
    )
  }
}

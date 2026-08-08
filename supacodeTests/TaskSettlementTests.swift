import Foundation
import Testing

@testable import supacode

/// Table tests for `TaskSettlement` (plan assertions A14 / A15 / A17 / A18 /
/// A18b). The cascade, the signal mapping, and the rationale for every
/// deliberate non-port live in `TaskSettlement.swift` itself — this file
/// asserts the behaviour, it does not re-document the design.
///
/// The one thing only a test can hold: t3's `hasQueuedTurnStart` is absent by
/// design, so there is no queued-turn input and no test for one. The grep
/// assertion at the bottom is what keeps it absent.
struct TaskSettlementTests {
  // MARK: - Fixtures

  private static let now = Date(timeIntervalSince1970: 1_700_000_000)
  private static let inactivityWindow: TimeInterval = 3 * 24 * 60 * 60
  private static let hour: TimeInterval = 60 * 60
  private static let malformedDate = Date(timeIntervalSince1970: .nan)

  /// Warm: inside BOTH the 1h finished-PR idle window and the 3d inactivity
  /// window, so no auto path may fire.
  private static let freshActivity = now.addingTimeInterval(-30 * 60)
  /// Cold: past both windows.
  private static let staleActivity = now.addingTimeInterval(-5 * 24 * 60 * 60)

  private enum ActivityAge: String, Sendable, CaseIterable {
    case fresh
    case stale
    case missing
    case malformed

    var date: Date? {
      switch self {
      case .fresh: TaskSettlementTests.freshActivity
      case .stale: TaskSettlementTests.staleActivity
      case .missing: nil
      case .malformed: TaskSettlementTests.malformedDate
      }
    }
  }

  private static func input(
    now: Date = TaskSettlementTests.now,
    activity: TaskSettlement.ActivitySnapshot = .idle,
    settledOverride: TaskRecord.SettledOverride? = nil,
    settledAt: Date? = nil,
    pullRequest: TaskPullRequestState = .none,
    lastActivityAt: Date? = nil,
    inactivityWindow: TimeInterval? = TaskSettlementTests.inactivityWindow,
    isAutoSettleEnabled: Bool = true,
    settlesOnFinishedPullRequest: Bool = true
  ) -> TaskSettlement.Input {
    TaskSettlement.Input(
      now: now,
      activity: activity,
      settledOverride: settledOverride,
      settledAt: settledAt,
      pullRequest: pullRequest,
      lastActivityAt: lastActivityAt,
      inactivityWindow: inactivityWindow,
      isAutoSettleEnabled: isAutoSettleEnabled,
      settlesOnFinishedPullRequest: settlesOnFinishedPullRequest
    )
  }

  // MARK: - A14: the full precedence matrix

  /// One row of the combinatorial truth table. `expected` is computed from an
  /// INDEPENDENT restatement of the rule (below), not from the implementation,
  /// so a cascade reordered in the source fails here instead of agreeing with
  /// itself. Ported from t3's `effectiveSettled` truth table.
  struct PrecedenceCase: Sendable, CustomStringConvertible {
    let settledOverride: TaskRecord.SettledOverride?
    let pullRequest: TaskPullRequestState
    let age: String
    let activityAt: Date?
    let isWorking: Bool
    let isAwaitingInput: Bool
    let isAwaitingApproval: Bool?
    let expected: Bool

    var description: String {
      let override = settledOverride.map(\.rawValue) ?? "none"
      let approval = isAwaitingApproval.map(String.init) ?? "unsupported"
      return "override=\(override) pr=\(pullRequest) activity=\(age) "
        + "working=\(isWorking) input=\(isAwaitingInput) approval=\(approval)"
    }
  }

  static let precedenceTable: [PrecedenceCase] = {
    let overrides: [TaskRecord.SettledOverride?] = [nil, .settled, .active]
    let pullRequests: [TaskPullRequestState] = [.none, .open, .merged, .closed]
    let workingCases = [false, true]
    let inputCases = [false, true]
    // `false` (agent reports no approval) and `nil` (agent cannot report) must
    // behave identically here: neither is a pending approval. Only `true`
    // blocks. `true` is covered by the dedicated blocker tests plus this axis.
    let approvalCases: [Bool?] = [nil, false, true]

    return overrides.flatMap { settledOverride in
      pullRequests.flatMap { pullRequest in
        ActivityAge.allCases.flatMap { age in
          workingCases.flatMap { isWorking in
            inputCases.flatMap { isAwaitingInput in
              approvalCases.map { isAwaitingApproval -> PrecedenceCase in
                let blocked = isWorking || isAwaitingInput || isAwaitingApproval == true
                // A finished PR settles an idle task. A MISSING activity stamp
                // counts as idle (nothing says it is warm); a MALFORMED one
                // does not — an unreadable stamp must never trigger a surprise
                // auto-settle (A17). This is a deliberate divergence from t3,
                // which cannot tell the two apart.
                let finishedPullRequest =
                  pullRequest == .merged || pullRequest == .closed
                let autoPullRequest =
                  finishedPullRequest && (age == .stale || age == .missing)
                // An open PR blocks the inactivity path only; it never blocks
                // an explicit settle (A15).
                let autoInactivity = pullRequest != .open && age == .stale
                let expected =
                  !blocked
                  && (settledOverride == .settled
                    || (settledOverride == nil && (autoPullRequest || autoInactivity)))

                return PrecedenceCase(
                  settledOverride: settledOverride,
                  pullRequest: pullRequest,
                  age: age.rawValue,
                  activityAt: age.date,
                  isWorking: isWorking,
                  isAwaitingInput: isAwaitingInput,
                  isAwaitingApproval: isAwaitingApproval,
                  expected: expected
                )
              }
            }
          }
        }
      }
    }
  }()

  @Test(arguments: TaskSettlementTests.precedenceTable)
  func effectiveSettledFollowsThePrecedenceCascade(_ testCase: PrecedenceCase) {
    let resolved = Self.effectiveSettled(
      Self.input(
        activity: TaskSettlement.ActivitySnapshot(
          isWorking: testCase.isWorking,
          isAwaitingInput: testCase.isAwaitingInput,
          isAwaitingApproval: testCase.isAwaitingApproval
        ),
        settledOverride: testCase.settledOverride,
        pullRequest: testCase.pullRequest,
        lastActivityAt: testCase.activityAt
      )
    )
    #expect(resolved == testCase.expected, "\(testCase)")
  }

  private static func effectiveSettled(_ input: TaskSettlement.Input) -> Bool {
    TaskSettlement.effectiveSettled(input)
  }

  // MARK: - Activity blockers beat everything (A14)

  @Test func blockersOverrideAnExplicitSettle() {
    let blockers: [TaskSettlement.ActivitySnapshot] = [
      TaskSettlement.ActivitySnapshot(isWorking: true),
      TaskSettlement.ActivitySnapshot(isAwaitingInput: true),
      TaskSettlement.ActivitySnapshot(isAwaitingApproval: true),
    ]
    for activity in blockers {
      #expect(
        Self.effectiveSettled(
          Self.input(
            activity: activity,
            settledOverride: .settled,
            pullRequest: .merged,
            lastActivityAt: Self.staleActivity
          )
        ) == false
      )
    }
  }

  /// An agent that cannot report approvals reports `nil`, and `nil` must never
  /// be read as a pending approval — that would pin every non-emitting agent's
  /// task permanently active.
  @Test func unsupportedApprovalSignalDoesNotBlock() {
    let unsupported = TaskSettlement.ActivitySnapshot(isAwaitingApproval: nil)
    let reportedFalse = TaskSettlement.ActivitySnapshot(isAwaitingApproval: false)
    #expect(
      Self.effectiveSettled(Self.input(activity: unsupported, settledOverride: .settled)) == true
    )
    #expect(
      Self.effectiveSettled(Self.input(activity: reportedFalse, settledOverride: .settled)) == true
    )
  }

  /// t3 maps `running`/`starting` sessions to a blocker; supacode's equivalent
  /// is `Activity.busy || .compacting`, both folded into `isWorking`.
  /// Compaction happens inside a live turn, so it must block exactly like busy.
  @Test func workingCoversBothBusyAndCompacting() {
    let working = TaskSettlement.ActivitySnapshot(isWorking: true)
    #expect(Self.effectiveSettled(Self.input(activity: working)) == false)
    #expect(Self.canSettle(Self.input(activity: working)) == false)
  }

  // MARK: - A15: tri-state override

  @Test func explicitSettleWinsOverAWarmOpenPullRequest() {
    #expect(
      Self.effectiveSettled(
        Self.input(
          settledOverride: .settled,
          pullRequest: .open,
          lastActivityAt: Self.freshActivity
        )
      ) == true
    )
  }

  @Test func explicitActivePinSuppressesBothAutoPaths() {
    #expect(
      Self.effectiveSettled(
        Self.input(
          settledOverride: .active,
          pullRequest: .merged,
          lastActivityAt: Self.staleActivity
        )
      ) == false
    )
  }

  @Test func openPullRequestBlocksInactivityAutoSettle() {
    #expect(
      Self.effectiveSettled(
        Self.input(pullRequest: .open, lastActivityAt: Self.staleActivity)
      ) == false
    )
    #expect(
      Self.effectiveSettled(
        Self.input(pullRequest: .none, lastActivityAt: Self.staleActivity)
      ) == true
    )
  }

  /// "No PR", "still loading", "the query failed", and "state we don't
  /// recognize" are four different absences of knowledge — none of them is an
  /// open PR, so none of them blocks the inactivity path, and none of them is
  /// a finished PR either, so none of them settles a warm task.
  @Test(
    arguments: [
      TaskPullRequestState.none,
      .loading,
      .failed,
      .unknown,
    ]
  )
  func unknownPullRequestStatesNeitherBlockNorSettle(
    _ state: TaskPullRequestState
  ) {
    #expect(
      Self.effectiveSettled(Self.input(pullRequest: state, lastActivityAt: Self.staleActivity))
        == true
    )
    #expect(
      Self.effectiveSettled(Self.input(pullRequest: state, lastActivityAt: Self.freshActivity))
        == false
    )
  }

  @Test(arguments: [TaskPullRequestState.merged, .closed])
  func finishedPullRequestsAutoSettleAnIdleTask(_ state: TaskPullRequestState) {
    #expect(
      Self.effectiveSettled(
        Self.input(
          pullRequest: state,
          lastActivityAt: Self.staleActivity,
          inactivityWindow: nil
        )
      ) == true
    )
  }

  /// t3's idle guard, boundary-exact: activity exactly one hour old is still
  /// warm; a millisecond older settles.
  @Test(arguments: [TaskPullRequestState.merged, .closed])
  func finishedPullRequestRespectsTheIdleWindowBoundary(
    _ state: TaskPullRequestState
  ) {
    #expect(TaskSettlement.finishedPullRequestIdleWindow == Self.hour)

    let justActive = Self.now.addingTimeInterval(-30 * 60)
    let boundary = Self.now.addingTimeInterval(-Self.hour)
    let idle = Self.now.addingTimeInterval(-Self.hour - 0.001)

    for (activity, expected) in [(justActive, false), (boundary, false), (idle, true)] {
      #expect(
        Self.effectiveSettled(
          Self.input(
            pullRequest: state,
            lastActivityAt: activity,
            inactivityWindow: nil
          )
        ) == expected
      )
    }
  }

  /// Same task, advancing clock: active while the follow-up burst is warm,
  /// settled again once it cools. The merge signal is permanent, the warmth is
  /// not.
  @Test func mergedPullRequestReSettlesOnceTheBurstGoesIdle() {
    let activityAt = Self.now.addingTimeInterval(-30 * 60)
    #expect(
      Self.effectiveSettled(
        Self.input(pullRequest: .merged, lastActivityAt: activityAt, inactivityWindow: nil)
      ) == false
    )
    #expect(
      Self.effectiveSettled(
        Self.input(
          now: Self.now.addingTimeInterval(30 * 60 + 0.001),
          pullRequest: .merged,
          lastActivityAt: activityAt,
          inactivityWindow: nil
        )
      ) == true
    )
  }

  /// A task that has never recorded activity is idle by definition, so the
  /// finished-PR signal settles it. Contrast with the inactivity path below,
  /// which refuses to settle on absent evidence.
  @Test func finishedPullRequestSettlesATaskWithNoRecordedActivity() {
    #expect(
      Self.effectiveSettled(
        Self.input(pullRequest: .merged, lastActivityAt: nil, inactivityWindow: nil)
      ) == true
    )
  }

  @Test func finishedPullRequestToggleDisablesOnlyThatPath() {
    // Toggle off: the merged PR alone no longer settles a warm task…
    #expect(
      Self.effectiveSettled(
        Self.input(
          pullRequest: .merged,
          lastActivityAt: Self.freshActivity,
          settlesOnFinishedPullRequest: false
        )
      ) == false
    )
    // …and a stale one still settles, but through the inactivity path.
    #expect(
      Self.effectiveSettled(
        Self.input(
          pullRequest: .merged,
          lastActivityAt: Self.staleActivity,
          settlesOnFinishedPullRequest: false
        )
      ) == true
    )
  }

  // MARK: - Inactivity window

  @Test func inactivityBoundaryIsStrict() {
    let boundary = Self.now.addingTimeInterval(-Self.inactivityWindow)
    let past = Self.now.addingTimeInterval(-Self.inactivityWindow - 0.001)
    #expect(Self.effectiveSettled(Self.input(lastActivityAt: boundary)) == false)
    #expect(Self.effectiveSettled(Self.input(lastActivityAt: past)) == true)
  }

  @Test func nilInactivityWindowDisablesTheInactivityPath() {
    #expect(
      Self.effectiveSettled(
        Self.input(lastActivityAt: Self.staleActivity, inactivityWindow: nil)
      ) == false
    )
  }

  /// Absent activity is not evidence of staleness: with no PR signal there is
  /// nothing to conclude, so the task stays active rather than quietly
  /// disappearing into the tail.
  @Test func missingActivityNeverAutoSettlesOnInactivityAlone() {
    #expect(Self.effectiveSettled(Self.input(lastActivityAt: nil)) == false)
  }

  // MARK: - A17: malformed timestamps never surprise-settle

  @Test(
    arguments: [
      Date(timeIntervalSince1970: .nan),
      Date(timeIntervalSince1970: .infinity),
      Date(timeIntervalSince1970: -.infinity),
    ]
  )
  func malformedActivityBlocksEveryAutoPath(_ activityAt: Date) {
    // Inactivity path: a `-infinity` stamp is numerically "older than
    // everything" and would settle the task on garbage. It must not.
    #expect(Self.effectiveSettled(Self.input(lastActivityAt: activityAt)) == false)
    // Finished-PR path: malformed is NOT the same as missing. Missing settles
    // (see above); malformed refuses, because we cannot show the user a
    // defensible reason the row moved.
    #expect(
      Self.effectiveSettled(
        Self.input(
          pullRequest: .merged,
          lastActivityAt: activityAt,
          inactivityWindow: nil
        )
      ) == false
    )
    // An explicit settle still works: the user's intent needs no timestamp.
    #expect(
      Self.effectiveSettled(
        Self.input(settledOverride: .settled, lastActivityAt: activityAt)
      ) == true
    )
  }

  /// A malformed `now` is the mirror hazard: every comparison against it is
  /// meaningless, so no auto path may fire off it either.
  @Test func malformedNowBlocksEveryAutoPath() {
    #expect(
      Self.effectiveSettled(
        Self.input(now: Self.malformedDate, lastActivityAt: Self.staleActivity)
      ) == false
    )
    #expect(
      Self.effectiveSettled(
        Self.input(
          now: Self.malformedDate,
          pullRequest: .merged,
          lastActivityAt: Self.staleActivity,
          inactivityWindow: nil
        )
      ) == false
    )
    // The case that ONLY the `now` guard catches: with no activity stamp the
    // finished-PR path never touches `now` at all (missing activity is idle by
    // definition), so a garbage clock would settle the row on nothing. Delete
    // the guard in `effectiveSettled` and this expectation — and only this one
    // — flips to true.
    #expect(
      Self.effectiveSettled(
        Self.input(
          now: Self.malformedDate,
          pullRequest: .merged,
          lastActivityAt: nil,
          inactivityWindow: nil
        )
      ) == false
    )
  }

  // MARK: - Global auto-settle off-switch (A30 groundwork)

  @Test func globalOffSwitchKillsEveryAutoPathButNotExplicitSettle() {
    let autoPaths: [TaskSettlement.Input] = [
      Self.input(lastActivityAt: Self.staleActivity, isAutoSettleEnabled: false),
      Self.input(
        pullRequest: .merged,
        lastActivityAt: Self.staleActivity,
        inactivityWindow: nil,
        isAutoSettleEnabled: false
      ),
      Self.input(
        pullRequest: .closed,
        lastActivityAt: nil,
        inactivityWindow: nil,
        isAutoSettleEnabled: false
      ),
    ]
    for input in autoPaths {
      #expect(Self.effectiveSettled(input) == false)
    }

    #expect(
      Self.effectiveSettled(
        Self.input(settledOverride: .settled, isAutoSettleEnabled: false)
      ) == true
    )
    // …and the explicit keep-active pin still reads as active, of course.
    #expect(
      Self.effectiveSettled(
        Self.input(settledOverride: .active, isAutoSettleEnabled: false)
      ) == false
    )
  }

  // MARK: - A18b: canSettle / canSnooze

  private static func canSettle(_ input: TaskSettlement.Input) -> Bool {
    TaskSettlement.canSettle(input)
  }

  /// `canSettle` is deliberately the same blocker list `effectiveSettled`
  /// checks first: anything the cascade refuses to CLASSIFY as settled must
  /// also be refused as a settle TARGET, so the affordance is disabled rather
  /// than invoked and failed.
  @Test(arguments: TaskSettlementTests.precedenceTable)
  func canSettleMatchesTheCascadeBlockers(_ testCase: PrecedenceCase) {
    let blocked =
      testCase.isWorking || testCase.isAwaitingInput || testCase.isAwaitingApproval == true
    let input = Self.input(
      activity: TaskSettlement.ActivitySnapshot(
        isWorking: testCase.isWorking,
        isAwaitingInput: testCase.isAwaitingInput,
        isAwaitingApproval: testCase.isAwaitingApproval
      ),
      settledOverride: testCase.settledOverride,
      pullRequest: testCase.pullRequest,
      lastActivityAt: testCase.activityAt
    )
    #expect(Self.canSettle(input) == !blocked, "\(testCase)")
    // The pair invariant: a refused settle can never be classified settled.
    if !Self.canSettle(input) {
      #expect(Self.effectiveSettled(input) == false, "\(testCase)")
    }
  }

  /// An open PR is a display signal, not a settle blocker: cj settles
  /// review-pending work on purpose all the time.
  @Test func openPullRequestDoesNotBlockAnExplicitSettle() {
    #expect(
      Self.canSettle(Self.input(pullRequest: .open, lastActivityAt: Self.freshActivity)) == true
    )
  }

  /// Snoozing something that is asking you a question is a no-op affordance:
  /// the raised-hand rule would surface it again immediately, so the menu item
  /// must be disabled instead of lying.
  @Test func canSnoozeRefusesTasksThatAreAskingForYou() {
    #expect(
      TaskSettlement.canSnooze(
        Self.input(activity: TaskSettlement.ActivitySnapshot(isAwaitingInput: true))
      ) == false
    )
    #expect(
      TaskSettlement.canSnooze(
        Self.input(activity: TaskSettlement.ActivitySnapshot(isAwaitingApproval: true))
      ) == false
    )
  }

  /// Working is snoozable — that is the whole point: park a long-running agent
  /// and let it wake you when it needs something.
  @Test func canSnoozeAllowsAWorkingTask() {
    #expect(
      TaskSettlement.canSnooze(
        Self.input(activity: TaskSettlement.ActivitySnapshot(isWorking: true))
      ) == true
    )
  }

  /// Phase 4 answers the open question this predicate carried: a settled task
  /// IS snoozable, in both directions.
  ///
  /// The auto-settled case is the one that forced it — a task the inactivity
  /// window parked reads as settled, and refusing to snooze it would deny the
  /// user the one affordance that says "and don't bring it back at the next
  /// keystroke". The explicitly-settled case follows from A16: snooze outranks
  /// settled, so settled-ness is no longer a reason to refuse. The reducer's
  /// snooze arm un-settles the record it parks, which is why this stays honest
  /// rather than offering a menu item that does nothing.
  @Test func canSnoozeAllowsASettledTask() {
    let settled = Self.input(settledOverride: .settled)
    #expect(Self.effectiveSettled(settled) == true)
    #expect(TaskSettlement.canSnooze(settled) == true)

    let autoSettled = Self.input(lastActivityAt: Self.staleActivity)
    #expect(Self.effectiveSettled(autoSettled) == true)
    #expect(TaskSettlement.canSnooze(autoSettled) == true)
  }

  /// Which leaves activity as the only input `canSnooze` reads. Asserted over
  /// the whole precedence table so no settings / PR / inactivity combination can
  /// quietly start gating the affordance again.
  @Test(arguments: TaskSettlementTests.precedenceTable)
  func canSnoozeReadsOnlyTheAttentionStates(_ testCase: PrecedenceCase) {
    let input = Self.input(
      activity: TaskSettlement.ActivitySnapshot(
        isWorking: testCase.isWorking,
        isAwaitingInput: testCase.isAwaitingInput,
        isAwaitingApproval: testCase.isAwaitingApproval
      ),
      settledOverride: testCase.settledOverride,
      pullRequest: testCase.pullRequest,
      lastActivityAt: testCase.activityAt
    )
    let expected = !testCase.isAwaitingInput && testCase.isAwaitingApproval != true
    #expect(TaskSettlement.canSnooze(input) == expected, "\(testCase)")
  }

  @Test func canSnoozeAllowsAPlainActiveTask() {
    #expect(TaskSettlement.canSnooze(Self.input(lastActivityAt: Self.freshActivity)) == true)
  }

  // MARK: - Phase 5: the settle stamp is explicit intent

  /// The settle arm stamps `settledAt` and deliberately does *not* write a
  /// `.settled` override (`RepositoriesFeature+Tasks.swift`, the settle case),
  /// so the cascade that replaces the record-only `isSettled` predicate has to
  /// read the stamp as the explicit intent it is. Without this the off-switch
  /// would un-settle every row the user settled by hand — A30 says the global
  /// switch kills the *auto* paths only.
  @Test func anExplicitSettleStampSettlesEvenWithEveryAutoPathOff() {
    #expect(
      TaskSettlement.effectiveSettled(
        Self.input(
          settledAt: Self.now.addingTimeInterval(-Self.hour),
          inactivityWindow: nil,
          isAutoSettleEnabled: false,
          settlesOnFinishedPullRequest: false
        )
      )
    )
  }

  /// The other direction, unchanged from the Phase-1 predicate: an explicit
  /// "no, this is still active" beats a stale stamp, so un-settling is not
  /// silently undone by the timestamp the settle left behind.
  @Test func anActiveOverrideBeatsASettleStamp() {
    #expect(
      !TaskSettlement.effectiveSettled(
        Self.input(settledOverride: .active, settledAt: Self.now.addingTimeInterval(-Self.hour))
      )
    )
  }

  /// A15/A30 spelled as the policy value the reducer threads from settings: the
  /// off-switch is one value, not three booleans every call site re-derives.
  @Test func theManualOnlyPolicyDisablesBothAutoPaths() {
    #expect(TaskSettlement.Policy.manualOnly.isAutoSettleEnabled == false)
    #expect(TaskSettlement.Policy.manualOnly.inactivityWindow == nil)
    #expect(TaskSettlement.Policy.manualOnly.settlesOnFinishedPullRequest == false)
  }

  // MARK: - The one non-port only a grep can hold

  /// t3's `hasQueuedTurnStart` blocker is absent by design, so there is no
  /// queued-turn input and no behavioural test that can notice it coming back.
  /// This is the tripwire. (The generic A18 purity sweep over the whole
  /// BusinessLogic directory lives in `TaskTimestampsTests`.)
  @Test func theQueuedTurnStartPortStaysDropped() {
    let url = URL(filePath: #filePath)
      .deletingLastPathComponent()  // supacodeTests
      .deletingLastPathComponent()  // repo root
      .appending(path: "supacode/Features/Repositories/BusinessLogic/TaskSettlement.swift")

    guard let source = try? String(contentsOf: url, encoding: .utf8) else {
      Issue.record("Missing pure-logic source file at \(url.path)")
      return
    }
    #expect(source.contains("hasQueuedTurnStart") == false)
  }
}

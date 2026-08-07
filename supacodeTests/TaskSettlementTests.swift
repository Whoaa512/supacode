import Foundation
import Testing

@testable import supacode

// MARK: - Expected API (Phase 2, plan assertions A14 / A15 / A17 / A18 / A18b)
//
// RED half of the TDD pair: `TaskSettlement` does not exist yet. The green step
// must create `supacode/Features/Repositories/BusinessLogic/TaskSettlement.swift`
// with exactly this surface — Foundation only, `nonisolated`, no `Date()`:
//
//   nonisolated enum TaskSettlement {
//     /// What the agent signals say right now. Supacode's mapping of t3's
//     /// session statuses (plan P2): t3 `running`/`starting` → `isWorking`
//     /// (`AgentPresenceFeature.Activity.busy || .compacting`); t3
//     /// `hasPendingUserInput` → `isAwaitingInput` (`.awaitingInput`); t3
//     /// `hasPendingApprovals` → `isAwaitingApproval`, which is `Bool?`
//     /// because the hook wire protocol only grows an approval discriminator
//     /// in this phase: `nil` means THIS AGENT CANNOT REPORT IT, never
//     /// "no approval pending" (plan Resolved #1 — never a guessed approval).
//     struct ActivitySnapshot: Equatable, Sendable {
//       var isWorking: Bool = false
//       var isAwaitingInput: Bool = false
//       var isAwaitingApproval: Bool? = nil
//       static let idle: ActivitySnapshot
//     }
//
//     /// All inputs as one value: pure function, injected `now`, no clock.
//     /// Declaration order below IS the memberwise-init order these tests use.
//     struct Input: Equatable, Sendable {
//       var now: Date
//       var activity: ActivitySnapshot = .idle
//       var settledOverride: TaskRecord.SettledOverride? = nil   // tri-state
//       // PR knowledge is explicitly tri-partite (top-level
//       // `TaskPullRequestState`): a real state, an absence, or an admission
//       // that we do not know. `unknown`/`loading`/`failed` are never collapsed
//       // into `none` — "no PR" and "we could not ask" have different settle
//       // consequences (A29).
//       var pullRequest: TaskPullRequestState = .none
//       var lastActivityAt: Date? = nil
//       var inactivityWindow: TimeInterval? = nil                // nil = off
//       var isAutoSettleEnabled: Bool = true                     // global switch
//       var settlesOnFinishedPullRequest: Bool = true
//     }
//
//     /// A merged/closed PR settles its task only once the task has been idle
//     /// this long. Ported from t3's CHANGE_REQUEST_SETTLE_IDLE_MS: the merge
//     /// signal never clears, so without the guard a follow-up message would
//     /// un-settle the row only until its turn ended, then snap it straight
//     /// back into the settled tail.
//     static let finishedPullRequestIdleWindow: TimeInterval  // 60 * 60
//
//     static func effectiveSettled(_ input: Input) -> Bool
//     static func canSettle(_ input: Input) -> Bool
//     static func canSnooze(_ input: Input) -> Bool
//   }
//
// Cascade order (A14 precedence, asserted combinatorially below):
//   1. activity blockers  (working / awaiting input / awaiting approval)
//   2. explicit override  (.settled → true, .active → false)
//   3. finished-PR auto-settle (gated on idle window + per-setting toggle)
//   4. inactivity auto-settle  (blocked by an OPEN PR)
//   with the global `isAutoSettleEnabled` switch killing steps 3 and 4 only.
//
// DELIBERATELY NOT PORTED: t3's `hasQueuedTurnStart` (and its 2-minute grace
// window, clock-skew bounds, and `serverAdjudicated` forgiveness). It exists
// solely for t3's dispatch → session-adoption race, where a `turn.start`
// command can sit unadopted while `session` is still null. Supacode's agent
// hook socket is local with no queue layer between dispatch and session, so
// the condition it detects cannot arise; porting it would add a clock-derived
// blocker with no signal behind it. There is therefore no queued-turn input on
// `Input`, and no test for one — the absence is the design.

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

  /// A row already in the settled tail has nothing to hide from.
  @Test func canSnoozeRefusesAnAlreadySettledTask() {
    let settled = Self.input(settledOverride: .settled)
    #expect(Self.effectiveSettled(settled) == true)
    #expect(TaskSettlement.canSnooze(settled) == false)

    let autoSettled = Self.input(lastActivityAt: Self.staleActivity)
    #expect(Self.effectiveSettled(autoSettled) == true)
    #expect(TaskSettlement.canSnooze(autoSettled) == false)
  }

  @Test func canSnoozeAllowsAPlainActiveTask() {
    #expect(TaskSettlement.canSnooze(Self.input(lastActivityAt: Self.freshActivity)) == true)
  }

  // MARK: - A18: pure-logic file stays pure

  /// Grep assertion. Fails loudly right now because the file does not exist —
  /// that absence IS the red state for this suite.
  @Test func sourceFileIsPureFoundationLogic() {
    let repositoryRoot = URL(filePath: #filePath)
      .deletingLastPathComponent()  // supacodeTests
      .deletingLastPathComponent()  // repo root
    let url =
      repositoryRoot
      .appending(path: "supacode/Features/Repositories/BusinessLogic")
      .appending(path: "TaskSettlement.swift")

    guard let source = try? String(contentsOf: url, encoding: .utf8) else {
      Issue.record("Missing pure-logic source file at \(url.path)")
      return
    }
    #expect(source.contains("import ComposableArchitecture") == false)
    #expect(source.contains("import SwiftUI") == false)
    #expect(source.contains("import AppKit") == false)
    // No ambient clock, in either spelling: `now` is always an injected
    // parameter.
    #expect(source.contains("Date()") == false)
    #expect(source.contains("Date.now") == false)
    // The dropped t3 port must stay dropped.
    #expect(source.contains("hasQueuedTurnStart") == false)
  }
}

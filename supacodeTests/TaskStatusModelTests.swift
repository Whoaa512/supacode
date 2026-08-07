import Foundation
import Testing

@testable import supacode

/// RED half of the Phase 2b TDD pair for `TaskStatusModel` (plan assertions
/// A18 / A27).
///
/// Ported from t3's `resolveSidebarV2Status`
/// (`apps/web/src/components/Sidebar.logic.ts:411`), which is a five-way
/// if-ladder over `hasPendingApprovals` → `hasPendingUserInput` →
/// `session.status`. Two things change in the port:
///  1. approval is `Bool?` here, because supacode's hook wire protocol only
///     grows the discriminator in this phase — t3's server always knew.
///  2. `failed` is not a session status we can read directly; it is derived
///     from an error timestamp, so it needs a freshness rule t3 didn't.
struct TaskStatusModelTests {
  // MARK: - Fixtures

  private static let now = Date(timeIntervalSince1970: 1_700_000_000)
  private static let hour: TimeInterval = 60 * 60
  private static let malformedDate = Date(timeIntervalSince1970: .nan)

  private static func input(
    activity: TaskSettlement.ActivitySnapshot = .idle,
    errorAt: Date? = nil,
    lastActivityAt: Date? = nil
  ) -> TaskStatusModel.Input {
    TaskStatusModel.Input(activity: activity, errorAt: errorAt, lastActivityAt: lastActivityAt)
  }

  // MARK: - A27: exactly one state, in a fixed order

  @Test func aPendingApprovalResolvesToApproval() {
    #expect(
      TaskStatusModel.resolve(
        Self.input(activity: TaskSettlement.ActivitySnapshot(isAwaitingApproval: true))
      ) == .approval
    )
  }

  @Test func pendingInputResolvesToInput() {
    #expect(
      TaskStatusModel.resolve(
        Self.input(activity: TaskSettlement.ActivitySnapshot(isAwaitingInput: true))
      ) == .input
    )
  }

  @Test func aBusyAgentResolvesToWorking() {
    #expect(
      TaskStatusModel.resolve(
        Self.input(activity: TaskSettlement.ActivitySnapshot(isWorking: true))
      ) == .working
    )
  }

  @Test func aRecentErrorResolvesToFailed() {
    #expect(TaskStatusModel.resolve(Self.input(errorAt: Self.now)) == .failed)
  }

  @Test func anIdleTaskWithNothingPendingResolvesToReady() {
    #expect(TaskStatusModel.resolve(Self.input()) == .ready)
  }

  /// The ladder order is the contract, not an implementation detail: a task
  /// blocking on a human outranks one that is merely busy, and both outrank a
  /// stale error, because the top of the list is what the user must act on.
  @Test func approvalOutranksEveryOtherSignal() {
    #expect(
      TaskStatusModel.resolve(
        Self.input(
          activity: TaskSettlement.ActivitySnapshot(
            isWorking: true,
            isAwaitingInput: true,
            isAwaitingApproval: true
          ),
          errorAt: Self.now
        )
      ) == .approval
    )
  }

  @Test func inputOutranksWorkingAndFailed() {
    #expect(
      TaskStatusModel.resolve(
        Self.input(
          activity: TaskSettlement.ActivitySnapshot(isWorking: true, isAwaitingInput: true),
          errorAt: Self.now
        )
      ) == .input
    )
  }

  /// A re-run after a crash reads as working, not failed: the agent is already
  /// doing something about it, so surfacing the old error would be noise.
  @Test func workingOutranksAStandingError() {
    #expect(
      TaskStatusModel.resolve(
        Self.input(
          activity: TaskSettlement.ActivitySnapshot(isWorking: true),
          errorAt: Self.now
        )
      ) == .working
    )
  }

  /// Resolved #1, restated as a status: an agent that cannot report approvals
  /// reports `input`. The alternative — treating "I don't know" as approval —
  /// would put a fake gate badge on every non-emitting agent's row.
  @Test func anAgentThatCannotReportApprovalReportsInputNotApproval() {
    let status = TaskStatusModel.resolve(
      Self.input(
        activity: TaskSettlement.ActivitySnapshot(isAwaitingInput: true, isAwaitingApproval: nil)
      )
    )
    #expect(status == .input)
    #expect(status != .approval)
  }

  /// ...and an unreportable approval on an otherwise quiet task is not a
  /// status at all.
  @Test func anUnreportableApprovalAloneIsNotAStatus() {
    #expect(
      TaskStatusModel.resolve(
        Self.input(activity: TaskSettlement.ActivitySnapshot(isAwaitingApproval: nil))
      ) == .ready
    )
  }

  /// An explicit `false` is a real answer from an agent that does emit the
  /// discriminator, and must read the same as silence.
  @Test func anExplicitlyAbsentApprovalIsNotAnApproval() {
    #expect(
      TaskStatusModel.resolve(
        Self.input(activity: TaskSettlement.ActivitySnapshot(isAwaitingApproval: false))
      ) == .ready
    )
  }

  /// Compaction happens inside a live turn, so it is working — same mapping the
  /// settle cascade uses. One `ActivitySnapshot` feeds both, deliberately: two
  /// snapshot types would let the sidebar badge and the settled tail disagree
  /// about whether a task is busy.
  @Test func workingCoversBothBusyAndCompacting() {
    #expect(
      TaskStatusModel.resolve(
        Self.input(activity: TaskSettlement.ActivitySnapshot(isWorking: true))
      ) == .working
    )
  }

  @Test func everySignalCombinationResolvesToExactlyOneState() {
    for isWorking in [true, false] {
      for isAwaitingInput in [true, false] {
        for isAwaitingApproval in [true, false, nil] as [Bool?] {
          for errorAt in [Self.now, nil] as [Date?] {
            let status = TaskStatusModel.resolve(
              Self.input(
                activity: TaskSettlement.ActivitySnapshot(
                  isWorking: isWorking,
                  isAwaitingInput: isAwaitingInput,
                  isAwaitingApproval: isAwaitingApproval
                ),
                errorAt: errorAt
              )
            )
            let expected: TaskStatusModel.Status =
              isAwaitingApproval == true
              ? .approval
              : isAwaitingInput ? .input : isWorking ? .working : errorAt == nil ? .ready : .failed
            #expect(status == expected)
          }
        }
      }
    }
  }

  // MARK: - Error freshness

  /// The rule that keeps `failed` honest: an error only counts while it is the
  /// newest thing that happened. Activity after the error means the agent kept
  /// going, so the row is `ready`, not permanently red.
  @Test func anErrorSupersededByLaterActivityIsNotFailed() {
    #expect(
      TaskStatusModel.resolve(
        Self.input(errorAt: Self.now, lastActivityAt: Self.now.addingTimeInterval(Self.hour))
      ) == .ready
    )
  }

  @Test func anErrorNewerThanTheLastActivityIsFailed() {
    #expect(
      TaskStatusModel.resolve(
        Self.input(
          errorAt: Self.now.addingTimeInterval(Self.hour),
          lastActivityAt: Self.now
        )
      ) == .failed
    )
  }

  /// Ties go to the error. The two stamps come from different writers with
  /// second-granularity clocks, so equality means "same moment", and the
  /// failure is the more actionable reading of that moment.
  @Test func anErrorStampedAtTheLastActivityInstantIsStillFailed() {
    #expect(
      TaskStatusModel.resolve(Self.input(errorAt: Self.now, lastActivityAt: Self.now)) == .failed
    )
  }

  /// No recorded activity is not evidence the error was superseded.
  @Test func anErrorWithNoRecordedActivityIsFailed() {
    #expect(TaskStatusModel.resolve(Self.input(errorAt: Self.now, lastActivityAt: nil)) == .failed)
  }

  /// A17's policy carried into the status model: unreadable input never
  /// invents a state. A malformed error stamp cannot be reasoned about, so the
  /// row reads `ready` rather than showing a failure nobody can date.
  @Test(
    arguments: [
      TaskStatusModelTests.malformedDate,
      Date(timeIntervalSince1970: .infinity),
      Date(timeIntervalSince1970: -.infinity),
    ]
  )
  func aMalformedErrorTimestampNeverFails(_ malformed: Date) {
    #expect(TaskStatusModel.resolve(Self.input(errorAt: malformed)) == .ready)
    #expect(
      TaskStatusModel.resolve(Self.input(errorAt: malformed, lastActivityAt: Self.now)) == .ready
    )
  }

  /// The other side: a malformed *activity* stamp must not suppress a real
  /// error, or a garbage write would silently hide failures.
  @Test func aMalformedActivityTimestampDoesNotSuppressARealError() {
    #expect(
      TaskStatusModel.resolve(Self.input(errorAt: Self.now, lastActivityAt: Self.malformedDate))
        == .failed
    )
  }

  // MARK: - Status shape

  /// The five states are the whole vocabulary (A27). A sixth would break the
  /// "exactly one state per task" contract that the status strip and the
  /// jump-to-next-needs-me predicate (A33) both depend on.
  @Test func thereAreExactlyFiveStates() {
    #expect(
      TaskStatusModel.Status.allCases == [.approval, .input, .working, .failed, .ready]
    )
  }

  /// A33 groundwork: the predicate is on the status, not re-derived at each
  /// call site, so the hint pill and the jump target can never disagree.
  @Test func onlyApprovalInputAndFailedNeedAHuman() {
    #expect(TaskStatusModel.Status.approval.needsHuman)
    #expect(TaskStatusModel.Status.input.needsHuman)
    #expect(TaskStatusModel.Status.failed.needsHuman)
    #expect(TaskStatusModel.Status.working.needsHuman == false)
    #expect(TaskStatusModel.Status.ready.needsHuman == false)
  }
}

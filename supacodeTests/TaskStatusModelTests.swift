import Foundation
import Testing

@testable import supacode

/// Table tests for `TaskStatusModel` (plan assertions A18 / A27).
///
/// Ported from t3's `resolveSidebarV2Status`
/// (`apps/web/src/components/Sidebar.logic.ts:411`), which is a five-way
/// if-ladder over `hasPendingApprovals` → `hasPendingUserInput` →
/// `session.status`. The one thing that changes in the port: approval is
/// `Bool?` here, because supacode's hook wire protocol only grows the
/// discriminator in this phase — t3's server always knew.
///
/// `failed` maps to t3's `session?.status === "error"`, i.e. a live presence
/// state, not a timestamp comparison. There is no error-freshness rule to test
/// because there is no error stamp to compare against.
struct TaskStatusModelTests {
  // MARK: - Fixtures

  private static func input(
    activity: TaskSettlement.ActivitySnapshot = .idle
  ) -> TaskStatusModel.Input {
    TaskStatusModel.Input(activity: activity)
  }

  private static func activity(
    isWorking: Bool = false,
    isAwaitingInput: Bool = false,
    isAwaitingApproval: Bool? = nil,
    isErrored: Bool = false
  ) -> TaskSettlement.ActivitySnapshot {
    TaskSettlement.ActivitySnapshot(
      isWorking: isWorking,
      isAwaitingInput: isAwaitingInput,
      isAwaitingApproval: isAwaitingApproval,
      isErrored: isErrored
    )
  }

  // MARK: - A27: exactly one state, in a fixed order

  @Test func aPendingApprovalResolvesToApproval() {
    #expect(TaskStatusModel.resolve(Self.input(activity: Self.activity(isAwaitingApproval: true))) == .approval)
  }

  @Test func pendingInputResolvesToInput() {
    #expect(TaskStatusModel.resolve(Self.input(activity: Self.activity(isAwaitingInput: true))) == .input)
  }

  @Test func aBusyAgentResolvesToWorking() {
    #expect(TaskStatusModel.resolve(Self.input(activity: Self.activity(isWorking: true))) == .working)
  }

  @Test func anErroredAgentResolvesToFailed() {
    #expect(TaskStatusModel.resolve(Self.input(activity: Self.activity(isErrored: true))) == .failed)
  }

  @Test func anIdleTaskWithNothingPendingResolvesToReady() {
    #expect(TaskStatusModel.resolve(Self.input()) == .ready)
  }

  // MARK: - Ladder order

  /// The ladder order is the contract, not an implementation detail: a task
  /// blocking on a human outranks one that is merely busy, and every one of
  /// them outranks a standing error, because the top of the list is what the
  /// user must act on.
  @Test func approvalOutranksEveryOtherSignal() {
    #expect(
      TaskStatusModel.resolve(
        Self.input(
          activity: Self.activity(
            isWorking: true,
            isAwaitingInput: true,
            isAwaitingApproval: true,
            isErrored: true
          )
        )
      ) == .approval
    )
  }

  @Test func inputOutranksWorkingAndFailed() {
    #expect(
      TaskStatusModel.resolve(
        Self.input(activity: Self.activity(isWorking: true, isAwaitingInput: true, isErrored: true))
      ) == .input
    )
  }

  /// A re-run after a crash reads as working, not failed: the agent is already
  /// doing something about it, so surfacing the error would be noise.
  @Test func workingOutranksAStandingError() {
    #expect(
      TaskStatusModel.resolve(Self.input(activity: Self.activity(isWorking: true, isErrored: true)))
        == .working
    )
  }

  @Test func failedOutranksReady() {
    #expect(TaskStatusModel.resolve(Self.input(activity: Self.activity(isErrored: true))) != .ready)
  }

  @Test func everySignalCombinationResolvesToExactlyOneState() {
    for isWorking in [true, false] {
      for isAwaitingInput in [true, false] {
        for isAwaitingApproval in [true, false, nil] as [Bool?] {
          for isErrored in [true, false] {
            let status = TaskStatusModel.resolve(
              Self.input(
                activity: Self.activity(
                  isWorking: isWorking,
                  isAwaitingInput: isAwaitingInput,
                  isAwaitingApproval: isAwaitingApproval,
                  isErrored: isErrored
                )
              )
            )
            let expected: TaskStatusModel.Status =
              isAwaitingApproval == true
              ? .approval
              : isAwaitingInput ? .input : isWorking ? .working : isErrored ? .failed : .ready
            #expect(status == expected)
          }
        }
      }
    }
  }

  // MARK: - Resolved #1: `nil` approval is "cannot report", not "pending"

  /// An agent that cannot report approvals reports `input`. The alternative —
  /// treating "I don't know" as approval — would put a fake gate badge on
  /// every non-emitting agent's row.
  @Test func anAgentThatCannotReportApprovalReportsInputNotApproval() {
    let status = TaskStatusModel.resolve(
      Self.input(activity: Self.activity(isAwaitingInput: true, isAwaitingApproval: nil))
    )
    #expect(status == .input)
    #expect(status != .approval)
  }

  /// ...and an unreportable approval on an otherwise quiet task is not a
  /// status at all.
  @Test func anUnreportableApprovalAloneIsNotAStatus() {
    #expect(TaskStatusModel.resolve(Self.input(activity: Self.activity(isAwaitingApproval: nil))) == .ready)
  }

  /// An explicit `false` is a real answer from an agent that does emit the
  /// discriminator, and must read the same as silence.
  @Test func anExplicitlyAbsentApprovalIsNotAnApproval() {
    #expect(TaskStatusModel.resolve(Self.input(activity: Self.activity(isAwaitingApproval: false))) == .ready)
  }

  /// Compaction happens inside a live turn, so it is working — same mapping the
  /// settle cascade uses. One `ActivitySnapshot` feeds both, deliberately: two
  /// snapshot types would let the sidebar badge and the settled tail disagree
  /// about whether a task is busy.
  @Test func workingCoversBothBusyAndCompacting() {
    #expect(TaskStatusModel.resolve(Self.input(activity: Self.activity(isWorking: true))) == .working)
  }

  // MARK: - Status shape

  /// The five states are the whole vocabulary (A27). A sixth would break the
  /// "exactly one state per task" contract that the status strip and the
  /// jump-to-next-needs-me predicate (A33) both depend on.
  @Test func thereAreExactlyFiveStates() {
    #expect(TaskStatusModel.Status.allCases == [.approval, .input, .working, .failed, .ready])
  }

  /// A33 groundwork: the predicate is on the status, not re-derived at each
  /// call site, so the hint pill and the jump target can never disagree about
  /// the status half of the jump rule.
  @Test func onlyApprovalInputAndFailedNeedAHuman() {
    #expect(TaskStatusModel.Status.approval.needsHuman)
    #expect(TaskStatusModel.Status.input.needsHuman)
    #expect(TaskStatusModel.Status.failed.needsHuman)
    #expect(TaskStatusModel.Status.working.needsHuman == false)
    #expect(TaskStatusModel.Status.ready.needsHuman == false)
  }

  /// The default snapshot is the quiet one: a task with no presence signal at
  /// all must not manufacture a failure.
  @Test func theIdleSnapshotIsNotErrored() {
    #expect(TaskSettlement.ActivitySnapshot.idle.isErrored == false)
  }
}

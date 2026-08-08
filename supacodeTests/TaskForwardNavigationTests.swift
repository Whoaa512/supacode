import Foundation
import Testing

@testable import supacode

/// RED half of the Phase 2b TDD pair for `TaskForwardNavigation` (plan
/// assertions A18 / A26).
///
/// Provenance: t3 has no `planForwardNavigation`. Its nearest relatives are
/// `resolveAdjacentThreadId` (`Sidebar.logic.ts:305`, plain index ±1, **no**
/// wrap-around and no eligibility filter) and `getFallbackThreadIdAfterDelete`
/// (`:674`, re-sorts and takes the head). What is ported is the "return null,
/// let the caller decide" shape; the wrap-around scan is supacode's, and so is
/// the no-next answer — t3 navigates home / to a new draft, supacode stays put
/// (A26). t3's `deletedThreadIds` batch-exclusion set is deliberately not
/// ported: supacode parks one task per action.
///
/// Everything here is a *plan*: a value computed from an ordered snapshot taken
/// before the mutation. The reducer applies it only if the open task is still
/// the one the plan was made for (Phase 4); none of that belongs in this file.
struct TaskForwardNavigationTests {
  // MARK: - Fixtures

  private static func id(_ raw: String) -> TaskID { TaskID(raw) }

  private static func task(
    _ raw: String,
    isSettled: Bool = false,
    isSnoozed: Bool = false
  ) -> TaskForwardNavigation.Candidate {
    TaskForwardNavigation.Candidate(id: id(raw), isSettled: isSettled, isSnoozed: isSnoozed)
  }

  /// Four plain active rows in sidebar order.
  private static let row = [task("a"), task("b"), task("c"), task("d")]

  // MARK: - The basic scan

  @Test func theNextRowAfterTheCurrentOneWins() {
    #expect(
      TaskForwardNavigation.planForwardNavigation(
        orderedTasks: Self.row,
        currentTaskID: Self.id("b")
      ) == Self.id("c")
    )
  }

  /// The wrap: settling the last row lands on the first, so a bottom-of-list
  /// settle does not dead-end the keyboard flow.
  @Test func theScanWrapsPastTheEndOfTheList() {
    #expect(
      TaskForwardNavigation.planForwardNavigation(
        orderedTasks: Self.row,
        currentTaskID: Self.id("d")
      ) == Self.id("a")
    )
  }

  /// The current row is excluded even though the wrap-around scan passes over
  /// it again — the whole point of the plan is to leave it.
  @Test func theCurrentRowIsNeverItsOwnNext() {
    #expect(
      TaskForwardNavigation.planForwardNavigation(
        orderedTasks: [Self.task("a")],
        currentTaskID: Self.id("a")
      ) == nil
    )
  }

  // MARK: - Eligibility filters

  @Test func settledRowsAreSkipped() {
    let tasks = [
      Self.task("a"),
      Self.task("b"),
      Self.task("c", isSettled: true),
      Self.task("d"),
    ]
    #expect(
      TaskForwardNavigation.planForwardNavigation(orderedTasks: tasks, currentTaskID: Self.id("b"))
        == Self.id("d")
    )
  }

  @Test func snoozedRowsAreSkipped() {
    let tasks = [
      Self.task("a"),
      Self.task("b"),
      Self.task("c", isSnoozed: true),
      Self.task("d"),
    ]
    #expect(
      TaskForwardNavigation.planForwardNavigation(orderedTasks: tasks, currentTaskID: Self.id("b"))
        == Self.id("d")
    )
  }

  @Test func skippingWrapsToo() {
    let tasks = [
      Self.task("a"),
      Self.task("b"),
      Self.task("c", isSettled: true),
      Self.task("d", isSnoozed: true),
    ]
    #expect(
      TaskForwardNavigation.planForwardNavigation(orderedTasks: tasks, currentTaskID: Self.id("b"))
        == Self.id("a")
    )
  }

  /// A26's supacode decision, stated as a test so nobody "fixes" it into t3's
  /// navigate-home behaviour: no eligible target means no navigation. The
  /// just-settled row stays selected and remains visible in the settled tail
  /// (A8), which is a far better recovery position than an empty home screen.
  @Test func noEligibleRowMeansStayPut() {
    let tasks = [
      Self.task("a"),
      Self.task("b", isSettled: true),
      Self.task("c", isSnoozed: true),
    ]
    #expect(
      TaskForwardNavigation.planForwardNavigation(orderedTasks: tasks, currentTaskID: Self.id("a"))
        == nil
    )
  }

  @Test func anEmptyListHasNoNext() {
    #expect(
      TaskForwardNavigation.planForwardNavigation(orderedTasks: [], currentTaskID: Self.id("a"))
        == nil
    )
  }

  // MARK: - Degenerate current-row cases

  /// No current selection: the scan starts at the top rather than answering
  /// `nil`, so a settle triggered from a menu with nothing selected still lands
  /// somewhere useful.
  @Test func noCurrentRowScansFromTheTop() {
    #expect(
      TaskForwardNavigation.planForwardNavigation(orderedTasks: Self.row, currentTaskID: nil)
        == Self.id("a")
    )
  }

  @Test func noCurrentRowStillSkipsIneligibleRows() {
    let tasks = [
      Self.task("a", isSnoozed: true),
      Self.task("b", isSettled: true),
      Self.task("c"),
    ]
    #expect(
      TaskForwardNavigation.planForwardNavigation(orderedTasks: tasks, currentTaskID: nil)
        == Self.id("c")
    )
  }

  /// The snapshot can be stale by a tick — the current task may already be gone
  /// from the ordered list. Scanning from the top beats returning `nil` (t3's
  /// `resolveAdjacentThreadId` answers `null` here) because the user's intent
  /// was "move me forward", and there is still somewhere to go.
  @Test func anUnknownCurrentRowScansFromTheTop() {
    #expect(
      TaskForwardNavigation.planForwardNavigation(
        orderedTasks: Self.row,
        currentTaskID: Self.id("zzz")
      ) == Self.id("a")
    )
  }

  /// A row can be both current and ineligible — settling is precisely that
  /// case once the snapshot is taken after the flag flips. It must not be
  /// picked, and it must not stop the scan.
  @Test func anIneligibleCurrentRowIsStillJustSkipped() {
    let tasks = [Self.task("a", isSettled: true), Self.task("b")]
    #expect(
      TaskForwardNavigation.planForwardNavigation(orderedTasks: tasks, currentTaskID: Self.id("a"))
        == Self.id("b")
    )
  }

  // MARK: - Determinism

  /// Order in, order out: the function never re-sorts. The caller passes the
  /// visible sidebar order, and a second ordering here would silently send the
  /// user somewhere other than the row below the one they were on.
  @Test func theResultFollowsTheGivenOrderNotTheIDs() {
    let reversed = [Self.task("d"), Self.task("c"), Self.task("b"), Self.task("a")]
    #expect(
      TaskForwardNavigation.planForwardNavigation(
        orderedTasks: reversed,
        currentTaskID: Self.id("c")
      ) == Self.id("b")
    )
  }

  @Test func repeatedCallsWithTheSameSnapshotAgree() {
    let first = TaskForwardNavigation.planForwardNavigation(
      orderedTasks: Self.row,
      currentTaskID: Self.id("b")
    )
    let second = TaskForwardNavigation.planForwardNavigation(
      orderedTasks: Self.row,
      currentTaskID: Self.id("b")
    )
    #expect(first == second)
  }
}

import Foundation
import Testing

@testable import supacode

/// RED half of the Phase 5 TDD pair for `TaskAttention` (plan assertions A28,
/// and the A33 predicate Phase 6 will reuse). The type does not exist yet;
/// these tests are the spec.
///
/// One predicate, two readings. `needsHuman` is the union of the three
/// disjuncts A33 names — a status parked on a person, an unread completion, and
/// a wake the user has not acted on — and `isReceded` is its complement *minus
/// working*, because a working row is not "quiet", it is busy: A33 skips
/// working and receded rows separately, so they cannot be the same category.
///
/// Pure logic, Foundation only (A18): the row's fade and the keyboard jump
/// target must read the same answer, and the only way to guarantee that is one
/// function neither of them can fork.
struct TaskAttentionTests {
  private static func input(
    _ status: TaskStatusModel.Status,
    isDoneUnread: Bool = false,
    isWoke: Bool = false
  ) -> TaskAttention.Input {
    TaskAttention.Input(status: status, isDoneUnread: isDoneUnread, isWoke: isWoke)
  }

  // MARK: - A28: recession never hides a row that is asking for something

  /// The hard half of A28: whatever else is true, a row parked on a human is
  /// never faded. Asserted per status rather than in aggregate so a future
  /// sixth state cannot quietly join the receded set.
  @Test(arguments: [TaskStatusModel.Status.approval, .input, .failed])
  func aStatusParkedOnAHumanIsNeverReceded(status: TaskStatusModel.Status) {
    #expect(TaskAttention.needsHuman(Self.input(status)))
    #expect(!TaskAttention.isReceded(Self.input(status)))
  }

  /// A working row is not receded and does not need a human: it is the third
  /// category, which is exactly why A33's jump predicate names "working" and
  /// "receded" separately.
  @Test func aWorkingRowIsNeitherRecededNorNeedingAHuman() {
    #expect(!TaskAttention.needsHuman(Self.input(.working)))
    #expect(!TaskAttention.isReceded(Self.input(.working)))
  }

  @Test func aQuietReadyRowRecedes() {
    #expect(!TaskAttention.needsHuman(Self.input(.ready)))
    #expect(TaskAttention.isReceded(Self.input(.ready)))
  }

  // MARK: - A28: the two non-status disjuncts

  /// An unread completion is the Done pill's own signal: the agent finished
  /// something the user has not looked at, so the row keeps full contrast even
  /// though its status reads `ready`.
  @Test func anUnreadCompletionHoldsAReadyRowOutOfRecession() {
    let unread = Self.input(.ready, isDoneUnread: true)
    #expect(TaskAttention.needsHuman(unread))
    #expect(!TaskAttention.isReceded(unread))
  }

  /// A24's Woke pill carries the "acted on once" invariant; fading the row it
  /// sits on would make the pill an apology for hiding the thing it announces.
  @Test func aWokeRowIsHeldOutOfRecession() {
    let woke = Self.input(.ready, isWoke: true)
    #expect(TaskAttention.needsHuman(woke))
    #expect(!TaskAttention.isReceded(woke))
  }

  /// A working row that also finished an earlier unseen turn still reads as
  /// working, not receded — the complement rule must not let the extra
  /// disjunct flip it into a category it never belonged to.
  @Test func workingOutranksAnUnreadCompletionForRecession() {
    #expect(!TaskAttention.isReceded(Self.input(.working, isDoneUnread: true)))
  }

  // MARK: - A33: jump to the next row needing a human

  /// The scan itself, stated over plain strings: A33's target is "the next row
  /// in the order the user can see whose `needsHuman` is true", so the walk has
  /// to be a pure function of an order plus that one predicate. Anything richer
  /// would give the jump a second opinion about a row the fade already ruled on.
  private static func next(
    _ order: [String],
    after current: String?,
    needing needsHuman: Set<String>
  ) -> String? {
    TaskAttention.nextNeedingHuman(in: order, after: current) { needsHuman.contains($0) }
  }

  @Test func theJumpStartsAfterTheCurrentRow() {
    #expect(Self.next(["a", "b", "c"], after: "a", needing: ["b", "c"]) == "b")
  }

  /// Quiet rows are stepped over rather than landed on: the whole value of the
  /// chord is that it never stops somewhere with nothing to do.
  @Test func theJumpSkipsRowsThatNeedNobody() {
    #expect(Self.next(["a", "b", "c", "d"], after: "a", needing: ["d"]) == "d")
  }

  /// One list, one lap. Wrapping is what makes the chord a triage loop instead
  /// of a walk that dead-ends at the bottom of the inbox.
  @Test func theJumpWrapsPastTheEndOfTheList() {
    #expect(Self.next(["a", "b", "c"], after: "c", needing: ["a"]) == "a")
  }

  /// No selection means the user has not entered the list yet, so the lap
  /// starts at the top rather than at an arbitrary anchor.
  @Test func theJumpWithoutASelectionStartsAtTheTop() {
    #expect(Self.next(["a", "b", "c"], after: nil, needing: ["b", "c"]) == "b")
    #expect(Self.next(["a", "b", "c"], after: nil, needing: ["a"]) == "a")
  }

  /// A selection whose row is gone (settled away, snoozed out of view) is the
  /// same situation as no selection at all.
  @Test func theJumpFromARowThatIsNoLongerVisibleStartsAtTheTop() {
    #expect(Self.next(["a", "b"], after: "gone", needing: ["a"]) == "a")
  }

  /// The current row is never its own target: re-selecting what is already open
  /// looks to the user exactly like a chord that did nothing, and it would
  /// re-stamp the visit. `nil` lets the reducer beep instead, which at least
  /// says something.
  @Test func theJumpNeverLandsBackOnTheCurrentRow() {
    #expect(Self.next(["a", "b", "c"], after: "a", needing: ["a"]) == nil)
  }

  @Test func theJumpFindsNothingInAQuietInbox() {
    #expect(Self.next(["a", "b"], after: "a", needing: []) == nil)
    #expect(Self.next([], after: nil, needing: ["a"]) == nil)
  }

  /// The predicate the jump is *actually* wired to, asserted through the same
  /// `Input` the row's fade reads: working and receded rows are skipped, and
  /// each of A33's three disjuncts is a landing site. Driving it from
  /// `needsHuman` rather than from a hand-written set is the point — a second
  /// spelling here is exactly the drift `TaskAttention` exists to prevent.
  @Test func theJumpSkipsWorkingAndRecededRowsAndLandsOnEveryDisjunct() {
    let rows: [String: TaskAttention.Input] = [
      "working": Self.input(.working),
      "quiet": Self.input(.ready),
      "approval": Self.input(.approval),
      "input": Self.input(.input),
      "failed": Self.input(.failed),
      "done": Self.input(.ready, isDoneUnread: true),
      "woke": Self.input(.ready, isWoke: true),
    ]
    let order = ["anchor", "working", "quiet", "approval", "input", "failed", "done", "woke"]
    func next(after current: String) -> String? {
      TaskAttention.nextNeedingHuman(in: order, after: current) { id in
        rows[id].map(TaskAttention.needsHuman) ?? false
      }
    }

    #expect(next(after: "anchor") == "approval")
    #expect(next(after: "approval") == "input")
    #expect(next(after: "input") == "failed")
    #expect(next(after: "failed") == "done")
    #expect(next(after: "done") == "woke")
    // Wraps past the quiet head of the list back to the first raised hand.
    #expect(next(after: "woke") == "approval")
  }
}

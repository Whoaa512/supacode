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
}

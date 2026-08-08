import Foundation

/// Whether a task row is asking for a person, and whether it may fade (A28, and
/// the predicate A33's jump target reuses).
///
/// One predicate, two readings, because the row's contrast and the keyboard's
/// jump target must never disagree about the same row — and the only way to
/// guarantee that is a function neither of them can fork.
///
/// `needsHuman` is the union of A33's three disjuncts: a status parked on a
/// person, a completion the user has not read, and a wake they have not acted
/// on. `isReceded` is its complement *minus working*: a working row is not
/// quiet, it is busy, which is exactly why A33 names "working" and "receded"
/// separately.
///
/// Pure logic — Foundation only, no ambient clock (A18). `nonisolated` because
/// the target compiles with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, which
/// would otherwise pin this to the main actor.
nonisolated enum TaskAttention {
  /// The three readings a row's attention state is a function of. Nothing here
  /// is a timestamp: the two instant-shaped signals (`isDoneUnread`, `isWoke`)
  /// are resolved against a visit before they get here, so this stays a pure
  /// function of what the row currently shows.
  nonisolated struct Input: Equatable, Sendable {
    var status: TaskStatusModel.Status
    var isDoneUnread: Bool = false
    var isWoke: Bool = false
  }

  static func needsHuman(_ input: Input) -> Bool {
    input.status.needsHuman || input.isDoneUnread || input.isWoke
  }

  /// The row may fade. Never true for a row that needs a human (A28's hard
  /// half), and never true for a working one — fading the row whose timer is
  /// counting up would read as the app losing interest in it.
  static func isReceded(_ input: Input) -> Bool {
    !needsHuman(input) && input.status != .working
  }
}

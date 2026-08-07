import Foundation

/// The one place a task timestamp is judged usable, and the one resolver behind
/// both the settled sort key and the settled label (A17) — two resolvers would
/// eventually disagree and show a row sorted by one date and labelled with
/// another.
///
/// The distinction the whole type exists for: *missing* and *malformed* are not
/// the same input. A `nil` stamp means nothing was ever recorded; a non-finite
/// one means something was recorded and cannot be reasoned about. The settlement
/// cascade grants them different powers (missing can auto-settle on a finished
/// PR, malformed can auto-settle nothing), so folding them together would let
/// garbage move rows.
///
/// `nonisolated` on purpose: the target compiles with
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, which would otherwise pin this
/// pure logic to the main actor.
nonisolated enum TaskTimestamps {
  /// The three-way judgement callers actually branch on. Returning this instead
  /// of an `Optional` plus a separate `isMalformed` predicate means a caller
  /// that cares about the distinction gets an exhaustive switch from the
  /// compiler rather than two lookups it could forget to pair up.
  nonisolated enum Reading: Equatable, Sendable {
    case missing
    case malformed
    case valid(Date)

    /// The usable instant. `nil` for both unusable readings, for the callers
    /// that genuinely treat missing and malformed the same way.
    var date: Date? {
      guard case .valid(let date) = self else { return nil }
      return date
    }
  }

  /// A zero interval is a real instant (1970-01-01), never "absent" — treating
  /// it as absent silently re-dates such rows to whatever fallback comes next.
  static func read(_ date: Date?) -> Reading {
    guard let date else { return .missing }
    guard date.timeIntervalSince1970.isFinite else { return .malformed }
    return .valid(date)
  }

  /// Newest usable candidate. Malformed candidates are dropped before the max,
  /// so an `infinity` stamp can never win it.
  static func latestValid(_ candidates: [Date?]) -> Date? {
    candidates.compactMap { read($0).date }.max()
  }

  /// Settle stamp → newest real activity → creation. `nil` when nothing is
  /// provable: the sidebar sorts such a row to the bottom of the tail rather
  /// than the row claiming a time it does not have (A2, A17).
  static func resolvedSettledTimestamp(
    settledAt: Date?,
    activityCandidates: [Date?],
    createdAt: Date?
  ) -> Date? {
    read(settledAt).date ?? latestValid(activityCandidates) ?? read(createdAt).date
  }

  /// Strict, and deliberately `false` for anything unusable on either side: an
  /// unreadable timestamp must never read as "ancient" and trip an auto-settle
  /// the user cannot be given a reason for (A17).
  static func isStrictlyOlder(_ date: Date?, than boundary: Date) -> Bool {
    // The boundary check stays even though callers now screen `now` themselves:
    // boundaries are computed as `now - window`, and window arithmetic can go
    // non-finite on its own, so this is the second line of defense.
    guard let date = read(date).date, let boundary = read(boundary).date else { return false }
    return date < boundary
  }
}

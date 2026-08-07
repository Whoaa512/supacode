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
  /// A zero interval is a real instant (1970-01-01), never "absent" — treating
  /// it as absent silently re-dates such rows to whatever fallback comes next.
  static func valid(_ date: Date?) -> Date? {
    guard let date, date.timeIntervalSince1970.isFinite else { return nil }
    return date
  }

  /// Present but unusable. Missing is not malformed.
  static func isMalformed(_ date: Date?) -> Bool {
    guard let date else { return false }
    return !date.timeIntervalSince1970.isFinite
  }

  /// First usable candidate in the caller's priority order — not the newest.
  static func firstValid(_ candidates: [Date?]) -> Date? {
    for candidate in candidates {
      if let usable = valid(candidate) { return usable }
    }
    return nil
  }

  /// Newest usable candidate. Malformed candidates are dropped before the max,
  /// so an `infinity` stamp can never win it.
  static func latestValid(_ candidates: [Date?]) -> Date? {
    candidates.compactMap(valid).max()
  }

  /// Settle stamp → newest real activity → creation. `nil` when nothing is
  /// provable: the sidebar sorts such a row to the bottom of the tail rather
  /// than the row claiming a time it does not have (A2, A17).
  static func resolvedSettledTimestamp(
    settledAt: Date?,
    activityCandidates: [Date?],
    createdAt: Date?
  ) -> Date? {
    valid(settledAt) ?? latestValid(activityCandidates) ?? valid(createdAt)
  }

  /// Strict, and deliberately `false` for anything unusable on either side: an
  /// unreadable timestamp must never read as "ancient" and trip an auto-settle
  /// the user cannot be given a reason for (A17).
  static func isStrictlyOlder(_ date: Date?, than boundary: Date) -> Bool {
    guard let date = valid(date), valid(boundary) != nil else { return false }
    return date < boundary
  }
}

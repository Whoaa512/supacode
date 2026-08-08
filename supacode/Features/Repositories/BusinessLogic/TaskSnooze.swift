import Foundation

/// Snooze classification, wake-time arithmetic and section placement (A16, A23,
/// A24, A25).
///
/// Pure logic — Foundation only, `now` and `Calendar` injected, no ambient clock
/// (A18) — so the DST and boundary cases below are testable without a reducer.
///
/// Snooze is a *classification*, never a mutation: a raised hand stops a task
/// reading as snoozed while `snoozedUntil` / `snoozedAt` stay exactly as the user
/// wrote them, so re-snoozing never asks for the wake time again.
///
/// Deliberately not ported from the browser prior art: the 32-bit `setTimeout`
/// ceiling that clamps far-future wakes. That clamp exists only because a browser
/// timer id overflows past ~24.8 days; supacode persists an absolute `Date` and
/// re-arms it from an injected clock, so a wake a year out costs exactly what one
/// an hour out costs.
///
/// Classification only: the settle-clears-pin mutation (A16) lives in the
/// reducer's settle arm, which owns the write.
///
/// `nonisolated` on purpose: the target compiles with
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, which would otherwise pin this
/// pure logic to the main actor.
nonisolated enum TaskSnooze {
  nonisolated struct Input: Equatable, Sendable {
    var now: Date
    var snoozedUntil: Date?
    /// When the user set the snooze. Freshness of the conditional triggers is
    /// measured against it, so without it they refuse rather than guess.
    var snoozedAt: Date?
    var activity: TaskSettlement.ActivitySnapshot = .idle
    /// Unlike `TaskStatusModel`, snooze needs the *instant* of the failure, not
    /// the fact of it: A25 only re-surfaces an error that is newer than
    /// `snoozedAt`. Producer arrives with the Phase 4/5 wiring (the presence
    /// layer's last-transition timestamp for `.error`).
    var errorAt: Date?
    var completedTurnAt: Date?
    /// Newest *unread* terminal notification (OSC 9/777) on the surfaces the
    /// task owns. The primary wake signal for a task running no hook-reporting
    /// agent at all — a `make test` that finished, a script that spoke up — and
    /// an *event* like the other two, so it follows the same freshness rule: a
    /// notification the user already scrolled past cannot hold a row out of the
    /// shelf forever.
    var notifiedAt: Date?
  }

  /// Which section of the sidebar a task sorts into.
  nonisolated enum Placement: Hashable, Sendable {
    case snoozed
    case pinned
    case settled
    case active
  }

  nonisolated enum Preset: Hashable, Sendable {
    case oneHour
    case thisEvening
    case tomorrow
    case nextWeek
  }

  nonisolated struct ResolvedPreset: Equatable, Sendable {
    var preset: Preset
    var wakeAt: Date
  }

  /// Structured rather than a `String`: formatting is locale- and
  /// settings-dependent, so the view formats the associated `Date` and this stays
  /// free of `DateFormatter`.
  nonisolated enum WakeLabel: Equatable, Sendable {
    case today(Date)
    case tomorrow(Date)
    case weekday(Date)
    case date(Date)
    /// Unreadable `until` or `now`. Distinct from `.date` because there is no
    /// honest `Date` to hand the view — rendering a malformed instant would
    /// print "Dec 31, 1969" or worse (A17: never invent a time).
    case unknown
  }

  private static let eveningHour = 18
  private static let morningHour = 8
  /// `Calendar`'s 1-based weekday for Monday.
  private static let monday = 2

  // MARK: - Classification

  /// The wake boundary is inclusive on the wake side: at exactly `snoozedUntil`
  /// the task is awake, so a boundary-armed effect that overshoots its target
  /// instant always observes the row as woken.
  ///
  /// Unreadable input fails open. A hidden task the user cannot explain is a
  /// worse bug than a row that reappears early (A17's direction applied to
  /// snooze).
  static func effectiveSnoozed(_ input: Input) -> Bool {
    guard
      let now = TaskTimestamps.read(input.now).date,
      let until = TaskTimestamps.read(input.snoozedUntil).date,
      now < until
    else { return false }
    return !raisedHandWhileSnoozed(input)
  }

  /// Two classes of trigger. Pending input and a pending approval are *states*
  /// that outrank the user's earlier "not now" unconditionally — a task asking a
  /// direct question cannot be left hidden. An error or a completed turn is an
  /// *event*, and only counts as news when it is strictly newer than the snooze:
  /// the user snoozing a task they already knew was broken must stay snoozed.
  static func raisedHandWhileSnoozed(_ input: Input) -> Bool {
    if input.activity.isAwaitingInput || input.activity.isAwaitingApproval == true { return true }
    return newestConditionalTrigger(input) != nil
  }

  /// The instant the Woke pill dates from, or `nil` while the task is still
  /// parked.
  ///
  /// Resolution order matters: an expired timer outranks a later raised hand
  /// because the row has been visible since the wake time, and that is the first
  /// moment the user could have seen it. A conditional raise carries its own
  /// instant; an unconditional one has none — pending input is a state, not an
  /// event — so it dates from `now` rather than backdating past a visit that
  /// already happened.
  static func wokeAt(_ input: Input) -> Date? {
    guard
      let now = TaskTimestamps.read(input.now).date,
      let until = TaskTimestamps.read(input.snoozedUntil).date
    else { return nil }
    if now >= until { return until }
    guard raisedHandWhileSnoozed(input) else { return nil }
    return newestConditionalTrigger(input) ?? now
  }

  private static func newestConditionalTrigger(_ input: Input) -> Date? {
    guard let snoozedAt = TaskTimestamps.read(input.snoozedAt).date else { return nil }
    return TaskTimestamps.latestValid([input.errorAt, input.completedTurnAt, input.notifiedAt])
      .flatMap { $0 > snoozedAt ? $0 : nil }
  }

  // MARK: - Presets

  /// Resolved at menu-open time against the caller's clock and calendar, never
  /// precomputed. A preset whose instant has already passed is *omitted* rather
  /// than rolled forward: rolling would make one menu item mean two different
  /// things depending on the hour.
  ///
  /// Soonest-first so the menu reads as a ramp, matching how the shelf sorts.
  static func resolveSnoozePresets(now: Date, calendar: Calendar) -> [ResolvedPreset] {
    guard TaskTimestamps.read(now).date != nil else { return [] }
    let candidates: [(Preset, Date?)] = [
      (.oneHour, now.addingTimeInterval(60 * 60)),
      (.thisEvening, wallClock(hour: eveningHour, daysAhead: 0, from: now, calendar: calendar)),
      (.tomorrow, wallClock(hour: morningHour, daysAhead: 1, from: now, calendar: calendar)),
      (
        .nextWeek,
        wallClock(
          hour: morningHour,
          daysAhead: daysUntilComingMonday(from: now, calendar: calendar),
          from: now,
          calendar: calendar
        )
      ),
    ]
    return
      candidates
      .compactMap { preset, wakeAt in
        guard let wakeAt, wakeAt > now else { return nil }
        return ResolvedPreset(preset: preset, wakeAt: wakeAt)
      }
      .sorted { $0.wakeAt < $1.wakeAt }
  }

  /// Calendar-day arithmetic, not interval arithmetic: `now + 24h` lands on 7 AM
  /// or 9 AM across a DST transition, and the whole point of "tomorrow at 8" is
  /// the wall clock.
  private static func wallClock(
    hour: Int,
    daysAhead: Int,
    from now: Date,
    calendar: Calendar
  ) -> Date? {
    let startOfDay = calendar.startOfDay(for: now)
    guard let day = calendar.date(byAdding: .day, value: daysAhead, to: startOfDay) else {
      return nil
    }
    return calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day)
  }

  /// "The coming Monday", never "the start of the next calendar week" — the
  /// calendar's `firstWeekday` must not move it. Today never qualifies: a Monday
  /// resolving to this morning is a wake time already in the past.
  private static func daysUntilComingMonday(from now: Date, calendar: Calendar) -> Int {
    let weekday = calendar.component(.weekday, from: now)
    let delta = (7 + monday - weekday) % 7
    return delta == 0 ? 7 : delta
  }

  // MARK: - Display

  /// Switches on the calendar-day delta, not elapsed hours: 11 PM → 8 AM is nine
  /// hours but two days, and "in 9 hours" is not what a person reads off the row.
  /// Past seven days a weekday name is ambiguous ("Monday" — which one?), so the
  /// label falls back to a full date.
  static func snoozeWakeLabel(until: Date, now: Date, calendar: Calendar) -> WakeLabel {
    guard
      TaskTimestamps.read(until).date != nil,
      TaskTimestamps.read(now).date != nil,
      let dayDelta = calendar.dateComponents(
        [.day],
        from: calendar.startOfDay(for: now),
        to: calendar.startOfDay(for: until)
      ).day
    else { return .unknown }

    switch dayDelta {
    case 0: return .today(until)
    case 1: return .tomorrow(until)
    case 2...6: return .weekday(until)
    default: return .date(until)
    }
  }

  // MARK: - Placement

  /// Snooze beats pin because it is the more recent, more specific instruction
  /// ("not now" beats "always up top"), and both beat settled because settled is
  /// derived while these are explicit.
  static func placement(isSnoozed: Bool, isPinned: Bool, isSettled: Bool) -> Placement {
    if isSnoozed { return .snoozed }
    if isPinned { return .pinned }
    if isSettled { return .settled }
    return .active
  }
}

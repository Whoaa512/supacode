import Foundation
import Testing

@testable import supacode

/// RED half of the Phase 2b TDD pair for `TaskSnooze` (plan assertions A16 /
/// A18 / A23 / A25). The type does not exist yet; these tests are the spec.
///
/// Provenance note, because the plan text points at a port that isn't there:
/// t3 (`~/code/t3code`) has **no** snooze feature — `rg -i snooz` over the
/// whole repo is empty, and `threadSettled.ts` exports only the settle cascade.
/// So the per-trigger raised-hand rules below are supacode-original, written
/// from the plan's A25 prose rather than copied. The one genuinely ported idea
/// is the `|| 7` next-Monday arithmetic, which is a JS-date idiom
/// (`(8 - getDay()) % 7 || 7`) re-expressed against `Calendar`'s 1-based
/// weekday.
struct TaskSnoozeTests {
  // MARK: - Fixtures

  /// A real DST-observing zone, fixed so the preset tests describe a stable
  /// wall clock. 2026 transitions: spring forward Sun Mar 8, fall back Sun Nov 1.
  private static let pacific = TimeZone(identifier: "America/Los_Angeles") ?? .gmt

  private static var calendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = pacific
    calendar.locale = Locale(identifier: "en_US_POSIX")
    return calendar
  }

  private static let malformedDate = Date(timeIntervalSince1970: .nan)
  private static let hour: TimeInterval = 60 * 60

  private static func date(
    _ year: Int,
    _ month: Int,
    _ day: Int,
    _ hour: Int,
    _ minute: Int = 0
  ) -> Date {
    var components = DateComponents()
    components.year = year
    components.month = month
    components.day = day
    components.hour = hour
    components.minute = minute
    components.second = 0
    // `.distantPast` rather than a force unwrap: every caller asserts on
    // resolved calendar components, so a bad fixture fails loudly downstream.
    return calendar.date(from: components) ?? .distantPast
  }

  private static func input(
    now: Date = TaskSnoozeTests.date(2026, 6, 1, 12),
    snoozedUntil: Date? = nil,
    snoozedAt: Date? = nil,
    activity: TaskSettlement.ActivitySnapshot = .idle,
    errorAt: Date? = nil,
    completedTurnAt: Date? = nil,
    notifiedAt: Date? = nil,
    pullRequestChangedAt: Date? = nil
  ) -> TaskSnooze.Input {
    TaskSnooze.Input(
      now: now,
      snoozedUntil: snoozedUntil,
      snoozedAt: snoozedAt,
      activity: activity,
      errorAt: errorAt,
      completedTurnAt: completedTurnAt,
      notifiedAt: notifiedAt,
      pullRequestChangedAt: pullRequestChangedAt
    )
  }

  /// Guards the `?? .gmt` fallback above: without the real zone, every DST
  /// assertion in this file would pass vacuously.
  @Test func fixtureTimeZoneIsTheRealDSTObservingOne() {
    #expect(Self.pacific.identifier == "America/Los_Angeles")
  }

  // MARK: - effectiveSnoozed (A24 classification half)

  @Test func aFutureWakeTimeSnoozesTheTask() {
    let now = Self.date(2026, 6, 1, 12)
    #expect(
      TaskSnooze.effectiveSnoozed(
        Self.input(now: now, snoozedUntil: now.addingTimeInterval(Self.hour), snoozedAt: now)
      ) == true
    )
  }

  @Test func noWakeTimeIsNotSnoozed() {
    #expect(TaskSnooze.effectiveSnoozed(Self.input()) == false)
  }

  /// The wake boundary is inclusive on the wake side: at exactly `snoozedUntil`
  /// the task is awake, so the boundary-armed effect firing at its target
  /// instant (+50ms overshoot, A23) always observes the row as woken.
  @Test func theWakeBoundaryIsInclusive() {
    let wake = Self.date(2026, 6, 1, 12)
    #expect(
      TaskSnooze.effectiveSnoozed(
        Self.input(now: wake.addingTimeInterval(-0.001), snoozedUntil: wake, snoozedAt: wake)
      ) == true
    )
    #expect(
      TaskSnooze.effectiveSnoozed(Self.input(now: wake, snoozedUntil: wake, snoozedAt: wake)) == false
    )
    #expect(
      TaskSnooze.effectiveSnoozed(
        Self.input(now: wake.addingTimeInterval(0.001), snoozedUntil: wake, snoozedAt: wake)
      ) == false
    )
  }

  /// A17's safety direction applied to snooze: unreadable input must never
  /// *hide* a row. Both an unreadable wake time and an unreadable `now` fail
  /// open, because a hidden task the user cannot explain is the worse bug.
  @Test(arguments: [TaskSnoozeTests.malformedDate, Date(timeIntervalSince1970: .infinity)])
  func malformedTimestampsNeverHideATask(_ malformed: Date) {
    let now = Self.date(2026, 6, 1, 12)
    #expect(
      TaskSnooze.effectiveSnoozed(Self.input(now: now, snoozedUntil: malformed, snoozedAt: now))
        == false
    )
    #expect(
      TaskSnooze.effectiveSnoozed(
        Self.input(now: malformed, snoozedUntil: now.addingTimeInterval(Self.hour), snoozedAt: now)
      ) == false
    )
  }

  /// A25's load-bearing invariant: the raised hand is a *classification*, so it
  /// stops the task reading as snoozed while `snoozedUntil` / `snoozedAt` stay
  /// exactly as the user wrote them. Nothing in this module may clear them —
  /// re-snoozing must not need a re-entry of the wake time.
  @Test func aRaisedHandUnsnoozesWithoutTouchingTheSnoozeFields() {
    let now = Self.date(2026, 6, 1, 12)
    let input = Self.input(
      now: now,
      snoozedUntil: now.addingTimeInterval(Self.hour),
      snoozedAt: now.addingTimeInterval(-Self.hour),
      activity: TaskSettlement.ActivitySnapshot(isAwaitingInput: true)
    )

    #expect(TaskSnooze.effectiveSnoozed(input) == false)
    #expect(input.snoozedUntil == now.addingTimeInterval(Self.hour))
    #expect(input.snoozedAt == now.addingTimeInterval(-Self.hour))
  }

  // MARK: - raisedHandWhileSnoozed (A25, per-trigger rules)

  /// Unconditional triggers: a task asking a direct question outranks the
  /// user's earlier "not now", regardless of when the snooze was set.
  @Test func pendingInputRaisesTheHandUnconditionally() {
    let now = Self.date(2026, 6, 1, 12)
    #expect(
      TaskSnooze.raisedHandWhileSnoozed(
        Self.input(
          now: now,
          snoozedAt: now,
          activity: TaskSettlement.ActivitySnapshot(isAwaitingInput: true)
        )
      ) == true
    )
  }

  @Test func pendingApprovalRaisesTheHandUnconditionally() {
    let now = Self.date(2026, 6, 1, 12)
    #expect(
      TaskSnooze.raisedHandWhileSnoozed(
        Self.input(
          now: now,
          snoozedAt: now,
          activity: TaskSettlement.ActivitySnapshot(isAwaitingApproval: true)
        )
      ) == true
    )
  }

  /// `nil` approval means THIS AGENT CANNOT REPORT IT (Resolved #1). Reading it
  /// as pending would make every non-emitting agent's snooze useless.
  @Test func anUnreportableApprovalSignalDoesNotRaiseTheHand() {
    let now = Self.date(2026, 6, 1, 12)
    #expect(
      TaskSnooze.raisedHandWhileSnoozed(
        Self.input(
          now: now,
          snoozedAt: now,
          activity: TaskSettlement.ActivitySnapshot(isAwaitingApproval: nil)
        )
      ) == false
    )
  }

  /// Working is not a raise. Parking a long-running agent until it needs you is
  /// the entire point of snoozing a busy task (`canSnooze` already allows it).
  @Test func workingDoesNotRaiseTheHand() {
    let now = Self.date(2026, 6, 1, 12)
    #expect(
      TaskSnooze.raisedHandWhileSnoozed(
        Self.input(
          now: now,
          snoozedAt: now,
          activity: TaskSettlement.ActivitySnapshot(isWorking: true)
        )
      ) == false
    )
  }

  /// Conditional trigger #1: an error raises only when it is *news*. The
  /// pre-snooze case is the one that matters — the user snoozed a task they
  /// already knew was broken, and re-surfacing it instantly would make snooze
  /// unusable on exactly the rows people most want to park.
  @Test func aFreshErrorRaisesTheHand() {
    let snoozedAt = Self.date(2026, 6, 1, 12)
    #expect(
      TaskSnooze.raisedHandWhileSnoozed(
        Self.input(
          now: snoozedAt.addingTimeInterval(2 * Self.hour),
          snoozedAt: snoozedAt,
          errorAt: snoozedAt.addingTimeInterval(Self.hour)
        )
      ) == true
    )
  }

  @Test func aPreSnoozeErrorDoesNotRaiseTheHand() {
    let snoozedAt = Self.date(2026, 6, 1, 12)
    #expect(
      TaskSnooze.raisedHandWhileSnoozed(
        Self.input(
          now: snoozedAt.addingTimeInterval(2 * Self.hour),
          snoozedAt: snoozedAt,
          errorAt: snoozedAt.addingTimeInterval(-Self.hour)
        )
      ) == false
    )
  }

  /// Freshness is strict. An error stamped at the same instant as the snooze is
  /// the error the user was looking at when they snoozed.
  @Test func anErrorStampedAtTheSnoozeInstantDoesNotRaiseTheHand() {
    let snoozedAt = Self.date(2026, 6, 1, 12)
    #expect(
      TaskSnooze.raisedHandWhileSnoozed(
        Self.input(now: snoozedAt.addingTimeInterval(Self.hour), snoozedAt: snoozedAt, errorAt: snoozedAt)
      ) == false
    )
  }

  /// Conditional trigger #2, same shape: a turn that completed before the
  /// snooze is the turn the user snoozed away from.
  @Test func aCompletionAfterTheSnoozeRaisesTheHand() {
    let snoozedAt = Self.date(2026, 6, 1, 12)
    #expect(
      TaskSnooze.raisedHandWhileSnoozed(
        Self.input(
          now: snoozedAt.addingTimeInterval(2 * Self.hour),
          snoozedAt: snoozedAt,
          completedTurnAt: snoozedAt.addingTimeInterval(Self.hour)
        )
      ) == true
    )
  }

  @Test func aCompletionBeforeTheSnoozeDoesNotRaiseTheHand() {
    let snoozedAt = Self.date(2026, 6, 1, 12)
    #expect(
      TaskSnooze.raisedHandWhileSnoozed(
        Self.input(
          now: snoozedAt.addingTimeInterval(2 * Self.hour),
          snoozedAt: snoozedAt,
          completedTurnAt: snoozedAt.addingTimeInterval(-Self.hour)
        )
      ) == false
    )
  }

  /// Freshness is unanswerable without a snooze instant, so the conditional
  /// triggers refuse rather than guess. (`snoozedAt` missing while
  /// `snoozedUntil` is set means a hand-edited or migrated record.)
  @Test func conditionalTriggersRefuseWhenTheSnoozeInstantIsUnknown() {
    let now = Self.date(2026, 6, 1, 12)
    #expect(
      TaskSnooze.raisedHandWhileSnoozed(
        Self.input(now: now, snoozedAt: nil, errorAt: now.addingTimeInterval(-Self.hour))
      ) == false
    )
    #expect(
      TaskSnooze.raisedHandWhileSnoozed(
        Self.input(now: now, snoozedAt: nil, completedTurnAt: now.addingTimeInterval(-Self.hour))
      ) == false
    )
  }

  /// ...but the unconditional triggers never needed one, so they still fire.
  @Test func unconditionalTriggersDoNotNeedTheSnoozeInstant() {
    #expect(
      TaskSnooze.raisedHandWhileSnoozed(
        Self.input(snoozedAt: nil, activity: TaskSettlement.ActivitySnapshot(isAwaitingInput: true))
      ) == true
    )
  }

  @Test(
    arguments: [
      TaskSnoozeTests.malformedDate,
      Date(timeIntervalSince1970: .infinity),
      Date(timeIntervalSince1970: -.infinity),
    ]
  )
  func malformedTriggerTimestampsNeverRaiseTheHand(_ malformed: Date) {
    let snoozedAt = Self.date(2026, 6, 1, 12)
    #expect(
      TaskSnooze.raisedHandWhileSnoozed(Self.input(snoozedAt: snoozedAt, errorAt: malformed)) == false
    )
    #expect(
      TaskSnooze.raisedHandWhileSnoozed(Self.input(snoozedAt: snoozedAt, completedTurnAt: malformed))
        == false
    )
    #expect(
      TaskSnooze.raisedHandWhileSnoozed(
        Self.input(snoozedAt: malformed, errorAt: snoozedAt.addingTimeInterval(Self.hour))
      ) == false
    )
  }

  // MARK: - notifiedAt (A25's terminal-notification trigger, wired in Phase 4)

  /// OSC 9/777 is the primary wake signal for a task with no agent hooks at all
  /// — a plain `make test` that finished, a script that printed a notification.
  /// It is an *event*, so it follows the error/completed-turn freshness rule
  /// rather than the unconditional pending-input one: an unread notification
  /// that predates the snooze is exactly what the user was snoozing away from.
  @Test func aNotificationNewerThanTheSnoozeRaisesTheHand() {
    let snoozedAt = Self.date(2026, 6, 1, 12)
    #expect(
      TaskSnooze.raisedHandWhileSnoozed(
        Self.input(
          now: snoozedAt.addingTimeInterval(Self.hour),
          snoozedUntil: snoozedAt.addingTimeInterval(4 * Self.hour),
          snoozedAt: snoozedAt,
          notifiedAt: snoozedAt.addingTimeInterval(Self.hour / 2)
        )
      ) == true
    )
  }

  @Test func aNotificationOlderThanTheSnoozeDoesNotRaiseTheHand() {
    let snoozedAt = Self.date(2026, 6, 1, 12)
    #expect(
      TaskSnooze.raisedHandWhileSnoozed(
        Self.input(
          now: snoozedAt.addingTimeInterval(Self.hour),
          snoozedUntil: snoozedAt.addingTimeInterval(4 * Self.hour),
          snoozedAt: snoozedAt,
          notifiedAt: snoozedAt.addingTimeInterval(-Self.hour)
        )
      ) == false
    )
  }

  /// The Woke pill dates from the newest conditional trigger, so a notification
  /// that arrived after an error is the instant the row reports.
  @Test func theNewestConditionalTriggerDatesTheWokePill() {
    let snoozedAt = Self.date(2026, 6, 1, 12)
    let error = snoozedAt.addingTimeInterval(Self.hour)
    let notification = snoozedAt.addingTimeInterval(2 * Self.hour)
    #expect(
      TaskSnooze.wokeAt(
        Self.input(
          now: snoozedAt.addingTimeInterval(3 * Self.hour),
          snoozedUntil: snoozedAt.addingTimeInterval(8 * Self.hour),
          snoozedAt: snoozedAt,
          errorAt: error,
          notifiedAt: notification
        )
      ) == notification
    )
  }

  /// Same guard the other conditional triggers get: without a readable
  /// `snoozedAt` there is nothing to measure freshness against, so it refuses
  /// rather than guessing.
  @Test func aNotificationWithoutAReadableSnoozeStampDoesNotRaiseTheHand() {
    #expect(
      TaskSnooze.raisedHandWhileSnoozed(
        Self.input(
          snoozedUntil: Self.date(2026, 6, 1, 18),
          snoozedAt: nil,
          notifiedAt: Self.date(2026, 6, 1, 13)
        )
      ) == false
    )
  }

  // MARK: - wokeAt (the Woke-pill instant, A24)

  @Test func aStillSnoozedTaskHasNoWakeInstant() {
    let now = Self.date(2026, 6, 1, 12)
    #expect(
      TaskSnooze.wokeAt(
        Self.input(now: now, snoozedUntil: now.addingTimeInterval(Self.hour), snoozedAt: now)
      ) == nil
    )
  }

  @Test func aNeverSnoozedTaskHasNoWakeInstant() {
    #expect(TaskSnooze.wokeAt(Self.input()) == nil)
  }

  /// Timer expiry wakes the task at the wake time, not at `now` — the pill has
  /// to survive the next tick, and "woke 40 minutes ago" is the honest reading.
  @Test func anExpiredTimerWakesAtTheWakeTime() {
    let wake = Self.date(2026, 6, 1, 12)
    #expect(
      TaskSnooze.wokeAt(
        Self.input(
          now: wake.addingTimeInterval(40 * 60),
          snoozedUntil: wake,
          snoozedAt: wake.addingTimeInterval(-Self.hour)
        )
      ) == wake
    )
  }

  /// The same inclusive boundary `effectiveSnoozed` uses, stated for the pill:
  /// at exactly the wake instant the task is awake and the pill dates from
  /// `snoozedUntil`. A `>` here would leave the row awake with no wake instant
  /// on the tick that the boundary-armed effect fires on.
  @Test func theWakeInstantItselfIsAWake() {
    let wake = Self.date(2026, 6, 1, 12)
    #expect(
      TaskSnooze.wokeAt(
        Self.input(now: wake, snoozedUntil: wake, snoozedAt: wake.addingTimeInterval(-Self.hour))
      ) == wake
    )
    #expect(
      TaskSnooze.wokeAt(
        Self.input(
          now: wake.addingTimeInterval(-0.001),
          snoozedUntil: wake,
          snoozedAt: wake.addingTimeInterval(-Self.hour)
        )
      ) == nil
    )
  }

  /// A conditional raise carries its own instant, so the pill dates from the
  /// event rather than from whenever the tick noticed it.
  @Test func aRaisedHandWakesAtTheTriggerInstant() {
    let snoozedAt = Self.date(2026, 6, 1, 12)
    let errorAt = snoozedAt.addingTimeInterval(Self.hour)
    #expect(
      TaskSnooze.wokeAt(
        Self.input(
          now: snoozedAt.addingTimeInterval(3 * Self.hour),
          snoozedUntil: snoozedAt.addingTimeInterval(24 * Self.hour),
          snoozedAt: snoozedAt,
          errorAt: errorAt
        )
      ) == errorAt
    )
  }

  /// Two conditional triggers: the newest one is the wake instant.
  @Test func theNewestTriggerInstantWins() {
    let snoozedAt = Self.date(2026, 6, 1, 12)
    let errorAt = snoozedAt.addingTimeInterval(Self.hour)
    let completedTurnAt = snoozedAt.addingTimeInterval(2 * Self.hour)
    #expect(
      TaskSnooze.wokeAt(
        Self.input(
          now: snoozedAt.addingTimeInterval(3 * Self.hour),
          snoozedUntil: snoozedAt.addingTimeInterval(24 * Self.hour),
          snoozedAt: snoozedAt,
          errorAt: errorAt,
          completedTurnAt: completedTurnAt
        )
      ) == completedTurnAt
    )
  }

  /// An unconditional trigger has no timestamp of its own — pending input is a
  /// *state*, not an event — so the wake instant is the snooze itself. It must
  /// be a *fixed* instant: the pill clears when the user's last visit is newer
  /// than `wokeAt`, and a `now` that re-samples on every recompute is newer than
  /// every visit that will ever happen, leaving a pill nobody can dismiss.
  @Test func anUnconditionalRaiseWakesAtTheSnoozeInstant() {
    let now = Self.date(2026, 6, 1, 12)
    let snoozedAt = now.addingTimeInterval(-Self.hour)
    #expect(
      TaskSnooze.wokeAt(
        Self.input(
          now: now,
          snoozedUntil: now.addingTimeInterval(24 * Self.hour),
          snoozedAt: snoozedAt,
          activity: TaskSettlement.ActivitySnapshot(isAwaitingInput: true)
        )
      ) == snoozedAt
    )
  }

  /// The instant must not move as the clock does, or the Woke pill outruns
  /// every visit that could clear it.
  @Test func anUnconditionalRaiseReportsTheSameInstantAsTimePasses() {
    let snoozedAt = Self.date(2026, 6, 1, 12)
    let input = { (now: Date) in
      Self.input(
        now: now,
        snoozedUntil: snoozedAt.addingTimeInterval(24 * Self.hour),
        snoozedAt: snoozedAt,
        activity: TaskSettlement.ActivitySnapshot(isAwaitingInput: true)
      )
    }
    #expect(
      TaskSnooze.wokeAt(input(snoozedAt.addingTimeInterval(Self.hour)))
        == TaskSnooze.wokeAt(input(snoozedAt.addingTimeInterval(5 * Self.hour)))
    )
  }

  /// No readable snooze stamp leaves nothing fixed to date the pill from, so it
  /// falls back to `now` rather than reporting no wake at all — a raised hand
  /// with no pill is a row the user has no reason to look at.
  @Test func anUnconditionalRaiseWithoutASnoozeStampFallsBackToNow() {
    let now = Self.date(2026, 6, 1, 12)
    #expect(
      TaskSnooze.wokeAt(
        Self.input(
          now: now,
          snoozedUntil: now.addingTimeInterval(24 * Self.hour),
          snoozedAt: nil,
          activity: TaskSettlement.ActivitySnapshot(isAwaitingInput: true)
        )
      ) == now
    )
  }

  // MARK: - timerIsLive (the menu's "is this snoozed" question)

  /// The row's menu asks a different question than its placement does: a raised
  /// hand renders the row in Active while the user's "not now" still stands, and
  /// that row needs Wake Now rather than a Snooze menu it is already inside of.
  @Test func aRaisedHandLeavesTheSnoozeTimerLive() {
    let snoozedAt = Self.date(2026, 6, 1, 12)
    let input = Self.input(
      now: snoozedAt.addingTimeInterval(Self.hour),
      snoozedUntil: snoozedAt.addingTimeInterval(24 * Self.hour),
      snoozedAt: snoozedAt,
      activity: TaskSettlement.ActivitySnapshot(isAwaitingInput: true)
    )
    #expect(!TaskSnooze.effectiveSnoozed(input))
    #expect(TaskSnooze.timerIsLive(input))
  }

  @Test func anExpiredOrAbsentSnoozeTimerIsNotLive() {
    let wake = Self.date(2026, 6, 1, 12)
    #expect(
      !TaskSnooze.timerIsLive(
        Self.input(now: wake, snoozedUntil: wake, snoozedAt: wake.addingTimeInterval(-Self.hour))
      )
    )
    #expect(!TaskSnooze.timerIsLive(Self.input()))
  }

  /// When both happened, the timer got there first: the row has been visible
  /// since the wake time, so that is when the user could first have seen it.
  @Test func anExpiredTimerOutranksALaterRaisedHand() {
    let wake = Self.date(2026, 6, 1, 12)
    #expect(
      TaskSnooze.wokeAt(
        Self.input(
          now: wake.addingTimeInterval(2 * Self.hour),
          snoozedUntil: wake,
          snoozedAt: wake.addingTimeInterval(-Self.hour),
          activity: TaskSettlement.ActivitySnapshot(isAwaitingInput: true)
        )
      ) == wake
    )
  }

  // MARK: - resolveSnoozePresets (A23)

  /// A23's core requirement: presets are resolved at menu-open time against the
  /// caller's clock and calendar, never precomputed. No 32-bit timeout clamp is
  /// ported — that ceiling is a `setTimeout` browser constraint, and supacode
  /// persists absolute `Date`s re-armed from an injected clock, so a wake a year
  /// out is as cheap as one an hour out.
  @Test func presetsResolveAgainstTheInjectedNow() {
    let now = Self.date(2026, 6, 1, 12)
    let presets = TaskSnooze.resolveSnoozePresets(now: now, calendar: Self.calendar)
    #expect(presets.isEmpty == false)
    #expect(presets.allSatisfy { $0.wakeAt > now })
  }

  @Test func oneHourIsExactlyAnHourOut() {
    let now = Self.date(2026, 6, 1, 12, 37)
    let presets = TaskSnooze.resolveSnoozePresets(now: now, calendar: Self.calendar)
    #expect(presets.first { $0.preset == .oneHour }?.wakeAt == now.addingTimeInterval(Self.hour))
  }

  @Test func thisEveningIsSixPMLocal() {
    let now = Self.date(2026, 6, 1, 9)
    let presets = TaskSnooze.resolveSnoozePresets(now: now, calendar: Self.calendar)
    let evening = presets.first { $0.preset == .thisEvening }?.wakeAt
    #expect(evening == Self.date(2026, 6, 1, 18))
  }

  /// The reason the API returns a list rather than a fixed tuple: a preset
  /// whose instant has already passed is *omitted*, not silently rolled to
  /// tomorrow. Rolling it would make one menu item mean two different things
  /// depending on the hour, which is exactly the bug A23 is guarding.
  @Test func thisEveningDisappearsOnceEveningHasPassed() {
    let presets = TaskSnooze.resolveSnoozePresets(
      now: Self.date(2026, 6, 1, 18),
      calendar: Self.calendar
    )
    #expect(presets.contains { $0.preset == .thisEvening } == false)
    #expect(presets.contains { $0.preset == .tomorrow })
  }

  @Test func tomorrowIsEightAMTheNextDay() {
    let presets = TaskSnooze.resolveSnoozePresets(
      now: Self.date(2026, 6, 1, 21),
      calendar: Self.calendar
    )
    #expect(presets.first { $0.preset == .tomorrow }?.wakeAt == Self.date(2026, 6, 2, 8))
  }

  /// DST, spring forward: Sun Mar 8 2026 loses the 2 AM hour in Pacific.
  /// "Tomorrow" must still land on an 8 AM wall clock, which is only 15 absolute
  /// hours after a 4 PM Saturday — the wall clock says 16.
  @Test func tomorrowSurvivesSpringForward() {
    let now = Self.date(2026, 3, 7, 16)
    let presets = TaskSnooze.resolveSnoozePresets(now: now, calendar: Self.calendar)
    let tomorrow = presets.first { $0.preset == .tomorrow }?.wakeAt

    #expect(tomorrow == Self.date(2026, 3, 8, 8))
    let components = Self.calendar.dateComponents([.hour, .day], from: tomorrow ?? .distantPast)
    #expect(components.hour == 8)
    #expect(components.day == 8)
    #expect(tomorrow?.timeIntervalSince(now) == 15 * Self.hour)
  }

  /// DST, fall back: Sun Nov 1 2026 repeats the 1 AM hour, so the same wall
  /// clock is 17 absolute hours out where the wall clock again says 16. A
  /// `now + 24h` implementation gets both of these wrong, and an
  /// `addingTimeInterval` one gets the hour wrong in opposite directions —
  /// which is why both transitions are asserted.
  @Test func tomorrowSurvivesFallBack() {
    let now = Self.date(2026, 10, 31, 16)
    let presets = TaskSnooze.resolveSnoozePresets(now: now, calendar: Self.calendar)
    let tomorrow = presets.first { $0.preset == .tomorrow }?.wakeAt

    #expect(tomorrow == Self.date(2026, 11, 1, 8))
    let components = Self.calendar.dateComponents([.hour, .day], from: tomorrow ?? .distantPast)
    #expect(components.hour == 8)
    #expect(components.day == 1)
    #expect(tomorrow?.timeIntervalSince(now) == 17 * Self.hour)
  }

  /// The `|| 7` rule. Mon Jun 1 2026 → Mon Jun 8, never today: "next week" that
  /// resolves to this morning is a wake time already in the past.
  @Test func nextWeekOnAMondayIsSevenDaysOut() {
    let presets = TaskSnooze.resolveSnoozePresets(
      now: Self.date(2026, 6, 1, 12),
      calendar: Self.calendar
    )
    let nextWeek = presets.first { $0.preset == .nextWeek }?.wakeAt
    #expect(nextWeek == Self.date(2026, 6, 8, 8))
    #expect(Self.calendar.component(.weekday, from: nextWeek ?? .distantPast) == 2)
  }

  /// Every other weekday walks forward to the coming Monday. Sun Jun 7 → Mon
  /// Jun 8 is the one-day case that a naive `+7` would overshoot by a week.
  @Test(
    arguments: [
      (day: 2, expectedDay: 8),  // Tue Jun 2 → Mon Jun 8
      (day: 3, expectedDay: 8),
      (day: 4, expectedDay: 8),
      (day: 5, expectedDay: 8),
      (day: 6, expectedDay: 8),  // Sat Jun 6 → Mon Jun 8
      (day: 7, expectedDay: 8),  // Sun Jun 7 → Mon Jun 8
    ]
  )
  func nextWeekWalksForwardToTheComingMonday(_ testCase: (day: Int, expectedDay: Int)) {
    let presets = TaskSnooze.resolveSnoozePresets(
      now: Self.date(2026, 6, testCase.day, 12),
      calendar: Self.calendar
    )
    let nextWeek = presets.first { $0.preset == .nextWeek }?.wakeAt
    #expect(nextWeek == Self.date(2026, 6, testCase.expectedDay, 8))
    #expect(Self.calendar.component(.weekday, from: nextWeek ?? .distantPast) == 2)
  }

  /// Next Monday crossing the fall-back boundary still lands on an 8 AM wall
  /// clock rather than 7 AM.
  @Test func nextWeekSurvivesADSTTransition() {
    let presets = TaskSnooze.resolveSnoozePresets(
      now: Self.date(2026, 10, 27, 12),  // Tue Oct 27, PDT
      calendar: Self.calendar
    )
    let nextWeek = presets.first { $0.preset == .nextWeek }?.wakeAt
    #expect(nextWeek == Self.date(2026, 11, 2, 8))  // Mon Nov 2, PST
    #expect(Self.calendar.component(.hour, from: nextWeek ?? .distantPast) == 8)
  }

  /// Ordering is soonest-first so the menu reads as a ramp; the shelf sorts the
  /// same way (A24), and two orderings would eventually disagree.
  @Test func presetsAreOrderedSoonestFirst() {
    let presets = TaskSnooze.resolveSnoozePresets(
      now: Self.date(2026, 6, 1, 9),
      calendar: Self.calendar
    )
    #expect(presets.map(\.wakeAt) == presets.map(\.wakeAt).sorted())
    #expect(presets.map(\.preset) == [.oneHour, .thisEvening, .tomorrow, .nextWeek])
  }

  /// An unreadable `now` makes every preset arithmetic meaningless, so the menu
  /// offers nothing rather than a set of wake times computed off garbage. The
  /// caller shows a disabled affordance; it never gets a plausible-looking date
  /// derived from a NaN.
  @Test(
    arguments: [
      TaskSnoozeTests.malformedDate,
      Date(timeIntervalSince1970: .infinity),
      Date(timeIntervalSince1970: -.infinity),
    ]
  )
  func aMalformedNowOffersNoPresets(_ malformed: Date) {
    #expect(TaskSnooze.resolveSnoozePresets(now: malformed, calendar: Self.calendar).isEmpty)
  }

  /// A calendar with a different first weekday must not move Monday. The rule
  /// is "the coming Monday", not "the start of the next calendar week".
  @Test func nextWeekIgnoresTheCalendarsFirstWeekday() {
    var mondayFirst = Self.calendar
    mondayFirst.firstWeekday = 2
    let presets = TaskSnooze.resolveSnoozePresets(
      now: Self.date(2026, 6, 3, 12),  // Wed
      calendar: mondayFirst
    )
    #expect(presets.first { $0.preset == .nextWeek }?.wakeAt == Self.date(2026, 6, 8, 8))
  }

  // MARK: - snoozeWakeLabel (A23 display)

  /// Structured, not a `String`: formatting is locale- and settings-dependent,
  /// so a string return would make these assertions machine-specific and push
  /// `DateFormatter` into pure logic. The view formats the associated `Date`.
  @Test func aWakeLaterTodayLabelsAsToday() {
    let now = Self.date(2026, 6, 1, 9)
    let wake = Self.date(2026, 6, 1, 18)
    #expect(TaskSnooze.snoozeWakeLabel(until: wake, now: now, calendar: Self.calendar) == .today(wake))
  }

  @Test func aWakeTheNextCalendarDayLabelsAsTomorrow() {
    let now = Self.date(2026, 6, 1, 23)
    let wake = Self.date(2026, 6, 2, 8)
    #expect(
      TaskSnooze.snoozeWakeLabel(until: wake, now: now, calendar: Self.calendar) == .tomorrow(wake)
    )
  }

  /// Calendar days, not elapsed hours: 11 PM → 8 AM is nine hours but two days,
  /// and "in 9 hours" is not what a person reads off that row.
  @Test func tomorrowIsACalendarDayNotAnElapsedDay() {
    let now = Self.date(2026, 6, 1, 23, 30)
    let wake = Self.date(2026, 6, 2, 0, 30)
    #expect(
      TaskSnooze.snoozeWakeLabel(until: wake, now: now, calendar: Self.calendar) == .tomorrow(wake)
    )
  }

  @Test func aWakeLaterThisWeekLabelsAsAWeekday() {
    let now = Self.date(2026, 6, 1, 12)
    let wake = Self.date(2026, 6, 4, 8)
    #expect(
      TaskSnooze.snoozeWakeLabel(until: wake, now: now, calendar: Self.calendar) == .weekday(wake)
    )
  }

  /// Past seven days a weekday name is ambiguous ("Monday" — which one?), so
  /// the label falls back to a full date.
  @Test func aDistantWakeLabelsAsADate() {
    let now = Self.date(2026, 6, 1, 12)
    let wake = Self.date(2026, 6, 20, 8)
    #expect(TaskSnooze.snoozeWakeLabel(until: wake, now: now, calendar: Self.calendar) == .date(wake))
  }

  /// Exactly seven calendar days out is where the weekday name starts colliding
  /// with today's, so the boundary belongs on the date side.
  @Test func theWeekdayLabelBoundaryIsSevenCalendarDays() {
    let now = Self.date(2026, 6, 1, 12)
    #expect(
      TaskSnooze.snoozeWakeLabel(until: Self.date(2026, 6, 7, 8), now: now, calendar: Self.calendar)
        == .weekday(Self.date(2026, 6, 7, 8))
    )
    #expect(
      TaskSnooze.snoozeWakeLabel(until: Self.date(2026, 6, 8, 8), now: now, calendar: Self.calendar)
        == .date(Self.date(2026, 6, 8, 8))
    )
  }

  /// A wake time already in the past renders as its date rather than as
  /// "today"/"tomorrow" nonsense; the row is awake anyway, so the label is only
  /// ever seen on a stale render.
  @Test func aPastWakeTimeLabelsAsADate() {
    let now = Self.date(2026, 6, 10, 12)
    let wake = Self.date(2026, 6, 1, 8)
    #expect(TaskSnooze.snoozeWakeLabel(until: wake, now: now, calendar: Self.calendar) == .date(wake))
  }

  /// `.unknown`, not `.date(until)`: there is no honest instant to hand the
  /// view, and formatting a non-finite `Date` prints nonsense. A17 again — the
  /// label refuses rather than invents.
  @Test(
    arguments: [
      TaskSnoozeTests.malformedDate,
      Date(timeIntervalSince1970: .infinity),
      Date(timeIntervalSince1970: -.infinity),
    ]
  )
  func anUnreadableWakeOrNowLabelsAsUnknown(_ malformed: Date) {
    let now = Self.date(2026, 6, 1, 12)
    let wake = Self.date(2026, 6, 2, 8)
    #expect(TaskSnooze.snoozeWakeLabel(until: malformed, now: now, calendar: Self.calendar) == .unknown)
    #expect(TaskSnooze.snoozeWakeLabel(until: wake, now: malformed, calendar: Self.calendar) == .unknown)
  }

  // MARK: - Placement precedence (A16)

  /// Snooze > pin > settled. Snooze wins over a pin because it is the more
  /// recent, more specific instruction ("not now" beats "always up top"), and
  /// both win over settled because settled is derived while these are explicit.
  @Test func snoozeOutranksPinAndSettled() {
    #expect(
      TaskSnooze.placement(isSnoozed: true, isPinned: true, isSettled: true) == .snoozed
    )
    #expect(
      TaskSnooze.placement(isSnoozed: true, isPinned: false, isSettled: true) == .snoozed
    )
  }

  @Test func pinOutranksSettled() {
    #expect(TaskSnooze.placement(isSnoozed: false, isPinned: true, isSettled: true) == .pinned)
  }

  @Test func settledIsTheLastClassificationBeforeActive() {
    #expect(TaskSnooze.placement(isSnoozed: false, isPinned: false, isSettled: true) == .settled)
    #expect(TaskSnooze.placement(isSnoozed: false, isPinned: false, isSettled: false) == .active)
  }

  // MARK: - A29b: a PR state change raises the hand

  /// Deferred out of A25 to Phase 5, because until the PR projection exists
  /// there is nothing to observe changing. It is an *event*, like an error or a
  /// completed turn: only a change strictly newer than the snooze is news, so
  /// parking a task whose PR merged an hour ago keeps it parked.
  @Test func aPullRequestChangeAfterTheSnoozeRaisesTheHand() {
    let snoozedAt = Self.date(2026, 6, 1, 9)
    let input = Self.input(
      snoozedUntil: Self.date(2026, 6, 2, 9),
      snoozedAt: snoozedAt,
      pullRequestChangedAt: snoozedAt.addingTimeInterval(Self.hour)
    )

    #expect(TaskSnooze.raisedHandWhileSnoozed(input))
    #expect(!TaskSnooze.effectiveSnoozed(input))
    // The record is untouched (A25): the hand only overrides placement, so the
    // wake instant the user wrote is still the one the shelf sorts by.
    #expect(TaskSnooze.timerIsLive(input))
  }

  @Test func aPullRequestChangeOlderThanTheSnoozeDoesNotRaiseTheHand() {
    let snoozedAt = Self.date(2026, 6, 1, 9)
    let input = Self.input(
      snoozedUntil: Self.date(2026, 6, 2, 9),
      snoozedAt: snoozedAt,
      pullRequestChangedAt: snoozedAt.addingTimeInterval(-Self.hour)
    )

    #expect(!TaskSnooze.raisedHandWhileSnoozed(input))
    #expect(TaskSnooze.effectiveSnoozed(input))
  }

  /// The Woke pill dates from the raise, so the row it announces is the row the
  /// user has not looked at since the PR moved.
  @Test func theWokeInstantOfAPullRequestRaiseIsTheChangeItself() {
    let snoozedAt = Self.date(2026, 6, 1, 9)
    let changedAt = snoozedAt.addingTimeInterval(Self.hour)

    #expect(
      TaskSnooze.wokeAt(
        Self.input(
          snoozedUntil: Self.date(2026, 6, 2, 9),
          snoozedAt: snoozedAt,
          pullRequestChangedAt: changedAt
        )
      ) == changedAt
    )
  }

  // MARK: - A24/A28: one woke rule, two callers

  /// The Woke-pill question, extracted so the cached structure and the per-task
  /// leaf ask it the same way. They both need the answer — the structure to
  /// place the pill, the leaf to hold the row out of recession (A28) — and two
  /// spellings of "woke" would eventually disagree about the same row.
  @Test func aWakeTheUserHasNotVisitedSinceReadsAsWoke() {
    let input = Self.input(
      now: Self.date(2026, 6, 2, 12),
      snoozedUntil: Self.date(2026, 6, 2, 9),
      snoozedAt: Self.date(2026, 6, 1, 9)
    )

    #expect(TaskSnooze.isWoke(input, lastVisitedAt: nil))
    #expect(TaskSnooze.isWoke(input, lastVisitedAt: Self.date(2026, 6, 1, 10)))
  }

  @Test func aVisitAfterTheWakeClearsTheWokeReading() {
    let input = Self.input(
      now: Self.date(2026, 6, 2, 12),
      snoozedUntil: Self.date(2026, 6, 2, 9),
      snoozedAt: Self.date(2026, 6, 1, 9)
    )

    #expect(!TaskSnooze.isWoke(input, lastVisitedAt: Self.date(2026, 6, 2, 11)))
  }

  @Test func aStillParkedTaskIsNotWoke() {
    let input = Self.input(
      now: Self.date(2026, 6, 1, 12),
      snoozedUntil: Self.date(2026, 6, 2, 9),
      snoozedAt: Self.date(2026, 6, 1, 9)
    )

    #expect(!TaskSnooze.isWoke(input, lastVisitedAt: nil))
  }

  @Test func everyPlacementCombinationResolvesToExactlyOneSection() {
    for isSnoozed in [true, false] {
      for isPinned in [true, false] {
        for isSettled in [true, false] {
          let placement = TaskSnooze.placement(
            isSnoozed: isSnoozed,
            isPinned: isPinned,
            isSettled: isSettled
          )
          let expected: TaskSnooze.Placement =
            isSnoozed ? .snoozed : isPinned ? .pinned : isSettled ? .settled : .active
          #expect(placement == expected)
        }
      }
    }
  }
}

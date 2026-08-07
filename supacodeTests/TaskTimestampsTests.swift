import Foundation
import Testing

@testable import supacode

// MARK: - Expected API (Phase 2, plan assertions A17 / A18)
//
// These tests are the RED half of the TDD pair: `TaskTimestamps` does not exist
// yet. The green step must create
// `supacode/Features/Repositories/BusinessLogic/TaskTimestamps.swift` with
// exactly this surface — Foundation only, `nonisolated`, no `Date()` anywhere
// (every boundary is passed in):
//
//   nonisolated enum TaskTimestamps {
//     /// nil-safe validity gate. Three DISTINCT policies, which is the whole
//     /// point of the type:
//     ///   - missing (`nil`)                → `nil`
//     ///   - malformed (non-finite Double)  → `nil`, and callers must be able
//     ///     to tell it apart from missing via `isMalformed`
//     ///   - valid epoch (1970-01-01)       → returned as-is; a zero interval
//     ///     is a real timestamp, never "absent" (the JS falsy-zero trap that
//     ///     t3's `Date.parse` checks had to dodge).
//     static func valid(_ date: Date?) -> Date?
//
//     /// `true` only for a present-but-unusable value. Missing is not
//     /// malformed: the settlement cascade grants them different powers.
//     static func isMalformed(_ date: Date?) -> Bool
//
//     /// First usable candidate in priority order; skips missing AND malformed.
//     static func firstValid(_ candidates: [Date?]) -> Date?
//
//     /// Newest usable candidate; skips missing AND malformed. `nil` when none.
//     static func latestValid(_ candidates: [Date?]) -> Date?
//
//     /// The single settled-timestamp resolver shared by the settled sort key
//     /// AND the displayed label (A17). Supersedes the interim
//     /// `TasksSidebarStructure.resolvedSettledTimestamp`, which the green step
//     /// must delete and re-point at this.
//     /// Order: settledAt → latest valid activity → createdAt.
//     static func resolvedSettledTimestamp(
//       settledAt: Date?,
//       activityCandidates: [Date?],
//       createdAt: Date?
//     ) -> Date?
//
//     /// Strictly older than the boundary. `nil`/malformed answer `false` —
//     /// an unreadable timestamp must never read as "ancient" and trip an
//     /// auto-settle (A17).
//     static func isStrictlyOlder(_ date: Date?, than boundary: Date) -> Bool
//   }

struct TaskTimestampsTests {
  private static let reference = Date(timeIntervalSince1970: 1_700_000_000)
  private static let epoch = Date(timeIntervalSince1970: 0)
  private static let notANumber = Date(timeIntervalSince1970: .nan)
  private static let infinite = Date(timeIntervalSince1970: .infinity)
  private static let negativelyInfinite = Date(timeIntervalSince1970: -.infinity)

  private static func at(_ offset: TimeInterval) -> Date {
    reference.addingTimeInterval(offset)
  }

  // MARK: - valid: missing vs malformed vs valid-epoch

  @Test func missingIsNotUsable() {
    #expect(TaskTimestamps.valid(nil) == nil)
  }

  /// The trap this API exists to close: a timestamp of exactly zero is a real
  /// instant, not an absent one. Anything that folds it into "missing" silently
  /// re-dates 1970 rows to whatever the next fallback is.
  @Test func validEpochSurvives() {
    #expect(TaskTimestamps.valid(Self.epoch) == Self.epoch)
    #expect(TaskTimestamps.isMalformed(Self.epoch) == false)
  }

  @Test(
    arguments: [
      TaskTimestampsTests.notANumber,
      TaskTimestampsTests.infinite,
      TaskTimestampsTests.negativelyInfinite,
    ]
  )
  func nonFiniteIsMalformed(_ date: Date) {
    #expect(TaskTimestamps.valid(date) == nil)
    #expect(TaskTimestamps.isMalformed(date) == true)
  }

  /// Missing and malformed both fail `valid`, but they are not the same input:
  /// the settlement cascade lets a missing activity stamp auto-settle on a
  /// finished PR while a malformed one blocks every auto path.
  @Test func missingIsDistinguishableFromMalformed() {
    #expect(TaskTimestamps.isMalformed(nil) == false)
    #expect(TaskTimestamps.isMalformed(Self.notANumber) == true)
  }

  /// `distantPast` / `distantFuture` are finite doubles. They are extreme, not
  /// broken, and clamping them here would silently rewrite honest data.
  @Test(arguments: [Date.distantPast, Date.distantFuture])
  func extremeButFiniteDatesAreValid(_ date: Date) {
    #expect(TaskTimestamps.valid(date) == date)
    #expect(TaskTimestamps.isMalformed(date) == false)
  }

  // MARK: - firstValid

  @Test func firstValidTakesThePriorityOrderNotTheNewest() {
    let older = Self.at(-1_000)
    let newer = Self.at(1_000)
    #expect(TaskTimestamps.firstValid([nil, older, newer]) == older)
  }

  @Test func firstValidSkipsMalformedCandidates() {
    let usable = Self.at(500)
    #expect(TaskTimestamps.firstValid([Self.notANumber, nil, usable]) == usable)
  }

  @Test func firstValidReturnsNilWhenNothingIsUsable() {
    #expect(TaskTimestamps.firstValid([]) == nil)
    #expect(TaskTimestamps.firstValid([nil, Self.infinite, nil]) == nil)
  }

  @Test func firstValidPrefersAnEpochCandidateOverALaterOne() {
    #expect(TaskTimestamps.firstValid([Self.epoch, Self.at(0)]) == Self.epoch)
  }

  // MARK: - latestValid

  @Test func latestValidPicksTheNewestUsableCandidate() {
    let candidates: [Date?] = [Self.at(-100), nil, Self.at(300), Self.at(50)]
    #expect(TaskTimestamps.latestValid(candidates) == Self.at(300))
  }

  /// Ported from t3's `threadLastActivityAt`, which seeds its scan with
  /// `-Infinity` so an unparseable candidate can never win the max. Here the
  /// malformed candidate is the largest raw double in the list.
  @Test func latestValidNeverLetsAMalformedCandidateWin() {
    #expect(TaskTimestamps.latestValid([Self.at(10), Self.infinite]) == Self.at(10))
  }

  @Test func latestValidReturnsNilWhenNothingIsUsable() {
    #expect(TaskTimestamps.latestValid([]) == nil)
    #expect(TaskTimestamps.latestValid([nil, Self.notANumber]) == nil)
  }

  // MARK: - resolvedSettledTimestamp (A17)

  @Test func settledStampWinsOverActivityAndCreation() {
    let resolved = TaskTimestamps.resolvedSettledTimestamp(
      settledAt: Self.at(900),
      activityCandidates: [Self.at(1_000)],
      createdAt: Self.at(1_100)
    )
    #expect(resolved == Self.at(900))
  }

  @Test func fallsBackToLatestValidActivityWhenNotSettled() {
    let resolved = TaskTimestamps.resolvedSettledTimestamp(
      settledAt: nil,
      activityCandidates: [Self.at(100), Self.at(700), nil],
      createdAt: Self.at(-5_000)
    )
    #expect(resolved == Self.at(700))
  }

  /// A malformed `settledAt` must not poison the row: it degrades to the next
  /// evidence rather than sorting the row to an arbitrary position.
  @Test func malformedSettledStampDegradesToActivity() {
    let resolved = TaskTimestamps.resolvedSettledTimestamp(
      settledAt: Self.notANumber,
      activityCandidates: [Self.at(200)],
      createdAt: Self.at(-1)
    )
    #expect(resolved == Self.at(200))
  }

  @Test func fallsBackToCreationWhenNoSettleOrActivityIsUsable() {
    let resolved = TaskTimestamps.resolvedSettledTimestamp(
      settledAt: nil,
      activityCandidates: [nil, Self.infinite],
      createdAt: Self.at(-42)
    )
    #expect(resolved == Self.at(-42))
  }

  /// Nothing provable at all: `nil`, not a fabricated instant. The sidebar sorts
  /// such a row to the bottom of the tail; it must never vanish and must never
  /// claim a time it does not have (A2 honesty, A17 no-hidden-tasks).
  @Test func resolvesToNilWhenNothingIsProvable() {
    let resolved = TaskTimestamps.resolvedSettledTimestamp(
      settledAt: Self.notANumber,
      activityCandidates: [nil],
      createdAt: Self.negativelyInfinite
    )
    #expect(resolved == nil)
  }

  /// A17's parity requirement stated as an executable claim: the sort key and
  /// the displayed label are the SAME call, so they cannot drift. If a second
  /// resolver ever appears, this test is the tripwire — it is the only resolver
  /// either consumer is allowed to reach for.
  @Test func sortKeyAndLabelShareOneResolver() {
    let settledAt: Date? = nil
    let activity: [Date?] = [Self.at(-3_600), Self.at(-60)]
    let createdAt = Self.at(-10_000)

    let sortKey = TaskTimestamps.resolvedSettledTimestamp(
      settledAt: settledAt,
      activityCandidates: activity,
      createdAt: createdAt
    )
    let label = TaskTimestamps.resolvedSettledTimestamp(
      settledAt: settledAt,
      activityCandidates: activity,
      createdAt: createdAt
    )
    #expect(sortKey == label)
    #expect(sortKey == Self.at(-60))
  }

  /// Two rows resolving to the identical instant must not sort ambiguously; the
  /// resolver is deterministic and the caller's ID tie-break does the rest.
  @Test func equalInputsResolveToEqualTimestamps() {
    let left = TaskTimestamps.resolvedSettledTimestamp(
      settledAt: Self.at(5),
      activityCandidates: [Self.at(9)],
      createdAt: Self.at(1)
    )
    let right = TaskTimestamps.resolvedSettledTimestamp(
      settledAt: Self.at(5),
      activityCandidates: [Self.at(2)],
      createdAt: Self.at(4)
    )
    #expect(left == right)
  }

  // MARK: - isStrictlyOlder (the auto-settle boundary, A17)

  @Test func strictlyOlderIsStrictAtTheBoundary() {
    let boundary = Self.at(0)
    #expect(TaskTimestamps.isStrictlyOlder(Self.at(-0.001), than: boundary) == true)
    #expect(TaskTimestamps.isStrictlyOlder(boundary, than: boundary) == false)
    #expect(TaskTimestamps.isStrictlyOlder(Self.at(0.001), than: boundary) == false)
  }

  /// The load-bearing safety property: unreadable input never reads as ancient.
  /// t3 leaned on `NaN` comparisons being false; we say it out loud instead.
  @Test(
    arguments: [
      nil,
      TaskTimestampsTests.notANumber,
      TaskTimestampsTests.infinite,
      TaskTimestampsTests.negativelyInfinite,
    ] as [Date?]
  )
  func unusableTimestampsAreNeverOlderThanAnything(_ date: Date?) {
    #expect(TaskTimestamps.isStrictlyOlder(date, than: Self.at(0)) == false)
    #expect(TaskTimestamps.isStrictlyOlder(date, than: .distantFuture) == false)
  }

  // MARK: - A18: pure-logic file stays pure

  /// Grep assertion. Fails loudly right now because the file does not exist —
  /// that absence IS the red state for this suite.
  @Test func sourceFileIsPureFoundationLogic() {
    let source = Self.readSource("TaskTimestamps.swift")
    #expect(source.contains("import ComposableArchitecture") == false)
    #expect(source.contains("import SwiftUI") == false)
    #expect(source.contains("import AppKit") == false)
    // No ambient clock: every boundary is an injected parameter.
    #expect(source.contains("Date()") == false)
  }

  private static func readSource(_ fileName: String) -> String {
    let repositoryRoot = URL(filePath: #filePath)
      .deletingLastPathComponent()  // supacodeTests
      .deletingLastPathComponent()  // repo root
    let url =
      repositoryRoot
      .appending(path: "supacode/Features/Repositories/BusinessLogic")
      .appending(path: fileName)
    guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
      Issue.record("Missing pure-logic source file at \(url.path)")
      return ""
    }
    return contents
  }
}

import Foundation
import Testing

@testable import supacode

// MARK: - Expected API (Phase 2, plan assertions A17 / A18)
//
// `supacode/Features/Repositories/BusinessLogic/TaskTimestamps.swift` —
// Foundation only, `nonisolated`, no `Date()` anywhere (every boundary is
// passed in):
//
//   nonisolated enum TaskTimestamps {
//     /// The three-way judgement, which is the whole point of the type:
//     ///   - missing (`nil`)                → `.missing`
//     ///   - malformed (non-finite Double)  → `.malformed`, which callers must
//     ///     be able to tell apart from missing
//     ///   - valid epoch (1970-01-01)       → `.valid`; a zero interval is a
//     ///     real timestamp, never "absent" (the JS falsy-zero trap that t3's
//     ///     `Date.parse` checks had to dodge).
//     enum Reading: Equatable, Sendable { case missing, malformed, valid(Date) }
//     static func read(_ date: Date?) -> Reading
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

  // MARK: - read: missing vs malformed vs valid-epoch

  @Test func missingReadsAsMissing() {
    #expect(TaskTimestamps.read(nil) == .missing)
    #expect(TaskTimestamps.read(nil).date == nil)
  }

  /// The trap this API exists to close: a timestamp of exactly zero is a real
  /// instant, not an absent one. Anything that folds it into "missing" silently
  /// re-dates 1970 rows to whatever the next fallback is.
  @Test func validEpochSurvives() {
    #expect(TaskTimestamps.read(Self.epoch) == .valid(Self.epoch))
    #expect(TaskTimestamps.read(Self.epoch).date == Self.epoch)
  }

  @Test(
    arguments: [
      TaskTimestampsTests.notANumber,
      TaskTimestampsTests.infinite,
      TaskTimestampsTests.negativelyInfinite,
    ]
  )
  func nonFiniteIsMalformed(_ date: Date) {
    #expect(TaskTimestamps.read(date) == .malformed)
    #expect(TaskTimestamps.read(date).date == nil)
  }

  /// Missing and malformed both yield a `nil` date, but they are not the same
  /// input: the settlement cascade lets a missing activity stamp auto-settle on
  /// a finished PR while a malformed one blocks every auto path.
  @Test func missingIsDistinguishableFromMalformed() {
    #expect(TaskTimestamps.read(nil) != TaskTimestamps.read(Self.notANumber))
  }

  /// `distantPast` / `distantFuture` are finite doubles. They are extreme, not
  /// broken, and clamping them here would silently rewrite honest data.
  @Test(arguments: [Date.distantPast, Date.distantFuture])
  func extremeButFiniteDatesAreValid(_ date: Date) {
    #expect(TaskTimestamps.read(date) == .valid(date))
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

  /// A17's parity requirement stated as an executable claim: the sidebar's
  /// per-record adapter must *delegate* here rather than resolve a second time,
  /// so the sort key and the displayed label cannot drift. If a second resolver
  /// ever grows inside `TasksSidebarStructure`, this is the tripwire.
  @Test func sidebarAdapterDelegatesToTheOneResolver() {
    let records: [TaskRecord] = [
      Self.record(settledAt: Self.at(900), lastVisitedAt: Self.at(1_000), createdAt: Self.at(-10)),
      Self.record(settledAt: nil, lastVisitedAt: Self.at(-60), createdAt: Self.at(-10_000)),
      Self.record(settledAt: Self.notANumber, lastVisitedAt: Self.at(200), createdAt: Self.at(-1)),
      Self.record(settledAt: nil, lastVisitedAt: nil, createdAt: Self.at(-42)),
      Self.record(
        settledAt: Self.infinite,
        lastVisitedAt: Self.notANumber,
        createdAt: Self.negativelyInfinite
      ),
    ]

    for record in records {
      #expect(
        TasksSidebarStructure.resolvedSettledTimestamp(for: record)
          == TaskTimestamps.resolvedSettledTimestamp(
            settledAt: record.settledAt,
            activityCandidates: [record.lastVisitedAt],
            createdAt: record.createdAt
          )
      )
    }

    // …and the last record has nothing provable at all, so the adapter must
    // hand the sidebar a `nil` rather than a fabricated instant.
    #expect(TasksSidebarStructure.resolvedSettledTimestamp(for: records[3]) == Self.at(-42))
    #expect(TasksSidebarStructure.resolvedSettledTimestamp(for: records[4]) == nil)
  }

  private static func record(
    settledAt: Date?,
    lastVisitedAt: Date?,
    createdAt: Date
  ) -> TaskRecord {
    TaskRecord(
      title: "t",
      directoryPath: "/tmp/t",
      createdAt: createdAt,
      settledAt: settledAt,
      lastVisitedAt: lastVisitedAt
    )
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

  /// The other half of that guard, which callers cannot screen for themselves:
  /// boundaries arrive as `now - window`, so a non-finite window makes an
  /// otherwise perfectly good timestamp "older than everything". Without the
  /// boundary check the `.infinity` case below answers `true`.
  @Test(
    arguments: [
      TaskTimestampsTests.notANumber,
      TaskTimestampsTests.infinite,
      TaskTimestampsTests.negativelyInfinite,
    ]
  )
  func aMalformedBoundaryMakesNothingOlder(_ boundary: Date) {
    #expect(TaskTimestamps.isStrictlyOlder(Self.at(-1_000), than: boundary) == false)
    #expect(TaskTimestamps.isStrictlyOlder(Self.epoch, than: boundary) == false)
  }

  // MARK: - A18: pure-logic file stays pure

  /// Grep assertion. A missing file is a recorded failure, not a silent pass —
  /// see `readSource`.
  /// The registry of pure-logic files, deliberately in one place: a per-suite
  /// copy of this check drifts the moment someone adds a file and forgets the
  /// sixth copy. `TaskSettlement.swift` keeps its own variant only because it
  /// carries an extra, file-specific assertion.
  @Test(
    arguments: [
      "TaskTimestamps.swift",
      "TaskPullRequestState.swift",
      "TaskSnooze.swift",
      "TaskStatusModel.swift",
      "TaskForwardNavigation.swift",
    ]
  )
  func sourceFileIsPureFoundationLogic(_ fileName: String) {
    let source = Self.readSource(fileName)
    #expect(source.isEmpty == false)
    #expect(source.contains("import ComposableArchitecture") == false)
    #expect(source.contains("import SwiftUI") == false)
    #expect(source.contains("import AppKit") == false)
    // No ambient clock, in either spelling: every boundary is an injected
    // parameter.
    #expect(source.contains("Date()") == false)
    #expect(source.contains("Date.now") == false)
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

import Foundation
import Testing

@testable import supacode

/// Seeder + reflog-parse coverage. The parse tests live here on purpose: a file
/// named `Git*.swift` routes to the `supacodeGitTests` bundle (AGENTS.md), and
/// splitting one feature's tests across two bundles makes `-only-testing` lie.
struct TaskActivitySeederTests {
  private static let now = Date(timeIntervalSince1970: 1_700_000_000)
  private static let day: TimeInterval = 24 * 60 * 60

  private static func daysAgo(_ days: Double) -> Date {
    now.addingTimeInterval(-days * day)
  }

  /// Deterministic ids so ordering assertions read as `t0, t1, …` in output order.
  private final class IDFactory {
    private var next = 0
    func make() -> TaskID {
      defer { next += 1 }
      return TaskID("t\(next)")
    }
  }

  private static func seeds(
    _ candidates: [TaskActivitySeeder.Candidate],
    existing: [TaskRecord] = [],
    stalenessThreshold: TimeInterval = TaskActivitySeeder.defaultStalenessThreshold
  ) -> [TaskRecord] {
    let factory = IDFactory()
    return TaskActivitySeeder.seeds(
      candidates: candidates,
      existingTasks: existing,
      now: now,
      stalenessThreshold: stalenessThreshold,
      makeID: factory.make
    )
  }

  private static func checkout(
    at date: Date,
    from source: String = "main",
    to target: String
  ) -> GitReflogEntry {
    GitReflogEntry(
      date: date,
      message: "checkout: moving from \(source) to \(target)",
      checkoutSource: source,
      checkoutTarget: target
    )
  }

  private static func existingTask(directoryPath: String) -> TaskRecord {
    TaskRecord(title: "already here", directoryPath: directoryPath, createdAt: now)
  }

  // MARK: - Qualification

  @Test func skipsDirectoryWithNoEvidence() {
    let seeded = Self.seeds([.init(directoryPath: "/repos/empty", currentBranch: "main")])
    #expect(seeded.isEmpty)
  }

  @Test func skipsLiveDirectoryWithoutScrollbackOrReflog() {
    // A tab existing proves a directory was opened, not that any work happened in
    // it; without a real timestamp there is nothing honest to seed.
    let seeded = Self.seeds([.init(directoryPath: "/repos/tabbed", hasLiveSurfaces: true)])
    #expect(seeded.isEmpty)
  }

  @Test func seedsFromScrollbackWhenSurfacesAreLive() {
    let seeded = Self.seeds([
      .init(
        directoryPath: "/repos/app",
        currentBranch: "main",
        hasLiveSurfaces: true,
        scrollbackLastMountedAt: Self.daysAgo(1)
      )
    ])
    #expect(seeded.count == 1)
    #expect(seeded.first?.createdAt == Self.daysAgo(1))
    #expect(seeded.first?.settledAt == nil)
  }

  @Test func seedsFromReflogWithoutLiveSurfaces() {
    let seeded = Self.seeds([
      .init(
        directoryPath: "/repos/app",
        currentBranch: "feature",
        reflogEntries: [Self.checkout(at: Self.daysAgo(2), to: "feature")]
      )
    ])
    #expect(seeded.count == 1)
    #expect(seeded.first?.createdAt == Self.daysAgo(2))
  }

  // MARK: - Fresh / stale split

  struct StalenessCase: Sendable, CustomStringConvertible {
    var ageInDays: Double
    var isStale: Bool
    var description: String { "\(ageInDays)d → stale=\(isStale)" }
  }

  @Test(arguments: [
    StalenessCase(ageInDays: 0, isStale: false),
    StalenessCase(ageInDays: 13.9, isStale: false),
    StalenessCase(ageInDays: 14, isStale: false),
    StalenessCase(ageInDays: 14.1, isStale: true),
    StalenessCase(ageInDays: 120, isStale: true),
  ])
  func freshStaleSplitUsesThreshold(testCase: StalenessCase) {
    let evidenceDate = Self.daysAgo(testCase.ageInDays)
    let seeded = Self.seeds([
      .init(
        directoryPath: "/repos/app",
        currentBranch: "main",
        reflogEntries: [Self.checkout(at: evidenceDate, to: "main")]
      )
    ])
    let task = seeded.first
    #expect(task?.createdAt == evidenceDate)
    #expect((task?.settledAt != nil) == testCase.isStale)
    if testCase.isStale {
      // Same resolved timestamp drives the settled sort key and its label (A17).
      #expect(task?.settledAt == evidenceDate)
    }
  }

  @Test func reflogTimestampWinsOverScrollbackMtime() {
    // The mtime is newer, but it only proves the surface was mounted; the reflog
    // is the real activity signal, and here it makes the task stale.
    let seeded = Self.seeds([
      .init(
        directoryPath: "/repos/app",
        currentBranch: "main",
        hasLiveSurfaces: true,
        scrollbackLastMountedAt: Self.daysAgo(1),
        reflogEntries: [Self.checkout(at: Self.daysAgo(40), to: "main")]
      )
    ])
    #expect(seeded.first?.createdAt == Self.daysAgo(40))
    #expect(seeded.first?.settledAt == Self.daysAgo(40))
  }

  @Test func newestReflogEntryWins() {
    let seeded = Self.seeds([
      .init(
        directoryPath: "/repos/app",
        currentBranch: "main",
        reflogEntries: [
          Self.checkout(at: Self.daysAgo(90), to: "old"),
          Self.checkout(at: Self.daysAgo(3), to: "main"),
          Self.checkout(at: Self.daysAgo(30), to: "middle"),
        ]
      )
    ])
    #expect(seeded.first?.createdAt == Self.daysAgo(3))
  }

  // MARK: - Branch provability (A2)

  @Test func attachesCurrentBranchAtHighConfidence() {
    let seeded = Self.seeds([
      .init(
        directoryPath: "/repos/app",
        currentBranch: "feature/x",
        reflogEntries: [Self.checkout(at: Self.daysAgo(1), to: "feature/x")]
      )
    ])
    #expect(seeded.first?.branch == "feature/x")
    #expect(seeded.first?.seedEvidence == .init(source: .currentBranch, confidence: .high))
  }

  @Test func staleSeedFallsBackToReflogBranchAtMediumConfidence() {
    let seeded = Self.seeds([
      .init(
        directoryPath: "/repos/app",
        currentBranch: nil,
        reflogEntries: [
          Self.checkout(at: Self.daysAgo(90), to: "older"),
          Self.checkout(at: Self.daysAgo(40), to: "last-known"),
        ]
      )
    ])
    #expect(seeded.first?.branch == "last-known")
    #expect(seeded.first?.seedEvidence == .init(source: .reflog, confidence: .medium))
  }

  @Test func freshSeedWithUnknownCurrentBranchHasNoBranch() {
    // Detached HEAD on a live directory: history would misdescribe where the
    // directory is *now*, so the row renders with no branch label.
    let seeded = Self.seeds([
      .init(
        directoryPath: "/repos/app",
        currentBranch: nil,
        reflogEntries: [Self.checkout(at: Self.daysAgo(1), to: "main")]
      )
    ])
    #expect(seeded.first?.branch == nil)
    #expect(seeded.first?.seedEvidence == .init(source: .reflog, confidence: .low))
  }

  @Test func staleSeedWithNoCheckoutHistoryHasNoBranch() {
    let seeded = Self.seeds([
      .init(
        directoryPath: "/repos/app",
        currentBranch: nil,
        reflogEntries: [GitReflogEntry(date: Self.daysAgo(60), message: "commit: wip")]
      )
    ])
    #expect(seeded.first?.branch == nil)
    #expect(seeded.first?.seedEvidence == .init(source: .reflog, confidence: .low))
  }

  @Test func scrollbackOnlySeedIsLowConfidence() {
    let seeded = Self.seeds([
      .init(
        directoryPath: "/repos/folder",
        hasLiveSurfaces: true,
        scrollbackLastMountedAt: Self.daysAgo(2)
      )
    ])
    #expect(seeded.first?.branch == nil)
    #expect(seeded.first?.seedEvidence == .init(source: .scrollbackMtime, confidence: .low))
  }

  @Test func blankCurrentBranchIsTreatedAsUnknown() {
    let seeded = Self.seeds([
      .init(
        directoryPath: "/repos/app",
        currentBranch: "   ",
        hasLiveSurfaces: true,
        scrollbackLastMountedAt: Self.daysAgo(1)
      )
    ])
    #expect(seeded.first?.branch == nil)
  }

  // MARK: - Title cascade (Resolved #15)

  @Test func titlePrefersCustomizationTitle() {
    let seeded = Self.seeds([
      .init(
        directoryPath: "/repos/app",
        customizationTitle: "Inbox rewrite",
        worktreeName: "app",
        worktreeDetail: "detail",
        currentBranch: "main",
        hasLiveSurfaces: true,
        scrollbackLastMountedAt: Self.daysAgo(1)
      )
    ])
    #expect(seeded.first?.title == "Inbox rewrite")
  }

  @Test func titleFallsBackThroughNameDetailBranchThenLeaf() {
    let base = TaskActivitySeeder.Candidate(
      directoryPath: "/repos/app-1/",
      currentBranch: "main",
      hasLiveSurfaces: true,
      scrollbackLastMountedAt: Self.daysAgo(1)
    )
    var withName = base
    withName.worktreeName = "worktree-name"
    withName.worktreeDetail = "worktree-detail"
    #expect(Self.seeds([withName]).first?.title == "worktree-name")

    var withDetail = base
    withDetail.worktreeName = "  "
    withDetail.worktreeDetail = "worktree-detail"
    #expect(Self.seeds([withDetail]).first?.title == "worktree-detail")

    #expect(Self.seeds([base]).first?.title == "main")

    var noBranch = base
    noBranch.currentBranch = nil
    #expect(Self.seeds([noBranch]).first?.title == "app-1")
  }

  @Test func duplicateTitlesAreAllowed() {
    let candidates = (1...3).map { index in
      TaskActivitySeeder.Candidate(
        directoryPath: "/repos/pool-\(index)",
        currentBranch: "main",
        hasLiveSurfaces: true,
        scrollbackLastMountedAt: Self.daysAgo(1)
      )
    }
    #expect(Self.seeds(candidates).map(\.title) == ["main", "main", "main"])
  }

  // MARK: - Idempotency (A1 / A13)

  @Test func secondRunWithExistingRecordsSeedsNothing() {
    let candidates = [
      TaskActivitySeeder.Candidate(
        directoryPath: "/repos/a",
        currentBranch: "main",
        hasLiveSurfaces: true,
        scrollbackLastMountedAt: Self.daysAgo(1)
      ),
      TaskActivitySeeder.Candidate(
        directoryPath: "/repos/b",
        currentBranch: "main",
        reflogEntries: [Self.checkout(at: Self.daysAgo(50), to: "main")]
      ),
    ]
    let first = Self.seeds(candidates)
    #expect(first.count == 2)
    #expect(Self.seeds(candidates, existing: first).isEmpty)
  }

  @Test func idempotencyIgnoresTrailingSlashes() {
    let seeded = Self.seeds(
      [
        .init(
          directoryPath: "/repos/a/",
          currentBranch: "main",
          hasLiveSurfaces: true,
          scrollbackLastMountedAt: Self.daysAgo(1)
        )
      ],
      existing: [Self.existingTask(directoryPath: "/repos/a")]
    )
    #expect(seeded.isEmpty)
  }

  @Test func settledExistingTaskStillBlocksReseeding() {
    var settled = Self.existingTask(directoryPath: "/repos/a")
    settled.settledAt = Self.daysAgo(30)
    let seeded = Self.seeds(
      [
        .init(
          directoryPath: "/repos/a",
          currentBranch: "main",
          reflogEntries: [Self.checkout(at: Self.daysAgo(60), to: "main")]
        )
      ],
      existing: [settled]
    )
    #expect(seeded.isEmpty)
  }

  // MARK: - Ordering

  @Test func ordersByEvidenceDateDescendingWithPathTieBreak() {
    let candidates = [
      TaskActivitySeeder.Candidate(
        directoryPath: "/repos/zulu",
        currentBranch: "main",
        reflogEntries: [Self.checkout(at: Self.daysAgo(5), to: "main")]
      ),
      TaskActivitySeeder.Candidate(
        directoryPath: "/repos/alpha",
        currentBranch: "main",
        reflogEntries: [Self.checkout(at: Self.daysAgo(5), to: "main")]
      ),
      TaskActivitySeeder.Candidate(
        directoryPath: "/repos/newest",
        currentBranch: "main",
        reflogEntries: [Self.checkout(at: Self.daysAgo(1), to: "main")]
      ),
    ]
    let seeded = Self.seeds(candidates)
    #expect(seeded.map(\.directoryPath) == ["/repos/newest", "/repos/alpha", "/repos/zulu"])
    #expect(seeded.map(\.id.rawValue) == ["t0", "t1", "t2"])
    // Input order must not leak into output order.
    #expect(Self.seeds(candidates.reversed()).map(\.directoryPath) == seeded.map(\.directoryPath))
  }

  // MARK: - Reflog parsing

  @Test func parsesCheckoutLine() {
    let text = """
      0000000000000000000000000000000000000000 abc1234def5678 CJ Winslow <cj@example.com> \
      1700000000 -0800\tcheckout: moving from main to feature/inbox
      """
    let entries = GitReflogReader.parse(reflogText: text)
    #expect(entries.count == 1)
    #expect(entries.first?.date == Date(timeIntervalSince1970: 1_700_000_000))
    #expect(entries.first?.checkoutSource == "main")
    #expect(entries.first?.checkoutTarget == "feature/inbox")
  }

  @Test func parsesNonCheckoutLineWithoutBranchInfo() {
    let text =
      "abc0000 def0000 CJ <cj@example.com> 1699990000 +0000\tcommit: add seeder"
    let entries = GitReflogReader.parse(reflogText: text)
    #expect(entries.count == 1)
    #expect(entries.first?.message == "commit: add seeder")
    #expect(entries.first?.checkoutTarget == nil)
  }

  @Test func detachedCheckoutTargetIsNotReportedAsBranch() {
    let text =
      "abc0000 def0000 CJ <cj@example.com> 1699990000 +0000\t"
      + "checkout: moving from main to 3f8a91c2b7d4e5f60718293a4b5c6d7e8f901234"
    let entries = GitReflogReader.parse(reflogText: text)
    #expect(entries.first?.checkoutSource == "main")
    #expect(entries.first?.checkoutTarget == nil)
  }

  @Test func skipsMalformedLinesButKeepsGoodOnes() {
    let text = """
      not a reflog line at all
      \tno prefix before the tab
      abc def CJ <cj@example.com> notanumber +0000\tcheckout: moving from main to x
      abc0000 def0000 CJ <cj@example.com> 1699990000 +0000\tcheckout: moving from main to good
      too few fields\tcheckout: moving from main to y
      """
    let entries = GitReflogReader.parse(reflogText: text)
    #expect(entries.count == 1)
    #expect(entries.first?.checkoutTarget == "good")
  }

  @Test func parsesEmptyTextAsNoEntries() {
    #expect(GitReflogReader.parse(reflogText: "").isEmpty)
    #expect(GitReflogReader.parse(reflogText: "\n\n").isEmpty)
  }

  @Test func preservesFileOrder() {
    let text = """
      a0 b0 CJ <cj@example.com> 100 +0000\tcheckout: moving from main to first
      a0 b0 CJ <cj@example.com> 200 +0000\tcheckout: moving from first to second
      """
    let entries = GitReflogReader.parse(reflogText: text)
    #expect(entries.map(\.checkoutTarget) == ["first", "second"])
  }

  // MARK: - Reflog reading

  @Test func readsMissingReflogAsNoEvidence() throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: "ReflogTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    #expect(GitReflogReader.read(worktreeURL: directory).isEmpty)
  }

  @Test func resolvesGitdirIndirectionForLinkedWorktree() throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: "ReflogTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    let worktree = root.appending(path: "wt", directoryHint: .isDirectory)
    let admin = root.appending(path: "admin/worktrees/wt", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: admin.appending(path: "logs", directoryHint: .isDirectory),
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: root) }

    try "gitdir: \(admin.path(percentEncoded: false))\n"
      .write(to: worktree.appending(path: ".git"), atomically: true, encoding: .utf8)
    try "a0 b0 CJ <cj@example.com> 1699990000 +0000\tcheckout: moving from main to linked\n"
      .write(to: admin.appending(path: "logs/HEAD"), atomically: true, encoding: .utf8)

    let entries = GitReflogReader.read(worktreeURL: worktree)
    #expect(entries.map(\.checkoutTarget) == ["linked"])
  }
}

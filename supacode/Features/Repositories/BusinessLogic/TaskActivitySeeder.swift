import Foundation

/// Day-one seeding: turns the evidence that already exists on disk into
/// `TaskRecord`s so the Tasks tab is populated the first time cj launches a
/// build that has it (assertion A1).
///
/// Pure logic — Foundation only, `now` passed in, no `Date()`, no filesystem, no
/// TCA (A18). The reducer gathers `Candidate`s (from the sidebar's live
/// worktrees, `layouts.json`, scrollback mtimes and `GitReflogReader`) and hands
/// them here; everything this type decides is derived from its arguments.
///
/// Evidence honesty rules, from plan Resolved #2/#3:
/// - A scrollback mtime proves only that the surface was *mounted* while the app
///   ran (the persist loop rewrites every surface every 30s), so it is a
///   low-confidence last-mounted signal — usable for the fresh/stale split,
///   never presented as activity.
/// - `.git/logs/HEAD` carries git-written timestamps and checkout targets, so it
///   is the preferred timestamp and the only source of a *historical* branch.
/// - A branch is attached only when provable: the live watcher's current branch,
///   else a stale seed's last reflog checkout target. Never inferred from a path
///   or a title (A2).
enum TaskActivitySeeder {
  /// Everything provable about one directory at seed time. All value types so
  /// the seeding decision is reproducible in a test without a repo on disk.
  nonisolated struct Candidate: Equatable, Sendable {
    /// Absolute working-directory path. Task identity is `(id, directoryPath)`,
    /// and this is also the idempotency key against already-seeded records.
    var directoryPath: String
    /// Sidebar customization title for the row, when the user set one.
    var customizationTitle: String?
    /// `Worktree.name` / `Worktree.detail` for the row, when the directory maps
    /// to a registered worktree.
    var worktreeName: String?
    var worktreeDetail: String?
    /// Current branch from the worktree info watcher. `nil` for detached HEAD, a
    /// folder synthetic, or an unreadable repo — never a guess.
    var currentBranch: String?
    /// A tab/surface for this directory exists in `layouts.json` / the live
    /// sidebar.
    var hasLiveSurfaces: Bool
    /// Newest scrollback file mtime for the directory's surfaces. Last-mounted
    /// only, per the rules above.
    var scrollbackLastMountedAt: Date?
    /// Parsed `.git/logs/HEAD`, oldest entry first. Empty when unreadable.
    var reflogEntries: [GitReflogEntry]
    /// Owning repository, when the directory maps to a registered one.
    var repositoryID: Repository.ID?

    init(
      directoryPath: String,
      customizationTitle: String? = nil,
      worktreeName: String? = nil,
      worktreeDetail: String? = nil,
      currentBranch: String? = nil,
      hasLiveSurfaces: Bool = false,
      scrollbackLastMountedAt: Date? = nil,
      reflogEntries: [GitReflogEntry] = [],
      repositoryID: Repository.ID? = nil
    ) {
      self.directoryPath = directoryPath
      self.customizationTitle = customizationTitle
      self.worktreeName = worktreeName
      self.worktreeDetail = worktreeDetail
      self.currentBranch = currentBranch
      self.hasLiveSurfaces = hasLiveSurfaces
      self.scrollbackLastMountedAt = scrollbackLastMountedAt
      self.reflogEntries = reflogEntries
      self.repositoryID = repositoryID
    }
  }

  /// Anything untouched for longer than this seeds straight into the settled
  /// tail. Two weeks: long enough that a paused-but-real task survives a
  /// vacation, short enough that a fresh inbox isn't a wall of dead worktrees.
  /// The caller passes it explicitly so the value stays a policy decision.
  static let defaultStalenessThreshold: TimeInterval = 14 * 24 * 60 * 60

  /// Records to create, newest evidence first with a `directoryPath` tie-break.
  ///
  /// Idempotent by `directoryPath`: a directory that already has a task (active
  /// or settled) is skipped, so a re-seed after an upgrade can never duplicate
  /// (A13). `makeID` is injectable purely so tests can assert order without
  /// fighting UUIDs; ids are minted after sorting.
  static func seeds(
    candidates: [Candidate],
    existingTasks: [TaskRecord],
    now: Date,
    stalenessThreshold: TimeInterval = defaultStalenessThreshold,
    makeID: () -> TaskID = TaskID.init
  ) -> [TaskRecord] {
    let claimed = Set(existingTasks.map { normalizedPath($0.directoryPath) })
    let drafts =
      candidates
      .filter { !claimed.contains(normalizedPath($0.directoryPath)) }
      .compactMap { draft(for: $0, now: now, stalenessThreshold: stalenessThreshold) }
      .sorted { lhs, rhs in
        if lhs.activityAt != rhs.activityAt { return lhs.activityAt > rhs.activityAt }
        return lhs.candidate.directoryPath < rhs.candidate.directoryPath
      }
    return drafts.map { $0.record(id: makeID()) }
  }

  // MARK: - Draft

  /// A qualifying candidate plus the facts the seed is built from. Separate from
  /// `TaskRecord` so sorting can key off `activityAt` before ids are minted.
  private struct Draft {
    var candidate: Candidate
    var activityAt: Date
    var isStale: Bool
    var branch: String?
    var evidence: TaskRecord.SeedEvidence

    func record(id: TaskID) -> TaskRecord {
      TaskRecord(
        id: id,
        title: TaskActivitySeeder.title(for: candidate, branch: branch),
        directoryPath: candidate.directoryPath,
        branch: branch,
        repositoryID: candidate.repositoryID,
        createdAt: activityAt,
        // The evidence timestamp doubles as `settledAt` so the settled tail's
        // sort key and its displayed label are the same resolved date (A17).
        settledAt: isStale ? activityAt : nil,
        seedEvidence: evidence
      )
    }
  }

  private static func draft(
    for candidate: Candidate,
    now: Date,
    stalenessThreshold: TimeInterval
  ) -> Draft? {
    guard let activity = activityTimestamp(for: candidate) else { return nil }
    let isStale = now.timeIntervalSince(activity.date) > stalenessThreshold
    let branch = resolvedBranch(for: candidate, isStale: isStale)
    return Draft(
      candidate: candidate,
      activityAt: activity.date,
      isStale: isStale,
      branch: branch?.name,
      evidence: evidence(branch: branch, timestampSource: activity.source)
    )
  }

  // MARK: - Evidence

  private enum TimestampSource {
    case reflog
    case scrollbackMtime
  }

  /// The best real timestamp for the directory, and where it came from. `nil`
  /// means the directory does not qualify: no reflog history, and no proof a
  /// surface was ever mounted for it.
  private static func activityTimestamp(
    for candidate: Candidate
  ) -> (date: Date, source: TimestampSource)? {
    if let latest = candidate.reflogEntries.map(\.date).max() {
      return (latest, .reflog)
    }
    guard candidate.hasLiveSurfaces, let mounted = candidate.scrollbackLastMountedAt else {
      return nil
    }
    return (mounted, .scrollbackMtime)
  }

  private struct ResolvedBranch {
    /// Only two sources can ever prove a branch, so this is not
    /// `SeedEvidence.Source`: the narrower type keeps the evidence mapping
    /// exhaustive.
    enum Source {
      case currentBranch
      case reflogCheckout
    }

    var name: String
    var source: Source
  }

  private static func resolvedBranch(for candidate: Candidate, isStale: Bool) -> ResolvedBranch? {
    if let current = nonEmpty(candidate.currentBranch) {
      return ResolvedBranch(name: current, source: .currentBranch)
    }
    // Only a stale seed may fall back to history: for a live directory the
    // watcher's silence means detached / unreadable, and the branch git *used* to
    // be on would misdescribe the row it renders next to.
    guard isStale else { return nil }
    guard let checkedOut = lastCheckedOutBranch(in: candidate.reflogEntries) else { return nil }
    return ResolvedBranch(name: checkedOut, source: .reflogCheckout)
  }

  private static func lastCheckedOutBranch(in entries: [GitReflogEntry]) -> String? {
    entries
      .sorted { $0.date < $1.date }
      .reversed()
      .lazy
      .compactMap(\.checkoutTarget)
      .first
  }

  /// `source` names the strongest fact behind the seed; `confidence` says how
  /// much of the row is provable. A seed with no branch is always low confidence,
  /// which is what lets the row render an honest unknown state (A2).
  private static func evidence(
    branch: ResolvedBranch?,
    timestampSource: TimestampSource
  ) -> TaskRecord.SeedEvidence {
    guard let branch else {
      switch timestampSource {
      case .reflog:
        return TaskRecord.SeedEvidence(source: .reflog, confidence: .low)
      case .scrollbackMtime:
        return TaskRecord.SeedEvidence(source: .scrollbackMtime, confidence: .low)
      }
    }
    switch branch.source {
    case .currentBranch:
      return TaskRecord.SeedEvidence(source: .currentBranch, confidence: .high)
    case .reflogCheckout:
      return TaskRecord.SeedEvidence(source: .reflog, confidence: .medium)
    }
  }

  // MARK: - Title

  /// Plan Resolved #15: customization title → worktree name → worktree detail →
  /// branch → directory leaf. Provable facts only, duplicates allowed and honest
  /// (a five-copy pool all on `main` really is five rows named `main`); the row's
  /// secondary line disambiguates, so there is no `(2)` suffix machinery.
  private static func title(for candidate: Candidate, branch: String?) -> String {
    nonEmpty(candidate.customizationTitle)
      ?? nonEmpty(candidate.worktreeName)
      ?? nonEmpty(candidate.worktreeDetail)
      ?? nonEmpty(branch)
      ?? directoryLeaf(candidate.directoryPath)
  }

  private static func directoryLeaf(_ path: String) -> String {
    let normalized = normalizedPath(path)
    guard let leaf = normalized.split(separator: "/").last else { return normalized }
    return String(leaf)
  }

  // MARK: - Helpers

  /// Trailing slashes are cosmetic in a path but would split the idempotency key,
  /// so `/a/b` and `/a/b/` must collapse to the same directory.
  private static func normalizedPath(_ path: String) -> String {
    var trimmed = path.trimmingCharacters(in: .whitespaces)
    while trimmed.count > 1, trimmed.hasSuffix("/") {
      trimmed.removeLast()
    }
    return trimmed
  }

  private static func nonEmpty(_ value: String?) -> String? {
    guard let trimmed = value?.trimmingCharacters(in: .whitespaces), !trimmed.isEmpty else {
      return nil
    }
    return trimmed
  }
}

import Foundation

/// Day-one seeding: turns the evidence that already exists on disk into
/// `TaskRecord`s so the Tasks tab is populated the first time cj launches a
/// build that has it (assertion A1).
///
/// Pure logic — Foundation only, `now` passed in, no ambient clock, no
/// filesystem, no TCA (A18). The reducer gathers `Candidate`s (from the sidebar's live
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
/// `nonisolated` on purpose: the target compiles with
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, which would otherwise pin this
/// pure logic to the main actor and make the "no side effects" claim above only
/// half true.
nonisolated enum TaskActivitySeeder {
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
    /// Branch names the caller could enumerate for this repo, used to validate
    /// the reflog fallback: `git checkout v1.2.3` writes the same reflog shape as
    /// a branch checkout, so a tag would otherwise be labelled as a branch (A2).
    /// `nil` means the caller could not read the refs at all; the reflog fallback
    /// is then still used, because dropping every stale branch label would be a
    /// bigger regression than the rare tag mislabel.
    var knownBranches: Set<String>?
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
      knownBranches: Set<String>? = nil,
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
      self.knownBranches = knownBranches
      self.repositoryID = repositoryID
    }
  }

  /// Anything untouched for longer than this seeds straight into the settled
  /// tail. Two weeks: long enough that a paused-but-real task survives a
  /// vacation, short enough that a fresh inbox isn't a wall of dead worktrees.
  /// The caller passes it explicitly so the value stays a policy decision.
  static let defaultStalenessThreshold: TimeInterval = 14 * 24 * 60 * 60

  /// Records to create, in candidate order. Ordering is not this type's job:
  /// the Tasks list sorts by `createdAt` descending with an id tie-break, so any
  /// sort here would be dead weight that only masks the real sort's behaviour.
  ///
  /// Idempotent by `directoryPath`: a directory that already has a task (active
  /// or settled) is skipped, and duplicate candidates collapse to the first one,
  /// so a re-seed after an upgrade can never duplicate (A13). `makeID` is
  /// injectable purely so tests can pin ids.
  static func seeds(
    candidates: [Candidate],
    existingTasks: [TaskRecord],
    now: Date,
    stalenessThreshold: TimeInterval = defaultStalenessThreshold,
    makeID: () -> TaskID = TaskID.init
  ) -> [TaskRecord] {
    var seen = Set(existingTasks.map { normalizedPath($0.directoryPath) })
    return
      candidates
      .filter { candidate in
        let path = normalizedPath(candidate.directoryPath)
        // An empty or root path has no leaf to title a row with, and no candidate
        // the app builds should ever have one.
        guard !path.isEmpty, path != "/" else { return false }
        return seen.insert(path).inserted
      }
      .compactMap {
        record(for: $0, now: now, stalenessThreshold: stalenessThreshold, makeID: makeID)
      }
  }

  // MARK: - Record

  private static func record(
    for candidate: Candidate,
    now: Date,
    stalenessThreshold: TimeInterval,
    makeID: () -> TaskID
  ) -> TaskRecord? {
    guard let activity = activityTimestamp(for: candidate) else { return nil }
    // Clock skew or a doctored mtime can date evidence in the future, which would
    // make the row permanently fresh and permanently first; clamping keeps the
    // age non-negative without inventing a timestamp.
    let activityAt = min(activity.date, now)
    let isStale = now.timeIntervalSince(activityAt) > stalenessThreshold
    let branch = resolvedBranch(for: candidate, isStale: isStale)
    return TaskRecord(
      id: makeID(),
      title: title(for: candidate, branch: branch?.name),
      directoryPath: candidate.directoryPath,
      branch: branch?.name,
      repositoryID: candidate.repositoryID,
      createdAt: activityAt,
      // The evidence timestamp doubles as `settledAt` so the settled tail's sort
      // key and its displayed label are the same resolved date (A17).
      settledAt: isStale ? activityAt : nil,
      // Stated, not derived. A stale seed is a decision — "this directory has
      // been dead for a fortnight, it starts in the tail" — and writing it as an
      // explicit override means A30's off-switch cannot resurrect a wall of dead
      // worktrees into Active, and the intent is readable in `tasks.json` rather
      // than inferred from a bare timestamp. Unsettling clears the override, so
      // the recovery path is untouched.
      settledOverride: isStale ? .settled : nil,
      seedEvidence: evidence(branch: branch, timestampSource: activity.source)
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
    // `git checkout v1.2.3` writes the same reflog line a branch checkout does,
    // so when the caller could enumerate refs, the name has to be one of them.
    if let knownBranches = candidate.knownBranches, !knownBranches.contains(checkedOut) {
      return nil
    }
    return ResolvedBranch(name: checkedOut, source: .reflogCheckout)
  }

  /// Latest checkout target, breaking ties by file position rather than sorting:
  /// Swift's sort is not stable, so two same-second checkouts would otherwise
  /// pick a nondeterministic branch. File order is git's append order, so the
  /// later line is the later checkout.
  private static func lastCheckedOutBranch(in entries: [GitReflogEntry]) -> String? {
    entries
      .enumerated()
      .filter { $0.element.checkoutTarget != nil }
      .max { ($0.element.date, $0.offset) < ($1.element.date, $1.offset) }?
      .element
      .checkoutTarget
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
  /// Also used by the manual promote path, so the two ways a task can be born
  /// title it identically.
  static func title(for candidate: Candidate, branch: String?) -> String {
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

  /// Collapses the cosmetic differences that would split the idempotency key:
  /// trailing slashes, `//`, and `..` segments. Case is preserved — APFS can be
  /// case-sensitive, so lowercasing would merge two genuinely distinct
  /// directories.
  ///
  /// Precondition: callers must already have canonicalized symlinks (via
  /// `URL.resolvingSymlinksInPath()`) when they build candidates. The seeder is
  /// pure and cannot touch the filesystem, so it cannot do that itself, and two
  /// candidates that differ only by a symlink hop will seed twice.
  private static func normalizedPath(_ path: String) -> String {
    let trimmed = path.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return "" }
    // `standardizedFileURL` collapses `//` and `..` but keeps a trailing slash
    // when the URL was built with a directory hint, so drop that separately.
    var standardized = URL(fileURLWithPath: trimmed)
      .standardizedFileURL
      .path(percentEncoded: false)
    while standardized.count > 1, standardized.hasSuffix("/") {
      standardized.removeLast()
    }
    return standardized
  }

  private static func nonEmpty(_ value: String?) -> String? {
    guard let trimmed = value?.trimmingCharacters(in: .whitespaces), !trimmed.isEmpty else {
      return nil
    }
    return trimmed
  }
}

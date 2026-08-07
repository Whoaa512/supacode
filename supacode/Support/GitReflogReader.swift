import Foundation
import SupacodeSettingsShared

/// One parsed line of `.git/logs/HEAD`.
///
/// The reflog is the only *real* activity evidence a directory carries at seed
/// time: scrollback mtimes only prove the surface was materialized while the app
/// ran (plan Resolved #2), while a reflog line carries a git-written timestamp
/// and, for checkouts, the branch that was moved onto.
nonisolated struct GitReflogEntry: Equatable, Sendable {
  /// Absolute instant from the line's unix timestamp. The trailing `-0700`-style
  /// timezone field is display-only — the unix timestamp is already absolute — so
  /// it is deliberately not parsed or stored.
  let date: Date
  /// Text after the tab, or `""` for a line git wrote without a message (the
  /// only line a freshly created linked worktree's reflog has).
  let message: String
  /// The `X` of `checkout: moving from X to Y`, when this line is a checkout and
  /// `X` is a plausible branch name (not a bare sha).
  let checkoutSource: String?
  /// The `Y` of `checkout: moving from X to Y`, same plausibility rule. `nil` for
  /// a detached-HEAD checkout, so a sha is never rendered as a branch (A2).
  let checkoutTarget: String?

  init(date: Date, message: String, checkoutSource: String? = nil, checkoutTarget: String? = nil) {
    self.date = date
    self.message = message
    self.checkoutSource = checkoutSource
    self.checkoutTarget = checkoutTarget
  }
}

/// Reads and parses git's HEAD reflog for a working directory.
///
/// `parse(reflogText:)` is pure so the seeder's evidence rules are testable
/// without a fixture repo; `read(worktreeURL:fileManager:)` is the thin
/// filesystem wrapper. No ComposableArchitecture / SwiftUI here.
nonisolated enum GitReflogReader {
  private static let logger = SupaLogger("GitReflogReader")

  /// Parses `.git/logs/HEAD` contents. Line shape:
  /// `<old-sha> <new-sha> <name> <email> <unix-ts> <tz>\t<message>`
  ///
  /// The tab and message are optional: `git worktree add` writes the worktree's
  /// first reflog line with no message at all, and dropping it would mean a
  /// brand-new worktree never seeds.
  ///
  /// A malformed line is skipped, never fatal: the file is append-only and a
  /// truncated tail (crash mid-write) must not cost the evidence in the lines
  /// above it. Entries come back in file order (oldest first), as git wrote them.
  static func parse(reflogText: String) -> [GitReflogEntry] {
    reflogText.split(whereSeparator: \.isNewline).compactMap(parseLine)
  }

  /// Reflog entries for `worktreeURL`, or `[]` when there is no readable one.
  /// A missing reflog is the normal case for a folder synthetic or a brand-new
  /// repo — it means "no evidence", never an error.
  ///
  /// A reflog that exists but cannot be read is a different situation — a real
  /// permissions or encoding problem — so it is logged rather than swallowed.
  static func read(worktreeURL: URL, fileManager: FileManager = .default) -> [GitReflogEntry] {
    guard let logURL = reflogURL(for: worktreeURL, fileManager: fileManager) else { return [] }
    guard fileManager.fileExists(atPath: logURL.path(percentEncoded: false)) else { return [] }
    do {
      return parse(reflogText: try String(contentsOf: logURL, encoding: .utf8))
    } catch {
      logger.debug("unreadable reflog at \(logURL.path(percentEncoded: false)): \(error)")
      return []
    }
  }

  /// `<gitdir>/logs/HEAD`, resolving the `gitdir:` indirection that linked
  /// worktrees use (their `.git` is a file, and the logs live under the admin
  /// directory it points at).
  static func reflogURL(for worktreeURL: URL, fileManager: FileManager = .default) -> URL? {
    GitWorktreeHeadResolver.gitDirectoryURL(for: worktreeURL, fileManager: fileManager)?
      .appending(path: "logs/HEAD")
  }

  private static func parseLine(_ line: some StringProtocol) -> GitReflogEntry? {
    let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
    guard let prefix = parts.first, let date = parseDate(prefix) else { return nil }
    let message = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
    let checkout = parseCheckout(message)
    return GitReflogEntry(
      date: date,
      message: message,
      checkoutSource: checkout?.from,
      checkoutTarget: checkout?.to
    )
  }

  /// The committer field holds spaces, so the timestamp is located from the end:
  /// the last field is the timezone offset and the one before it the unix time.
  /// The two leading fields must be object ids as well, so an arbitrary line of
  /// prose that happens to have a number in the right slot is still rejected.
  private static func parseDate(_ prefix: some StringProtocol) -> Date? {
    let fields = prefix.split(separator: " ", omittingEmptySubsequences: true)
    guard fields.count >= 4 else { return nil }
    guard fields[0].allSatisfy(\.isHexDigit), fields[1].allSatisfy(\.isHexDigit) else { return nil }
    guard let seconds = TimeInterval(fields[fields.count - 2]) else { return nil }
    return Date(timeIntervalSince1970: seconds)
  }

  private static func parseCheckout(_ message: String) -> (from: String?, to: String?)? {
    let prefix = "checkout: moving from "
    guard message.hasPrefix(prefix) else { return nil }
    let body = message.dropFirst(prefix.count)
    // Branch names may contain spaces in no sane repo, but ` to ` can appear in
    // one, so split on the last occurrence: git always writes the target last.
    guard let separator = body.range(of: " to ", options: .backwards) else { return nil }
    return (
      from: plausibleBranchName(body[body.startIndex..<separator.lowerBound]),
      to: plausibleBranchName(body[separator.upperBound...])
    )
  }

  /// Rejects empty names and bare object shas. A detached checkout writes the
  /// sha in the branch position; reporting it as a branch would be exactly the
  /// fabricated label A2 forbids.
  private static func plausibleBranchName(_ candidate: some StringProtocol) -> String? {
    let trimmed = candidate.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return nil }
    guard !isObjectSHA(trimmed) else { return nil }
    return trimmed
  }

  /// Known false positive: a branch literally named `deadbeef` is all-hex and
  /// long enough, so it is treated as a sha and dropped. Silently omitting a
  /// branch label is the safe direction — A2 forbids fabricating one.
  private static func isObjectSHA(_ value: String) -> Bool {
    guard value.count >= 7 else { return false }
    return value.allSatisfy(\.isHexDigit)
  }
}

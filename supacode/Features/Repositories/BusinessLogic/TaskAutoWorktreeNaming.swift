import Foundation

/// The branch name Supacode derives for a worktree it creates on a task's
/// behalf (plan assertion A20).
///
/// Derived only from data the record already carries — its title and its opaque
/// id — so the same capture always produces the same name. That is what lets a
/// failed warm creation be retried cold under the *same* name: a second name
/// would leave the record's delete marker pointing at a directory that was
/// never created.
///
/// The id tail is what keeps two captures apart, because titles are allowed to
/// collide (Resolved #15) and ids are not. It is never truncated.
nonisolated enum TaskAutoWorktreeNaming {
  /// Long enough to stay readable in a directory listing, short enough that the
  /// id tail survives every filesystem's name limit.
  static let slugCharacterLimit = 32
  /// UUID prefix length. Eight hex characters is ~4 billion values, and the
  /// names only ever have to be unique inside one repository.
  static let shortIDCharacterLimit = 8

  static func branchName(title: String, taskID: TaskID) -> String {
    let shortID = String(
      taskID.rawValue.lowercased().replacing("-", with: "").prefix(shortIDCharacterLimit)
    )
    let slug = slug(from: title)
    guard !slug.isEmpty else { return "task/\(shortID)" }
    return "task/\(slug)-\(shortID)"
  }

  /// Lowercased `[a-z0-9-]` only: git rejects plenty of what a title may contain
  /// (`~^:?*[`, `..`, `@{`, a trailing `.lock`), and keeping the alphabet this
  /// narrow means no title can produce a name `git worktree add` refuses.
  private static func slug(from title: String) -> String {
    var slug = ""
    slug.reserveCapacity(title.count)
    for character in title.lowercased() {
      guard character.isASCII, character.isLetter || character.isNumber else {
        // Runs of punctuation collapse into one separator, and a leading run
        // produces none at all.
        if !slug.isEmpty, !slug.hasSuffix("-") { slug.append("-") }
        continue
      }
      slug.append(character)
    }
    // Truncated before trimming, so a cut that lands on a separator cannot
    // leave the name ending in one.
    slug = String(slug.prefix(slugCharacterLimit))
    while slug.hasSuffix("-") { slug.removeLast() }
    return slug
  }
}

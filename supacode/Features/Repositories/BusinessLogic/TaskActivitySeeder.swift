import Foundation

/// Titles a task record from the facts the roster can prove about its
/// directory. Day-one bulk seeding is gone on purpose — joining the inbox is a
/// per-tab (promote) or per-task (⌘N) choice — but every task is still born
/// through `title(for:branch:)`, so the two ways a task can be created title it
/// identically.
///
/// Pure logic — Foundation only, no filesystem, no TCA (A18).
nonisolated enum TaskActivitySeeder {
  /// Everything provable about one directory at creation time. All value types
  /// so the title decision is reproducible in a test without a repo on disk.
  nonisolated struct Candidate: Equatable, Sendable {
    /// Absolute working-directory path. Task identity is `(id, directoryPath)`.
    var directoryPath: String
    /// Sidebar customization title for the row, when the user set one.
    var customizationTitle: String?
    /// `Worktree.name` / `Worktree.detail` for the row, when the directory maps
    /// to a registered worktree.
    var worktreeName: String?
    var worktreeDetail: String?

    init(
      directoryPath: String,
      customizationTitle: String? = nil,
      worktreeName: String? = nil,
      worktreeDetail: String? = nil
    ) {
      self.directoryPath = directoryPath
      self.customizationTitle = customizationTitle
      self.worktreeName = worktreeName
      self.worktreeDetail = worktreeDetail
    }
  }

  /// Plan Resolved #15: customization title → worktree name → worktree detail →
  /// branch → directory leaf. Provable facts only, duplicates allowed and honest
  /// (a five-copy pool all on `main` really is five rows named `main`); the row's
  /// secondary line disambiguates, so there is no `(2)` suffix machinery.
  static func title(for candidate: Candidate, branch: String?) -> String {
    nonEmpty(candidate.customizationTitle)
      ?? nonEmpty(candidate.worktreeName)
      ?? nonEmpty(candidate.worktreeDetail)
      ?? nonEmpty(branch)
      ?? directoryLeaf(candidate.directoryPath)
  }

  private static func directoryLeaf(_ path: String) -> String {
    let normalized = TaskDirectoryPath.normalized(path)
    guard let leaf = normalized.split(separator: "/").last else { return normalized }
    return String(leaf)
  }

  private static func nonEmpty(_ value: String?) -> String? {
    guard let trimmed = value?.trimmingCharacters(in: .whitespaces), !trimmed.isEmpty else {
      return nil
    }
    return trimmed
  }
}

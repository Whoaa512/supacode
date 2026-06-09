import ComposableArchitecture
import Foundation
import OrderedCollections

/// Computes the macOS main-window title for the navigation title.
/// Format is `<repo> · <tab>` for a selected worktree (tab segment
/// dropped if absent), `Archive` for the archived view, and `Supacode`
/// when nothing is selected. Compare launches append their worktree label
/// to every window title.
enum WindowTitle {
  static var appName: String {
    appendCompareLabel(to: "Supacode")
  }
  static let archivedLabel = "Archive"

  private static var compareLabel: String? {
    let label = ProcessInfo.processInfo.environment["SUPACODE_COMPARE_LABEL"]?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard let label, !label.isEmpty else { return nil }
    return label
  }

  private static func appendCompareLabel(to title: String) -> String {
    guard let label = compareLabel else { return title }
    return "\(title) — \(label)"
  }

  static func format(repo: String, tab: String?) -> String {
    guard let tab, !tab.isEmpty else { return repo }
    return "\(repo) · \(tab)"
  }

  @MainActor
  static func compute(
    repositories: RepositoriesFeature.State,
    terminalManager: WorktreeTerminalManager,
  ) -> String {
    let title: String
    switch repositories.selection {
    case .archivedWorktrees:
      title = archivedLabel
    case .worktree(let worktreeID):
      title = worktreeTitle(
        worktreeID: worktreeID,
        repositories: repositories,
        terminalManager: terminalManager,
      )
    case .failedRepository(let repositoryID):
      let url = URL(fileURLWithPath: repositoryID).standardizedFileURL
      let name = repoDisplayName(
        repositoryID: repositoryID,
        fallback: Repository.name(for: url),
        repositories: repositories
      )
      return format(repo: name, tab: "Unavailable")
    case .none:
      return appName
    }
    return appendCompareLabel(to: title)
  }

  @MainActor
  private static func worktreeTitle(
    worktreeID: Worktree.ID,
    repositories: RepositoriesFeature.State,
    terminalManager: WorktreeTerminalManager,
  ) -> String {
    guard let repositoryID = repositories.repositoryID(containing: worktreeID),
      let repository = repositories.repositories[id: repositoryID]
    else {
      return appName
    }
    let repoTitle = repoDisplayName(
      repositoryID: repositoryID,
      fallback: repository.name,
      repositories: repositories
    )
    let tabTitle = terminalManager.stateIfExists(for: worktreeID).flatMap { state in
      tabDisplayTitle(in: state)
    }
    return format(repo: repoTitle, tab: tabTitle)
  }

  @MainActor
  private static func repoDisplayName(
    repositoryID: Repository.ID,
    fallback: String,
    repositories: RepositoriesFeature.State
  ) -> String {
    Repository.sidebarDisplayName(
      custom: repositories.sidebar.sections[repositoryID]?.title,
      fallback: fallback
    )
  }

  @MainActor
  private static func tabDisplayTitle(in state: WorktreeTerminalState) -> String? {
    guard let id = state.tabManager.selectedTabId,
      let tab = state.tabManager.tabs.first(where: { $0.id == id })
    else { return nil }
    return sanitize(tab.displayTitle)
  }

  /// Strips control characters (incl. embedded `\n` that would
  /// truncate `NSWindow.title`) from a tab title, then trims edge
  /// whitespace. Returns `nil` if nothing remains.
  static func sanitize(_ raw: String) -> String? {
    let scalars = raw.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
    let trimmed = String(String.UnicodeScalarView(scalars))
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}

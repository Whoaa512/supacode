import Dependencies
import DependenciesMacros
import Foundation
import SupacodeSettingsShared

private nonisolated let fileSystemBrowseLogger = SupaLogger("FileSystemBrowse")

struct DirectoryEntry: Identifiable, Equatable, Sendable {
  var id: String { fullPath }
  let name: String
  let fullPath: String
  let isGitRepo: Bool
  /// Path relative to the directory the palette listed / searched from, e.g. `supacode`
  /// for a direct child and `code/supacode` for a nested search hit. Fuzzy matching and
  /// the "in <folder>" row subtitle both read it, so neither has to re-derive it.
  let relativePath: String

  init(name: String, fullPath: String, isGitRepo: Bool, relativePath: String? = nil) {
    self.name = name
    self.fullPath = fullPath
    self.isGitRepo = isGitRepo
    self.relativePath = relativePath ?? name
  }
}

@DependencyClient
struct FileSystemBrowseClient: Sendable {
  /// Immediate children of `path`. Hidden directories are included; callers decide
  /// whether to show them (the palette reveals them once the typed leaf starts with ".").
  var listDirectory: @Sendable (_ path: URL) async throws -> [DirectoryEntry]
  /// Directories at or below `root` (depth-limited) whose root-relative path fuzzy-matches
  /// `query`. Lets the palette match `~/code/supacode` while the user is still browsing `~`.
  var searchDirectories: @Sendable (_ root: URL, _ query: String, _ maxDepth: Int) async throws -> [DirectoryEntry]
}

extension FileSystemBrowseClient: DependencyKey {
  /// Enough matches to fill the list several times over without walking a huge tree.
  private static let searchResultLimit = 60
  /// Ceiling on directories visited per search so a deep home folder can't stall the UI.
  private static let searchVisitLimit = 4_000

  static let liveValue: FileSystemBrowseClient = {
    FileSystemBrowseClient(
      listDirectory: { url in try Self.childDirectories(of: url) },
      searchDirectories: { root, query, maxDepth in
        try Self.search(root: root, query: query, maxDepth: maxDepth)
      }
    )
  }()

  private static func childDirectories(of url: URL) throws -> [DirectoryEntry] {
    let fileManager = FileManager.default
    let contents = try fileManager.contentsOfDirectory(
      at: url,
      includingPropertiesForKeys: [.isDirectoryKey],
      options: [.skipsPackageDescendants],
    )

    return
      contents
      .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
      .map { childURL in
        DirectoryEntry(
          name: childURL.lastPathComponent,
          fullPath: childURL.path(percentEncoded: false),
          isGitRepo: fileManager.fileExists(
            atPath: childURL.appending(path: ".git").path(percentEncoded: false)
          ),
        )
      }
      .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }

  /// Breadth-first so shallow matches land first, which is also the order the palette
  /// wants to display. Hidden directories are skipped entirely, and a git repository is
  /// a leaf: its internals are never interesting as a project to open.
  private static func search(root: URL, query: String, maxDepth: Int) throws -> [DirectoryEntry] {
    guard !BrowseFuzzyMatch.normalizedQuery(query).isEmpty, maxDepth > 0 else { return [] }
    let resolved = Self.searchRoot(for: root, query: query)
    var matches: [DirectoryEntry] = []
    var frontier: [(url: URL, relativePath: String)] = [(resolved.root, "")]
    var visited = 0

    for depth in 1...maxDepth {
      // The walk is synchronous, so the caller's cancellation (a keystroke superseding
      // this search) only lands if we check for it between frontiers. The same guard
      // stops descending once either cap is hit, not just the current frontier.
      try Task.checkCancellation()
      guard visited < searchVisitLimit, matches.count < searchResultLimit else { break }
      var next: [(url: URL, relativePath: String)] = []
      for directory in frontier {
        guard visited < searchVisitLimit, matches.count < searchResultLimit else { break }
        visited += 1
        let children = Self.childDirectoriesLoggingFailure(of: directory.url)
        for child in children where !child.name.hasPrefix(".") {
          let relativePath =
            directory.relativePath.isEmpty ? child.name : directory.relativePath + "/" + child.name
          if BrowseFuzzyMatch.matches(path: relativePath, query: resolved.query) {
            matches.append(
              DirectoryEntry(
                name: child.name,
                fullPath: child.fullPath,
                isGitRepo: child.isGitRepo,
                relativePath: relativePath
              )
            )
          }
          if depth < maxDepth, !child.isGitRepo {
            next.append((URL(fileURLWithPath: child.fullPath), relativePath))
          }
        }
      }
      frontier = next
      if frontier.isEmpty { break }
    }

    return BrowseFuzzyMatch.ranked(
      Array(matches.prefix(searchResultLimit)),
      query: resolved.query,
      path: \.relativePath
    )
  }

  /// The directory to walk, plus the query to match against paths relative to it. A typed
  /// path like `~/co/sup` points the browse directory at `~/co`, which need not exist; walk
  /// from the deepest existing ancestor and fold the missing components back into the query
  /// so `co/sup` fuzzy-matches `code/supacode` under `~`.
  private static func searchRoot(for root: URL, query: String) -> (root: URL, query: String) {
    let fileManager = FileManager.default
    var directory = root.standardized
    var missingComponents: [String] = []

    while !fileManager.fileExists(atPath: directory.path(percentEncoded: false)) {
      let parent = directory.deletingLastPathComponent().standardized
      guard parent.path != directory.path else { return (root, query) }
      missingComponents.insert(directory.lastPathComponent, at: 0)
      directory = parent
    }

    guard !missingComponents.isEmpty else { return (directory, query) }
    return (directory, (missingComponents + [query]).joined(separator: "/"))
  }

  /// An unreadable directory mid-walk is expected (permissions, races) and must not abort
  /// the whole search, but it should not vanish silently either.
  private static func childDirectoriesLoggingFailure(of url: URL) -> [DirectoryEntry] {
    do {
      return try childDirectories(of: url)
    } catch {
      fileSystemBrowseLogger.debug(
        "Skipping unreadable directory \(url.path(percentEncoded: false)): \(error)"
      )
      return []
    }
  }

  static let testValue = FileSystemBrowseClient()
}

extension DependencyValues {
  var fileSystemBrowseClient: FileSystemBrowseClient {
    get { self[FileSystemBrowseClient.self] }
    set { self[FileSystemBrowseClient.self] = newValue }
  }
}

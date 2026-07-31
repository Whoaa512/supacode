import Dependencies
import DependenciesMacros
import Foundation

struct DirectoryEntry: Identifiable, Equatable, Sendable {
  var id: String { fullPath }
  let name: String
  let fullPath: String
  let isGitRepo: Bool
}

@DependencyClient
struct FileSystemBrowseClient: Sendable {
  /// Immediate children of `path`. Hidden directories are included; callers decide
  /// whether to show them (the palette reveals them once the typed leaf starts with ".").
  var listDirectory: @Sendable (_ path: URL) async throws -> [DirectoryEntry]
  /// Directories at or below `root` (depth-limited) whose name matches `query`.
  /// Lets the palette match `~/code/supacode` while the user is still browsing `~`.
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
    guard !query.isEmpty, maxDepth > 0 else { return [] }
    let needle = query.lowercased()
    var matches: [DirectoryEntry] = []
    var frontier: [URL] = [root]
    var visited = 0

    for depth in 1...maxDepth {
      var next: [URL] = []
      for directory in frontier {
        guard visited < searchVisitLimit, matches.count < searchResultLimit else { break }
        visited += 1
        let children = (try? childDirectories(of: directory)) ?? []
        for child in children where !child.name.hasPrefix(".") {
          if child.name.lowercased().contains(needle) {
            matches.append(child)
          }
          if depth < maxDepth, !child.isGitRepo {
            next.append(URL(fileURLWithPath: child.fullPath))
          }
        }
      }
      frontier = next
      if frontier.isEmpty { break }
    }

    // Prefix matches read as "what I typed"; substring matches are the long tail.
    return
      matches
      .prefix(searchResultLimit)
      .enumerated()
      .sorted { left, right in
        let leftPrefix = left.element.name.lowercased().hasPrefix(needle)
        let rightPrefix = right.element.name.lowercased().hasPrefix(needle)
        if leftPrefix != rightPrefix { return leftPrefix }
        return left.offset < right.offset
      }
      .map(\.element)
  }

  static let testValue = FileSystemBrowseClient()
}

extension DependencyValues {
  var fileSystemBrowseClient: FileSystemBrowseClient {
    get { self[FileSystemBrowseClient.self] }
    set { self[FileSystemBrowseClient.self] = newValue }
  }
}

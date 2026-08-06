import Foundation

enum GitWorktreeHeadResolver {
  static func headURL(for worktreeURL: URL, fileManager: FileManager) -> URL? {
    gitDirectoryURL(for: worktreeURL, fileManager: fileManager)?.appending(path: "HEAD")
  }

  /// The directory git keeps this worktree's state in: `.git` itself for a main
  /// checkout, or the admin directory its `gitdir:` pointer file names for a
  /// linked worktree. `nil` when there is no `.git` to resolve.
  static func gitDirectoryURL(for worktreeURL: URL, fileManager: FileManager = .default) -> URL? {
    let gitURL = worktreeURL.appending(path: ".git")
    var isDirectory = ObjCBool(false)
    guard
      fileManager.fileExists(
        atPath: gitURL.path(percentEncoded: false),
        isDirectory: &isDirectory
      )
    else {
      return nil
    }
    if isDirectory.boolValue {
      return gitURL
    }
    guard let contents = try? String(contentsOf: gitURL, encoding: .utf8) else {
      return nil
    }
    guard let line = contents.split(whereSeparator: \.isNewline).first else {
      return nil
    }
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    let prefix = "gitdir:"
    guard trimmed.hasPrefix(prefix) else {
      return nil
    }
    let pathPart = trimmed.dropFirst(prefix.count).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !pathPart.isEmpty else {
      return nil
    }
    return URL(fileURLWithPath: String(pathPart), relativeTo: worktreeURL).standardizedFileURL
  }
}

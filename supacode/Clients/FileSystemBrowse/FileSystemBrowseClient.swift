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
  var listDirectory: @Sendable (_ path: URL) async throws -> [DirectoryEntry]
}

extension FileSystemBrowseClient: DependencyKey {
  static let liveValue: FileSystemBrowseClient = {
    let fileManager = FileManager.default

    return FileSystemBrowseClient(
      listDirectory: { url in
        let contents = try fileManager.contentsOfDirectory(
          at: url,
          includingPropertiesForKeys: [.isDirectoryKey, .isHiddenKey],
          options: [.skipsPackageDescendants],
        )

        return
          contents
          .filter { url in
            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isHiddenKey]) else {
              return false
            }
            return values.isDirectory == true && values.isHidden != true
          }
          .map { childURL in
            let childPath = childURL.path(percentEncoded: false)
            let isGitRepo = fileManager.fileExists(
              atPath: childURL.appending(path: ".git").path(percentEncoded: false)
            )
            return DirectoryEntry(
              name: childURL.lastPathComponent,
              fullPath: childPath,
              isGitRepo: isGitRepo,
            )
          }
          .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
      }
    )
  }()

  static let testValue = FileSystemBrowseClient()
}

extension DependencyValues {
  var fileSystemBrowseClient: FileSystemBrowseClient {
    get { self[FileSystemBrowseClient.self] }
    set { self[FileSystemBrowseClient.self] = newValue }
  }
}

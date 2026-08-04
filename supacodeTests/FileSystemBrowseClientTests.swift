import Foundation
import Testing

@testable import supacode

@Suite struct FileSystemBrowseClientTests {
  /// A throwaway tree on disk, since the live client's whole job is talking to the
  /// filesystem. Removed when the fixture goes out of scope.
  private final class Fixture {
    let root: URL

    init(directories: [String], gitRepositories: [String] = []) throws {
      root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appending(path: "supacode-browse-\(UUID().uuidString)")
      let fileManager = FileManager.default
      try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
      for directory in directories {
        try fileManager.createDirectory(
          at: root.appending(path: directory),
          withIntermediateDirectories: true
        )
      }
      for repository in gitRepositories {
        try fileManager.createDirectory(
          at: root.appending(path: repository).appending(path: ".git"),
          withIntermediateDirectories: true
        )
      }
    }

    deinit { try? FileManager.default.removeItem(at: root) }
  }

  private static func names(_ entries: [DirectoryEntry]) -> [String] {
    entries.map(\.name)
  }

  private static func search(
    _ fixture: Fixture,
    _ query: String,
    depth: Int
  ) async throws -> [DirectoryEntry] {
    try await FileSystemBrowseClient.liveValue.searchDirectories(fixture.root, query, depth)
  }

  @Test func listDirectoryReturnsChildDirectoriesAndFlagsGitRepositories() async throws {
    let fixture = try Fixture(directories: ["beta", ".hidden"], gitRepositories: ["alpha"])
    _ = FileManager.default.createFile(
      atPath: fixture.root.appending(path: "file.txt").path(percentEncoded: false),
      contents: nil
    )

    let entries = try await FileSystemBrowseClient.liveValue.listDirectory(fixture.root)

    // Files are excluded; hidden directories are returned for the caller to filter.
    #expect(Set(Self.names(entries)) == ["alpha", "beta", ".hidden"])
    #expect(entries.first { $0.name == "alpha" }?.isGitRepo == true)
    #expect(entries.first { $0.name == "beta" }?.isGitRepo == false)
  }

  @Test func searchRanksPrefixMatchesBeforeSubstringMatches() async throws {
    let fixture = try Fixture(directories: ["my-target", "target", "nest/deep-target"])

    let entries = try await Self.search(fixture, "target", depth: 3)

    #expect(Self.names(entries) == ["target", "my-target", "deep-target"])
  }

  @Test func searchFuzzyMatchesTheRootRelativePath() async throws {
    let fixture = try Fixture(directories: ["code/supacode", "code/other"])

    // Neither query matches the directory *name*; both are subsequences of `code/supacode`.
    #expect(Self.names(try await Self.search(fixture, "co/sup", depth: 3)) == ["supacode"])
    #expect(Self.names(try await Self.search(fixture, "code supa", depth: 3)) == ["supacode"])
  }

  @Test func searchReportsThePathRelativeToTheSearchRoot() async throws {
    let fixture = try Fixture(directories: ["code/supacode"])

    let entries = try await Self.search(fixture, "supacode", depth: 3)

    #expect(entries.map(\.relativePath) == ["code/supacode"])
  }

  @Test func searchClimbsToTheDeepestExistingRootAndFoldsMissingComponentsIntoTheQuery() async throws {
    let fixture = try Fixture(directories: ["code/supacode", "cold/supper"])

    // The palette points the search at `<root>/co`, which doesn't exist: `co` becomes part
    // of the needle so a half-typed path still resolves.
    let entries = try await FileSystemBrowseClient.liveValue.searchDirectories(
      fixture.root.appending(path: "co"),
      "sup",
      3
    )

    #expect(entries.map(\.relativePath) == ["code/supacode", "cold/supper"])
  }

  @Test func searchSkipsHiddenDirectories() async throws {
    let fixture = try Fixture(directories: [".target-hidden", "target", ".nest/target-nested"])

    let entries = try await Self.search(fixture, "target", depth: 3)

    #expect(Self.names(entries) == ["target"])
  }

  @Test func searchTreatsAGitRepositoryAsALeaf() async throws {
    let fixture = try Fixture(
      directories: ["repo/target-inside", "plain/target-inside"],
      gitRepositories: ["repo"]
    )

    let entries = try await Self.search(fixture, "target", depth: 3)

    // Only the plain folder's child: a repository's internals are never a project to open.
    #expect(entries.count == 1)
    #expect(entries.first?.fullPath.contains("/plain/") == true)
  }

  @Test func searchStopsAtMaxDepth() async throws {
    let fixture = try Fixture(directories: ["target", "nest/deep-target"])

    #expect(Self.names(try await Self.search(fixture, "target", depth: 1)) == ["target"])
    #expect(Self.names(try await Self.search(fixture, "target", depth: 2)) == ["target", "deep-target"])
  }

  @Test func searchCapsTheNumberOfResults() async throws {
    let fixture = try Fixture(directories: (0..<80).map { "cap-\($0)" })

    let entries = try await Self.search(fixture, "cap", depth: 3)

    #expect(entries.count == 60)
  }

  @Test func searchReturnsNothingForAnEmptyQueryOrZeroDepth() async throws {
    let fixture = try Fixture(directories: ["target"])

    #expect(try await Self.search(fixture, "", depth: 3).isEmpty)
    #expect(try await Self.search(fixture, "target", depth: 0).isEmpty)
  }

  @Test func searchThrowsWhenTheTaskIsCancelled() async throws {
    let fixture = try Fixture(directories: (0..<40).map { "nest-\($0)/child" })
    let root = fixture.root

    let task = Task {
      try await FileSystemBrowseClient.liveValue.searchDirectories(root, "child", 3)
    }
    task.cancel()

    await #expect(throws: CancellationError.self) { try await task.value }
  }
}

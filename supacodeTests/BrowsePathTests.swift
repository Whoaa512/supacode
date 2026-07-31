import Foundation
import Testing

@testable import supacode

@Suite struct BrowsePathTests {
  private static var homePath: String { FileManager.default.homeDirectoryForCurrentUser.path }

  @Test func slashlessQueryThatIsAnExistingDirectoryBecomesTheDirectory() {
    // Bare "~" used to resolve to directory "~/" with leaf "~", so every row was
    // filtered out and the list came up empty.
    let resolved = BrowsePath.resolve("~")
    #expect(resolved.directoryText == "~/")
    #expect(resolved.leaf.isEmpty)
    #expect(BrowsePath.directoryURL(of: "~").path == Self.homePath)
  }

  @Test func emptyQueryBrowsesHome() {
    let resolved = BrowsePath.resolve("")
    #expect(resolved.directoryText == "~/")
    #expect(resolved.leaf.isEmpty)
    #expect(BrowsePath.directoryURL(of: "").path == Self.homePath)
  }

  @Test func surroundingWhitespaceIsIgnored() {
    #expect(BrowsePath.resolve("  ~  ").directoryText == "~/")
    #expect(BrowsePath.resolve("  ~  ").leaf.isEmpty)
    #expect(BrowsePath.resolve("~/code ").leaf == "code")
    #expect(BrowsePath.resolve(" /tmp/ ").directoryText == "/tmp/")
    #expect(BrowsePath.resolve(" /tmp/ ").leaf.isEmpty)
  }

  @Test func slashlessQueryThatIsNotADirectoryStaysALeafAgainstHome() {
    let resolved = BrowsePath.resolve("definitely-not-a-real-directory")
    #expect(resolved.directoryText == "~/")
    #expect(resolved.leaf == "definitely-not-a-real-directory")
  }

  @Test func queryWithSeparatorSplitsAtTheLastOne() {
    #expect(BrowsePath.resolve("~/code/sup").directoryText == "~/code/")
    #expect(BrowsePath.resolve("~/code/sup").leaf == "sup")
    #expect(BrowsePath.resolve("/tmp/").directoryText == "/tmp/")
    #expect(BrowsePath.resolve("/tmp/").leaf.isEmpty)
    #expect(BrowsePath.resolve("/").directoryText == "/")
    #expect(BrowsePath.resolve("/").leaf.isEmpty)
  }

  @Test func ensureTrailingSlashIsIdempotent() {
    #expect(BrowsePath.ensureTrailingSlash("/tmp") == "/tmp/")
    #expect(BrowsePath.ensureTrailingSlash("/tmp/") == "/tmp/")
    #expect(BrowsePath.ensureTrailingSlash("/") == "/")
    #expect(BrowsePath.ensureTrailingSlash("") == "/")
  }

  @Test func descendingNormalizesTheTrailingSlashAndKeepsTheUsersStyle() {
    // A directory query always ends in "/" so the next keystroke starts a new leaf.
    #expect(BrowsePath.descending(into: "/tmp/child", from: "/tmp/ch") == "/tmp/child/")
    #expect(BrowsePath.descending(into: "/tmp/child/", from: "/tmp/ch") == "/tmp/child/")
    // Tilde style in, tilde style out.
    #expect(BrowsePath.descending(into: Self.homePath + "/code", from: "~/co") == "~/code/")
    #expect(BrowsePath.descending(into: Self.homePath + "/code", from: "/tmp/") == Self.homePath + "/code/")
  }

  @Test func parentClearsATypedLeafBeforeChangingDirectory() {
    #expect(BrowsePath.parent(of: "/tmp/ch") == "/tmp/")
    #expect(BrowsePath.parent(of: "/tmp/") == "/")
    #expect(BrowsePath.parent(of: "/") == nil)
  }
}

import Foundation
import Testing

@testable import supacode

struct PiSessionSourceTests {
  private struct Fixture {
    let base = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    var root: URL { base.appending(path: "sessions") }
    var cache: URL { base.appending(path: "state/index.json") }
    var directory: URL { root.appending(path: "encoded-cwd") }

    init() throws {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func write(_ text: String, name: String = "one.jsonl") throws -> URL {
      let file = directory.appending(path: name)
      try Data(text.utf8).write(to: file)
      return file
    }

    func clean() { try? FileManager.default.removeItem(at: base) }

    func source(chunkSize: Int = 7) -> PiSessionSource {
      PiSessionSource(root: root, cacheURL: cache, chunkSize: chunkSize)
    }
  }

  private static func header(id: String = "one", cwd: String = "/workspace/project") -> String {
    "{\"type\":\"session\",\"id\":\"\(id)\",\"timestamp\":\"2026-01-01T00:00:00.000Z\",\"cwd\":\"\(cwd)\"}\n"
  }

  private static let user =
    "{\"type\":\"message\",\"timestamp\":\"2026-01-02T00:00:00Z\","
    + "\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"hello\\nworld café\"}]}}\n"

  @Test func streamedTitleClearFallbackCountAndActivity() async throws {
    let fixture = try Fixture()
    defer { fixture.clean() }
    try fixture.write(
      Self.header() + Self.user
        + "{\"type\":\"message\",\"timestamp\":\"2026-01-03T00:00:00Z\","
        + "\"message\":{\"role\":\"toolResult\",\"content\":[]}}\n"
        + "{\"type\":\"session_info\",\"timestamp\":\"2026-02-01T00:00:00Z\",\"name\":\"renamed\"}\n"
        + "{\"type\":\"session_info\",\"name\":\"\"}\n")
    let rows = try await fixture.source().sessions()
    let row = try #require(rows.first)
    #expect(row.title == "hello world café")
    #expect(row.cwd == "/workspace/project")
    #expect(row.messageCount == 2)
    #expect(row.lastActivity == ISO8601DateFormatter().date(from: "2026-01-03T00:00:00Z"))
  }

  @Test func cacheRestartHitAppendDeleteAndRewrite() async throws {
    let fixture = try Fixture()
    defer { fixture.clean() }
    let file = try fixture.write(Self.header() + Self.user)
    let first = fixture.source()
    let original = try await first.sessions()
    #expect(await first.parsedFileCount == 1)
    #expect(try await first.sessions() == original)
    #expect(await first.parsedFileCount == 1)
    let restarted = fixture.source()
    #expect(await restarted.cachedSessions() == original)
    #expect(try await restarted.sessions() == original)
    #expect(await restarted.parsedFileCount == 0)
    try fixture.write(Self.header() + Self.user + "{\"type\":\"session_info\",\"name\":\"new title\"}\n")
    #expect(try await restarted.sessions().first?.title == "new title")
    #expect(await restarted.parsedFileCount == 1)
    try fixture.write(Self.header(id: "replacement"))
    #expect(try await restarted.sessions().first?.sessionID == "replacement")
    try FileManager.default.removeItem(at: file)
    #expect(try await restarted.sessions().isEmpty)
    #expect(await fixture.source().cachedSessions().isEmpty)
  }

  @Test func cacheLoadsOnFirstActorAccessNotInitialization() async throws {
    let fixture = try Fixture()
    defer { fixture.clean() }
    try fixture.write(Self.header() + Self.user)
    let initializedBeforeCacheExists = fixture.source()
    let original = try await fixture.source().sessions()
    #expect(await initializedBeforeCacheExists.cachedSessions() == original)
    try FileManager.default.removeItem(at: fixture.cache)
    #expect(await initializedBeforeCacheExists.cachedSessions() == original)
    #expect(try await initializedBeforeCacheExists.sessions() == original)
    #expect(await initializedBeforeCacheExists.parsedFileCount == 0)
  }

  @Test func refreshFirstLoadsPersistedCacheWithoutParsing() async throws {
    let fixture = try Fixture()
    defer { fixture.clean() }
    try fixture.write(Self.header() + Self.user)
    let original = try await fixture.source().sessions()
    let restarted = fixture.source()
    #expect(try await restarted.sessions() == original)
    #expect(await restarted.parsedFileCount == 0)
  }

  @Test func sameSizeRewriteInvalidatesOnModificationDate() async throws {
    let fixture = try Fixture()
    defer { fixture.clean() }
    let file = try fixture.write(Self.header(id: "one"))
    try FileManager.default.setAttributes(
      [.modificationDate: Date(timeIntervalSince1970: 10)],
      ofItemAtPath: file.path)
    let source = fixture.source()
    #expect(try await source.sessions().first?.sessionID == "one")
    try fixture.write(Self.header(id: "two"))
    try FileManager.default.setAttributes(
      [.modificationDate: Date(timeIntervalSince1970: 20)],
      ofItemAtPath: file.path)
    #expect(try await source.sessions().first?.sessionID == "two")
    #expect(await source.parsedFileCount == 2)
  }

  @Test func malformedSiblingAndTailDoNotHideValidSession() async throws {
    let fixture = try Fixture()
    defer { fixture.clean() }
    try fixture.write("not json\n", name: "broken.jsonl")
    try fixture.write(Self.header() + Self.user + "{\"type\":\"message\",\"timestamp\":\"")
    let source = fixture.source()
    #expect(try await source.sessions().first?.messageCount == 1)
    try fixture.write(Self.header() + Self.user + Self.user)
    #expect(try await source.sessions().first?.messageCount == 2)
  }

  @Test func latestNameAndFallbackCapAndUntitled() async throws {
    let fixture = try Fixture()
    defer { fixture.clean() }
    try fixture.write(
      Self.header() + Self.user + "{\"type\":\"session_info\",\"name\":\"first\"}\n"
        + "{\"type\":\"session_info\",\"name\":\"last\\u0001title\"}\n")
    #expect(try await fixture.source().sessions().first?.title == "last title")
    let content = String(repeating: "x", count: 400)
    try fixture.write(
      Self.header() + "{\"type\":\"message\",\"message\":{\"role\":\"user\",\"content\":\"\(content)\"}}\n")
    #expect(try await fixture.source().sessions().first?.title.count == 200)
    try fixture.write(Self.header())
    let row = try #require(try await fixture.source().sessions().first)
    #expect(row.title == "Untitled session")
    #expect(row.lastActivity == row.createdAt)
  }

  @Test(arguments: [
    "/tmp", "/tmp/a", "/private/tmp/a", "/var/folders/a", "/private/var/folders/a", "/workspace/../tmp/a",
  ])
  func excludesTemporaryPaths(_ cwd: String) async throws {
    let fixture = try Fixture()
    defer { fixture.clean() }
    try fixture.write(Self.header(cwd: cwd))
    #expect(try await fixture.source().sessions().isEmpty)
  }

  @Test(arguments: ["/tmp-project", "/private/project", "/var/folders-project"])
  func preservesComponentBoundaries(_ cwd: String) async throws {
    let fixture = try Fixture()
    defer { fixture.clean() }
    try fixture.write(Self.header(cwd: cwd))
    #expect(try await fixture.source().sessions().count == 1)
  }

  @Test func excludesSymlinksNestedFilesAndTempAlias() async throws {
    let fixture = try Fixture()
    defer { fixture.clean() }
    let outside = fixture.base.appending(path: "outside")
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    let external = outside.appending(path: "external.jsonl")
    try Data(Self.header().utf8).write(to: external)
    try FileManager.default.createSymbolicLink(
      at: fixture.directory.appending(path: "link.jsonl"), withDestinationURL: external)
    try FileManager.default.createSymbolicLink(
      at: fixture.root.appending(path: "linked-directory"), withDestinationURL: outside)
    let nested = fixture.directory.appending(path: "nested")
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    try Data(Self.header().utf8).write(to: nested.appending(path: "nested.jsonl"))
    let alias = fixture.base.appending(path: "alias")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.base)
    try fixture.write(Self.header(cwd: alias.path))
    #expect(try await fixture.source().sessions().isEmpty)
  }

  @Test func resumeValidatesIdentity() {
    let source = PiSessionSource(root: URL(fileURLWithPath: "/unused"), cacheURL: URL(fileURLWithPath: "/unused/cache"))
    #expect(source.resumeCommand(sessionID: "abc-123") == "pi --session abc-123")
    #expect(source.resumeCommand(sessionID: "bad;command") == nil)
  }
}

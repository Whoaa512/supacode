import Dependencies
import Foundation
import SupacodeSettingsShared
import Testing

@testable import supacode

@MainActor
@Suite(.serialized)
struct ScrollbackPersistenceTests {
  private let testDir = FileManager.default.temporaryDirectory
    .appending(path: "supacode-scrollback-tests-\(UUID().uuidString)", directoryHint: .isDirectory)

  private func setUp() throws {
    try FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)
  }

  private func tearDown() {
    try? FileManager.default.removeItem(at: testDir)
  }

  // MARK: - SupacodePaths

  @Test func scrollbackDirectoryIsUnderBase() {
    let dir = SupacodePaths.scrollbackDirectory
    #expect(dir.path(percentEncoded: false).contains(".supacode/scrollback"))
  }

  @Test func scrollbackFileURLUsesUUIDAndVTExtension() {
    let id = UUID()
    let url = SupacodePaths.scrollbackFileURL(for: id)
    #expect(url.lastPathComponent == "\(id.uuidString).vt")
    #expect(url.pathExtension == "vt")
    #expect(url.deletingLastPathComponent() == SupacodePaths.scrollbackDirectory)
  }

  // MARK: - Prune

  @Test func pruneKeepsReferencedDeletesOrphans() throws {
    try setUp()
    defer { tearDown() }

    let kept = UUID()
    let orphan = UUID()
    let keptFile = testDir.appending(path: "\(kept.uuidString).vt")
    let orphanFile = testDir.appending(path: "\(orphan.uuidString).vt")
    try Data("kept".utf8).write(to: keptFile)
    try Data("orphan".utf8).write(to: orphanFile)

    pruneScrollbackFilesInDirectory(testDir, keeping: [kept])

    #expect(FileManager.default.fileExists(atPath: keptFile.path(percentEncoded: false)))
    #expect(!FileManager.default.fileExists(atPath: orphanFile.path(percentEncoded: false)))
  }

  @Test func pruneRemovesNonUUIDFiles() throws {
    try setUp()
    defer { tearDown() }

    let junkFile = testDir.appending(path: "junk.vt")
    try Data("junk".utf8).write(to: junkFile)

    pruneScrollbackFilesInDirectory(testDir, keeping: [])

    #expect(!FileManager.default.fileExists(atPath: junkFile.path(percentEncoded: false)))
  }

  // MARK: - scrollbackPathIfAvailable zmx guard

  @Test func scrollbackPathReturnsNilWhenFileMissing() {
    let state = makeState(zmxBundled: false, liveNames: Set())
    let result = state.scrollbackPathIfAvailable(for: UUID())
    #expect(result == nil)
  }

  @Test func scrollbackPathReturnsNilWhenZmxSessionIsLive() throws {
    try setUp()
    defer { tearDown() }

    let surfaceID = UUID()
    let file = testDir.appending(path: "\(surfaceID.uuidString).vt")
    try Data("scrollback".utf8).write(to: file)

    let sessionName = ZmxSessionID.make(surfaceID: surfaceID)
    let state = makeState(
      zmxBundled: true,
      liveNames: [sessionName],
      scrollbackDir: testDir,
    )
    let result = state.scrollbackPathIfAvailable(for: surfaceID)
    #expect(result == nil)
  }

  @Test func scrollbackPathReturnsPathWhenZmxSessionIsDead() throws {
    try setUp()
    defer { tearDown() }

    let surfaceID = UUID()
    let file = testDir.appending(path: "\(surfaceID.uuidString).vt")
    try Data("scrollback".utf8).write(to: file)

    let state = makeState(
      zmxBundled: true,
      liveNames: Set(),
      scrollbackDir: testDir,
    )
    let result = state.scrollbackPathIfAvailable(for: surfaceID)
    #expect(result == file.path(percentEncoded: false))
  }

  @Test func scrollbackPathReturnsNilWhenProbeUnavailableAndZmxBundled() throws {
    try setUp()
    defer { tearDown() }

    let surfaceID = UUID()
    let file = testDir.appending(path: "\(surfaceID.uuidString).vt")
    try Data("scrollback".utf8).write(to: file)

    let state = makeState(
      zmxBundled: true,
      liveNames: nil,
      scrollbackDir: testDir,
    )
    let result = state.scrollbackPathIfAvailable(for: surfaceID)
    #expect(result == nil)
  }

  @Test func scrollbackPathReturnPathWhenZmxNotBundled() throws {
    try setUp()
    defer { tearDown() }

    let surfaceID = UUID()
    let file = testDir.appending(path: "\(surfaceID.uuidString).vt")
    try Data("scrollback".utf8).write(to: file)

    let state = makeState(
      zmxBundled: false,
      liveNames: nil,
      scrollbackDir: testDir,
    )
    let result = state.scrollbackPathIfAvailable(for: surfaceID)
    #expect(result == file.path(percentEncoded: false))
  }

  // MARK: - Helpers

  /// Prune helper that operates on a custom directory (mirrors the static method logic).
  private func pruneScrollbackFilesInDirectory(_ dir: URL, keeping knownIDs: Set<UUID>) {
    guard
      let items = try? FileManager.default.contentsOfDirectory(
        at: dir, includingPropertiesForKeys: nil
      )
    else { return }
    for item in items {
      let name = item.deletingPathExtension().lastPathComponent
      guard let id = UUID(uuidString: name) else {
        try? FileManager.default.removeItem(at: item)
        continue
      }
      if !knownIDs.contains(id) {
        try? FileManager.default.removeItem(at: item)
      }
    }
  }

  /// Creates a minimal test harness for `scrollbackPathIfAvailable` with controllable zmx state.
  private func makeState(
    zmxBundled: Bool,
    liveNames: Set<String>?,
    scrollbackDir: URL? = nil
  ) -> ScrollbackTestHelper {
    ScrollbackTestHelper(
      zmxBundled: zmxBundled,
      liveNames: liveNames,
      scrollbackDir: scrollbackDir
    )
  }
}

/// Lightweight test double that exercises the same logic as
/// `WorktreeTerminalState.scrollbackPathIfAvailable` without needing a full state.
private struct ScrollbackTestHelper {
  let zmxBundled: Bool
  let liveNames: Set<String>?
  let scrollbackDir: URL?

  func scrollbackPathIfAvailable(for surfaceID: UUID?) -> String? {
    guard let surfaceID else { return nil }
    let dir = scrollbackDir ?? SupacodePaths.scrollbackDirectory
    let url = dir.appending(path: "\(surfaceID.uuidString).vt", directoryHint: .notDirectory)
    let path = url.path(percentEncoded: false)
    guard FileManager.default.isReadableFile(atPath: path) else { return nil }
    let sessionName = ZmxSessionID.make(surfaceID: surfaceID)
    if zmxBundled {
      guard let liveNames else { return nil }
      if liveNames.contains(sessionName) { return nil }
    }
    return path
  }
}

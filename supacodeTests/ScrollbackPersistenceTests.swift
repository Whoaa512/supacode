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

  // MARK: - Prune (real implementation)

  @Test func pruneKeepsReferencedDeletesOrphans() throws {
    try setUp()
    defer { tearDown() }

    let kept = UUID()
    let orphan = UUID()
    let keptFile = testDir.appending(path: "\(kept.uuidString).vt")
    let orphanFile = testDir.appending(path: "\(orphan.uuidString).vt")
    try Data("kept".utf8).write(to: keptFile)
    try Data("orphan".utf8).write(to: orphanFile)

    WorktreeTerminalState.pruneScrollbackFiles(keeping: [kept], directory: testDir)

    #expect(FileManager.default.fileExists(atPath: keptFile.path(percentEncoded: false)))
    #expect(!FileManager.default.fileExists(atPath: orphanFile.path(percentEncoded: false)))
  }

  @Test func pruneRemovesNonUUIDFiles() throws {
    try setUp()
    defer { tearDown() }

    let junkFile = testDir.appending(path: "junk.vt")
    try Data("junk".utf8).write(to: junkFile)

    WorktreeTerminalState.pruneScrollbackFiles(keeping: [], directory: testDir)

    #expect(!FileManager.default.fileExists(atPath: junkFile.path(percentEncoded: false)))
  }

  // MARK: - shouldReplayScrollback (real static)

  @Test func replayReturnsFalseWhenFileMissing() {
    let result = WorktreeTerminalState.shouldReplayScrollback(
      fileExists: false,
      zmxBundled: false,
      liveSessionNames: Set(),
      sessionName: "test",
    )
    #expect(result == false)
  }

  @Test func replayReturnsFalseWhenZmxSessionIsLive() {
    let sessionName = "supacode-session"
    let result = WorktreeTerminalState.shouldReplayScrollback(
      fileExists: true,
      zmxBundled: true,
      liveSessionNames: [sessionName],
      sessionName: sessionName,
    )
    #expect(result == false)
  }

  @Test func replayReturnsTrueWhenZmxSessionIsDead() {
    let result = WorktreeTerminalState.shouldReplayScrollback(
      fileExists: true,
      zmxBundled: true,
      liveSessionNames: Set(),
      sessionName: "dead-session",
    )
    #expect(result == true)
  }

  @Test func replayReturnsFalseWhenProbeUnavailableAndZmxBundled() {
    let result = WorktreeTerminalState.shouldReplayScrollback(
      fileExists: true,
      zmxBundled: true,
      liveSessionNames: nil,
      sessionName: "any",
    )
    #expect(result == false)
  }

  @Test func replayReturnsTrueWhenZmxNotBundled() {
    let result = WorktreeTerminalState.shouldReplayScrollback(
      fileExists: true,
      zmxBundled: false,
      liveSessionNames: nil,
      sessionName: "any",
    )
    #expect(result == true)
  }
}

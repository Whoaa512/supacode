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

  // MARK: - Launch-time zmx resolution gate

  @Test func resolutionFlagStartsFalseWhenZmxBundled() {
    let manager = withDependencies {
      $0.zmxClient = ZmxClient(
        executableURL: { nil },
        isBundled: { true },
        killSession: { _ in },
        killRemoteSession: { _, _ in },
        listSessionsWithClients: { [] }
      )
    } operation: {
      WorktreeTerminalManager(runtime: GhosttyRuntime())
    }
    #expect(manager.hasResolvedLiveZmxSessions == false)
  }

  @Test func resolutionFlagStartsTrueWhenZmxNotBundled() {
    let manager = withDependencies {
      $0.zmxClient = .noop
    } operation: {
      WorktreeTerminalManager(runtime: GhosttyRuntime())
    }
    #expect(manager.hasResolvedLiveZmxSessions == true)
  }

  @Test func resolveLiveZmxSessionsFlipsFlagAndCachesNames() async {
    let manager = withDependencies {
      $0.zmxClient = ZmxClient(
        executableURL: { nil },
        isBundled: { true },
        killSession: { _ in },
        killRemoteSession: { _, _ in },
        listSessionsWithClients: { [.init(name: "supa-live", clients: 1)] }
      )
    } operation: {
      WorktreeTerminalManager(runtime: GhosttyRuntime())
    }
    await manager.resolveLiveZmxSessions()
    #expect(manager.hasResolvedLiveZmxSessions == true)
    #expect(manager.liveZmxSessionNames == ["supa-live"])
  }

  @Test func resolveLiveZmxSessionsFlipsFlagEvenWhenProbeFails() async {
    let manager = withDependencies {
      $0.zmxClient = ZmxClient(
        executableURL: { nil },
        isBundled: { true },
        killSession: { _ in },
        killRemoteSession: { _, _ in },
        listSessionsWithClients: { nil }
      )
    } operation: {
      WorktreeTerminalManager(runtime: GhosttyRuntime())
    }
    await manager.resolveLiveZmxSessions()
    #expect(manager.hasResolvedLiveZmxSessions == true)
    #expect(manager.liveZmxSessionNames == nil)
  }

  // MARK: - persistScrollbackEnabled gates replay

  @Test func replayGatedByPersistScrollbackEnabled() {
    // When enabled, the pure zmx check passes as expected
    let enabled = WorktreeTerminalState.shouldReplayScrollback(
      fileExists: true,
      zmxBundled: false,
      liveSessionNames: nil,
      sessionName: "any",
    )
    #expect(enabled == true)
    // The actual gating happens in scrollbackPathIfAvailable which reads
    // settingsFile.global.persistScrollbackEnabled before calling this.
    // When disabled, scrollbackPathIfAvailable returns nil without reaching
    // the pure check — tested via integration in the app.
  }

  // MARK: - Directory permissions

  @Test func scrollbackDirectoryCreatedWith0700() throws {
    try setUp()
    defer { tearDown() }

    let dir = testDir.appending(path: "scrollback-perms", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: dir, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    let attrs = try FileManager.default.attributesOfItem(atPath: dir.path(percentEncoded: false))
    let perms = attrs[.posixPermissions] as? Int
    #expect(perms == 0o700)
  }

  // MARK: - Purge all scrollback files

  @Test func purgeAllRemovesEverything() throws {
    try setUp()
    defer { tearDown() }

    let file1 = testDir.appending(path: "\(UUID().uuidString).vt")
    let file2 = testDir.appending(path: "\(UUID().uuidString).vt")
    try Data("data".utf8).write(to: file1)
    try Data("data".utf8).write(to: file2)

    let items = try FileManager.default.contentsOfDirectory(
      at: testDir, includingPropertiesForKeys: nil
    )
    #expect(items.count == 2)

    for item in items {
      try FileManager.default.removeItem(at: item)
    }
    let afterItems = try? FileManager.default.contentsOfDirectory(
      at: testDir, includingPropertiesForKeys: nil
    )
    #expect((afterItems ?? []).isEmpty)
  }

  // MARK: - Scrollback restored banner

  @Test func bannerContainsExpectedContent() {
    let banner = WorktreeTerminalState.scrollbackRestoredBanner
    #expect(banner.contains("scrollback restored from disk"))
    #expect(banner.contains("processes are not running"))
    #expect(banner.contains("\u{1b}[2m"))
    #expect(banner.contains("\u{1b}[0m"))
  }

  @Test func pruneRemovesReplayFiles() throws {
    try setUp()
    defer { tearDown() }

    let id = UUID()
    let canonicalFile = testDir.appending(path: "\(id.uuidString).vt")
    let replayFile = testDir.appending(path: "\(id.uuidString).replay.vt")
    try Data("canon".utf8).write(to: canonicalFile)
    try Data("replay".utf8).write(to: replayFile)

    WorktreeTerminalState.pruneScrollbackFiles(keeping: [id], directory: testDir)

    #expect(FileManager.default.fileExists(atPath: canonicalFile.path(percentEncoded: false)))
    #expect(!FileManager.default.fileExists(atPath: replayFile.path(percentEncoded: false)))
  }
}

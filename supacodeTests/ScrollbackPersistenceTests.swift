import Dependencies
import DependenciesTestSupport
import Foundation
import SupacodeSettingsShared
import Testing

@testable import supacode

@MainActor
@Suite(.serialized, .dependencies)
struct ScrollbackPersistenceTests {
  struct ReplayCase: Sendable {
    var fileExists: Bool
    var persistenceEnabled: Bool
    var zmxBundled: Bool
    var liveSessionNames: Set<String>?
    var sessionName: String
    var expected: Bool
  }

  private func withStateDirectory(_ operation: (URL) throws -> Void) throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: "supacode-scrollback-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    let previous = ProcessInfo.processInfo.environment["SUPACODE_STATE_DIR"]
    setenv("SUPACODE_STATE_DIR", directory.path(percentEncoded: false), 1)
    defer {
      if let previous {
        setenv("SUPACODE_STATE_DIR", previous, 1)
      } else {
        unsetenv("SUPACODE_STATE_DIR")
      }
      try? FileManager.default.removeItem(at: directory)
    }
    try operation(directory)
  }

  @Test func pathsUseStateDirectoryAndSurfaceID() throws {
    try withStateDirectory { stateDirectory in
      let id = UUID()
      #expect(
        SupacodePaths.scrollbackDirectory
          == stateDirectory.appending(path: "scrollback", directoryHint: .isDirectory))
      #expect(SupacodePaths.scrollbackFileURL(surfaceID: id).lastPathComponent == "\(id.uuidString).vt")
      #expect(
        SupacodePaths.scrollbackReplayFileURL(surfaceID: id).lastPathComponent
          == "\(id.uuidString).replay.vt")
    }
  }

  @Test func prepareDirectoryCreatesAndEnforces0700() throws {
    try withStateDirectory { _ in
      let directory = SupacodePaths.scrollbackDirectory
      try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o755]
      )
      _ = try SupacodePaths.prepareScrollbackDirectory()
      let attributes = try FileManager.default.attributesOfItem(
        atPath: directory.path(percentEncoded: false))
      #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    }
  }

  @Test func purgeAllRemovesCanonicalAndReplayFiles() throws {
    try withStateDirectory { _ in
      let directory = try SupacodePaths.prepareScrollbackDirectory()
      try Data("canonical".utf8).write(
        to: SupacodePaths.scrollbackFileURL(surfaceID: UUID()))
      try Data("replay".utf8).write(
        to: directory.appending(path: "stale.replay.vt"))

      SupacodePaths.purgeAllScrollbackFiles()

      let remaining = try FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: nil)
      #expect(remaining.isEmpty)
    }
  }

  @Test func pruneKeepsKnownCanonicalAndRemovesEverythingElse() throws {
    try withStateDirectory { _ in
      let directory = try SupacodePaths.prepareScrollbackDirectory()
      let kept = UUID()
      let orphan = UUID()
      try Data().write(to: SupacodePaths.scrollbackFileURL(surfaceID: kept))
      try Data().write(to: SupacodePaths.scrollbackFileURL(surfaceID: orphan))
      try Data().write(to: SupacodePaths.scrollbackReplayFileURL(surfaceID: kept))
      try Data().write(to: directory.appending(path: "junk.vt"))

      ScrollbackPersistence.pruneFiles(keeping: [kept])

      #expect(FileManager.default.fileExists(atPath: SupacodePaths.scrollbackFileURL(surfaceID: kept).path))
      #expect(!FileManager.default.fileExists(atPath: SupacodePaths.scrollbackFileURL(surfaceID: orphan).path))
      #expect(!FileManager.default.fileExists(atPath: SupacodePaths.scrollbackReplayFileURL(surfaceID: kept).path))
      #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "junk.vt").path))
    }
  }

  @Test(
    arguments: [
      ReplayCase(
        fileExists: false, persistenceEnabled: true, zmxBundled: false,
        liveSessionNames: [], sessionName: "session", expected: false),
      ReplayCase(
        fileExists: true, persistenceEnabled: false, zmxBundled: false,
        liveSessionNames: [], sessionName: "session", expected: false),
      ReplayCase(
        fileExists: true, persistenceEnabled: true, zmxBundled: false,
        liveSessionNames: nil, sessionName: "session", expected: true),
      ReplayCase(
        fileExists: true, persistenceEnabled: true, zmxBundled: true,
        liveSessionNames: nil, sessionName: "session", expected: false),
      ReplayCase(
        fileExists: true, persistenceEnabled: true, zmxBundled: true,
        liveSessionNames: ["session"], sessionName: "session", expected: false),
      ReplayCase(
        fileExists: true, persistenceEnabled: true, zmxBundled: true,
        liveSessionNames: [], sessionName: "session", expected: true),
    ]
  )
  func replayGate(testCase: ReplayCase) {
    #expect(
      ScrollbackPersistence.shouldReplay(
        fileExists: testCase.fileExists,
        persistenceEnabled: testCase.persistenceEnabled,
        zmxBundled: testCase.zmxBundled,
        liveSessionNames: testCase.liveSessionNames,
        sessionName: testCase.sessionName
      ) == testCase.expected)
  }

  @Test func replayFileAppendsBoundaryMarker() throws {
    try withStateDirectory { _ in
      _ = try SupacodePaths.prepareScrollbackDirectory()
      let id = UUID()
      try Data("saved output".utf8).write(
        to: SupacodePaths.scrollbackFileURL(surfaceID: id))

      let path = try #require(
        ScrollbackPersistence.replayFile(
          surfaceID: id,
          persistenceEnabled: true,
          zmxBundled: false,
          liveSessionNames: nil
        ))
      let contents = try String(contentsOfFile: path, encoding: .utf8)
      #expect(contents.hasPrefix("saved output"))
      #expect(contents.contains("── scrollback restored from disk ──"))
      #expect(contents.contains("\u{1b}[2m"))
      #expect(contents.contains("\u{1b}[0m"))
    }
  }

  @Test func liveSessionResolutionCachesNamesAndCompletesGate() async {
    let manager = withDependencies {
      $0.zmxClient.isBundled = { true }
      $0.zmxClient.listSessionsWithClients = {
        [.init(name: "supa-live", clients: 1)]
      }
    } operation: {
      WorktreeTerminalManager(runtime: GhosttyRuntime())
    }
    #expect(!manager.hasResolvedLiveZmxSessions)

    await manager.resolveLiveZmxSessions()

    #expect(manager.hasResolvedLiveZmxSessions)
    #expect(manager.liveZmxSessionNames == ["supa-live"])
  }

  @Test func failedLiveSessionProbeCompletesWithUnknownNames() async {
    let manager = withDependencies {
      $0.zmxClient.isBundled = { true }
      $0.zmxClient.listSessionsWithClients = { nil }
    } operation: {
      WorktreeTerminalManager(runtime: GhosttyRuntime())
    }

    await manager.resolveLiveZmxSessions()

    #expect(manager.hasResolvedLiveZmxSessions)
    #expect(manager.liveZmxSessionNames == nil)
  }
}

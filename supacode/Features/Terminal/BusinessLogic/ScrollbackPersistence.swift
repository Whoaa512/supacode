import Foundation
import SupacodeSettingsShared

nonisolated enum ScrollbackPersistence {
  private static let logger = SupaLogger("Scrollback")

  static let restoredBoundary = "\r\n\u{1b}[2m── scrollback restored from disk ──\u{1b}[0m\r\n"

  static func shouldReplay(
    fileExists: Bool,
    persistenceEnabled: Bool,
    zmxBundled: Bool,
    liveSessionNames: Set<String>?,
    sessionName: String
  ) -> Bool {
    guard persistenceEnabled, fileExists else { return false }
    guard zmxBundled else { return true }
    guard let liveSessionNames else { return false }
    return !liveSessionNames.contains(sessionName)
  }

  static func replayFile(
    surfaceID: UUID,
    persistenceEnabled: Bool,
    zmxBundled: Bool,
    liveSessionNames: Set<String>?
  ) -> String? {
    let source = SupacodePaths.scrollbackFileURL(surfaceID: surfaceID)
    let sourcePath = source.path(percentEncoded: false)
    guard
      shouldReplay(
        fileExists: FileManager.default.isReadableFile(atPath: sourcePath),
        persistenceEnabled: persistenceEnabled,
        zmxBundled: zmxBundled,
        liveSessionNames: liveSessionNames,
        sessionName: ZmxSessionID.make(surfaceID: surfaceID)
      )
    else { return nil }
    guard let sourceData = FileManager.default.contents(atPath: sourcePath) else { return nil }
    var replayData = sourceData
    replayData.append(contentsOf: restoredBoundary.utf8)
    let replay = SupacodePaths.scrollbackReplayFileURL(surfaceID: surfaceID)
    do {
      _ = try SupacodePaths.prepareScrollbackDirectory()
      try replayData.write(to: replay, options: .atomic)
      return replay.path(percentEncoded: false)
    } catch {
      logger.warning("Failed to prepare scrollback replay for \(surfaceID): \(error.localizedDescription)")
      return sourcePath
    }
  }

  static func removeFiles(surfaceIDs: some Sequence<UUID>) {
    for surfaceID in surfaceIDs {
      try? FileManager.default.removeItem(
        at: SupacodePaths.scrollbackFileURL(surfaceID: surfaceID))
      try? FileManager.default.removeItem(
        at: SupacodePaths.scrollbackReplayFileURL(surfaceID: surfaceID))
    }
  }

  static func pruneFiles(
    keeping knownIDs: Set<UUID>,
    directory: URL = SupacodePaths.scrollbackDirectory
  ) {
    guard
      let items = try? FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: nil)
    else { return }
    for item in items {
      let stem = item.deletingPathExtension().lastPathComponent
      if stem.hasSuffix(".replay") {
        try? FileManager.default.removeItem(at: item)
        continue
      }
      guard let id = UUID(uuidString: stem), knownIDs.contains(id) else {
        try? FileManager.default.removeItem(at: item)
        continue
      }
    }
  }
}

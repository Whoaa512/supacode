import Dependencies
import Foundation
import SupacodeSettingsShared

/// On-disk envelope for `~/.supacode/tasks.json`.
///
/// `didSeedTasks` lives in the envelope rather than in UserDefaults so the flag
/// travels with the records it describes: deleting `tasks.json` re-enables
/// seeding, and restoring an old copy restores its seeding state, which keeps
/// "seed exactly once" true across upgrades and downgrades (A13).
nonisolated struct TaskStoreFile: Equatable, Sendable, Codable {
  /// Bumped only for a shape change this build could not otherwise decode.
  /// Additive fields never bump it — `TaskRecord`'s decode tolerates them.
  static let currentSchemaVersion = 1

  var schemaVersion: Int
  var didSeedTasks: Bool
  var tasks: [TaskRecord]

  init(
    schemaVersion: Int = TaskStoreFile.currentSchemaVersion,
    didSeedTasks: Bool = false,
    tasks: [TaskRecord] = []
  ) {
    self.schemaVersion = schemaVersion
    self.didSeedTasks = didSeedTasks
    self.tasks = tasks
  }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion
    case didSeedTasks
    case tasks
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.schemaVersion = (try? container.decodeIfPresent(Int.self, forKey: .schemaVersion)) ?? 0
    self.didSeedTasks = (try? container.decodeIfPresent(Bool.self, forKey: .didSeedTasks)) ?? false
    // Per-element lossy: one unreadable record costs that record only, never the
    // whole inbox (A12). `LossyTaskRecord.init` never throws, so the array
    // container always advances past a bad element.
    let lossy = try container.decodeIfPresent([LossyTaskRecord].self, forKey: .tasks) ?? []
    self.tasks = lossy.compactMap(\.record)
  }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(schemaVersion, forKey: .schemaVersion)
    try container.encode(didSeedTasks, forKey: .didSeedTasks)
    try container.encode(tasks, forKey: .tasks)
  }

  /// Wrapper whose `init(from:)` swallows the element's decode error, so a
  /// malformed entry decodes to `nil` instead of failing the array.
  nonisolated struct LossyTaskRecord: Decodable, Sendable {
    let record: TaskRecord?

    init(from decoder: any Decoder) throws {
      self.record = try? TaskRecord(from: decoder)
    }
  }
}

/// Reads and writes the task inbox at `~/.supacode/tasks.json`.
///
/// Deliberately not a `SharedKey`: the seeder and the reducer need explicit
/// load/save points (seed-once, ownership mutations), and a sibling file with a
/// plain store keeps `sidebar.json` structurally untouchable by task work (A11).
nonisolated struct TaskStore: Sendable {
  private static let logger = SupaLogger("Tasks")

  let url: URL
  private let storage: SettingsFileStorage

  init(url: URL? = nil, storage: SettingsFileStorage? = nil) {
    @Dependency(\.settingsFileStorage) var defaultStorage
    self.url = url ?? SupacodePaths.tasksURL
    self.storage = storage ?? defaultStorage
  }

  /// Never throws: a missing file is a fresh start, and a whole-file decode
  /// failure is renamed aside before falling back to empty so the next `save`
  /// can't overwrite the only copy of the user's tasks.
  func load() -> TaskStoreFile {
    let data: Data
    do {
      data = try storage.load(url)
    } catch {
      return TaskStoreFile()
    }
    do {
      return try JSONDecoder().decode(TaskStoreFile.self, from: data)
    } catch {
      Self.logger.warning(
        "Failed to decode tasks from \(url.path(percentEncoded: false)): \(error)"
      )
      renameCorruptFile()
      return TaskStoreFile()
    }
  }

  /// Atomic through `SettingsFileStorage`, whose live value is
  /// `SymlinkPreservingFileWriter` (temp + rename, symlink preserved). A crashed
  /// write therefore leaves the previous complete file, never a truncated one.
  func save(_ file: TaskStoreFile) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    do {
      try storage.save(encoder.encode(file), url)
    } catch {
      Self.logger.error(
        "Failed to persist tasks to \(url.path(percentEncoded: false)): \(error)"
      )
      throw error
    }
  }

  /// Moves a corrupt `tasks.json` aside to `tasks.json.corrupt-<ISO8601>`.
  /// A missing or already-renamed file returns silently; a failed rename logs so
  /// the double failure is unambiguous, and the caller still proceeds to empty.
  private func renameCorruptFile() {
    let sourcePath = url.path(percentEncoded: false)
    guard FileManager.default.fileExists(atPath: sourcePath) else {
      return
    }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    let timestamp = formatter.string(from: Date()).replacing(":", with: "-")
    let destination = url.deletingLastPathComponent()
      .appending(
        path: "\(url.lastPathComponent).corrupt-\(timestamp)",
        directoryHint: .notDirectory
      )
    do {
      try SymlinkPreservingFileWriter.moveAside(at: url, to: destination)
    } catch {
      Self.logger.warning(
        """
        Failed to rename corrupt tasks file to \(destination.lastPathComponent): \(error). \
        Next save WILL overwrite the corrupt bytes.
        """
      )
    }
  }
}

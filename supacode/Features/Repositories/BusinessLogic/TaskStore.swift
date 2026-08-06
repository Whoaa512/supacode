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
  private static let logger = SupaLogger("Tasks")

  /// Bumped only for a shape change this build could not otherwise decode.
  /// Additive fields never bump it — `TaskRecord`'s decode tolerates them.
  static let currentSchemaVersion = 1

  var schemaVersion: Int
  var didSeedTasks: Bool
  var tasks: [TaskRecord]
  /// Records present in the file that this build could not decode at all.
  /// Never persisted and never part of equality: it is decode-time diagnostics
  /// that `TaskStore.load` uses to tell one bad record (lossy, keep going) from
  /// a systemic decode failure (every record lost — treat as corruption).
  var droppedRecordCount: Int = 0

  init(
    schemaVersion: Int = TaskStoreFile.currentSchemaVersion,
    didSeedTasks: Bool = false,
    tasks: [TaskRecord] = []
  ) {
    self.schemaVersion = schemaVersion
    self.didSeedTasks = didSeedTasks
    self.tasks = tasks
  }

  static func == (lhs: TaskStoreFile, rhs: TaskStoreFile) -> Bool {
    lhs.schemaVersion == rhs.schemaVersion
      && lhs.didSeedTasks == rhs.didSeedTasks
      && lhs.tasks == rhs.tasks
  }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion
    case didSeedTasks
    case tasks
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    // An absent version is this build's version, not 0: writing 0 back would
    // brand a file we understand as pre-schema and invite a bogus migration.
    self.schemaVersion =
      (try? container.decodeIfPresent(Int.self, forKey: .schemaVersion))
      ?? TaskStoreFile.currentSchemaVersion
    self.didSeedTasks = (try? container.decodeIfPresent(Bool.self, forKey: .didSeedTasks)) ?? false
    // Per-element lossy: one unreadable record costs that record only, never the
    // whole inbox (A12). `LossyTaskRecord.init` never throws, so the array
    // container always advances past a bad element.
    let lossy = try container.decodeIfPresent([LossyTaskRecord].self, forKey: .tasks) ?? []
    self.droppedRecordCount = lossy.count { $0.record == nil }
    self.tasks = Self.deduplicated(lossy.compactMap(\.record))
  }

  /// Keeps the first record per id. A duplicate id would make `IdentifiedArray`
  /// lookups and ownership mutations ambiguous, and the later copy is the one
  /// with no provenance (hand-edit, bad merge of two `tasks.json` copies).
  private static func deduplicated(_ records: [TaskRecord]) -> [TaskRecord] {
    var seen: Set<TaskID> = []
    var unique: [TaskRecord] = []
    for record in records {
      guard seen.insert(record.id).inserted else {
        Self.logger.warning("Dropping duplicate task id \(record.id) while decoding tasks")
        continue
      }
      unique.append(record)
    }
    return unique
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

/// Outcome of a `TaskStore.load`. The unreadable case exists so a transient read
/// failure (permissions, I/O error) can never be mistaken for a fresh install:
/// treating it as empty would let the next save overwrite every task and
/// re-enable seeding.
nonisolated enum TaskStoreLoadResult: Equatable, Sendable {
  /// Decoded contents, an empty file because none exists yet, or an empty file
  /// after corrupt bytes were moved aside. Safe to save over.
  case file(TaskStoreFile)
  /// `tasks.json` exists but could not be read. Callers must not save.
  case unreadable

  /// Contents when the load produced a saveable file, `nil` when unreadable.
  var file: TaskStoreFile? {
    guard case .file(let file) = self else { return nil }
    return file
  }
}

nonisolated enum TaskStoreError: Error, Equatable {
  /// The file carries a schema this build does not know how to write. Encoding
  /// it would drop the newer build's fields while keeping its version number,
  /// so the loss would be invisible to both builds.
  case schemaFromNewerBuild(fileVersion: Int, supportedVersion: Int)
}

/// Reads and writes the task inbox at `~/.supacode/tasks.json`.
///
/// Deliberately not a `SharedKey`: the seeder and the reducer need explicit
/// load/save points (seed-once, ownership mutations), and a sibling file with a
/// plain store keeps `sidebar.json` structurally untouchable by task work (A11).
nonisolated struct TaskStore: Sendable {
  private static let logger = SupaLogger("Tasks")

  let url: URL

  /// Holds only the URL: `\.settingsFileStorage` is read inside `load` / `save`
  /// so a `withDependencies` override that wraps a call still applies, instead
  /// of the store freezing whichever storage existed when it was constructed.
  init(url: URL? = nil) {
    self.url = url ?? SupacodePaths.tasksURL
  }

  /// Never throws. Returns `.unreadable` for a present-but-unreadable file,
  /// `.file` for everything a save may safely follow: an absent file, a decoded
  /// file, or empty after corrupt bytes were moved aside.
  func load() -> TaskStoreLoadResult {
    @Dependency(\.settingsFileStorage) var storage
    let data: Data
    do {
      data = try storage.load(url)
    } catch {
      // Only an absent file is a fresh start. Anything else means bytes we
      // couldn't read are still on disk, and reporting empty here would erase
      // them on the next save and re-seed on top.
      guard Self.isFileAbsent(error) else {
        Self.logger.error(
          """
          Failed to read tasks from \(url.path(percentEncoded: false)): \(error). \
          Refusing to treat this as an empty inbox; no save may follow.
          """
        )
        return .unreadable
      }
      return .file(TaskStoreFile())
    }

    let file: TaskStoreFile
    do {
      file = try Self.makeDecoder().decode(TaskStoreFile.self, from: data)
    } catch {
      Self.logger.warning(
        "Failed to decode tasks from \(url.path(percentEncoded: false)): \(error)"
      )
      moveFileAside(kind: "corrupt", storage: storage)
      return .file(TaskStoreFile())
    }

    guard file.droppedRecordCount > 0 else { return .file(file) }

    guard !file.tasks.isEmpty else {
      // Every record failed: that is a systemic problem (a date-format or shape
      // change), not one bad row, and the file decoding "successfully empty"
      // would let the next save erase the whole inbox.
      Self.logger.error(
        """
        All \(file.droppedRecordCount) task records in \
        \(url.path(percentEncoded: false)) failed to decode; treating the file as corrupt.
        """
      )
      moveFileAside(kind: "corrupt", storage: storage)
      return .file(TaskStoreFile())
    }

    Self.logger.warning(
      """
      Dropped \(file.droppedRecordCount) unreadable task record(s) from \
      \(url.path(percentEncoded: false)); keeping \(file.tasks.count).
      """
    )
    copyDroppedEvidence(data, storage: storage)
    return .file(file)
  }

  /// Atomic through `SettingsFileStorage`, whose live value is
  /// `SymlinkPreservingFileWriter` (temp + rename, symlink preserved). A crashed
  /// write therefore leaves the previous complete file, never a truncated one.
  func save(_ file: TaskStoreFile) throws {
    guard file.schemaVersion <= TaskStoreFile.currentSchemaVersion else {
      let error = TaskStoreError.schemaFromNewerBuild(
        fileVersion: file.schemaVersion,
        supportedVersion: TaskStoreFile.currentSchemaVersion
      )
      Self.logger.error(
        """
        Refusing to write tasks at schema \(file.schemaVersion) \
        (this build writes \(TaskStoreFile.currentSchemaVersion)): a newer build's fields \
        would be stripped while its version number survived.
        """
      )
      throw error
    }
    @Dependency(\.settingsFileStorage) var storage
    do {
      try storage.save(Self.makeEncoder().encode(file), url)
    } catch {
      Self.logger.error(
        "Failed to persist tasks to \(url.path(percentEncoded: false)): \(error)"
      )
      throw error
    }
  }

  /// Dates are pinned to epoch seconds on both sides so the on-disk format can
  /// never drift with a Foundation default. An unpinned pair is exactly how a
  /// whole inbox becomes per-element-undecodable at once.
  private static func makeDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .secondsSince1970
    return decoder
  }

  private static func makeEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .secondsSince1970
    return encoder
  }

  /// True only when the read failed because the file does not exist.
  private static func isFileAbsent(_ error: any Error) -> Bool {
    if let cocoa = error as? CocoaError, cocoa.code == .fileReadNoSuchFile { return true }
    if let posix = error as? POSIXError, posix.code == .ENOENT { return true }
    return false
  }

  /// Moves an unusable `tasks.json` aside so the empty fallback's next save
  /// can't overwrite the only copy of the user's tasks. Goes through the
  /// injected storage, not `FileManager`, so tests exercise the real aside.
  private func moveFileAside(kind: String, storage: SettingsFileStorage) {
    let destination = SymlinkPreservingFileWriter.asideURL(for: url, kind: kind)
    do {
      try storage.moveAside(url, destination)
    } catch {
      Self.logger.warning(
        """
        Failed to move tasks file aside to \(destination.lastPathComponent): \(error). \
        Next save WILL overwrite the bad bytes.
        """
      )
    }
  }

  /// Copies — never moves — the bytes behind a partial decode. The surviving
  /// tasks stay live in `tasks.json`, so the evidence for the dropped ones has
  /// to be a second copy rather than a rename.
  private func copyDroppedEvidence(_ data: Data, storage: SettingsFileStorage) {
    let destination = SymlinkPreservingFileWriter.asideURL(for: url, kind: "dropped")
    do {
      try storage.save(data, destination)
    } catch {
      Self.logger.warning(
        "Failed to copy dropped-record evidence to \(destination.lastPathComponent): \(error)"
      )
    }
  }
}

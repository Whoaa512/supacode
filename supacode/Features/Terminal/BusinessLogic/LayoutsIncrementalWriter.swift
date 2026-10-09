import Dependencies
import Foundation
import SupacodeSettingsShared

/// Thread-safe UserDefaults handle for the layouts blob. `UserDefaults` is
/// documented thread-safe, so `@unchecked Sendable` is honest, and `nonisolated`
/// lets the off-main writer own the read-modify-write without hopping to the main
/// actor (the module defaults to main-actor isolation).
nonisolated struct LayoutsUserDefaultsStore: @unchecked Sendable {
  let defaults: UserDefaults

  func read() -> Data? { defaults.data(forKey: LayoutsFile.userDefaultsKey) }
  func write(_ data: Data) { defaults.set(data, forKey: LayoutsFile.userDefaultsKey) }

  /// Stashes an undecodable blob under a sibling key so a wholly-unreadable value
  /// (genuine corruption, or a newer schema after a downgrade) survives for
  /// diagnosis while the live store recovers to a fresh value.
  /// False when the stash does not hold these bytes afterwards; the caller
  /// must then leave the live value alone, since it is the only copy.
  func stashCorrupt(_ data: Data) -> Bool {
    let key = LayoutsFile.userDefaultsKey + ".corrupt"
    defaults.set(data, forKey: key)
    return defaults.data(forKey: key) == data
  }

  /// Keeps the pre-v3 bytes before v3 replaces them. Write-once: a later
  /// legacy blob never overwrites the first backup. False when no backup is
  /// held afterwards; the caller must then leave the legacy bytes alone.
  func backUpLegacyIfAbsent(_ data: Data) -> Bool {
    if defaults.data(forKey: LayoutsFile.preTasksBackupKey) != nil { return true }
    defaults.set(data, forKey: LayoutsFile.preTasksBackupKey)
    return defaults.data(forKey: LayoutsFile.preTasksBackupKey) != nil
  }

  /// Keeps the unsplit bytes before the task split replaces them. Write-once,
  /// same contract as `backUpLegacyIfAbsent`.
  func backUpUnsplitIfAbsent(_ data: Data) -> Bool {
    if defaults.data(forKey: LayoutsFile.preSplitBackupKey) != nil { return true }
    defaults.set(data, forKey: LayoutsFile.preSplitBackupKey)
    return defaults.data(forKey: LayoutsFile.preSplitBackupKey) != nil
  }

  /// Forces a synchronous flush for the on-quit write, where the run loop is
  /// tearing down before UserDefaults' own periodic flush would run.
  func synchronize() { defaults.synchronize() }
}

/// Serialized off-main writer for incremental layout persistence. Every flush
/// re-reads the layouts blob from UserDefaults, splices in only the per-task
/// keys it carries, then writes the whole value back. Being an actor makes the
/// read-modify-write a FIFO critical section: a positive record and a delete
/// tombstone for the same key can't interleave, and concurrent keys from
/// separate flushes both survive (last-writer-wins per key, not whole-file).
actor LayoutsIncrementalWriter {
  /// One per-task change to splice into the value. `.delete` is an explicit
  /// tombstone: absence from a flush means "leave the key alone", so a pruned
  /// layout must be carried as `.delete`, never as omission.
  enum RecordChange: Sendable {
    /// Upsert: an existing task takes the layout and, after the sessions it
    /// already lists, any it does not list yet (its directory and `createdAt`
    /// are kept, and no stored session is ever dropped or moved); a new one
    /// is created from all four. A task left with
    /// no tab and no session is removed like a `.delete`.
    case record(layout: PaneLayout, directory: TaskRecord.Directory, sessions: [SessionKey] = [], createdAt: Date)
    case delete
    /// A delete keyed on a guess from the directory: a stored record that
    /// names another directory is that directory's task and stays.
    case deleteIfOn(Worktree.ID)
  }

  private static let logger = SupaLogger("Layouts")
  /// Dedicated executor so the encode never runs on the cooperative pool, and
  /// never on main when the test main serial executor is active.
  private nonisolated let executorQueue = DispatchSerialQueue(label: "app.supabit.supacode.layouts-writer")
  nonisolated var unownedExecutor: UnownedSerialExecutor { executorQueue.asUnownedSerialExecutor() }
  private let store: LayoutsUserDefaultsStore
  /// Redundant now that `flushSync` also runs on `executorQueue`, so the queue
  /// serializes every write and owns their ordering; kept as belt-and-suspenders
  /// mutual exclusion around the read-modify-write.
  private let writeLock = NSLock()

  init(store: LayoutsUserDefaultsStore) {
    self.store = store
  }

  /// Re-reads the persisted value, applies `changes`, and writes the result.
  /// Keys not present in `changes` are preserved untouched.
  func flush(records changes: [LayoutID: RecordChange]) {
    applyAndWriteRecords(changes, synchronize: false)
  }

  /// Synchronous variant for the on-quit terminal write, where the run loop is
  /// tearing down and there's no chance to await the actor. Runs on the writer's
  /// serial executor so this terminal write is FIFO-ordered strictly after any
  /// flush already enqueued at quit, never overtaken and regressed by a late one.
  /// Forces a UserDefaults flush so the last write survives termination.
  nonisolated func flushSync(records changes: [LayoutID: RecordChange]) {
    executorQueue.sync { applyAndWriteRecords(changes, synchronize: true) }
  }

  /// Records which task a directory resolves to; `nil` clears the entry, so
  /// the directory falls back to the task stored under its own key.
  func flush(activeTask layoutID: LayoutID?, forDirectory directoryID: Worktree.ID) {
    update(synchronize: false) { file in
      file.activeTasks[directoryID.rawValue] = layoutID?.persistenceKey
    }
  }

  private nonisolated func applyAndWriteRecords(_ changes: [LayoutID: RecordChange], synchronize: Bool) {
    guard !changes.isEmpty else { return }
    update(synchronize: synchronize) { file in Self.apply(changes, to: &file) }
  }

  private nonisolated func update(synchronize: Bool, _ mutate: (inout TaskLayoutsFile) -> Void) {
    writeLock.lock()
    defer { writeLock.unlock() }
    guard var file = readPersisted() else { return }
    let original = file
    mutate(&file)
    guard file != original else { return }
    write(file, synchronize: synchronize)
  }

  private nonisolated static func apply(_ changes: [LayoutID: RecordChange], to file: inout TaskLayoutsFile) {
    var vacatedDirectories: Set<String> = []
    func remove(_ key: String) {
      // A task that was never written can only be a directory's own-key
      // one, whose key is the directory.
      let removed = file.tasks.removeValue(forKey: key)
      vacatedDirectories.insert(removed?.directory.worktreeID.rawValue ?? key)
      file.activeTasks = file.activeTasks.filter { $0.value != key }
    }
    for (id, change) in changes {
      let key = id.persistenceKey
      switch change {
      case .record(let layout, let directory, let sessions, let createdAt):
        var task = file.tasks[key] ?? TaskRecord(id: id, directory: directory, createdAt: createdAt)
        task.layout = layout
        // The caller may not have loaded the stored sessions, so its list
        // only adds to them: stored order stands (the first is the primary)
        // and anything new goes after.
        task.sessions += sessions.filter { !task.sessions.contains($0) }
        // Nothing open and nothing to resume: the task leaves no trace. One
        // with sessions stays, so its members are still there to resume.
        guard layout.panes.isEmpty, task.sessions.isEmpty else {
          file.tasks[key] = task
          continue
        }
        remove(key)
      case .deleteIfOn(let directoryID):
        // The directory itself is going, whoever holds its key.
        vacatedDirectories.insert(directoryID.rawValue)
        if let stored = file.tasks[key], stored.directory.worktreeID != directoryID { continue }
        remove(key)
      case .delete:
        remove(key)
      }
    }
    // An origin belongs to its directory, not to the task stored under the
    // directory's key: it is released to the reaper only with the directory's
    // last task, whichever id that task has.
    let occupied = Set(file.tasks.values.map(\.directory.worktreeID.rawValue))
    for directory in vacatedDirectories.subtracting(occupied) {
      file.origins.removeValue(forKey: directory)
    }
  }

  /// The persisted layouts; an empty stamped value when absent or after a
  /// wholly-undecodable blob is stashed aside; `nil` (abort the flush) on a
  /// lossy-but-decodable value, so the caller never makes partial loss
  /// permanent, and on a newer schema, which is read-only for this build.
  /// A v2 blob is backed up before the caller's v3 write replaces it, and a
  /// failed backup or stash aborts the flush too.
  private nonisolated func readPersisted() -> TaskLayoutsFile? {
    guard let data = store.read() else { return TaskLayoutsFile() }
    switch TaskLayoutsFile.classify(data) {
    case .tasks(let file):
      return file
    case .legacy(let file):
      guard store.backUpLegacyIfAbsent(data) else {
        Self.logger.error("Aborting layout flush: the pre-v3 layouts could not be backed up.")
        return nil
      }
      return file
    case .newer(let version):
      Self.logger.warning("Skipping layout flush into newer schema v\(version).")
      return nil
    case .lossy:
      Self.logger.error("Aborting layout flush: persisted blob has unreadable entries.")
      return nil
    case .undecodable:
      guard store.stashCorrupt(data) else {
        Self.logger.error("Aborting layout flush: the undecodable layouts blob could not be stashed aside.")
        return nil
      }
      Self.logger.error("Persisted layouts blob undecodable; stashed it aside and starting fresh.")
      return TaskLayoutsFile()
    }
  }

  private nonisolated func write(_ file: TaskLayoutsFile, synchronize: Bool) {
    do {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      store.write(try encoder.encode(file))
      if synchronize { store.synchronize() }
    } catch {
      Self.logger.warning("Failed to write incremental layouts: \(error)")
    }
  }

  /// True only when a file read failed because the file does not exist. Retained
  /// for the legacy `layouts.json` readers in the migration path.
  static func isFileAbsent(_ error: Error) -> Bool {
    if let cocoa = error as? CocoaError, cocoa.code == .fileReadNoSuchFile { return true }
    if let posix = error as? POSIXError, posix.code == .ENOENT { return true }
    return false
  }
}

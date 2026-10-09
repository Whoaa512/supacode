import Foundation

/// In-memory `UserDefaults` that logs every write in order and can refuse
/// writes to chosen keys, so a test can pin "backup before the first write"
/// and what happens when the backup cannot be made. Nothing reaches disk.
nonisolated final class RecordingUserDefaults: UserDefaults, @unchecked Sendable {
  private let lock = NSLock()
  private var store: [String: Any] = [:]
  private var log: [String] = []
  private let refusedKeys: Set<String>

  init(refusingWritesTo refusedKeys: Set<String> = []) {
    self.refusedKeys = refusedKeys
    super.init(suiteName: "recording-\(UUID().uuidString)")!
  }

  /// Keys in the order they were written; refused writes are not listed.
  var writtenKeys: [String] {
    lock.withLock { log }
  }

  override func object(forKey defaultName: String) -> Any? {
    lock.withLock { store[defaultName] }
  }

  override func data(forKey defaultName: String) -> Data? {
    lock.withLock { store[defaultName] as? Data }
  }

  override func bool(forKey defaultName: String) -> Bool {
    lock.withLock { store[defaultName] as? Bool ?? false }
  }

  override func set(_ value: Any?, forKey defaultName: String) {
    lock.withLock {
      guard !refusedKeys.contains(defaultName) else { return }
      store[defaultName] = value
      log.append(defaultName)
    }
  }

  override func set(_ value: Bool, forKey defaultName: String) {
    set(value as Any?, forKey: defaultName)
  }

  override func removeObject(forKey defaultName: String) {
    lock.withLock { store[defaultName] = nil }
  }

  override func synchronize() -> Bool { true }
}

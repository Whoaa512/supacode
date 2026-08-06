import Dependencies
import Foundation
import Sharing

public nonisolated struct SettingsFileStorage: Sendable {
  public var load: @Sendable (URL) throws -> Data
  public var save: @Sendable (Data, URL) throws -> Void
  /// Moves the file at the first URL to the second. Part of the dependency so a
  /// corrupt-file rename is substitutable in tests: a store that renamed through
  /// `FileManager` directly would silently skip the aside against in-memory
  /// storage, and the "corrupt bytes are preserved" guarantee would go untested.
  public var moveAside: @Sendable (URL, URL) throws -> Void

  public init(
    load: @escaping @Sendable (URL) throws -> Data,
    save: @escaping @Sendable (Data, URL) throws -> Void,
    // Defaults to the real on-disk rename so existing call sites keep their
    // behaviour; substitute it explicitly when the load/save pair is in-memory.
    moveAside: @escaping @Sendable (URL, URL) throws -> Void = {
      try SymlinkPreservingFileWriter.moveAside(at: $0, to: $1)
    }
  ) {
    self.load = load
    self.save = save
    self.moveAside = moveAside
  }
}

public nonisolated enum SettingsFileStorageKey: DependencyKey {
  public static var liveValue: SettingsFileStorage {
    SettingsFileStorage(
      load: { try Data(contentsOf: $0) },
      save: { data, url in try SymlinkPreservingFileWriter.write(data, to: url) },
      moveAside: { source, destination in
        try SymlinkPreservingFileWriter.moveAside(at: source, to: destination)
      }
    )
  }
  public static var previewValue: SettingsFileStorage { .inMemory() }
  public static var testValue: SettingsFileStorage { .inMemory() }
}

public nonisolated enum SettingsFileURLKey: DependencyKey {
  public static var liveValue: URL { SupacodePaths.settingsURL }
  public static var previewValue: URL { SupacodePaths.settingsURL }
  public static var testValue: URL { SupacodePaths.settingsURL }
}

extension DependencyValues {
  public nonisolated var settingsFileStorage: SettingsFileStorage {
    get { self[SettingsFileStorageKey.self] }
    set { self[SettingsFileStorageKey.self] = newValue }
  }

  public nonisolated var settingsFileURL: URL {
    get { self[SettingsFileURLKey.self] }
    set { self[SettingsFileURLKey.self] = newValue }
  }
}

extension SettingsFileStorage {
  public nonisolated static func inMemory() -> SettingsFileStorage {
    let storage = InMemorySettingsFileStorage()
    return SettingsFileStorage(
      load: { try storage.load($0) },
      save: { try storage.save($0, $1) },
      moveAside: { try storage.moveAside($0, $1) }
    )
  }
}

nonisolated final class InMemorySettingsFileStorage: @unchecked Sendable {
  private let lock = NSLock()
  private var dataByURL: [URL: Data] = [:]

  func load(_ url: URL) throws -> Data {
    lock.lock()
    defer { lock.unlock() }
    guard let data = dataByURL[url] else {
      // Mirror real-disk semantics so callers that distinguish "file absent"
      // (fresh start) from a read failure see the same `fileReadNoSuchFile`.
      throw CocoaError(.fileReadNoSuchFile)
    }
    return data
  }

  func save(_ data: Data, _ url: URL) throws {
    lock.lock()
    defer { lock.unlock() }
    dataByURL[url] = data
  }

  /// Re-keys the bytes so a rename is observable in memory, and throws
  /// `fileNoSuchFile` for an absent source exactly as `FileManager` would.
  func moveAside(_ source: URL, _ destination: URL) throws {
    lock.lock()
    defer { lock.unlock() }
    guard let data = dataByURL.removeValue(forKey: source) else {
      throw CocoaError(.fileNoSuchFile)
    }
    dataByURL[destination] = data
  }
}

public nonisolated struct SettingsFileKeyID: Hashable, Sendable {
  public let url: URL

  public init(url: URL) {
    self.url = url
  }
}

public nonisolated struct SettingsFileKey: SharedKey {
  public let url: URL

  public init(url: URL? = nil) {
    if let url {
      self.url = url
      return
    }
    @Dependency(\.settingsFileURL) var settingsFileURL
    self.url = settingsFileURL
  }

  public var id: SettingsFileKeyID {
    SettingsFileKeyID(url: url)
  }

  public func load(context: LoadContext<SettingsFile>, continuation: LoadContinuation<SettingsFile>) {
    @Dependency(\.settingsFileStorage) var storage
    let decoder = Self.makeDecoder()
    if let data = try? storage.load(url),
      let settings = try? decoder.decode(SettingsFile.self, from: data)
    {
      continuation.resume(returning: settings)
      return
    }

    let initial = context.initialValue ?? .default
    _ = try? save(initial, storage: storage)
    continuation.resumeReturningInitialValue()
  }

  public func subscribe(
    context _: LoadContext<SettingsFile>,
    subscriber _: SharedSubscriber<SettingsFile>
  ) -> SharedSubscription {
    SharedSubscription {}
  }

  public func save(_ value: SettingsFile, context _: SaveContext, continuation: SaveContinuation) {
    @Dependency(\.settingsFileStorage) var storage
    do {
      try save(value, storage: storage)
      continuation.resume()
    } catch {
      continuation.resume(throwing: error)
    }
  }

  private func save(_ value: SettingsFile, storage: SettingsFileStorage) throws {
    let data = try Self.makeEncoder().encode(value)
    try storage.save(data, url)
  }

  private static func makeDecoder() -> JSONDecoder {
    JSONDecoder()
  }

  private static func makeEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return encoder
  }
}
nonisolated extension SharedReaderKey where Self == SettingsFileKey.Default {
  public static var settingsFile: Self {
    Self[SettingsFileKey(), default: .default]
  }
}

import Dependencies
import Foundation
import Testing

@testable import SupacodeSettingsShared
@testable import supacode

struct TaskStoreTests {
  private static let referenceDate = Date(timeIntervalSince1970: 1_700_000_000)

  /// Isolated temp directory + the *live* file storage, so every test exercises
  /// the real atomic write and the real rename-aside path without touching the
  /// user's `~/.supacode/tasks.json`.
  private final class Sandbox {
    let directory: URL
    let tasksURL: URL
    let store: TaskStore
    private let storage: SettingsFileStorage

    init(storage: SettingsFileStorage = SettingsFileStorageKey.liveValue) throws {
      directory = FileManager.default.temporaryDirectory
        .appending(path: "TaskStoreTests-\(UUID().uuidString)", directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      tasksURL = directory.appending(path: "tasks.json", directoryHint: .notDirectory)
      store = TaskStore(url: tasksURL)
      self.storage = storage
    }

    /// The store reads `\.settingsFileStorage` per call (so an override always
    /// applies), so every test call goes through the sandbox's storage here.
    func load() -> TaskStoreLoadResult {
      withDependencies { $0.settingsFileStorage = storage } operation: { store.load() }
    }

    func loadFile(sourceLocation: SourceLocation = #_sourceLocation) throws -> TaskStoreFile {
      try #require(load().file, sourceLocation: sourceLocation)
    }

    func save(_ file: TaskStoreFile) throws {
      try withDependencies { $0.settingsFileStorage = storage } operation: { try store.save(file) }
    }

    func entries() throws -> [String] {
      try FileManager.default
        .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        .map(\.lastPathComponent)
        .sorted()
    }

    func write(_ json: String) throws {
      try Data(json.utf8).write(to: tasksURL)
    }

    deinit {
      try? FileManager.default.removeItem(at: directory)
    }
  }

  /// In-memory storage with an injectable read failure, so the "present but
  /// unreadable" branch and the storage-routed rename are both observable.
  private final class StubStorage: @unchecked Sendable {
    private let lock = NSLock()
    private var dataByURL: [URL: Data] = [:]
    private let loadError: (any Error)?

    init(loadError: (any Error)? = nil) {
      self.loadError = loadError
    }

    var storage: SettingsFileStorage {
      SettingsFileStorage(
        load: { try self.read($0) },
        save: { self.put($0, at: $1) },
        moveAside: { try self.move($0, to: $1) }
      )
    }

    var urls: [URL] {
      lock.lock()
      defer { lock.unlock() }
      return Array(dataByURL.keys)
    }

    func put(_ data: Data, at url: URL) {
      lock.lock()
      defer { lock.unlock() }
      dataByURL[url] = data
    }

    func data(at url: URL) -> Data? {
      lock.lock()
      defer { lock.unlock() }
      return dataByURL[url]
    }

    private func read(_ url: URL) throws -> Data {
      if let loadError { throw loadError }
      lock.lock()
      defer { lock.unlock() }
      guard let data = dataByURL[url] else { throw CocoaError(.fileReadNoSuchFile) }
      return data
    }

    private func move(_ source: URL, to destination: URL) throws {
      lock.lock()
      defer { lock.unlock() }
      guard let data = dataByURL.removeValue(forKey: source) else {
        throw CocoaError(.fileNoSuchFile)
      }
      dataByURL[destination] = data
    }
  }

  private static func makeRecord(id: String, title: String = "task") -> TaskRecord {
    TaskRecord(
      id: TaskID(id),
      title: title,
      directoryPath: "/Users/test/code/\(id)",
      branch: "main",
      createdAt: referenceDate,
      surfaceIDs: [UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!],
      seedEvidence: .init(source: .currentBranch, confidence: .high)
    )
  }

  @Test func missingFileLoadsEmptyAndUnseeded() throws {
    let sandbox = try Sandbox()
    let file = try sandbox.loadFile()
    #expect(file.tasks.isEmpty)
    #expect(file.didSeedTasks == false)
    #expect(try sandbox.entries().isEmpty)
  }

  @Test func savedFileRoundTrips() throws {
    let sandbox = try Sandbox()
    let saved = TaskStoreFile(
      didSeedTasks: true,
      tasks: [Self.makeRecord(id: "a"), Self.makeRecord(id: "b")]
    )
    try sandbox.save(saved)
    #expect(try sandbox.loadFile() == saved)
  }

  @Test func didSeedTasksPersists() throws {
    let sandbox = try Sandbox()
    try sandbox.save(TaskStoreFile(didSeedTasks: true, tasks: [Self.makeRecord(id: "a")]))
    #expect(try sandbox.loadFile().didSeedTasks == true)

    var reloaded = try sandbox.loadFile()
    reloaded.tasks.append(Self.makeRecord(id: "b"))
    try sandbox.save(reloaded)
    // Seeding must stay done across a later mutation, or a relaunch re-seeds
    // and duplicates every task (A13).
    #expect(try sandbox.loadFile().didSeedTasks == true)
    #expect(try sandbox.loadFile().tasks.count == 2)
  }

  @Test func oneMalformedElementLosesOnlyThatElement() throws {
    let sandbox = try Sandbox()
    let json = """
      {
        "schemaVersion": 1,
        "didSeedTasks": true,
        "tasks": [
          { "id": "good-1", "title": "keep me", "directoryPath": "/tmp/a", "createdAt": 0 },
          { "title": "no id", "directoryPath": "/tmp/b", "createdAt": 0 },
          "not-even-an-object",
          { "id": "good-2", "title": "keep me too", "directoryPath": "/tmp/c", "createdAt": 0 }
        ]
      }
      """
    try sandbox.write(json)
    let file = try sandbox.loadFile()
    #expect(file.tasks.map(\.id) == [TaskID("good-1"), TaskID("good-2")])
    #expect(file.didSeedTasks == true)
    // The surviving tasks stay live in tasks.json; the dropped ones' bytes are
    // preserved as a *copy* beside it.
    let entries = try sandbox.entries()
    #expect(entries.contains("tasks.json"))
    let evidence = try #require(entries.first { $0.hasPrefix("tasks.json.dropped-") })
    let evidenceURL = sandbox.directory.appending(path: evidence, directoryHint: .notDirectory)
    #expect(try String(bytes: Data(contentsOf: evidenceURL), encoding: .utf8) == json)
    #expect(try String(bytes: Data(contentsOf: sandbox.tasksURL), encoding: .utf8) == json)
  }

  @Test func everyRecordFailingToDecodeIsTreatedAsCorruptionNotAnEmptyInbox() throws {
    // A systemic decode failure (a date-format or shape change) would otherwise
    // look like a valid empty file and let the next save erase the whole inbox.
    let json = """
      {
        "schemaVersion": 1,
        "didSeedTasks": true,
        "tasks": [
          { "title": "no id", "directoryPath": "/tmp/a", "createdAt": 0 },
          { "title": "also no id", "directoryPath": "/tmp/b", "createdAt": 0 }
        ]
      }
      """
    let sandbox = try Sandbox()
    try sandbox.write(json)

    let file = try sandbox.loadFile()
    #expect(file.tasks.isEmpty)
    #expect(file.didSeedTasks == false)

    let entries = try sandbox.entries()
    #expect(!entries.contains("tasks.json"))
    let aside = try #require(entries.first { $0.hasPrefix("tasks.json.corrupt-") })
    let asideURL = sandbox.directory.appending(path: aside, directoryHint: .notDirectory)
    #expect(try String(bytes: Data(contentsOf: asideURL), encoding: .utf8) == json)
  }

  @Test func unreadableFileIsNeverReportedAsAnEmptyInbox() throws {
    let storage = StubStorage(loadError: CocoaError(.fileReadNoPermission))
    let sandbox = try Sandbox(storage: storage.storage)
    // A transient read failure must not read as a fresh install: reporting empty
    // here would erase the unread bytes on the next save and re-seed on top.
    #expect(sandbox.load() == .unreadable)
    #expect(sandbox.load().file == nil)
  }

  @Test func absentFileFromStorageLoadsFresh() throws {
    let storage = StubStorage(loadError: CocoaError(.fileReadNoSuchFile))
    let sandbox = try Sandbox(storage: storage.storage)
    #expect(try sandbox.loadFile() == TaskStoreFile())
  }

  @Test func corruptFileIsMovedAsideThroughTheInjectedStorage() throws {
    let storage = StubStorage()
    let sandbox = try Sandbox(storage: storage.storage)
    storage.put(Data("this-is-not-json".utf8), at: sandbox.tasksURL)

    #expect(try sandbox.loadFile().tasks.isEmpty)
    // The rename must go through the dependency, not FileManager, or in-memory
    // storage silently skips the aside and the bad bytes get overwritten.
    #expect(storage.data(at: sandbox.tasksURL) == nil)
    let aside = try #require(storage.urls.first { $0.lastPathComponent.hasPrefix("tasks.json.corrupt-") })
    #expect(storage.data(at: aside) == Data("this-is-not-json".utf8))
  }

  @Test func duplicateRecordIDsCollapseToTheFirst() throws {
    let json = """
      {
        "schemaVersion": 1,
        "tasks": [
          { "id": "dupe", "title": "first wins", "directoryPath": "/tmp/a", "createdAt": 0 },
          { "id": "dupe", "title": "second loses", "directoryPath": "/tmp/b", "createdAt": 0 },
          { "id": "other", "title": "kept", "directoryPath": "/tmp/c", "createdAt": 0 }
        ]
      }
      """
    let sandbox = try Sandbox()
    try sandbox.write(json)
    let file = try sandbox.loadFile()
    #expect(file.tasks.map(\.id) == [TaskID("dupe"), TaskID("other")])
    #expect(file.tasks.first?.title == "first wins")
    // Duplicates are not corruption: nothing moves aside.
    #expect(try sandbox.entries() == ["tasks.json"])
  }

  @Test func missingEnvelopeKeysDecodeToDefaults() throws {
    let sandbox = try Sandbox()
    try sandbox.write(#"{ "tasks": [] }"#)
    let file = try sandbox.loadFile()
    // Absent version means "a file this build understands", not version 0: a 0
    // written back would brand it pre-schema and invite a bogus migration.
    #expect(file.schemaVersion == TaskStoreFile.currentSchemaVersion)
    #expect(file.didSeedTasks == false)
    #expect(file.tasks.isEmpty)
  }

  @Test func saveRefusesAFileFromANewerSchema() throws {
    let json = """
      { "schemaVersion": 99, "didSeedTasks": true, "tasks": [] }
      """
    let sandbox = try Sandbox()
    try sandbox.write(json)
    let file = try sandbox.loadFile()

    // Encoding it would strip the newer build's fields while keeping its version
    // number, making the loss invisible to both builds.
    #expect(throws: TaskStoreError.schemaFromNewerBuild(fileVersion: 99, supportedVersion: 1)) {
      try sandbox.save(file)
    }
    #expect(try String(bytes: Data(contentsOf: sandbox.tasksURL), encoding: .utf8) == json)
  }

  @Test func unknownEnvelopeKeysFromAFutureSchemaStillDecode() throws {
    let sandbox = try Sandbox()
    let json = """
      {
        "schemaVersion": 99,
        "didSeedTasks": true,
        "collapsedSettledTail": false,
        "tasks": [
          {
            "id": "future-1",
            "title": "from a newer build",
            "directoryPath": "/tmp/a",
            "createdAt": 0,
            "estimatedMinutes": 30
          }
        ]
      }
      """
    try sandbox.write(json)
    let file = try sandbox.loadFile()
    #expect(file.schemaVersion == 99)
    #expect(file.didSeedTasks == true)
    #expect(file.tasks.map(\.id) == [TaskID("future-1")])
    #expect(try sandbox.entries() == ["tasks.json"])
  }

  @Test(arguments: ["this-is-not-json", "[]", #"{"tasks": 7}"#])
  func corruptFileIsRenamedAsideNotOverwritten(contents: String) throws {
    let sandbox = try Sandbox()
    try sandbox.write(contents)

    let file = try sandbox.loadFile()
    #expect(file.tasks.isEmpty)
    #expect(file.didSeedTasks == false)

    let entries = try sandbox.entries()
    #expect(!entries.contains("tasks.json"))
    let renamed = try #require(entries.first { $0.hasPrefix("tasks.json.corrupt-") })
    let renamedURL = sandbox.directory.appending(path: renamed, directoryHint: .notDirectory)
    // The original bytes must survive verbatim — this is the only recovery copy.
    #expect(try String(bytes: Data(contentsOf: renamedURL), encoding: .utf8) == contents)

    // A save from the empty fallback lands on a fresh file and leaves the
    // corrupt copy alone.
    try sandbox.save(TaskStoreFile(didSeedTasks: true))
    #expect(try sandbox.entries().contains("tasks.json"))
    #expect(try String(bytes: Data(contentsOf: renamedURL), encoding: .utf8) == contents)
  }

  @Test func saveLeavesNoPartialOrTemporarySibling() throws {
    let sandbox = try Sandbox()
    let big = TaskStoreFile(
      didSeedTasks: true,
      tasks: (0..<200).map { Self.makeRecord(id: "task-\($0)", title: String(repeating: "x", count: 80)) }
    )
    try sandbox.save(big)
    #expect(try sandbox.entries() == ["tasks.json"])

    // Shrinking the payload must replace the file wholesale; a partial write
    // would leave trailing bytes from the larger file and fail to decode.
    let small = TaskStoreFile(didSeedTasks: true, tasks: [Self.makeRecord(id: "only")])
    try sandbox.save(small)
    #expect(try sandbox.entries() == ["tasks.json"])
    #expect(try sandbox.loadFile() == small)
  }

  @Test func taskWritesNeverTouchTheSidebarFile() throws {
    let sandbox = try Sandbox()
    let sidebarURL = sandbox.directory.appending(path: "sidebar.json", directoryHint: .notDirectory)
    let sidebarBytes = Data(#"{"schemaVersion":1,"sections":{}}"#.utf8)
    try sidebarBytes.write(to: sidebarURL)

    try sandbox.save(TaskStoreFile(didSeedTasks: true, tasks: [Self.makeRecord(id: "a")]))
    _ = sandbox.load()

    #expect(try Data(contentsOf: sidebarURL) == sidebarBytes)
    #expect(sandbox.store.url.lastPathComponent == "tasks.json")
  }

  @Test func defaultURLIsASiblingOfSidebarJSON() {
    let store = TaskStore()
    #expect(store.url == SupacodePaths.tasksURL)
    #expect(
      store.url.deletingLastPathComponent() == SupacodePaths.sidebarURL.deletingLastPathComponent()
    )
  }
}

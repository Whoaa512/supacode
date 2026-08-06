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

    init() throws {
      directory = FileManager.default.temporaryDirectory
        .appending(path: "TaskStoreTests-\(UUID().uuidString)", directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      tasksURL = directory.appending(path: "tasks.json", directoryHint: .notDirectory)
      store = TaskStore(url: tasksURL, storage: SettingsFileStorageKey.liveValue)
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
    let file = sandbox.store.load()
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
    try sandbox.store.save(saved)
    #expect(sandbox.store.load() == saved)
  }

  @Test func didSeedTasksPersists() throws {
    let sandbox = try Sandbox()
    try sandbox.store.save(TaskStoreFile(didSeedTasks: true, tasks: [Self.makeRecord(id: "a")]))
    #expect(sandbox.store.load().didSeedTasks == true)

    var reloaded = sandbox.store.load()
    reloaded.tasks.append(Self.makeRecord(id: "b"))
    try sandbox.store.save(reloaded)
    // Seeding must stay done across a later mutation, or a relaunch re-seeds
    // and duplicates every task (A13).
    #expect(sandbox.store.load().didSeedTasks == true)
    #expect(sandbox.store.load().tasks.count == 2)
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
    let file = sandbox.store.load()
    #expect(file.tasks.map(\.id) == [TaskID("good-1"), TaskID("good-2")])
    #expect(file.didSeedTasks == true)
    // A lossy element is not corruption: the file stays where it is.
    #expect(try sandbox.entries() == ["tasks.json"])
  }

  @Test func missingEnvelopeKeysDecodeToDefaults() throws {
    let sandbox = try Sandbox()
    try sandbox.write(#"{ "tasks": [] }"#)
    let file = sandbox.store.load()
    #expect(file.schemaVersion == 0)
    #expect(file.didSeedTasks == false)
    #expect(file.tasks.isEmpty)
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
    let file = sandbox.store.load()
    #expect(file.schemaVersion == 99)
    #expect(file.didSeedTasks == true)
    #expect(file.tasks.map(\.id) == [TaskID("future-1")])
    #expect(try sandbox.entries() == ["tasks.json"])
  }

  @Test(arguments: ["this-is-not-json", "[]", #"{"tasks": 7}"#])
  func corruptFileIsRenamedAsideNotOverwritten(contents: String) throws {
    let sandbox = try Sandbox()
    try sandbox.write(contents)

    let file = sandbox.store.load()
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
    try sandbox.store.save(TaskStoreFile(didSeedTasks: true))
    #expect(try sandbox.entries().contains("tasks.json"))
    #expect(try String(bytes: Data(contentsOf: renamedURL), encoding: .utf8) == contents)
  }

  @Test func saveLeavesNoPartialOrTemporarySibling() throws {
    let sandbox = try Sandbox()
    let big = TaskStoreFile(
      didSeedTasks: true,
      tasks: (0..<200).map { Self.makeRecord(id: "task-\($0)", title: String(repeating: "x", count: 80)) }
    )
    try sandbox.store.save(big)
    #expect(try sandbox.entries() == ["tasks.json"])

    // Shrinking the payload must replace the file wholesale; a partial write
    // would leave trailing bytes from the larger file and fail to decode.
    let small = TaskStoreFile(didSeedTasks: true, tasks: [Self.makeRecord(id: "only")])
    try sandbox.store.save(small)
    #expect(try sandbox.entries() == ["tasks.json"])
    #expect(sandbox.store.load() == small)
  }

  @Test func taskWritesNeverTouchTheSidebarFile() throws {
    let sandbox = try Sandbox()
    let sidebarURL = sandbox.directory.appending(path: "sidebar.json", directoryHint: .notDirectory)
    let sidebarBytes = Data(#"{"schemaVersion":1,"sections":{}}"#.utf8)
    try sidebarBytes.write(to: sidebarURL)

    try sandbox.store.save(TaskStoreFile(didSeedTasks: true, tasks: [Self.makeRecord(id: "a")]))
    _ = sandbox.store.load()

    #expect(try Data(contentsOf: sidebarURL) == sidebarBytes)
    #expect(sandbox.store.url.lastPathComponent == "tasks.json")
  }

  @Test func defaultURLIsASiblingOfSidebarJSON() {
    let store = withDependencies {
      $0.settingsFileStorage = .inMemory()
    } operation: {
      TaskStore()
    }
    #expect(store.url == SupacodePaths.tasksURL)
    #expect(
      store.url.deletingLastPathComponent() == SupacodePaths.sidebarURL.deletingLastPathComponent()
    )
  }
}

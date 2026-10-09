import Dependencies
import Foundation
import IdentifiedCollections
import Sharing
import SupacodeSettingsShared
import Testing

@testable import supacode

@MainActor
struct LayoutsIncrementalWriterTests {
  private func makeDefaults() -> UserDefaults {
    // A fresh, isolated in-memory store per test so writes never touch disk.
    .inMemory
  }

  private func makeWriter(_ defaults: UserDefaults) -> LayoutsIncrementalWriter {
    LayoutsIncrementalWriter(store: LayoutsUserDefaultsStore(defaults: defaults))
  }

  private func readFile(_ defaults: UserDefaults) -> TaskLayoutsFile? {
    guard let data = defaults.data(forKey: LayoutsFile.userDefaultsKey) else { return nil }
    return try? JSONDecoder().decode(TaskLayoutsFile.self, from: data)
  }

  @Test func identicalReflushKeepsASingleEntry() async {
    let defaults = makeDefaults()
    let writer = makeWriter(defaults)

    let entry = record("/w1")
    await writer.flush(records: ["w1": entry])
    // Re-splicing the same record changes nothing; the writer skips the write.
    await writer.flush(records: ["w1": entry])

    #expect(Set(readFile(defaults)?.tasks.keys.map { $0 } ?? []) == ["w1"])
  }

  @Test func corruptBlobIsStashedAsideThenRecovers() async {
    let defaults = makeDefaults()
    // A wholly-undecodable blob (genuine corruption, or a newer-schema downgrade).
    let garbage = Data("not json".utf8)
    defaults.set(garbage, forKey: LayoutsFile.userDefaultsKey)
    let writer = makeWriter(defaults)

    await writer.flush(records: ["w1": record("/w1")])

    // The blob is preserved under a sibling key, and the live store recovers to a
    // fresh value rather than wedging forever.
    #expect(defaults.data(forKey: LayoutsFile.userDefaultsKey + ".corrupt") == garbage)
    #expect(readFile(defaults)?.tasks["w1"] != nil)
  }

  @Test func emptyChangesIsNoOp() async {
    let defaults = makeDefaults()
    let writer = makeWriter(defaults)

    await writer.flush(records: ["w1": record("/w1")])
    await writer.flush(records: [:])

    #expect(Set(readFile(defaults)?.tasks.keys.map { $0 } ?? []) == ["w1"])
  }

  // MARK: - Task record flushes.

  private static let createdAt = Date(timeIntervalSince1970: 1_000)

  private func layout(_ marker: String) -> PaneLayout {
    let paneID = PaneID()
    let tabID = TabID()
    return PaneLayout(
      tree: SplitTree(view: paneID),
      panes: [
        Pane(
          id: paneID,
          tabs: [
            TabItem(
              id: tabID,
              title: marker,
              content: ContentSnapshot(
                id: ContentID(),
                state: .terminal(TerminalContentState(workingDirectory: marker))
              )
            )
          ],
          selectedTabID: tabID
        )
      ],
      focusedPaneID: paneID
    )
  }

  private func record(
    _ marker: String,
    directory: TaskRecord.Directory? = nil,
    createdAt: Date = LayoutsIncrementalWriterTests.createdAt
  ) -> LayoutsIncrementalWriter.RecordChange {
    .record(
      layout: layout(marker),
      directory: directory ?? TaskRecord.Directory(worktreeID: WorktreeID(marker)),
      createdAt: createdAt
    )
  }

  private func seedV2(_ defaults: UserDefaults, _ file: LayoutsFile) throws -> Data {
    let data = try JSONEncoder().encode(file)
    defaults.set(data, forKey: LayoutsFile.userDefaultsKey)
    return data
  }

  @Test func recordFlushesStampAndMergeByTask() async {
    let defaults = makeDefaults()
    let writer = makeWriter(defaults)

    await writer.flush(records: ["w1": record("/w1")])
    await writer.flush(records: ["w2": record("/w2")])

    let file = readFile(defaults)
    #expect(file?.schemaVersion == TaskLayoutsFile.currentSchemaVersion)
    #expect(Set(file?.tasks.keys.map { $0 } ?? []) == ["w1", "w2"])
    #expect(file?.tasks["w1"]?.id == LayoutID(legacyWorktreeKey: "w1"))
    #expect(file?.tasks["w1"]?.directory == TaskRecord.Directory(worktreeID: "/w1"))
    #expect(file?.tasks["w1"]?.createdAt == Self.createdAt)
  }

  @Test func recordDeleteRemovesOnlyTargetKey() async {
    let defaults = makeDefaults()
    let writer = makeWriter(defaults)

    await writer.flush(records: ["w1": record("/w1"), "w2": record("/w2")])
    await writer.flush(records: ["w1": .delete])

    #expect(Set(readFile(defaults)?.tasks.keys.map { $0 } ?? []) == ["w2"])
  }

  @Test func upsertOfAnExistingTaskOnlyReplacesItsLayout() async throws {
    let defaults = makeDefaults()
    let directory = TaskRecord.Directory(worktreeID: "/repo")
    let session = SessionKey(rawValue: "pi:abc")
    let taskID = LayoutID(task: UUID())
    let seeded = TaskRecord(
      id: taskID, directory: directory, layout: layout("/old"), sessions: [session], createdAt: Self.createdAt)
    defaults.set(
      try JSONEncoder().encode(TaskLayoutsFile(tasks: [taskID.persistenceKey: seeded])),
      forKey: LayoutsFile.userDefaultsKey)
    let writer = makeWriter(defaults)
    let replacement = layout("/new")

    await writer.flush(records: [
      taskID: .record(
        layout: replacement,
        directory: TaskRecord.Directory(worktreeID: "/elsewhere"),
        createdAt: Date(timeIntervalSince1970: 9_000))
    ])

    let task = readFile(defaults)?.tasks[taskID.persistenceKey]
    #expect(task?.layout == replacement)
    #expect(task?.directory == directory)
    #expect(task?.sessions == [session])
    #expect(task?.createdAt == Self.createdAt)
    // Already v3: nothing to back up.
    #expect(defaults.data(forKey: LayoutsFile.preTasksBackupKey) == nil)
  }

  @Test func firstV3WriteBacksUpTheV2BlobOnceAndKeepsEveryRecord() async throws {
    let defaults = makeDefaults()
    let origin = TerminalLayoutSnapshot(tabs: [], selectedTabIndex: 0)
    let kept = layout("/w1")
    let legacy = LayoutsFile(worktrees: [
      "/w1": LayoutRecord(layout: kept, origin: origin),
      "/w2": LayoutRecord(layout: layout("/w2")),
    ])
    let v2Data = try seedV2(defaults, legacy)
    let writer = makeWriter(defaults)

    await writer.flush(records: ["/w3": record("/w3")])

    #expect(defaults.data(forKey: LayoutsFile.preTasksBackupKey) == v2Data)
    let file = try #require(readFile(defaults))
    #expect(file.schemaVersion == TaskLayoutsFile.currentSchemaVersion)
    #expect(Set(file.tasks.keys) == ["/w1", "/w2", "/w3"])
    #expect(file.tasks["/w1"]?.layout == kept)
    #expect(file.tasks["/w1"]?.directory == TaskRecord.Directory(worktreeID: "/w1"))
    #expect(file.origins["/w1"] == origin)

    // A later flush never rewrites the backup.
    await writer.flush(records: ["/w4": record("/w4")])
    #expect(defaults.data(forKey: LayoutsFile.preTasksBackupKey) == v2Data)
  }

  @Test func firstV3WriteComesAfterTheBackup() async throws {
    let defaults = RecordingUserDefaults()
    let v2Data = try seedV2(defaults, LayoutsFile(worktrees: ["/w1": LayoutRecord(layout: layout("/w1"))]))

    await makeWriter(defaults).flush(records: ["/w2": record("/w2")])

    #expect(
      defaults.writtenKeys == [
        LayoutsFile.userDefaultsKey, LayoutsFile.preTasksBackupKey, LayoutsFile.userDefaultsKey,
      ])
    #expect(defaults.data(forKey: LayoutsFile.preTasksBackupKey) == v2Data)
  }

  @Test func aFailedBackupAbortsEveryFlushAndLeavesV2Untouched() async throws {
    let defaults = RecordingUserDefaults(refusingWritesTo: [LayoutsFile.preTasksBackupKey])
    let v2Data = try seedV2(defaults, LayoutsFile(worktrees: ["/w1": LayoutRecord(layout: layout("/w1"))]))
    let writer = makeWriter(defaults)

    await writer.flush(records: ["/w2": record("/w2")])
    await writer.flush(records: ["/w1": .delete])
    await writer.flush(activeTask: LayoutID(task: UUID()), forDirectory: "/w1")
    writer.flushSync(records: ["/w3": record("/w3")])

    #expect(defaults.data(forKey: LayoutsFile.userDefaultsKey) == v2Data)
    #expect(defaults.writtenKeys == [LayoutsFile.userDefaultsKey])
  }

  @Test func lossyV2BlobAbortsTheFlushAndIsLeftUntouched() async {
    let defaults = makeDefaults()
    let lossy = Data(
      """
      {"schemaVersion":2,"worktrees":{
        "good":{"layout":{"panes":[],"tree":{}}},
        "bad":{"layout":"not an object"}}}
      """.utf8)
    defaults.set(lossy, forKey: LayoutsFile.userDefaultsKey)
    let writer = makeWriter(defaults)

    await writer.flush(records: ["w1": record("/w1")])

    #expect(defaults.data(forKey: LayoutsFile.userDefaultsKey) == lossy)
    #expect(defaults.data(forKey: LayoutsFile.preTasksBackupKey) == nil)
  }

  @Test func malformedV2OriginAbortsTheFlushAndIsLeftUntouched() async throws {
    let defaults = makeDefaults()
    let encoded = try JSONEncoder().encode(LayoutsFile(worktrees: ["/w1": LayoutRecord(layout: layout("/w1"))]))
    var root = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    var worktrees = try #require(root["worktrees"] as? [String: Any])
    var entry = try #require(worktrees["/w1"] as? [String: Any])
    entry["origin"] = "not a snapshot"
    worktrees["/w1"] = entry
    root["worktrees"] = worktrees
    let malformed = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    defaults.set(malformed, forKey: LayoutsFile.userDefaultsKey)
    let writer = makeWriter(defaults)

    await writer.flush(records: ["/w2": record("/w2")])

    #expect(defaults.data(forKey: LayoutsFile.userDefaultsKey) == malformed)
    #expect(defaults.data(forKey: LayoutsFile.preTasksBackupKey) == nil)
  }

  @Test func upsertKeepsADirectorysOriginAndDeleteReleasesIt() async throws {
    let defaults = makeDefaults()
    let origin = TerminalLayoutSnapshot(tabs: [], selectedTabIndex: 0)
    _ = try seedV2(defaults, LayoutsFile(worktrees: ["/w1": LayoutRecord(layout: layout("/w1"), origin: origin)]))
    let writer = makeWriter(defaults)

    await writer.flush(records: ["/w1": record("/w1b")])
    #expect(readFile(defaults)?.origins["/w1"] == origin)

    await writer.flush(records: ["/w1": .delete])
    #expect(readFile(defaults)?.origins.isEmpty == true)
    #expect(readFile(defaults)?.tasks.isEmpty == true)
  }

  private func origin(surface: UUID) -> TerminalLayoutSnapshot {
    TerminalLayoutSnapshot(
      tabs: [
        .init(
          id: surface, title: "Old", customTitle: nil, icon: nil, tintColor: nil,
          layout: .leaf(.init(id: surface, workingDirectory: nil)), focusedLeafIndex: 0)
      ],
      selectedTabIndex: 0
    )
  }

  @Test func aDeleteGuessedFromADirectoryNeverRemovesAnotherDirectorysTask() async throws {
    let defaults = makeDefaults()
    let writer = makeWriter(defaults)
    let elsewhere = TaskRecord.Directory(worktreeID: "/w2", host: RemoteHost(alias: "build-box"))
    // Stored under the key of /w1, but it is a task of /w2.
    await writer.flush(records: ["/w1": record("/w1", directory: elsewhere)])
    let seeded = try #require(readFile(defaults))
    var withOrigins = seeded
    withOrigins.origins = ["/w1": origin(surface: UUID()), "/w2": origin(surface: UUID())]
    defaults.set(try JSONEncoder().encode(withOrigins), forKey: LayoutsFile.userDefaultsKey)

    await writer.flush(records: ["/w1": .deleteIfOn("/w1")])

    // The task and its directory's origin stay; only the deleted directory's
    // own origin is released.
    var file = try #require(readFile(defaults))
    #expect(file.tasks == seeded.tasks)
    #expect(Set(file.origins.keys) == ["/w2"])

    // A record that does name the directory goes, with its origin.
    await writer.flush(records: ["/w1": .deleteIfOn("/w2")])
    file = try #require(readFile(defaults))
    #expect(file.tasks.isEmpty)
    #expect(file.origins.isEmpty)
  }

  @Test func deletingTheOwnKeyTaskKeepsTheOriginWhileASiblingTaskRemains() async throws {
    let defaults = makeDefaults()
    let originSurface = UUID()
    _ = try seedV2(
      defaults,
      LayoutsFile(worktrees: ["/w1": LayoutRecord(layout: layout("/w1"), origin: origin(surface: originSurface))]))
    let writer = makeWriter(defaults)
    let sibling = LayoutID(task: UUID())
    await writer.flush(records: [sibling: record("/w1")])

    await writer.flush(records: ["/w1": .delete])

    // The sibling still sits on the directory, so the origin's sessions stay
    // in the reaper's known set.
    var file = try #require(readFile(defaults))
    #expect(Set(file.tasks.keys) == [sibling.persistenceKey])
    #expect(file.origins["/w1"] != nil)
    #expect(file.allKnownSurfaceIDs.contains(originSurface))

    // The directory's last task releases it.
    await writer.flush(records: [sibling: .delete])
    file = try #require(readFile(defaults))
    #expect(file.tasks.isEmpty)
    #expect(file.origins.isEmpty)
    #expect(!file.allKnownSurfaceIDs.contains(originSurface))
  }

  @Test func aDirectoryOfMintedTasksReleasesItsOriginWithTheLastOne() async throws {
    let defaults = makeDefaults()
    let originSurface = UUID()
    let otherSurface = UUID()
    let first = LayoutID(task: UUID())
    let second = LayoutID(task: UUID())
    let elsewhere = LayoutID(task: UUID())
    // No task is stored under either directory's own key.
    var seeded = TaskLayoutsFile(origins: [
      "/w1": origin(surface: originSurface), "/w2": origin(surface: otherSurface),
    ])
    for (id, path) in [(first, "/w1"), (second, "/w1"), (elsewhere, "/w2")] {
      seeded.tasks[id.persistenceKey] = TaskRecord(
        id: id, directory: TaskRecord.Directory(worktreeID: WorktreeID(path)), layout: layout(path),
        createdAt: Self.createdAt)
    }
    defaults.set(try JSONEncoder().encode(seeded), forKey: LayoutsFile.userDefaultsKey)
    let writer = makeWriter(defaults)

    await writer.flush(records: [first: .delete])
    #expect(readFile(defaults)?.allKnownSurfaceIDs.contains(originSurface) == true)

    await writer.flush(records: [second: .delete])
    let file = try #require(readFile(defaults))
    #expect(Set(file.tasks.keys) == [elsewhere.persistenceKey])
    // Only the emptied directory lets go; the other keeps its origin.
    #expect(Set(file.origins.keys) == ["/w2"])
    #expect(!file.allKnownSurfaceIDs.contains(originSurface))
    #expect(file.allKnownSurfaceIDs.contains(otherSurface))
  }

  @Test func deletingEveryTaskOfADirectoryInOneFlushReleasesItsOrigin() async throws {
    let defaults = makeDefaults()
    let originSurface = UUID()
    _ = try seedV2(
      defaults,
      LayoutsFile(worktrees: ["/w1": LayoutRecord(layout: layout("/w1"), origin: origin(surface: originSurface))]))
    let writer = makeWriter(defaults)
    let sibling = LayoutID(task: UUID())
    await writer.flush(records: [sibling: record("/w1")])

    await writer.flush(records: ["/w1": .delete, sibling: .delete])

    let file = try #require(readFile(defaults))
    #expect(file.tasks.isEmpty)
    #expect(file.origins.isEmpty)
  }

  @Test func activeTaskIsStoredPerDirectoryAndClearedByNil() async {
    let defaults = makeDefaults()
    let writer = makeWriter(defaults)
    let minted = LayoutID(task: UUID())
    await writer.flush(records: [minted: record("/w1"), "/w1": record("/w1")])

    await writer.flush(activeTask: minted, forDirectory: "/w1")
    #expect(readFile(defaults)?.activeTasks == ["/w1": minted.persistenceKey])
    // Records are untouched by a selection write.
    #expect(readFile(defaults)?.tasks.count == 2)

    await writer.flush(activeTask: nil, forDirectory: "/w1")
    #expect(readFile(defaults)?.activeTasks.isEmpty == true)
  }

  @Test func deletingATaskDropsTheDirectoryEntryThatNamesIt() async {
    let defaults = makeDefaults()
    let writer = makeWriter(defaults)
    let minted = LayoutID(task: UUID())
    let other = LayoutID(task: UUID())
    await writer.flush(records: [minted: record("/w1"), other: record("/w2")])
    await writer.flush(activeTask: minted, forDirectory: "/w1")
    await writer.flush(activeTask: other, forDirectory: "/w2")

    await writer.flush(records: [minted: .delete])

    #expect(readFile(defaults)?.activeTasks == ["/w2": other.persistenceKey])
  }

  @Test func activeTaskFlushSkipsNewerSchema() async throws {
    let defaults = makeDefaults()
    let newer = try JSONEncoder().encode(
      TaskLayoutsFile(schemaVersion: TaskLayoutsFile.currentSchemaVersion + 1))
    defaults.set(newer, forKey: LayoutsFile.userDefaultsKey)

    await makeWriter(defaults).flush(activeTask: LayoutID(task: UUID()), forDirectory: "/w1")

    #expect(defaults.data(forKey: LayoutsFile.userDefaultsKey) == newer)
  }

  @Test func aFileWithoutActiveTasksEncodesAsBefore() throws {
    // No directory has a recorded task until a second one exists, so today's
    // stores keep their exact bytes.
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let json = try #require(String(data: encoder.encode(TaskLayoutsFile()), encoding: .utf8))
    #expect(!json.contains("activeTasks"))
    #expect(try JSONDecoder().decode(TaskLayoutsFile.self, from: Data(json.utf8)).activeTasks.isEmpty)
  }

  @Test func recordFlushSkipsNewerSchema() async throws {
    let defaults = makeDefaults()
    let newer = try JSONEncoder().encode(
      TaskLayoutsFile(schemaVersion: TaskLayoutsFile.currentSchemaVersion + 1))
    defaults.set(newer, forKey: LayoutsFile.userDefaultsKey)
    let writer = makeWriter(defaults)

    await writer.flush(records: ["w1": record("/w1")])

    #expect(defaults.data(forKey: LayoutsFile.userDefaultsKey) == newer)
    #expect(defaults.data(forKey: LayoutsFile.userDefaultsKey + ".corrupt") == nil)
  }

  @Test func aPreV3BuildReadsAV3BlobAsANewerSchemaNotAsCorrupt() async throws {
    // The old reader and writer decode `LayoutsFile`; the empty compat key lets
    // that succeed so they see schema 3 and leave the blob alone.
    let defaults = makeDefaults()
    let writer = makeWriter(defaults)
    await writer.flush(records: ["w1": record("/w1")])

    let data = try #require(defaults.data(forKey: LayoutsFile.userDefaultsKey))
    let asV2 = try JSONDecoder().decode(LayoutsFile.self, from: data)
    #expect(asV2.schemaVersion == 3)
    #expect(asV2.worktrees.isEmpty)
  }

  // MARK: - Sessions and the last tab

  private func sessionKey(_ ref: String) -> SessionKey { SessionKey(harness: .pi, sessionID: ref) }

  private func change(
    _ layout: PaneLayout, directory: Worktree.ID = "/w1", sessions: [SessionKey] = []
  ) -> LayoutsIncrementalWriter.RecordChange {
    .record(
      layout: layout, directory: TaskRecord.Directory(worktreeID: directory), sessions: sessions,
      createdAt: Self.createdAt)
  }

  @Test func recordStoresATasksSessionsPrimaryFirst() async {
    let defaults = makeDefaults()
    let writer = makeWriter(defaults)
    let minted = LayoutID(task: UUID())

    await writer.flush(records: [minted: change(layout("/w1"), sessions: [sessionKey("one"), sessionKey("two")])])

    #expect(readFile(defaults)?.tasks[minted.persistenceKey]?.sessions == [sessionKey("one"), sessionKey("two")])
  }

  @Test func recordNeverDropsAStoredSession() async {
    let defaults = makeDefaults()
    let writer = makeWriter(defaults)
    let minted = LayoutID(task: UUID())
    await writer.flush(records: [minted: change(layout("/w1"), sessions: [sessionKey("one"), sessionKey("two")])])

    // A caller that has not loaded the stored sessions sends what it has.
    await writer.flush(records: [minted: change(layout("/w1"), sessions: [])])
    await writer.flush(records: [minted: change(layout("/w1"), sessions: [sessionKey("three")])])

    #expect(
      Set(readFile(defaults)?.tasks[minted.persistenceKey]?.sessions ?? [])
        == [sessionKey("one"), sessionKey("two"), sessionKey("three")])
  }

  @Test func taskWithSessionsKeepsItsRecordWhenItsLastTabCloses() async {
    let defaults = makeDefaults()
    let writer = makeWriter(defaults)
    let minted = LayoutID(task: UUID())
    await writer.flush(records: [minted: change(layout("/w1"), sessions: [sessionKey("one")])])
    await writer.flush(activeTask: minted, forDirectory: "/w1")

    // The caller lists no session: the stored record decides.
    await writer.flush(records: [minted: change(PaneLayout())])

    let file = readFile(defaults)
    let task = file?.tasks[minted.persistenceKey]
    #expect(task?.layout.panes.isEmpty == true)
    #expect(task?.sessions == [sessionKey("one")])
    #expect(task?.directory == TaskRecord.Directory(worktreeID: "/w1"))
    #expect(file?.activeTasks == ["/w1": minted.persistenceKey])
  }

  @Test func taskWithoutSessionsIsDeletedWhenItsLastTabCloses() async {
    let defaults = makeDefaults()
    let writer = makeWriter(defaults)
    let minted = LayoutID(task: UUID())
    let sibling = LayoutID(task: UUID())
    await writer.flush(records: [minted: change(layout("/w1")), sibling: change(layout("/w2"), directory: "/w2")])
    await writer.flush(activeTask: minted, forDirectory: "/w1")

    await writer.flush(records: [minted: change(PaneLayout())])

    let file = readFile(defaults)
    #expect(Set(file?.tasks.keys.map { $0 } ?? []) == [sibling.persistenceKey])
    #expect(file?.activeTasks.isEmpty == true)
  }

  @Test func aTaskThatNeverHadATabOrASessionIsNeverWritten() async {
    let defaults = makeDefaults()
    let writer = makeWriter(defaults)

    await writer.flush(records: [LayoutID(task: UUID()): change(PaneLayout())])

    #expect(readFile(defaults)?.tasks.isEmpty != false)
  }

  @Test func emptiedTaskWithSessionsStillHoldsItsDirectorysOrigin() async throws {
    let defaults = makeDefaults()
    let writer = makeWriter(defaults)
    let minted = LayoutID(task: UUID())
    var seeded = TaskLayoutsFile()
    seeded.origins = ["/w1": TerminalLayoutSnapshot(tabs: [], selectedTabIndex: 0)]
    seeded.tasks[minted.persistenceKey] = TaskRecord(
      id: minted, directory: TaskRecord.Directory(worktreeID: "/w1"), layout: layout("/w1"),
      sessions: [sessionKey("one")], createdAt: Self.createdAt)
    defaults.set(try JSONEncoder().encode(seeded), forKey: LayoutsFile.userDefaultsKey)

    await writer.flush(records: [minted: change(PaneLayout())])

    #expect(readFile(defaults)?.origins.keys.map { $0 } == ["/w1"])
  }
}

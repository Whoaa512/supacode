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
}

import Foundation
import IdentifiedCollections
import Sharing
import SupacodeSettingsShared
import Testing

@testable import supacode

/// The one-time on-disk split of an unsplit layouts store into tasks.
struct LayoutsTaskSplitMigrationTests {
  private typealias AgentRecord = TerminalLayoutSnapshot.SurfaceAgentRecord

  private static let now = Date(timeIntervalSince1970: 2_000)
  private static let mixed = "/tmp/repo/a"
  private static let allAgents = "/tmp/repo/b"
  private static let remote = "dev@box:2222/srv/c"
  private static let shells = "/tmp/repo/d"

  private static func uuid(_ number: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", number))!
  }

  /// Tab `n` has tab id `n` and content id `1000 + n`.
  private static func tab(_ number: Int, agents: [AgentRecord]? = nil) -> TabItem {
    TabItem(
      id: TabID(rawValue: uuid(number)),
      title: "Tab \(number)",
      content: ContentSnapshot(
        id: ContentID(rawValue: uuid(1000 + number)),
        state: .terminal(TerminalContentState(workingDirectory: "/tmp/cwd-\(number)", agents: agents))
      )
    )
  }

  private static func agent(_ name: String = "pi", ref: String? = nil, dead: Bool = false) -> AgentRecord {
    AgentRecord(
      agent: name, pids: dead ? [] : [42], activity: "idle", doneUnseen: nil,
      sessionRef: ref, resumeCandidate: dead ? true : nil)
  }

  private static func pane(_ number: Int, _ tabs: [TabItem], selected: Int) -> Pane {
    Pane(
      id: PaneID(rawValue: uuid(number)),
      tabs: IdentifiedArray(uniqueElements: tabs),
      selectedTabID: TabID(rawValue: uuid(selected))
    )
  }

  private static func layout(_ panes: [Pane], focused: Int) throws -> PaneLayout {
    var tree = SplitTree<PaneID>()
    for (index, pane) in panes.enumerated() {
      tree =
        index == 0
        ? SplitTree(view: pane.id)
        : try tree.inserting(view: pane.id, at: panes[index - 1].id, direction: .right)
    }
    return PaneLayout(
      tree: tree,
      panes: IdentifiedArray(uniqueElements: panes),
      focusedPaneID: PaneID(rawValue: uuid(focused))
    )
  }

  private static func origin(surface: Int) -> TerminalLayoutSnapshot {
    TerminalLayoutSnapshot(
      tabs: [
        .init(
          id: uuid(surface), title: "Old", customTitle: nil, icon: nil, tintColor: nil,
          layout: .leaf(.init(id: uuid(surface), workingDirectory: nil)), focusedLeafIndex: 0)
      ],
      selectedTabIndex: 0
    )
  }

  /// Four directories. `a`: two panes mixing shells and live agents, focus on
  /// an agent tab, plus an origin. `b`: only agents (one dead-flagged, one with
  /// no session ref) and an origin owning a surface no tab references. `c`:
  /// remote, an agent and a focused shell. `d`: two shell panes, no agent.
  private static func v2Fixture() throws -> LayoutsFile {
    LayoutsFile(worktrees: [
      mixed: LayoutRecord(
        layout: try layout(
          [
            pane(101, [tab(1), tab(2, agents: [agent(ref: "s2")]), tab(3)], selected: 2),
            pane(102, [tab(4, agents: [agent("claude", ref: "s4")]), tab(5)], selected: 5),
          ], focused: 101),
        origin: origin(surface: 501)),
      allAgents: LayoutRecord(
        layout: try layout(
          [pane(201, [tab(6, agents: [agent(ref: "s6", dead: true)]), tab(7, agents: [agent()])], selected: 7)],
          focused: 201),
        origin: origin(surface: 502)),
      remote: LayoutRecord(
        layout: try layout([pane(301, [tab(8, agents: [agent(ref: "s8")]), tab(9)], selected: 9)], focused: 301)),
      shells: LayoutRecord(
        layout: try layout([pane(401, [tab(10)], selected: 10), pane(402, [tab(11)], selected: 11)], focused: 402)),
    ])
  }

  /// Fresh ids start at `base + 1` so they never collide with fixture ids.
  private static func migrate(_ defaults: UserDefaults, idsFrom base: Int = 9000) {
    var next = base
    LayoutsMigrator.migrateStoreToTasksIfNeeded(defaults: defaults, now: now) {
      next += 1
      return uuid(next)
    }
  }

  private static func stored(_ defaults: UserDefaults) throws -> TaskLayoutsFile {
    guard case .file(let file) = TaskLayoutsFile.readPersisted(from: defaults) else {
      throw StoreUnreadable()
    }
    return file
  }

  private struct StoreUnreadable: Error {}

  private static func tabs(_ file: TaskLayoutsFile) -> [TabItem] {
    file.tasks.values.flatMap { $0.layout.panes.flatMap(\.tabs) }
      .sorted { $0.id.rawValue.uuidString < $1.id.rawValue.uuidString }
  }

  private static func task(holdingTab number: Int, in file: TaskLayoutsFile) -> TaskRecord? {
    file.tasks.values.first { $0.layout.panes.contains { $0.tabs[id: TabID(rawValue: uuid(number))] != nil } }
  }

  private static func restoredSurfaces(_ file: TaskLayoutsFile) -> Set<UUID> {
    Set(AgentPresenceFeature.stageRestore(from: file).keys.map(\.surfaceID))
  }

  // MARK: - End to end

  @Test func v2StoreIsSplitIntoTasksLosingNothing() throws {
    let legacy = try Self.v2Fixture()
    let unsplit = TaskLayoutsFile(oneTaskPerDirectory: legacy)
    let v2Data = try JSONEncoder().encode(legacy)
    let defaults = UserDefaults.inMemory
    defaults.set(v2Data, forKey: LayoutsFile.userDefaultsKey)

    Self.migrate(defaults)

    let file = try Self.stored(defaults)
    #expect(file.tasksSplit)
    #expect(file.schemaVersion == 3)
    // A7: five agent tabs, and a shell task for each directory with leftovers.
    #expect(file.tasks.count == 8)
    #expect(file.tasks[Self.allAgents] == nil, "an all-agent directory gets no shell task")
    for number in [2, 4, 6, 7, 8] {
      let task = try #require(Self.task(holdingTab: number, in: file))
      #expect(UUID(uuidString: task.id.persistenceKey) != nil)
      #expect(task.layout.panes.count == 1)
      #expect(task.layout.panes.first?.tabs.count == 1)
      #expect(task.layout.focusedPaneID == task.layout.panes.first?.id)
      #expect(task.layout.isConsistent)
      #expect(task.createdAt == Self.now)
    }
    #expect(Self.task(holdingTab: 2, in: file)?.sessions == [SessionKey(rawValue: "pi:s2")])
    #expect(Self.task(holdingTab: 4, in: file)?.sessions == [SessionKey(rawValue: "claude:s4")])
    #expect(Self.task(holdingTab: 6, in: file)?.sessions == [SessionKey(rawValue: "pi:s6")], "dead-flagged agent")
    #expect(Self.task(holdingTab: 7, in: file)?.sessions == [], "agent with no session ref")
    #expect(
      Self.task(holdingTab: 6, in: file)?.directory == TaskRecord.Directory(worktreeID: WorktreeID(Self.allAgents)))
    let remoteTask = try #require(Self.task(holdingTab: 8, in: file))
    #expect(remoteTask.directory.worktreeID == WorktreeID(Self.remote))
    #expect(remoteTask.directory.host != nil)
    #expect(file.tasks[Self.remote]?.directory == remoteTask.directory)

    // Leftover tabs keep their panes and splits under the directory's own id.
    let mixedShell = try #require(file.tasks[Self.mixed])
    #expect(mixedShell.id == LayoutID(legacyWorktreeKey: Self.mixed))
    #expect(mixedShell.layout.panes.map(\.id) == [PaneID(rawValue: Self.uuid(101)), PaneID(rawValue: Self.uuid(102))])
    #expect(
      mixedShell.layout.panes.map { $0.tabs.map(\.id.rawValue) } == [[Self.uuid(1), Self.uuid(3)], [Self.uuid(5)]])
    #expect(mixedShell.layout.isConsistent)
    #expect(file.tasks[Self.shells]?.layout == legacy.worktrees[Self.shells]?.layout)

    // A8: same tabs, same content, nothing duplicated; every origin kept.
    #expect(Self.tabs(file) == Self.tabs(unsplit))
    #expect(Self.tabs(file).count == 11)
    #expect(file.origins == unsplit.origins)
    #expect(Set(file.origins.keys) == [Self.mixed, Self.allAgents])

    // A10: the reaper's set and the presence restore cover what v2 covered.
    #expect(file.allKnownSurfaceIDs == legacy.allKnownSurfaceIDs)
    #expect(file.allKnownSurfaceIDs.isSuperset(of: [Self.uuid(501), Self.uuid(502)]))
    #expect(Self.restoredSurfaces(file) == Self.restoredSurfaces(unsplit))
    #expect(Self.restoredSurfaces(file).count == 5)

    // Each directory resolves to a task that exists: the one that took its
    // focused tab, else its first agent task when no own-key task is left.
    #expect(
      file.activeTasks == [
        Self.mixed: try #require(Self.task(holdingTab: 2, in: file)).id.persistenceKey,
        Self.allAgents: try #require(Self.task(holdingTab: 7, in: file)).id.persistenceKey,
      ])

    // A9: both backups hold the v2 bytes.
    #expect(defaults.data(forKey: LayoutsFile.preTasksBackupKey) == v2Data)
    #expect(defaults.data(forKey: LayoutsFile.preSplitBackupKey) == v2Data)
  }

  @Test func unsplitV3StoreIsSplitAndBackedUpUnderItsOwnKey() throws {
    let legacy = try Self.v2Fixture()
    var unsplit = TaskLayoutsFile(oneTaskPerDirectory: legacy)
    // The user last looked at the remote directory's own task, and a stale hint names a task that is gone.
    unsplit.activeTasks = [Self.remote: Self.remote, Self.shells: "no-such-task"]
    let v3Data = try JSONEncoder().encode(unsplit)
    let earlier = Data("v2 bytes from the first upgrade".utf8)
    let defaults = UserDefaults.inMemory
    defaults.set(earlier, forKey: LayoutsFile.preTasksBackupKey)
    defaults.set(v3Data, forKey: LayoutsFile.userDefaultsKey)

    Self.migrate(defaults)

    let file = try Self.stored(defaults)
    #expect(file.tasksSplit)
    #expect(file.tasks.count == 8)
    #expect(Self.tabs(file) == Self.tabs(unsplit))
    #expect(file.origins == unsplit.origins)
    #expect(file.allKnownSurfaceIDs == legacy.allKnownSurfaceIDs)
    #expect(Self.restoredSurfaces(file) == Self.restoredSurfaces(unsplit))
    #expect(file.activeTasks[Self.remote] == Self.remote, "focus was on the shell tab, which stays")
    #expect(file.activeTasks[Self.shells] == nil)
    #expect(defaults.data(forKey: LayoutsFile.preSplitBackupKey) == v3Data)
    #expect(defaults.data(forKey: LayoutsFile.preTasksBackupKey) == earlier)
  }

  @Test func backupIsWrittenBeforeTheSplitValue() throws {
    let defaults = RecordingUserDefaults()
    let v3Data = try JSONEncoder().encode(TaskLayoutsFile(oneTaskPerDirectory: try Self.v2Fixture()))
    defaults.set(v3Data, forKey: LayoutsFile.userDefaultsKey)

    Self.migrate(defaults)

    #expect(
      defaults.writtenKeys == [
        LayoutsFile.userDefaultsKey, LayoutsFile.preSplitBackupKey, LayoutsFile.userDefaultsKey,
      ])
  }

  // MARK: - Runs once

  @Test func secondRunChangesNothing() throws {
    let defaults = UserDefaults.inMemory
    defaults.set(try JSONEncoder().encode(try Self.v2Fixture()), forKey: LayoutsFile.userDefaultsKey)

    Self.migrate(defaults)
    let first = defaults.data(forKey: LayoutsFile.userDefaultsKey)
    let backup = defaults.data(forKey: LayoutsFile.preSplitBackupKey)
    Self.migrate(defaults, idsFrom: 7000)

    #expect(defaults.data(forKey: LayoutsFile.userDefaultsKey) == first)
    #expect(defaults.data(forKey: LayoutsFile.preSplitBackupKey) == backup)
  }

  @Test func splitStoreThatLostItsMarkerKeepsItsTaskIDsAndSessions() throws {
    // An older build rewrites the store without the marker it does not know.
    let defaults = UserDefaults.inMemory
    defaults.set(try JSONEncoder().encode(try Self.v2Fixture()), forKey: LayoutsFile.userDefaultsKey)
    Self.migrate(defaults)
    var split = try Self.stored(defaults)
    split.tasksSplit = false
    defaults.set(try JSONEncoder().encode(split), forKey: LayoutsFile.userDefaultsKey)

    Self.migrate(defaults, idsFrom: 7000)

    var again = try Self.stored(defaults)
    #expect(again.tasksSplit)
    again.tasksSplit = false
    #expect(again == split)
  }

  @Test func storeCreatedFreshIsNeverSplit() throws {
    // Nothing in a store born after the split predates task ownership.
    let fresh = TaskLayoutsFile(tasks: [
      Self.mixed: TaskRecord(
        id: LayoutID(legacyWorktreeKey: Self.mixed),
        directory: TaskRecord.Directory(worktreeID: WorktreeID(Self.mixed)),
        layout: try Self.layout(
          [Self.pane(101, [Self.tab(1), Self.tab(2, agents: [Self.agent(ref: "s2")])], selected: 1)], focused: 101),
        createdAt: Self.now)
    ])
    let data = try JSONEncoder().encode(fresh)
    let defaults = RecordingUserDefaults()
    defaults.set(data, forKey: LayoutsFile.userDefaultsKey)

    Self.migrate(defaults)

    #expect(try JSONDecoder().decode(TaskLayoutsFile.self, from: data).tasksSplit)
    #expect(defaults.writtenKeys == [LayoutsFile.userDefaultsKey])
    #expect(defaults.data(forKey: LayoutsFile.userDefaultsKey) == data)
  }

  @Test func unsplitMarkerSurvivesTheCodec() throws {
    let unsplit = TaskLayoutsFile(oneTaskPerDirectory: try Self.v2Fixture())
    let decoded = try JSONDecoder().decode(TaskLayoutsFile.self, from: try JSONEncoder().encode(unsplit))
    #expect(!unsplit.tasksSplit)
    #expect(!decoded.tasksSplit)
  }

  // MARK: - Abort

  /// A split that silently loses the first agent tab it meets.
  private static func lossySplit(_ file: TaskLayoutsFile) -> TaskLayoutsFile {
    var result = LayoutsTaskSplitter.split(file, now: now)
    if let key = result.tasks.keys.sorted().first(where: { UUID(uuidString: $0) != nil }) {
      result.tasks[key] = nil
      result.activeTasks = result.activeTasks.filter { $0.value != key }
    }
    return result
  }

  @Test func failedIntegrityCheckLeavesTheUnsplitV3StoreUntouched() throws {
    let defaults = RecordingUserDefaults()
    let v3Data = try JSONEncoder().encode(TaskLayoutsFile(oneTaskPerDirectory: try Self.v2Fixture()))
    defaults.set(v3Data, forKey: LayoutsFile.userDefaultsKey)

    LayoutsMigrator.migrateStoreToTasksIfNeeded(defaults: defaults, now: Self.now, split: Self.lossySplit)

    #expect(defaults.data(forKey: LayoutsFile.userDefaultsKey) == v3Data)
    #expect(defaults.writtenKeys == [LayoutsFile.userDefaultsKey], "no backup, no rewrite")

    // The store is still usable and the next launch splits it.
    Self.migrate(defaults)
    #expect(try Self.stored(defaults).tasksSplit)
    #expect(defaults.data(forKey: LayoutsFile.preSplitBackupKey) == v3Data)
  }

  @Test func failedIntegrityCheckStillUpgradesV2WithoutSplitting() throws {
    let legacy = try Self.v2Fixture()
    let v2Data = try JSONEncoder().encode(legacy)
    let defaults = UserDefaults.inMemory
    defaults.set(v2Data, forKey: LayoutsFile.userDefaultsKey)

    LayoutsMigrator.migrateStoreToTasksIfNeeded(defaults: defaults, now: Self.now, split: Self.lossySplit)

    let file = try Self.stored(defaults)
    #expect(!file.tasksSplit)
    #expect(file == TaskLayoutsFile(oneTaskPerDirectory: legacy))
    #expect(defaults.data(forKey: LayoutsFile.preTasksBackupKey) == v2Data)
    #expect(defaults.data(forKey: LayoutsFile.preSplitBackupKey) == nil)
  }

  @Test func refusedBackupLeavesTheUnsplitStoreUntouched() throws {
    let defaults = RecordingUserDefaults(refusingWritesTo: [LayoutsFile.preSplitBackupKey])
    let v3Data = try JSONEncoder().encode(TaskLayoutsFile(oneTaskPerDirectory: try Self.v2Fixture()))
    defaults.set(v3Data, forKey: LayoutsFile.userDefaultsKey)

    Self.migrate(defaults)

    #expect(defaults.data(forKey: LayoutsFile.userDefaultsKey) == v3Data)
    #expect(defaults.writtenKeys == [LayoutsFile.userDefaultsKey])
  }

  @Test func refusedSplitBackupLeavesV2Untouched() throws {
    let defaults = RecordingUserDefaults(refusingWritesTo: [LayoutsFile.preSplitBackupKey])
    let v2Data = try JSONEncoder().encode(try Self.v2Fixture())
    defaults.set(v2Data, forKey: LayoutsFile.userDefaultsKey)

    Self.migrate(defaults)

    #expect(defaults.data(forKey: LayoutsFile.userDefaultsKey) == v2Data)
  }

  @Test func lossyUnsplitV3StoreIsLeftUntouched() throws {
    let encoded = try JSONEncoder().encode(TaskLayoutsFile(oneTaskPerDirectory: try Self.v2Fixture()))
    var root = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    var tasks = try #require(root["tasks"] as? [String: Any])
    tasks["rotten"] = "not a task"
    root["tasks"] = tasks
    let lossy = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    let defaults = RecordingUserDefaults()
    defaults.set(lossy, forKey: LayoutsFile.userDefaultsKey)

    Self.migrate(defaults)

    #expect(defaults.data(forKey: LayoutsFile.userDefaultsKey) == lossy)
    #expect(defaults.writtenKeys == [LayoutsFile.userDefaultsKey])
  }

  // MARK: - Integrity check

  @Test func integrityCheckNamesEachKindOfLoss() throws {
    let source = TaskLayoutsFile(oneTaskPerDirectory: try Self.v2Fixture())
    var next = 9000
    let good = LayoutsTaskSplitter.split(source, now: Self.now) {
      next += 1
      return Self.uuid(next)
    }
    #expect(LayoutsMigrator.splitIntegrityFailure(from: source, to: good) == nil)

    var unmarked = good
    unmarked.tasksSplit = false
    #expect(LayoutsMigrator.splitIntegrityFailure(from: source, to: unmarked) != nil)

    var droppedTab = good
    droppedTab.tasks[try #require(Self.task(holdingTab: 4, in: good)).id.persistenceKey] = nil
    #expect(LayoutsMigrator.splitIntegrityFailure(from: source, to: droppedTab) == "tabs differ")

    var duplicatedTab = good
    let copy = try #require(Self.task(holdingTab: 4, in: good))
    let copyID = LayoutID(task: Self.uuid(8000))
    duplicatedTab.tasks[copyID.persistenceKey] = TaskRecord(
      id: copyID, directory: copy.directory, layout: copy.layout, createdAt: Self.now)
    #expect(LayoutsMigrator.splitIntegrityFailure(from: source, to: duplicatedTab) == "tabs differ")

    var droppedOrigin = good
    droppedOrigin.origins[Self.allAgents] = nil
    #expect(LayoutsMigrator.splitIntegrityFailure(from: source, to: droppedOrigin) == "origins differ")

    var dangling = good
    dangling.activeTasks[Self.shells] = "no-such-task"
    #expect(LayoutsMigrator.splitIntegrityFailure(from: source, to: dangling) == "active task missing")

    var misfiled = good
    misfiled.tasks["elsewhere"] = misfiled.tasks.removeValue(forKey: Self.shells)
    #expect(LayoutsMigrator.splitIntegrityFailure(from: source, to: misfiled) == "task stored under another id")
  }
}

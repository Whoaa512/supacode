import Foundation
import IdentifiedCollections
import SupacodeSettingsShared
import Testing

@testable import supacode

struct LayoutsTaskSplitterTests {
  private typealias AgentRecord = TerminalLayoutSnapshot.SurfaceAgentRecord

  private static let now = Date(timeIntervalSince1970: 1_000)
  private static let local = "/tmp/repo/wt-a"

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

  private static func agent(
    _ name: String = "pi", ref: String? = nil, dead: Bool = false
  ) -> AgentRecord {
    AgentRecord(
      agent: name, pids: dead ? [] : [42], activity: "idle", doneUnseen: nil,
      sessionRef: ref, resumeCandidate: dead ? true : nil)
  }

  private static func pane(_ number: Int, _ tabs: [TabItem], selected: Int? = nil) -> Pane {
    Pane(
      id: PaneID(rawValue: uuid(number)),
      tabs: IdentifiedArray(uniqueElements: tabs),
      selectedTabID: selected.map { TabID(rawValue: uuid($0)) }
    )
  }

  private static func layout(_ panes: [Pane], focused: Int? = nil) throws -> PaneLayout {
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
      focusedPaneID: focused.map { PaneID(rawValue: uuid($0)) }
    )
  }

  private static func origin(surfaces: [Int]) -> TerminalLayoutSnapshot {
    TerminalLayoutSnapshot(
      tabs: surfaces.map {
        .init(
          id: uuid($0), title: "Old", customTitle: nil, icon: nil, tintColor: nil,
          layout: .leaf(.init(id: uuid($0), workingDirectory: nil)), focusedLeafIndex: 0)
      },
      selectedTabIndex: 0
    )
  }

  /// Fresh ids start at 9001 so they never collide with fixture ids.
  private static func split(_ file: LayoutsFile) -> TaskLayoutsFile {
    var next = 9000
    return LayoutsTaskSplitter.split(file, now: now) {
      next += 1
      return uuid(next)
    }
  }

  private static func tabIDs(_ file: TaskLayoutsFile) -> [UUID] {
    file.tasks.values.flatMap { $0.layout.panes.flatMap { $0.tabs.map(\.id.rawValue) } }.sorted {
      $0.uuidString < $1.uuidString
    }
  }

  private static func contentIDs(_ file: TaskLayoutsFile) -> [UUID] {
    file.tasks.values.flatMap { $0.layout.allContentIDs.map(\.rawValue) }.sorted {
      $0.uuidString < $1.uuidString
    }
  }

  private static func shellTask(_ file: TaskLayoutsFile, _ key: String) -> TaskRecord? {
    file.tasks[key]
  }

  private static func agentTasks(_ file: TaskLayoutsFile) -> [TaskRecord] {
    file.tasks.filter { UUID(uuidString: $0.key) != nil }.map(\.value)
      .sorted { $0.id.persistenceKey < $1.id.persistenceKey }
  }

  // MARK: - A7

  @Test func agentTabsBecomeTheirOwnTasksAndTheRestOneShellTask() throws {
    let record = LayoutRecord(
      layout: try Self.layout(
        [
          Self.pane(
            101,
            [Self.tab(1), Self.tab(2, agents: [Self.agent(ref: "s2")]), Self.tab(3)],
            selected: 2),
          Self.pane(102, [Self.tab(4, agents: [Self.agent("claude", ref: "s4")])]),
        ], focused: 102))
    let result = Self.split(LayoutsFile(worktrees: [Self.local: record]))

    #expect(result.schemaVersion == 3)
    #expect(result.tasks.count == 3)

    let agents = Self.agentTasks(result)
    #expect(agents.map { $0.layout.panes.count } == [1, 1])
    #expect(agents.map { $0.layout.panes[0].tabs.map(\.id.rawValue) } == [[Self.uuid(2)], [Self.uuid(4)]])
    #expect(agents.map(\.sessions) == [[SessionKey(rawValue: "pi:s2")], [SessionKey(rawValue: "claude:s4")]])
    #expect(agents.allSatisfy { $0.directory == .init(worktreeID: WorktreeID(Self.local)) })
    #expect(agents.allSatisfy { $0.createdAt == Self.now })
    #expect(agents.allSatisfy { $0.layout.isConsistent })
    for task in agents {
      let pane = task.layout.panes[0]
      #expect(task.layout.focusedPaneID == pane.id)
      #expect(pane.selectedTabID == pane.tabs[0].id)
      #expect(task.id == LayoutID(legacyWorktreeKey: task.id.persistenceKey))
    }
    // The tab moves verbatim: title, content id and terminal state.
    #expect(agents[0].layout.panes[0].tabs[0] == Self.tab(2, agents: [Self.agent(ref: "s2")]))

    let shell = try #require(Self.shellTask(result, Self.local))
    #expect(shell.id == LayoutID(legacyWorktreeKey: Self.local))
    #expect(shell.sessions.isEmpty)
    #expect(shell.layout.panes.map(\.id.rawValue) == [Self.uuid(101)])
    #expect(shell.layout.panes[0].tabs.map(\.id.rawValue) == [Self.uuid(1), Self.uuid(3)])
    // The selected tab and focused pane both left with an agent: both retarget.
    #expect(shell.layout.panes[0].selectedTabID == TabID(rawValue: Self.uuid(1)))
    #expect(shell.layout.focusedPaneID == PaneID(rawValue: Self.uuid(101)))
    #expect(shell.layout.isConsistent)
  }

  @Test func directoryWithOnlyAgentTabsGetsNoShellTask() throws {
    let record = LayoutRecord(
      layout: try Self.layout([Self.pane(101, [Self.tab(1, agents: [Self.agent(ref: "s1")])])]))
    let result = Self.split(LayoutsFile(worktrees: [Self.local: record]))

    #expect(result.tasks.count == 1)
    #expect(Self.shellTask(result, Self.local) == nil)
    #expect(Self.agentTasks(result).count == 1)
  }

  @Test func directoryWithNoAgentsKeepsItsLayoutUnchanged() throws {
    let layout = try Self.layout([Self.pane(101, [Self.tab(1), Self.tab(2)], selected: 2)])
    let result = Self.split(LayoutsFile(worktrees: [Self.local: LayoutRecord(layout: layout)]))

    #expect(result.tasks.count == 1)
    #expect(Self.shellTask(result, Self.local)?.layout == layout)
  }

  @Test func emptyLayoutYieldsNoTask() {
    let result = Self.split(LayoutsFile(worktrees: [Self.local: LayoutRecord(layout: PaneLayout())]))
    #expect(result.tasks.isEmpty)
  }

  @Test func deadFlaggedAgentTabIsStillAnAgentTask() throws {
    let record = LayoutRecord(
      layout: try Self.layout([
        Self.pane(101, [Self.tab(1), Self.tab(2, agents: [Self.agent(ref: "s2", dead: true)])])
      ]))
    let result = Self.split(LayoutsFile(worktrees: [Self.local: record]))

    let agents = Self.agentTasks(result)
    #expect(agents.count == 1)
    #expect(agents[0].sessions == [SessionKey(rawValue: "pi:s2")])
    #expect(Self.shellTask(result, Self.local)?.layout.allContentIDs.map(\.rawValue) == [Self.uuid(1001)])
  }

  @Test func agentTabWithoutSessionRefBecomesATaskWithNoSessions() throws {
    let record = LayoutRecord(
      layout: try Self.layout([Self.pane(101, [Self.tab(1, agents: [Self.agent()])])]))
    let result = Self.split(LayoutsFile(worktrees: [Self.local: record]))

    let agents = Self.agentTasks(result)
    #expect(agents.count == 1)
    #expect(agents[0].sessions.isEmpty)
    #expect(agents[0].layout.allContentIDs.map(\.rawValue) == [Self.uuid(1001)])
  }

  @Test func sessionsKeepRecordOrderAndSkipUnusableRefs() throws {
    let records = [
      Self.agent("pi", ref: "first"), Self.agent("not-a-harness", ref: "x"),
      Self.agent("claude", ref: "second"), Self.agent("pi", ref: "first"),
    ]
    let record = LayoutRecord(layout: try Self.layout([Self.pane(101, [Self.tab(1, agents: records)])]))
    let result = Self.split(LayoutsFile(worktrees: [Self.local: record]))

    #expect(
      Self.agentTasks(result).map(\.sessions) == [
        [SessionKey(rawValue: "pi:first"), SessionKey(rawValue: "claude:second")]
      ])
  }

  @Test func emptyAgentArrayIsAShellTab() throws {
    let record = LayoutRecord(layout: try Self.layout([Self.pane(101, [Self.tab(1, agents: [])])]))
    let result = Self.split(LayoutsFile(worktrees: [Self.local: record]))

    #expect(Self.agentTasks(result).isEmpty)
    #expect(Self.shellTask(result, Self.local) != nil)
  }

  // MARK: - A8

  @Test func nothingIsLostOrReidentified() throws {
    let other = "/tmp/repo/wt-b"
    let file = LayoutsFile(worktrees: [
      Self.local: LayoutRecord(
        layout: try Self.layout([
          Self.pane(101, [Self.tab(1), Self.tab(2, agents: [Self.agent(ref: "s2")])]),
          Self.pane(102, [Self.tab(3, agents: [Self.agent()]), Self.tab(4)]),
          Self.pane(103, [Self.tab(5, agents: [Self.agent(ref: "s5", dead: true)])]),
        ]),
        origin: Self.origin(surfaces: [501, 1001])),
      other: LayoutRecord(layout: try Self.layout([Self.pane(201, [Self.tab(6), Self.tab(7)])])),
    ])
    let result = Self.split(file)

    #expect(Self.tabIDs(result) == (1...7).map(Self.uuid))
    #expect(Self.contentIDs(result) == (1001...1007).map(Self.uuid))
    #expect(result.allKnownSurfaceIDs == file.allKnownSurfaceIDs)
    #expect(result.tasks.values.allSatisfy { $0.layout.isConsistent })
    #expect(result.tasks.allSatisfy { $0.key == $0.value.id.persistenceKey })
    #expect(result.tasks.count == 5)
  }

  @Test func leftoverSplitsStayTogether() throws {
    let record = LayoutRecord(
      layout: try Self.layout(
        [
          Self.pane(101, [Self.tab(1)]),
          Self.pane(102, [Self.tab(2, agents: [Self.agent(ref: "s2")])]),
          Self.pane(103, [Self.tab(3)]),
        ], focused: 103))
    let result = Self.split(LayoutsFile(worktrees: [Self.local: record]))

    let shell = try #require(Self.shellTask(result, Self.local))
    #expect(shell.layout.panes.map(\.id.rawValue) == [Self.uuid(101), Self.uuid(103)])
    #expect(Set(shell.layout.tree.leaves()) == Set(shell.layout.panes.ids))
    #expect(shell.layout.focusedPaneID == PaneID(rawValue: Self.uuid(103)))
    #expect(shell.layout.isConsistent)
  }

  @Test func originMovesToItsDirectoryEvenWithoutAShellTask() throws {
    let origin = Self.origin(surfaces: [501, 502])
    let file = LayoutsFile(worktrees: [
      Self.local: LayoutRecord(
        layout: try Self.layout([Self.pane(101, [Self.tab(1, agents: [Self.agent(ref: "s1")])])]),
        origin: origin)
    ])
    let result = Self.split(file)

    #expect(Self.shellTask(result, Self.local) == nil)
    #expect(result.origins == [Self.local: origin])
    // Origin-only surface ids stay known, so the reaper cannot take their sessions.
    #expect(result.allKnownSurfaceIDs.isSuperset(of: [Self.uuid(501), Self.uuid(502)]))
    #expect(result.allKnownSurfaceIDs == file.allKnownSurfaceIDs)
  }

  @Test func originOfAnEmptyLayoutSurvives() {
    let origin = Self.origin(surfaces: [501])
    let file = LayoutsFile(worktrees: [Self.local: LayoutRecord(layout: PaneLayout(), origin: origin)])
    let result = Self.split(file)

    #expect(result.tasks.isEmpty)
    #expect(result.origins == [Self.local: origin])
    #expect(result.allKnownSurfaceIDs == file.allKnownSurfaceIDs)
  }

  // MARK: - Directory, determinism, codec

  @Test func remoteDirectoryCarriesItsHost() throws {
    let key = "dev@box:2222/home/dev/repo"
    let record = LayoutRecord(
      layout: try Self.layout([Self.pane(101, [Self.tab(1), Self.tab(2, agents: [Self.agent(ref: "s2")])])]))
    let result = Self.split(LayoutsFile(worktrees: [key: record]))

    let expected = TaskRecord.Directory(
      worktreeID: WorktreeID(key), host: RemoteHost(alias: "box", username: "dev", port: 2222))
    #expect(result.tasks.count == 2)
    #expect(result.tasks.values.allSatisfy { $0.directory == expected })
    #expect(Self.shellTask(result, key)?.id == LayoutID(legacyWorktreeKey: key))
  }

  @Test func splitIsDeterministicForInjectedIDs() throws {
    let file = LayoutsFile(worktrees: [
      "/b": LayoutRecord(layout: try Self.layout([Self.pane(101, [Self.tab(1, agents: [Self.agent()])])])),
      "/a": LayoutRecord(layout: try Self.layout([Self.pane(102, [Self.tab(2, agents: [Self.agent()])])])),
    ])
    let result = Self.split(file)

    #expect(Self.split(file) == result)
    // Directories are walked in key order: "/a" takes the first minted id.
    #expect(result.tasks[Self.uuid(9001).uuidString]?.directory.worktreeID == WorktreeID("/a"))
  }

  @Test func lossyInputStaysLossy() {
    var file = LayoutsFile(worktrees: [:])
    file.undecodedEntryCount = 2
    #expect(Self.split(file).undecodedEntryCount == 2)
  }

  @Test func v3FileRoundTripsThroughJSON() throws {
    let file = LayoutsFile(worktrees: [
      Self.local: LayoutRecord(
        layout: try Self.layout([Self.pane(101, [Self.tab(1), Self.tab(2, agents: [Self.agent(ref: "s2")])])]),
        origin: Self.origin(surfaces: [501]))
    ])
    let result = Self.split(file)
    let decoded = try JSONDecoder().decode(TaskLayoutsFile.self, from: JSONEncoder().encode(result))

    #expect(decoded == result)
    #expect(decoded.undecodedEntryCount == 0)
  }

  @Test func unreadableTaskOrOriginMarksTheFileLossy() throws {
    let json = #"{"schemaVersion":3,"tasks":{"x":{"id":"x"}},"origins":{"/a":{"tabs":7}}}"#
    let decoded = try JSONDecoder().decode(TaskLayoutsFile.self, from: Data(json.utf8))

    #expect(decoded.tasks.isEmpty)
    #expect(decoded.origins.isEmpty)
    #expect(decoded.undecodedEntryCount == 2)
  }
}

import Foundation
import Testing

@testable import supacode

struct TasksSidebarStructureTests {
  private static let reference = Date(timeIntervalSince1970: 1_700_000_000)

  private static func task(
    _ id: String,
    createdAt offset: TimeInterval = 0,
    settledAt: TimeInterval? = nil,
    lastVisitedAt: TimeInterval? = nil,
    override: TaskRecord.SettledOverride? = nil
  ) -> TaskRecord {
    TaskRecord(
      id: TaskID(id),
      title: id,
      directoryPath: "/tmp/\(id)",
      createdAt: reference.addingTimeInterval(offset),
      settledAt: settledAt.map(reference.addingTimeInterval),
      settledOverride: override,
      lastVisitedAt: lastVisitedAt.map(reference.addingTimeInterval)
    )
  }

  private static func settledTasks(count: Int) -> [TaskRecord] {
    // Settle stamps descend with the index, so `s-0` is the newest-ended row.
    (0..<count).map { index in
      task("s-\(index)", createdAt: TimeInterval(index), settledAt: -TimeInterval(index))
    }
  }

  // MARK: - Empty

  @Test func emptyInputProducesEmptyStructure() {
    #expect(TasksSidebarStructure.compute(tasks: []) == .empty)
  }

  @Test func openTaskThatDoesNotExistIsIgnored() {
    let structure = TasksSidebarStructure.compute(
      tasks: [Self.task("a")],
      openTaskID: TaskID("missing")
    )
    #expect(structure.activeTaskIDs == [TaskID("a")])
    #expect(structure.visibleSettledTail.isEmpty)
  }

  // MARK: - A4: static active ordering

  @Test(arguments: [
    // (input order, expected order) — the projection must not depend on input order.
    (["a", "b", "c"], ["c", "b", "a"]),
    (["c", "a", "b"], ["c", "b", "a"]),
    (["b", "c", "a"], ["c", "b", "a"]),
  ])
  func activeRowsAreNewestCreatedFirst(input: [String], expected: [String]) {
    let byID = ["a": 0.0, "b": 60.0, "c": 120.0]
    let tasks = input.map { Self.task($0, createdAt: byID[$0]!) }
    let structure = TasksSidebarStructure.compute(tasks: tasks)
    #expect(structure.activeTaskIDs.map(\.rawValue) == expected)
  }

  @Test func equalCreatedAtFallsBackToIDOrder() {
    let tasks = [Self.task("zzz"), Self.task("aaa"), Self.task("mmm")]
    let structure = TasksSidebarStructure.compute(tasks: tasks)
    #expect(structure.activeTaskIDs.map(\.rawValue) == ["aaa", "mmm", "zzz"])
    // Same records shuffled produce the same order: no input-order dependence.
    let reshuffled = TasksSidebarStructure.compute(tasks: tasks.reversed())
    #expect(reshuffled == structure)
  }

  /// A4 by construction: `compute` accepts only records plus the open-task
  /// selection, so there is no activity input that could reorder a row. This
  /// test documents that signature — if activity is ever threaded in, it stops
  /// compiling and the invariant gets re-litigated deliberately.
  @Test func computeTakesOnlyRecordsAndSelection() {
    let projection: ([TaskRecord], TaskID?, Int, Bool) -> TasksSidebarStructure =
      TasksSidebarStructure.compute
    let tasks = [Self.task("a", createdAt: 0), Self.task("b", createdAt: 60)]
    let structure = projection(tasks, nil, TasksSidebarStructure.settledTailInitialCount, true)
    #expect(structure.activeTaskIDs.map(\.rawValue) == ["b", "a"])
  }

  // MARK: - Active / settled partition

  @Test func settledStampMovesTaskToTheTail() {
    let structure = TasksSidebarStructure.compute(
      tasks: [Self.task("active"), Self.task("done", settledAt: 30)]
    )
    #expect(structure.activeTaskIDs.map(\.rawValue) == ["active"])
    #expect(structure.settledTail.map(\.id.rawValue) == ["done"])
    #expect(structure.visibleTaskIDs.map(\.rawValue) == ["active", "done"])
  }

  @Test func explicitActiveOverrideBeatsAStaleSettleStamp() {
    let structure = TasksSidebarStructure.compute(
      tasks: [Self.task("resumed", settledAt: 30, override: .active)]
    )
    #expect(structure.activeTaskIDs.map(\.rawValue) == ["resumed"])
    #expect(structure.settledTail.isEmpty)
  }

  @Test func explicitSettledOverrideSettlesWithoutAStamp() {
    let structure = TasksSidebarStructure.compute(
      tasks: [Self.task("parked", override: .settled)]
    )
    #expect(structure.activeTaskIDs.isEmpty)
    #expect(structure.settledTail.map(\.id.rawValue) == ["parked"])
  }

  // MARK: - A17: settled tail order + sort key == label key

  @Test func settledTailIsNewestEndedFirst() {
    let tasks = [
      Self.task("old", createdAt: 500, settledAt: 10),
      Self.task("newest", createdAt: 0, settledAt: 900),
      Self.task("middle", createdAt: 100, settledAt: 400),
    ]
    let structure = TasksSidebarStructure.compute(tasks: tasks)
    // Creation order is deliberately the inverse: settled rows sort by when the
    // work ENDED, not when the task started.
    #expect(structure.settledTail.map(\.id.rawValue) == ["newest", "middle", "old"])
  }

  @Test func equalSettledTimestampsFallBackToIDOrder() {
    let tasks = [
      Self.task("zzz", settledAt: 42),
      Self.task("aaa", settledAt: 42),
    ]
    let structure = TasksSidebarStructure.compute(tasks: tasks)
    #expect(structure.settledTail.map(\.id.rawValue) == ["aaa", "zzz"])
    #expect(TasksSidebarStructure.compute(tasks: tasks.reversed()) == structure)
  }

  @Test func settledEntryCarriesTheTimestampItSortedBy() {
    let stamped = Self.task("stamped", createdAt: 0, settledAt: 90, lastVisitedAt: 50)
    let visited = Self.task("visited", createdAt: 0, lastVisitedAt: 60, override: .settled)
    let bare = Self.task("bare", createdAt: 10, override: .settled)
    let structure = TasksSidebarStructure.compute(tasks: [stamped, visited, bare])

    let byID = Dictionary(
      uniqueKeysWithValues: structure.settledTail.map { ($0.id.rawValue, $0.settledTimestamp) }
    )
    // Cascade: settledAt → latest activity (lastVisitedAt) → createdAt. Each
    // entry reports exactly the value it was ordered by, so the row's label
    // cannot diverge from the sort key.
    #expect(byID["stamped"] == stamped.settledAt)
    #expect(byID["visited"] == visited.lastVisitedAt)
    #expect(byID["bare"] == bare.createdAt)
    // Ordered by those resolved values: 90 (stamp) > 60 (visit) > 10 (created).
    #expect(structure.settledTail.map(\.id.rawValue) == ["stamped", "visited", "bare"])
    for entry in structure.settledTail {
      let record = [stamped, visited, bare].first { $0.id == entry.id }!
      #expect(entry.settledTimestamp == TasksSidebarStructure.resolvedSettledTimestamp(for: record))
    }
  }

  // MARK: - Paging

  @Test func settledTailUnderThePageWindowIsFullyVisible() {
    let structure = TasksSidebarStructure.compute(tasks: Self.settledTasks(count: 4))
    #expect(structure.visibleSettledTail.count == 4)
    #expect(structure.hiddenSettledCount == 0)
  }

  @Test func settledTailBeyondThePageWindowIsTruncated() {
    let structure = TasksSidebarStructure.compute(tasks: Self.settledTasks(count: 14))
    #expect(structure.visibleSettledTail.count == TasksSidebarStructure.settledTailInitialCount)
    #expect(structure.hiddenSettledCount == 4)
    #expect(structure.visibleSettledTail.map(\.id.rawValue).first == "s-0")
    #expect(structure.visibleSettledTail.map(\.id.rawValue).last == "s-9")
  }

  @Test func expandingThePageWindowRevealsMore() {
    let tasks = Self.settledTasks(count: 14)
    let expanded = TasksSidebarStructure.expandedSettledVisibleCount(
      from: TasksSidebarStructure.settledTailInitialCount
    )
    let structure = TasksSidebarStructure.compute(tasks: tasks, settledVisibleCount: expanded)
    #expect(expanded == 35)
    #expect(structure.visibleSettledTail.count == 14)
    #expect(structure.hiddenSettledCount == 0)
  }

  @Test func collapsedShelfRendersNoSettledRows() {
    let structure = TasksSidebarStructure.compute(
      tasks: Self.settledTasks(count: 3) + [Self.task("live", createdAt: 999)],
      isSettledTailExpanded: false
    )
    #expect(structure.visibleSettledTail.isEmpty)
    #expect(structure.hiddenSettledCount == 3)
    #expect(structure.visibleTaskIDs.map(\.rawValue) == ["live"])
  }

  // MARK: - A8: the open task is never hidden

  @Test func openSettledTaskBeyondThePageWindowIsPulledIn() {
    let structure = TasksSidebarStructure.compute(
      tasks: Self.settledTasks(count: 14),
      openTaskID: TaskID("s-13")
    )
    #expect(structure.visibleSettledTail.map(\.id.rawValue).contains("s-13"))
    #expect(structure.visibleSettledTail.count == TasksSidebarStructure.settledTailInitialCount + 1)
    // Pulled in without displacing the window: it appends after the page.
    #expect(structure.visibleSettledTail.map(\.id.rawValue).last == "s-13")
    #expect(structure.hiddenSettledCount == 3)
  }

  @Test func openSettledTaskInsideThePageWindowIsNotDuplicated() {
    let structure = TasksSidebarStructure.compute(
      tasks: Self.settledTasks(count: 14),
      openTaskID: TaskID("s-2")
    )
    let ids = structure.visibleSettledTail.map(\.id.rawValue)
    #expect(ids.count == TasksSidebarStructure.settledTailInitialCount)
    #expect(ids.filter { $0 == "s-2" }.count == 1)
  }

  @Test func openSettledTaskIsVisibleEvenWithTheShelfCollapsed() {
    let structure = TasksSidebarStructure.compute(
      tasks: Self.settledTasks(count: 14),
      openTaskID: TaskID("s-13"),
      isSettledTailExpanded: false
    )
    #expect(structure.visibleSettledTail.map(\.id.rawValue) == ["s-13"])
    #expect(structure.visibleTaskIDs.map(\.rawValue) == ["s-13"])
  }

  @Test func openActiveTaskIsTriviallyVisible() {
    let structure = TasksSidebarStructure.compute(
      tasks: Self.settledTasks(count: 14) + [Self.task("live", createdAt: 999)],
      openTaskID: TaskID("live"),
      isSettledTailExpanded: false
    )
    #expect(structure.visibleTaskIDs.map(\.rawValue) == ["live"])
  }

  // MARK: - Timestamp robustness (A17)

  @Test func aTaskWithNoUsableTimestampStillRendersAtTheTailEnd() {
    var broken = Self.task("broken", override: .settled)
    broken.createdAt = Date(timeIntervalSince1970: .infinity)
    let structure = TasksSidebarStructure.compute(
      tasks: [broken, Self.task("fine", settledAt: 10)]
    )
    #expect(structure.settledTail.map(\.id.rawValue) == ["fine", "broken"])
    #expect(structure.settledTail.last?.settledTimestamp == nil)
    #expect(structure.visibleTaskIDs.map(\.rawValue).contains("broken"))
  }
}

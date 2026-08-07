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

  /// The common wiring: the initial page window with the shelf expanded.
  /// `compute` itself takes both explicitly so a caller can't forget to thread
  /// its real paging state through.
  private static func compute(
    _ tasks: [TaskRecord],
    openTaskID: TaskID? = nil,
    settledVisibleCount: Int = TasksSidebarStructure.settledTailInitialCount,
    isSettledTailExpanded: Bool = true
  ) -> TasksSidebarStructure {
    TasksSidebarStructure.compute(
      tasks: tasks,
      openTaskID: openTaskID,
      settledVisibleCount: settledVisibleCount,
      isSettledTailExpanded: isSettledTailExpanded
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
    #expect(Self.compute([]) == .empty)
  }

  @Test func openTaskThatDoesNotExistIsIgnored() {
    let structure = Self.compute([Self.task("a")], openTaskID: TaskID("missing"))
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
    let structure = Self.compute(tasks)
    #expect(structure.activeTaskIDs.map(\.rawValue) == expected)
  }

  @Test func equalCreatedAtFallsBackToIDOrder() {
    let tasks = [Self.task("zzz"), Self.task("aaa"), Self.task("mmm")]
    let structure = Self.compute(tasks)
    #expect(structure.activeTaskIDs.map(\.rawValue) == ["aaa", "mmm", "zzz"])
    // Same records shuffled produce the same order: no input-order dependence.
    let reshuffled = Self.compute(tasks.reversed())
    #expect(reshuffled == structure)
  }

  /// Signature lock only: it asserts nothing about behaviour, it just pins the
  /// shape of `compute` (records, selection, paging) so threading an activity
  /// input in stops compiling here and A4 gets re-litigated deliberately.
  @Test func computeTakesOnlyRecordsAndSelection() {
    let projection: ([TaskRecord], TaskID?, Int, Bool) -> TasksSidebarStructure =
      TasksSidebarStructure.compute
    let tasks = [Self.task("a", createdAt: 0), Self.task("b", createdAt: 60)]
    let structure = projection(tasks, nil, TasksSidebarStructure.settledTailInitialCount, true)
    #expect(structure.activeTaskIDs.map(\.rawValue) == ["b", "a"])
  }

  // MARK: - Active / settled partition

  @Test func settledStampMovesTaskToTheTail() {
    let structure = Self.compute([Self.task("active"), Self.task("done", settledAt: 30)])
    #expect(structure.activeTaskIDs.map(\.rawValue) == ["active"])
    #expect(structure.visibleSettledTail.map(\.id.rawValue) == ["done"])
    #expect(structure.settledTotalCount == 1)
    #expect(structure.visibleTaskIDs.map(\.rawValue) == ["active", "done"])
  }

  @Test func explicitActiveOverrideBeatsAStaleSettleStamp() {
    let structure = Self.compute([Self.task("resumed", settledAt: 30, override: .active)])
    #expect(structure.activeTaskIDs.map(\.rawValue) == ["resumed"])
    #expect(structure.settledTotalCount == 0)
    #expect(structure.visibleSettledTail.isEmpty)
  }

  @Test func explicitSettledOverrideSettlesWithoutAStamp() {
    let structure = Self.compute([Self.task("parked", override: .settled)])
    #expect(structure.activeTaskIDs.isEmpty)
    #expect(structure.visibleSettledTail.map(\.id.rawValue) == ["parked"])
  }

  /// Phase 1 classifies on `settledAt` / the override and nothing else: a
  /// snoozed task is still an active row until something stamps it settled.
  @Test func snoozeAloneDoesNotSettleATask() {
    var snoozed = Self.task("snoozed")
    snoozed.snoozedUntil = Self.reference.addingTimeInterval(3600)
    snoozed.snoozedAt = Self.reference
    let structure = Self.compute([snoozed])
    #expect(structure.activeTaskIDs.map(\.rawValue) == ["snoozed"])
    #expect(structure.settledTotalCount == 0)
  }

  // MARK: - A17: settled tail order + sort key == label key

  @Test func settledTailIsNewestEndedFirst() {
    let tasks = [
      Self.task("old", createdAt: 500, settledAt: 10),
      Self.task("newest", createdAt: 0, settledAt: 900),
      Self.task("middle", createdAt: 100, settledAt: 400),
    ]
    let structure = Self.compute(tasks)
    // Creation order is deliberately the inverse: settled rows sort by when the
    // work ENDED, not when the task started.
    #expect(structure.visibleSettledTail.map(\.id.rawValue) == ["newest", "middle", "old"])
  }

  /// Same ordering with the page window wide open, so tail order is asserted
  /// independently of paging.
  @Test func settledTailOrderHoldsWithTheWindowWideOpen() {
    let structure = Self.compute(Self.settledTasks(count: 14), settledVisibleCount: 500)
    #expect(structure.visibleSettledTail.map(\.id.rawValue) == (0..<14).map { "s-\($0)" })
    #expect(structure.settledTotalCount == 14)
    #expect(structure.hiddenSettledCount == 0)
  }

  @Test func equalSettledTimestampsFallBackToIDOrder() {
    let tasks = [
      Self.task("zzz", settledAt: 42),
      Self.task("aaa", settledAt: 42),
    ]
    let structure = Self.compute(tasks)
    #expect(structure.visibleSettledTail.map(\.id.rawValue) == ["aaa", "zzz"])
    #expect(Self.compute(tasks.reversed()) == structure)
  }

  @Test func settledEntryCarriesTheTimestampItSortedBy() {
    let stamped = Self.task("stamped", createdAt: 0, settledAt: 90, lastVisitedAt: 50)
    let visited = Self.task("visited", createdAt: 0, lastVisitedAt: 60, override: .settled)
    let bare = Self.task("bare", createdAt: 10, override: .settled)
    let structure = Self.compute([stamped, visited, bare])

    let byID = Dictionary(
      uniqueKeysWithValues: structure.visibleSettledTail.map {
        ($0.id.rawValue, $0.settledTimestamp)
      }
    )
    // Cascade: settledAt → lastVisitedAt → createdAt. Each entry reports exactly
    // the value it was ordered by, so the row's label cannot diverge from the
    // sort key.
    #expect(byID["stamped"] == stamped.settledAt)
    #expect(byID["visited"] == visited.lastVisitedAt)
    #expect(byID["bare"] == bare.createdAt)
    // Ordered by those resolved values: 90 (stamp) > 60 (visit) > 10 (created).
    #expect(structure.visibleSettledTail.map(\.id.rawValue) == ["stamped", "visited", "bare"])
    for entry in structure.visibleSettledTail {
      let record = [stamped, visited, bare].first { $0.id == entry.id }!
      #expect(entry.settledTimestamp == TasksSidebarStructure.resolvedSettledTimestamp(for: record))
    }
  }

  // MARK: - Paging

  @Test func settledTailUnderThePageWindowIsFullyVisible() {
    let structure = Self.compute(Self.settledTasks(count: 4))
    #expect(structure.visibleSettledTail.count == 4)
    #expect(structure.hiddenSettledCount == 0)
  }

  @Test func settledTailBeyondThePageWindowIsTruncated() {
    let structure = Self.compute(Self.settledTasks(count: 14))
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
    let structure = Self.compute(tasks, settledVisibleCount: expanded)
    #expect(expanded == 35)
    #expect(structure.visibleSettledTail.count == 14)
    #expect(structure.hiddenSettledCount == 0)
  }

  @Test func collapsedShelfRendersNoSettledRows() {
    let structure = Self.compute(
      Self.settledTasks(count: 3) + [Self.task("live", createdAt: 999)],
      isSettledTailExpanded: false
    )
    #expect(structure.visibleSettledTail.isEmpty)
    // Collapsed has no "Show more" affordance, so nothing is "hidden behind" it:
    // the header reads the total instead.
    #expect(structure.hiddenSettledCount == 0)
    #expect(structure.settledTotalCount == 3)
    #expect(structure.visibleTaskIDs.map(\.rawValue) == ["live"])
  }

  // MARK: - A8: the open task is never hidden

  @Test func openSettledTaskBeyondThePageWindowIsPulledIn() {
    let structure = Self.compute(Self.settledTasks(count: 14), openTaskID: TaskID("s-13"))
    #expect(structure.visibleSettledTail.map(\.id.rawValue).contains("s-13"))
    #expect(structure.visibleSettledTail.count == TasksSidebarStructure.settledTailInitialCount + 1)
    // Pulled in without displacing the window: it appends after the page.
    #expect(structure.visibleSettledTail.map(\.id.rawValue).last == "s-13")
    #expect(structure.hiddenSettledCount == 3)
  }

  @Test func openSettledTaskInsideThePageWindowIsNotDuplicated() {
    let structure = Self.compute(Self.settledTasks(count: 14), openTaskID: TaskID("s-2"))
    let ids = structure.visibleSettledTail.map(\.id.rawValue)
    #expect(ids.count == TasksSidebarStructure.settledTailInitialCount)
    #expect(ids.filter { $0 == "s-2" }.count == 1)
  }

  @Test func openSettledTaskIsVisibleEvenWithTheShelfCollapsed() {
    let structure = Self.compute(
      Self.settledTasks(count: 14),
      openTaskID: TaskID("s-13"),
      isSettledTailExpanded: false
    )
    #expect(structure.visibleSettledTail.map(\.id.rawValue) == ["s-13"])
    #expect(structure.visibleTaskIDs.map(\.rawValue) == ["s-13"])
  }

  @Test func openActiveTaskIsTriviallyVisible() {
    let structure = Self.compute(
      Self.settledTasks(count: 14) + [Self.task("live", createdAt: 999)],
      openTaskID: TaskID("live"),
      isSettledTailExpanded: false
    )
    #expect(structure.visibleTaskIDs.map(\.rawValue) == ["live"])
  }

  // MARK: - Timestamp robustness (A17)

  @Test(arguments: [Double.infinity, -.infinity, .nan])
  func aTaskWithNoUsableTimestampStillRendersAtTheTailEnd(interval: Double) {
    var broken = Self.task("broken", override: .settled)
    broken.createdAt = Date(timeIntervalSince1970: interval)
    let structure = Self.compute([broken, Self.task("fine", settledAt: 10)])
    #expect(structure.visibleSettledTail.map(\.id.rawValue) == ["fine", "broken"])
    #expect(structure.visibleSettledTail.last?.settledTimestamp == nil)
    #expect(structure.visibleTaskIDs.map(\.rawValue).contains("broken"))
  }

  /// A non-finite stamp on the settle field itself falls through the cascade
  /// rather than sorting the row somewhere surprising.
  @Test(arguments: [Double.infinity, -.infinity, .nan])
  func aNonFiniteSettleStampFallsBackToCreatedAt(interval: Double) {
    var broken = Self.task("broken", createdAt: 5, override: .settled)
    broken.settledAt = Date(timeIntervalSince1970: interval)
    let structure = Self.compute([broken])
    #expect(structure.visibleSettledTail.first?.settledTimestamp == broken.createdAt)
  }
}

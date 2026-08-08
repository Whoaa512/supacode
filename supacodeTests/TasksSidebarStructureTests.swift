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
    override: TaskRecord.SettledOverride? = nil,
    snoozedUntil: TimeInterval? = nil,
    snoozedAt: TimeInterval? = nil,
    pinnedAt: TimeInterval? = nil
  ) -> TaskRecord {
    TaskRecord(
      id: TaskID(id),
      title: id,
      directoryPath: "/tmp/\(id)",
      createdAt: reference.addingTimeInterval(offset),
      settledAt: settledAt.map(reference.addingTimeInterval),
      settledOverride: override,
      snoozedUntil: snoozedUntil.map(reference.addingTimeInterval),
      snoozedAt: snoozedAt.map(reference.addingTimeInterval),
      pinnedAt: pinnedAt.map(reference.addingTimeInterval),
      lastVisitedAt: lastVisitedAt.map(reference.addingTimeInterval)
    )
  }

  /// The common wiring: the initial page window with the shelf expanded.
  /// `compute` itself takes both explicitly so a caller can't forget to thread
  /// its real paging state through.
  private static func compute(
    _ tasks: [TaskRecord],
    now: Date = reference,
    signals: [TaskID: TasksSidebarStructure.Signals] = [:],
    openTaskID: TaskID? = nil,
    settledVisibleCount: Int = TasksSidebarStructure.settledTailInitialCount,
    isSettledTailExpanded: Bool = true,
    isSnoozedShelfExpanded: Bool = true
  ) -> TasksSidebarStructure {
    TasksSidebarStructure.compute(
      tasks: tasks,
      now: now,
      signals: signals,
      openTaskID: openTaskID,
      settledVisibleCount: settledVisibleCount,
      isSettledTailExpanded: isSettledTailExpanded,
      isSnoozedShelfExpanded: isSnoozedShelfExpanded
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

  /// A4 survives Phase 4's new inputs. `signals` and `now` were added so a
  /// raised hand can move a row *between sections* (A25) and a wake can expire
  /// (A24) — never so activity can reorder rows. Asserted rather than pinned by
  /// signature now that the signature legitimately carries activity: the same
  /// records under every activity reading produce the same active order.
  @Test func activityNeverReordersTheActiveSection() {
    let tasks = [Self.task("a", createdAt: 0), Self.task("b", createdAt: 60)]
    let baseline = Self.compute(tasks)
    #expect(baseline.activeTaskIDs.map(\.rawValue) == ["b", "a"])

    let noisy = Self.compute(
      tasks,
      signals: [
        TaskID("a"): TasksSidebarStructure.Signals(
          activity: TaskSettlement.ActivitySnapshot(isWorking: true, isAwaitingInput: true),
          errorAt: Self.reference,
          completedTurnAt: Self.reference
        )
      ]
    )
    #expect(noisy.activeTaskIDs == baseline.activeTaskIDs)
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

  /// A16: snooze beats settled. A task that is both stamped settled and parked
  /// renders on the snoozed shelf, not in the settled tail — the snooze is the
  /// more recent, more specific instruction.
  @Test func snoozeBeatsASettleStamp() {
    let structure = Self.compute(
      [Self.task("both", settledAt: -30, snoozedUntil: 3600, snoozedAt: 0)]
    )
    #expect(structure.settledTotalCount == 0)
    #expect(structure.activeTaskIDs.isEmpty)
    #expect(structure.snoozedTotalCount == 1)
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

  // MARK: - A16 / A24: the snoozed shelf

  @Test func snoozedTaskLeavesTheActiveSectionForTheShelf() {
    let structure = Self.compute(
      [Self.task("live", createdAt: 60), Self.task("parked", snoozedUntil: 3600, snoozedAt: 0)]
    )
    #expect(structure.activeTaskIDs.map(\.rawValue) == ["live"])
    #expect(structure.snoozedTotalCount == 1)
    #expect(structure.visibleSnoozedEntries.map(\.id.rawValue) == ["parked"])
  }

  /// The entry carries the resolved wake `Date` so the row's countdown and the
  /// shelf's ordering read the same value — the settled tail's rule (A17)
  /// applied to snooze.
  @Test func snoozedEntryCarriesItsWakeDate() {
    let parked = Self.task("parked", snoozedUntil: 3600, snoozedAt: 0)
    let structure = Self.compute([parked])
    #expect(structure.visibleSnoozedEntries.first?.wakeAt == parked.snoozedUntil)
  }

  @Test func snoozedShelfIsSoonestWakeFirst() {
    let tasks = [
      Self.task("late", createdAt: 900, snoozedUntil: 7200, snoozedAt: 0),
      Self.task("soon", createdAt: 0, snoozedUntil: 600, snoozedAt: 0),
      Self.task("middle", createdAt: 400, snoozedUntil: 3600, snoozedAt: 0),
    ]
    let structure = Self.compute(tasks)
    // Creation order is deliberately unrelated: the shelf reads as a ramp of
    // what comes back next, not as an inbox.
    #expect(structure.visibleSnoozedEntries.map(\.id.rawValue) == ["soon", "middle", "late"])
    #expect(Self.compute(tasks.reversed()) == structure)
  }

  @Test func equalWakeTimesFallBackToIDOrder() {
    let tasks = [
      Self.task("zzz", snoozedUntil: 600, snoozedAt: 0),
      Self.task("aaa", snoozedUntil: 600, snoozedAt: 0),
    ]
    #expect(Self.compute(tasks).visibleSnoozedEntries.map(\.id.rawValue) == ["aaa", "zzz"])
  }

  /// Collapsed by default, exactly like the settled tail: the shelf is a place
  /// things went to be quiet, so it must not cost rows on screen.
  @Test func collapsedShelfRendersNoSnoozedRows() {
    let structure = Self.compute(
      [Self.task("live", createdAt: 60), Self.task("parked", snoozedUntil: 3600, snoozedAt: 0)],
      isSnoozedShelfExpanded: false
    )
    #expect(structure.visibleSnoozedEntries.isEmpty)
    #expect(structure.snoozedTotalCount == 1)
    #expect(structure.visibleTaskIDs.map(\.rawValue) == ["live"])
  }

  /// A8, extended to snooze: parking the task you are looking at must not make
  /// it vanish out from under you.
  @Test func openSnoozedTaskStaysVisibleWithTheShelfCollapsed() {
    let structure = Self.compute(
      [Self.task("live", createdAt: 60), Self.task("parked", snoozedUntil: 3600, snoozedAt: 0)],
      openTaskID: TaskID("parked"),
      isSnoozedShelfExpanded: false
    )
    #expect(structure.visibleSnoozedEntries.map(\.id.rawValue) == ["parked"])
    #expect(structure.visibleTaskIDs.map(\.rawValue) == ["live", "parked"])
  }

  @Test func openSnoozedTaskIsNotDuplicatedWhenTheShelfIsExpanded() {
    let structure = Self.compute(
      [Self.task("parked", snoozedUntil: 3600, snoozedAt: 0)],
      openTaskID: TaskID("parked")
    )
    #expect(structure.visibleSnoozedEntries.map(\.id.rawValue) == ["parked"])
  }

  /// Render order top-down: active (pinned first), then the snoozed shelf, then
  /// the settled tail. Hotkey slots key off this list, so it is contract.
  @Test func visibleOrderIsActiveThenSnoozedThenSettled() {
    let structure = Self.compute(
      [
        Self.task("live", createdAt: 60),
        Self.task("pinned", createdAt: 0, pinnedAt: 0),
        Self.task("parked", createdAt: 30, snoozedUntil: 3600, snoozedAt: 0),
        Self.task("done", createdAt: 90, settledAt: 30),
      ]
    )
    #expect(
      structure.visibleTaskIDs.map(\.rawValue) == ["pinned", "live", "parked", "done"]
    )
  }

  // MARK: - A16: pin

  @Test func pinnedRowsLeadTheActiveSection() {
    let structure = Self.compute([
      Self.task("newest", createdAt: 300),
      Self.task("oldest-pinned", createdAt: 0, pinnedAt: 0),
      Self.task("middle", createdAt: 100),
    ])
    #expect(
      structure.activeTaskIDs.map(\.rawValue) == ["oldest-pinned", "newest", "middle"]
    )
    #expect(structure.pinnedTaskIDs == [TaskID("oldest-pinned")])
  }

  /// Within the pinned block the same static rule applies — newest-created
  /// first, ID tie-break — so pinning never introduces a second sort order.
  @Test func pinnedBlockKeepsTheStaticActiveOrder() {
    let structure = Self.compute([
      Self.task("p-old", createdAt: 0, pinnedAt: 500),
      Self.task("p-new", createdAt: 200, pinnedAt: 0),
      Self.task("plain", createdAt: 400),
    ])
    #expect(structure.activeTaskIDs.map(\.rawValue) == ["p-new", "p-old", "plain"])
  }

  /// A16 precedence, the other half: pin beats settled, so a pinned task with a
  /// stale settle stamp stays on top rather than sinking into the tail. (The
  /// reducer clears `pinnedAt` on an explicit settle, so this state only exists
  /// when the settle was derived.)
  @Test func pinBeatsASettleStamp() {
    let structure = Self.compute([Self.task("pinned", settledAt: 30, pinnedAt: 0)])
    #expect(structure.activeTaskIDs.map(\.rawValue) == ["pinned"])
    #expect(structure.settledTotalCount == 0)
  }

  @Test func snoozeBeatsPin() {
    let structure = Self.compute(
      [Self.task("both", snoozedUntil: 3600, snoozedAt: 0, pinnedAt: 0)]
    )
    #expect(structure.activeTaskIDs.isEmpty)
    #expect(structure.snoozedTotalCount == 1)
    // The pin survives the snooze (A16) — the shelf entry still reports it, so
    // the row keeps its glyph and returns to the top when it wakes.
    #expect(structure.pinnedTaskIDs == [TaskID("both")])
  }

  // MARK: - A24: waking

  /// The whole point of the static ordering: a task that comes back lands where
  /// it always was, not at the top of the list.
  @Test func awokenTaskReturnsToItsCreationOrderPosition() {
    let tasks = [
      Self.task("newest", createdAt: 300),
      Self.task("waking", createdAt: 100, snoozedUntil: 600, snoozedAt: 0),
      Self.task("oldest", createdAt: 0),
    ]
    let asleep = Self.compute(tasks)
    #expect(asleep.activeTaskIDs.map(\.rawValue) == ["newest", "oldest"])

    let awake = Self.compute(tasks, now: Self.reference.addingTimeInterval(900))
    #expect(awake.activeTaskIDs.map(\.rawValue) == ["newest", "waking", "oldest"])
    #expect(awake.snoozedTotalCount == 0)
  }

  /// The wake boundary is inclusive on the wake side (`TaskSnooze`), so a
  /// boundary-armed effect that lands exactly on the instant always observes a
  /// woken row.
  @Test func aTaskIsAwakeExactlyAtItsWakeInstant() {
    let structure = Self.compute(
      [Self.task("waking", snoozedUntil: 600, snoozedAt: 0)],
      now: Self.reference.addingTimeInterval(600)
    )
    #expect(structure.activeTaskIDs.map(\.rawValue) == ["waking"])
  }

  /// The Woke pill is derived, never stored: an expired snooze the user has not
  /// visited since. No new persisted field, so a relaunch re-derives the same
  /// answer instead of resurrecting a stale marker.
  @Test func wokeTaskIsMarkedUntilItIsVisited() {
    let unvisited = Self.task("unvisited", snoozedUntil: 600, snoozedAt: 0)
    let visited = Self.task("visited", snoozedUntil: 600, snoozedAt: 0, lastVisitedAt: 900)
    let staleVisit = Self.task("stale-visit", snoozedUntil: 600, snoozedAt: 0, lastVisitedAt: 100)
    let structure = Self.compute(
      [unvisited, visited, staleVisit],
      now: Self.reference.addingTimeInterval(1200)
    )
    #expect(structure.wokeTaskIDs == [TaskID("unvisited"), TaskID("stale-visit")])
  }

  @Test func aStillParkedTaskIsNotMarkedWoke() {
    let structure = Self.compute([Self.task("parked", snoozedUntil: 3600, snoozedAt: 0)])
    #expect(structure.wokeTaskIDs.isEmpty)
  }

  /// A task that was never snoozed has nothing to wake from.
  @Test func aNeverSnoozedTaskIsNeverMarkedWoke() {
    #expect(Self.compute([Self.task("plain")]).wokeTaskIDs.isEmpty)
  }

  // MARK: - A25: raised hand while snoozed

  /// A pending question outranks the user's earlier "not now" with no clock
  /// involved at all: the row is back in the active section on the same
  /// recompute the signal arrives on, and the snooze fields are untouched.
  @Test func pendingInputUnsnoozesWithoutAdvancingTheClock() {
    let parked = Self.task("parked", createdAt: 0, snoozedUntil: 3600, snoozedAt: 0)
    let structure = Self.compute(
      [parked],
      signals: [
        parked.id: TasksSidebarStructure.Signals(
          activity: TaskSettlement.ActivitySnapshot(isAwaitingInput: true)
        )
      ]
    )
    #expect(structure.activeTaskIDs.map(\.rawValue) == ["parked"])
    #expect(structure.snoozedTotalCount == 0)
    #expect(structure.wokeTaskIDs == [parked.id])
  }

  @Test func pendingApprovalUnsnoozes() {
    let parked = Self.task("parked", snoozedUntil: 3600, snoozedAt: 0)
    let structure = Self.compute(
      [parked],
      signals: [
        parked.id: TasksSidebarStructure.Signals(
          activity: TaskSettlement.ActivitySnapshot(isAwaitingApproval: true)
        )
      ]
    )
    #expect(structure.activeTaskIDs.map(\.rawValue) == ["parked"])
  }

  /// An agent that cannot report approval at all (`nil`, Resolved #1) must not
  /// read as pending — that would un-snooze every non-emitting agent's task.
  @Test func unreportableApprovalDoesNotUnsnooze() {
    let parked = Self.task("parked", snoozedUntil: 3600, snoozedAt: 0)
    let structure = Self.compute(
      [parked],
      signals: [
        parked.id: TasksSidebarStructure.Signals(
          activity: TaskSettlement.ActivitySnapshot(isAwaitingApproval: nil)
        )
      ]
    )
    #expect(structure.snoozedTotalCount == 1)
  }

  @Test func anErrorNewerThanTheSnoozeUnsnoozes() {
    let parked = Self.task("parked", snoozedUntil: 3600, snoozedAt: 0)
    let structure = Self.compute(
      [parked],
      signals: [parked.id: .init(errorAt: Self.reference.addingTimeInterval(60))]
    )
    #expect(structure.activeTaskIDs.map(\.rawValue) == ["parked"])
  }

  /// The user snoozed a task they already knew was broken. It stays parked.
  @Test func aPreSnoozeErrorDoesNotUnsnooze() {
    let parked = Self.task("parked", snoozedUntil: 3600, snoozedAt: 0)
    let structure = Self.compute(
      [parked],
      signals: [parked.id: .init(errorAt: Self.reference.addingTimeInterval(-60))]
    )
    #expect(structure.snoozedTotalCount == 1)
    #expect(structure.wokeTaskIDs.isEmpty)
  }

  @Test func aTurnThatFinishedAfterTheSnoozeUnsnoozes() {
    let parked = Self.task("parked", snoozedUntil: 3600, snoozedAt: 0)
    let structure = Self.compute(
      [parked],
      signals: [parked.id: .init(completedTurnAt: Self.reference.addingTimeInterval(60))]
    )
    #expect(structure.activeTaskIDs.map(\.rawValue) == ["parked"])
  }

  @Test func aTurnThatFinishedBeforeTheSnoozeDoesNotUnsnooze() {
    let parked = Self.task("parked", snoozedUntil: 3600, snoozedAt: 0)
    let structure = Self.compute(
      [parked],
      signals: [parked.id: .init(completedTurnAt: Self.reference.addingTimeInterval(-60))]
    )
    #expect(structure.snoozedTotalCount == 1)
  }

  /// A raised hand is classification, not a mutation (A25): it never clears the
  /// snooze, so the moment the hand goes down the row returns to the shelf with
  /// its original wake time. Nothing had to be re-asked.
  @Test func aRaisedHandThatGoesDownReturnsTheTaskToTheShelf() {
    let parked = Self.task("parked", snoozedUntil: 3600, snoozedAt: 0)
    let raised = Self.compute(
      [parked],
      signals: [parked.id: .init(activity: .init(isAwaitingInput: true))]
    )
    #expect(raised.snoozedTotalCount == 0)

    let lowered = Self.compute([parked])
    #expect(lowered.visibleSnoozedEntries.map(\.id) == [parked.id])
    #expect(lowered.visibleSnoozedEntries.first?.wakeAt == parked.snoozedUntil)
  }

  /// Resolved #7: an unread terminal notification is the primary wake trigger
  /// for a task running no hook-reporting agent at all. Same freshness rule as
  /// the other events.
  @Test func aNotificationNewerThanTheSnoozeUnsnoozes() {
    let parked = Self.task("parked", snoozedUntil: 3600, snoozedAt: 0)
    let structure = Self.compute(
      [parked],
      signals: [parked.id: .init(notifiedAt: Self.reference.addingTimeInterval(60))]
    )
    #expect(structure.activeTaskIDs.map(\.rawValue) == ["parked"])
  }

  @Test func aNotificationOlderThanTheSnoozeDoesNotUnsnooze() {
    let parked = Self.task("parked", snoozedUntil: 3600, snoozedAt: 0)
    let structure = Self.compute(
      [parked],
      signals: [parked.id: .init(notifiedAt: Self.reference.addingTimeInterval(-60))]
    )
    #expect(structure.snoozedTotalCount == 1)
  }

  /// Signals for a task that no longer exists are inert, and a task with no
  /// entry in the map reads as idle rather than as an unreportable unknown.
  @Test func missingSignalsReadAsIdle() {
    let structure = Self.compute(
      [Self.task("parked", snoozedUntil: 3600, snoozedAt: 0)],
      signals: [TaskID("ghost"): .init(activity: .init(isAwaitingInput: true))]
    )
    #expect(structure.snoozedTotalCount == 1)
  }
}

import ComposableArchitecture
import Dependencies
import DependenciesTestSupport
import Foundation
import IdentifiedCollections
import Sharing
import Testing

@testable import SupacodeSettingsShared
@testable import supacode

/// Phase-6 keyboard wiring: assertions A32 (slots), A33 (jump to the next row
/// needing a person) and A34 (mouseless settle / snooze / pin on the focused
/// row) of `plans/task-inbox-sidebar-plan.md`, against the context map in
/// `plans/task-inbox-keyboard-context-map.md`.
///
/// Every chord here reuses an existing arm. ⌃1–9 and ⌃⌘↑↓ are the *same*
/// actions the Worktrees and Agents panels fire — they only grow a `.tasks`
/// branch — so this suite's other half is the inertness suite next door
/// (`RepositoriesFeatureTasksTabRoutingTests`), which pins that none of this
/// ever moves the *worktree* selection. Both must stay green: they are the two
/// halves of A35.
///
/// Attention state is driven through `.agentSnapshotChanged`, the arm that
/// actually writes it, never by hand-assembling a leaf: the jump target and the
/// row's fade read one predicate, and a test that fabricates the input cannot
/// see them disagree.
@MainActor
struct RepositoriesFeatureTaskKeyboardTests {
  private typealias Sandbox = TaskInboxSandbox
  private static let now = TaskInboxFixture.now
  private static let freshDate = TaskInboxFixture.freshDate
  private static let hour: TimeInterval = 60 * 60

  // MARK: - Fixture

  private func makeSandbox() throws -> Sandbox {
    try Sandbox(name: "RepositoriesFeatureTaskKeyboardTests")
  }

  private func makeStore(
    _ state: RepositoriesFeature.State,
    sandbox: Sandbox
  ) -> TestStoreOf<RepositoriesFeature> {
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    } withDependencies: {
      $0.settingsFileStorage = sandbox.storage
      $0.date.now = Self.now
      $0.continuousClock = TestClock()
    }
    store.exhaustivity = .off
    return store
  }

  /// Every chord in this file only fires while the Tasks panel is the one on
  /// screen; the shared tab value is what the reducer branches on.
  private func withTasksTab<T>(_ body: () async throws -> T) async rethrows -> T {
    try await withDependencies {
      $0.defaultAppStorage = .inMemory
    } operation: {
      @Shared(.sidebarTab) var sidebarTabRawValue
      $sidebarTabRawValue.withLock { $0 = SidebarTab.tasks.rawValue }
      return try await body()
    }
  }

  private struct Inbox {
    var state: RepositoriesFeature.State
    var records: [TaskRecord]
    var directories: [URL]
  }

  /// `count` directories, one task each, newest-created first — so the visible
  /// order is `task-0, task-1, …`, which is what the slot numbers follow.
  private func makeInbox(
    sandbox: Sandbox,
    count: Int,
    snoozedIndices: Set<Int> = [],
    isSnoozedShelfExpanded: Bool = true,
    selecting selectedIndex: Int? = nil
  ) throws -> Inbox {
    let directories = try (0..<count).map { index in
      try sandbox.makeDirectory("task-\(index)", activityAt: Self.freshDate)
    }
    var state = TaskInboxFixture.makeState(
      sandbox: sandbox,
      directories: directories,
      hasLoadedTasks: true
    )
    let records = directories.enumerated().map { index, directory in
      TaskRecord(
        id: TaskID("task-\(index)"),
        title: directory.lastPathComponent,
        directoryPath: TaskDirectoryPath.canonical(directory),
        // Descending, so index 0 is the newest and therefore the top row.
        createdAt: Self.freshDate.addingTimeInterval(-TimeInterval(index)),
        snoozedUntil: snoozedIndices.contains(index) ? Self.now.addingTimeInterval(Self.hour) : nil,
        snoozedAt: snoozedIndices.contains(index) ? Self.now : nil
      )
    }
    state.taskRecords = IdentifiedArray(uniqueElements: records)
    state.taskNow = Self.now
    state.isSnoozedShelfExpanded = isSnoozedShelfExpanded
    if let selectedIndex {
      state.selection = .task(records[selectedIndex].id)
    }
    state.applyPostReduceCacheRecomputes(.all)
    return Inbox(state: state, records: records, directories: directories)
  }

  private func visibleIDs(_ store: TestStoreOf<RepositoriesFeature>) -> [TaskID] {
    store.state.tasksSidebarStructure.visibleTaskIDs
  }

  // MARK: - A32: ⌃1–9 opens the nth visible task

  @Test func theSlotChordOpensTheNthVisibleTask() async throws {
    let sandbox = try makeSandbox()
    let inbox = try makeInbox(sandbox: sandbox, count: 3)
    try await withTasksTab {
      let store = makeStore(inbox.state, sandbox: sandbox)
      let visible = visibleIDs(store)

      await store.send(.selectWorktreeAtHotkeySlot(1))
      await store.finish()

      #expect(store.state.selection == .task(visible[1]))
      // A9 still holds: task navigation never moves the worktree selection.
      #expect(store.state.selectedWorktreeID == nil)
    }
  }

  /// Out of range beeps rather than wrapping: ⌃9 in a three-task inbox meant a
  /// row that is not there, and silently opening the last one would teach the
  /// wrong map.
  @Test func aSlotPastTheLastVisibleTaskLeavesTheSelectionAlone() async throws {
    let sandbox = try makeSandbox()
    let inbox = try makeInbox(sandbox: sandbox, count: 2, selecting: 0)
    try await withTasksTab {
      let store = makeStore(inbox.state, sandbox: sandbox)

      await store.send(.selectWorktreeAtHotkeySlot(5))
      await store.finish()

      #expect(store.state.selection == .task(inbox.records[0].id))
    }
  }

  /// A32's "hidden rows consume no slots", end to end: with the shelf collapsed
  /// the parked task is unaddressable, and ⌃2 lands on the row the user can
  /// actually see in second place.
  @Test func rowsBehindACollapsedShelfAreUnaddressableBySlot() async throws {
    let sandbox = try makeSandbox()
    let inbox = try makeInbox(
      sandbox: sandbox,
      count: 3,
      snoozedIndices: [1],
      isSnoozedShelfExpanded: false
    )
    try await withTasksTab {
      let store = makeStore(inbox.state, sandbox: sandbox)
      #expect(visibleIDs(store) == [inbox.records[0].id, inbox.records[2].id])

      await store.send(.selectWorktreeAtHotkeySlot(1))
      await store.finish()

      #expect(store.state.selection == .task(inbox.records[2].id))
    }
  }

  // MARK: - A32: ⌃⌘↓ / ⌃⌘↑ walk the visible list

  @Test func selectNextWalksToTheFollowingVisibleTask() async throws {
    let sandbox = try makeSandbox()
    let inbox = try makeInbox(sandbox: sandbox, count: 3, selecting: 0)
    try await withTasksTab {
      let store = makeStore(inbox.state, sandbox: sandbox)

      await store.send(.selectNextWorktree)
      await store.finish()

      #expect(store.state.selection == .task(inbox.records[1].id))
    }
  }

  /// Wrapping, matching `worktreeID(byOffset:)` and
  /// `agentDashboardEntryID(byOffset:)` — three panels, one walk.
  @Test func selectNextWrapsAtTheEndOfTheVisibleList() async throws {
    let sandbox = try makeSandbox()
    let inbox = try makeInbox(sandbox: sandbox, count: 3, selecting: 2)
    try await withTasksTab {
      let store = makeStore(inbox.state, sandbox: sandbox)

      await store.send(.selectNextWorktree)
      await store.finish()

      #expect(store.state.selection == .task(inbox.records[0].id))
    }
  }

  @Test func selectPreviousWrapsAtTheTopOfTheVisibleList() async throws {
    let sandbox = try makeSandbox()
    let inbox = try makeInbox(sandbox: sandbox, count: 3, selecting: 0)
    try await withTasksTab {
      let store = makeStore(inbox.state, sandbox: sandbox)

      await store.send(.selectPreviousWorktree)
      await store.finish()

      #expect(store.state.selection == .task(inbox.records[2].id))
    }
  }

  /// Nothing selected yet: enter the list from the end the user is travelling
  /// towards, exactly like the Agents panel.
  @Test func walkingWithoutASelectionEntersFromTheTravelledEnd() async throws {
    let sandbox = try makeSandbox()
    let inbox = try makeInbox(sandbox: sandbox, count: 3)
    try await withTasksTab {
      let next = makeStore(inbox.state, sandbox: sandbox)
      await next.send(.selectNextWorktree)
      await next.finish()
      #expect(next.state.selection == .task(inbox.records[0].id))

      let previous = makeStore(inbox.state, sandbox: sandbox)
      await previous.send(.selectPreviousWorktree)
      await previous.finish()
      #expect(previous.state.selection == .task(inbox.records[2].id))
    }
  }

  @Test func walkingAnEmptyInboxLeavesEverythingAlone() async throws {
    let sandbox = try makeSandbox()
    let inbox = try makeInbox(sandbox: sandbox, count: 0)
    try await withTasksTab {
      let store = makeStore(inbox.state, sandbox: sandbox)

      await store.send(.selectNextWorktree)
      await store.send(.selectWorktreeAtHotkeySlot(0))
      await store.finish()

      #expect(store.state.selection == nil)
    }
  }

  // MARK: - A33: ⌃⌘J jumps to the next row needing a person

  /// Working rows are skipped — they are busy, not owed — and the landing site
  /// is the next raised hand in visible order.
  @Test func theJumpSkipsWorkingRowsAndLandsOnTheNextRaisedHand() async throws {
    let sandbox = try makeSandbox()
    let inbox = try makeInbox(sandbox: sandbox, count: 4, selecting: 0)
    try await withTasksTab {
      let store = makeStore(inbox.state, sandbox: sandbox)

      await store.send(
        .tasks(
          .agentSnapshotChanged(
            taskID: inbox.records[1].id,
            snapshot: .init(isWorking: true)
          )
        )
      )
      await store.send(
        .tasks(
          .agentSnapshotChanged(
            taskID: inbox.records[2].id,
            snapshot: .init(isAwaitingInput: true)
          )
        )
      )
      await store.finish()
      // The two readings agree before the jump is asked for anything.
      #expect(store.state.taskLeaves[id: inbox.records[1].id]?.needsHuman == false)
      #expect(store.state.taskLeaves[id: inbox.records[2].id]?.needsHuman == true)

      await store.send(.tasks(.jumpToNextNeedingAttention))
      await store.finish()

      #expect(store.state.selection == .task(inbox.records[2].id))
    }
  }

  @Test func theJumpWrapsPastTheEndOfTheInbox() async throws {
    let sandbox = try makeSandbox()
    let inbox = try makeInbox(sandbox: sandbox, count: 3, selecting: 2)
    try await withTasksTab {
      let store = makeStore(inbox.state, sandbox: sandbox)

      await store.send(
        .tasks(
          .agentSnapshotChanged(
            taskID: inbox.records[0].id,
            snapshot: .init(isAwaitingInput: true)
          )
        )
      )
      await store.send(.tasks(.jumpToNextNeedingAttention))
      await store.finish()

      #expect(store.state.selection == .task(inbox.records[0].id))
    }
  }

  /// A quiet inbox: the chord beeps and changes nothing. Silently re-selecting
  /// the open row would read as a broken shortcut.
  @Test func theJumpWithNoCandidateLeavesTheSelectionAlone() async throws {
    let sandbox = try makeSandbox()
    let inbox = try makeInbox(sandbox: sandbox, count: 3, selecting: 1)
    try await withTasksTab {
      let store = makeStore(inbox.state, sandbox: sandbox)

      await store.send(.tasks(.jumpToNextNeedingAttention))
      await store.finish()

      #expect(store.state.selection == .task(inbox.records[1].id))
    }
  }

  /// The chord belongs to the inbox. On the Worktrees panel it must not reach
  /// across and move a selection the user cannot see.
  @Test func theJumpIsInertWhileAnotherPanelIsOnScreen() async throws {
    let sandbox = try makeSandbox()
    let inbox = try makeInbox(sandbox: sandbox, count: 2, selecting: 0)
    await withDependencies {
      $0.defaultAppStorage = .inMemory
    } operation: {
      @Shared(.sidebarTab) var sidebarTabRawValue
      $sidebarTabRawValue.withLock { $0 = SidebarTab.worktrees.rawValue }
      let store = makeStore(inbox.state, sandbox: sandbox)

      await store.send(
        .tasks(
          .agentSnapshotChanged(
            taskID: inbox.records[1].id,
            snapshot: .init(isAwaitingInput: true)
          )
        )
      )
      await store.send(.tasks(.jumpToNextNeedingAttention))
      await store.finish()

      #expect(store.state.selection == .task(inbox.records[0].id))
    }
  }

  // MARK: - A34: settle / snooze / pin on the focused row

  @Test func theSettleChordSettlesTheFocusedTask() async throws {
    let sandbox = try makeSandbox()
    let inbox = try makeInbox(sandbox: sandbox, count: 2, selecting: 0)
    try await withTasksTab {
      let store = makeStore(inbox.state, sandbox: sandbox)

      await store.send(.tasks(.settleSelected))
      await store.send(.tasks(.stopTimers))
      await store.finish()

      #expect(store.state.taskRecords[id: inbox.records[0].id]?.settledAt == Self.now)
      #expect(store.state.taskRecords[id: inbox.records[1].id]?.settledAt == nil)
    }
  }

  /// The same chord takes it back, matching the context menu's own branch: one
  /// key, one row, both directions, and the direction is read from the same
  /// cached structure the menu item's title is.
  @Test func theSettleChordUnsettlesAnAlreadySettledTask() async throws {
    let sandbox = try makeSandbox()
    let inbox = try makeInbox(sandbox: sandbox, count: 1, selecting: 0)
    try await withTasksTab {
      let store = makeStore(inbox.state, sandbox: sandbox)

      await store.send(.tasks(.settleSelected))
      await store.finish()
      #expect(store.state.tasksSidebarStructure.openTaskCommands?.isSettled == true)

      await store.send(.tasks(.settleSelected))
      await store.send(.tasks(.stopTimers))
      await store.finish()

      #expect(store.state.taskRecords[id: inbox.records[0].id]?.settledAt == nil)
    }
  }

  /// A18b through the keyboard: the menu item is disabled, but a chord that
  /// arrives anyway must refuse rather than file away a task that is asking the
  /// user a question.
  @Test func theSettleChordRefusesATaskThatIsAwaitingAPerson() async throws {
    let sandbox = try makeSandbox()
    let inbox = try makeInbox(sandbox: sandbox, count: 1, selecting: 0)
    try await withTasksTab {
      let store = makeStore(inbox.state, sandbox: sandbox)

      await store.send(
        .tasks(
          .agentSnapshotChanged(
            taskID: inbox.records[0].id,
            snapshot: .init(isAwaitingInput: true)
          )
        )
      )
      await store.send(.tasks(.settleSelected))
      await store.send(.tasks(.stopTimers))
      await store.finish()

      #expect(store.state.tasksSidebarStructure.openTaskCommands?.canSettle == false)
      #expect(store.state.taskRecords[id: inbox.records[0].id]?.settledAt == nil)
    }
  }

  /// A chord cannot express a duration, so it takes the cheapest, most
  /// reversible preset — "In an Hour" — and Wake Now stays one context menu
  /// away. The instant comes from the reducer's own clock sample, never from a
  /// view reaching for `Date()`.
  @Test func theSnoozeChordParksTheFocusedTaskForAnHour() async throws {
    let sandbox = try makeSandbox()
    let inbox = try makeInbox(sandbox: sandbox, count: 2, selecting: 1)
    try await withTasksTab {
      let store = makeStore(inbox.state, sandbox: sandbox)

      await store.send(.tasks(.snoozeSelected))
      await store.send(.tasks(.stopTimers))
      await store.finish()

      let parked = try #require(store.state.taskRecords[id: inbox.records[1].id])
      #expect(parked.snoozedUntil == Self.now.addingTimeInterval(Self.hour))
      #expect(parked.snoozedAt == Self.now)
      #expect(store.state.taskRecords[id: inbox.records[0].id]?.snoozedUntil == nil)
    }
  }

  @Test func theSnoozeChordRefusesATaskThatIsAwaitingAPerson() async throws {
    let sandbox = try makeSandbox()
    let inbox = try makeInbox(sandbox: sandbox, count: 1, selecting: 0)
    try await withTasksTab {
      let store = makeStore(inbox.state, sandbox: sandbox)

      await store.send(
        .tasks(
          .agentSnapshotChanged(
            taskID: inbox.records[0].id,
            snapshot: .init(isAwaitingInput: true)
          )
        )
      )
      await store.send(.tasks(.snoozeSelected))
      await store.send(.tasks(.stopTimers))
      await store.finish()

      #expect(store.state.taskRecords[id: inbox.records[0].id]?.snoozedUntil == nil)
    }
  }

  @Test func thePinChordPinsAndThenUnpinsTheFocusedTask() async throws {
    let sandbox = try makeSandbox()
    let inbox = try makeInbox(sandbox: sandbox, count: 2, selecting: 1)
    try await withTasksTab {
      let store = makeStore(inbox.state, sandbox: sandbox)

      await store.send(.tasks(.togglePinSelected))
      await store.finish()
      #expect(store.state.taskRecords[id: inbox.records[1].id]?.pinnedAt == Self.now)
      // Slots follow render order, so the pin moves the row to ⌃1.
      #expect(store.state.tasksSidebarStructure.slotByTaskID[inbox.records[1].id] == 0)

      await store.send(.tasks(.togglePinSelected))
      await store.send(.tasks(.stopTimers))
      await store.finish()

      #expect(store.state.taskRecords[id: inbox.records[1].id]?.pinnedAt == nil)
    }
  }

  /// Nothing focused: every lifecycle chord is a no-op. The menu items are
  /// disabled in that state, so this is the belt to their braces.
  @Test func theLifecycleChordsDoNothingWithoutAFocusedTask() async throws {
    let sandbox = try makeSandbox()
    let inbox = try makeInbox(sandbox: sandbox, count: 2)
    try await withTasksTab {
      let store = makeStore(inbox.state, sandbox: sandbox)

      await store.send(.tasks(.settleSelected))
      await store.send(.tasks(.snoozeSelected))
      await store.send(.tasks(.togglePinSelected))
      await store.send(.tasks(.stopTimers))
      await store.finish()

      #expect(store.state.taskRecords.allSatisfy { $0.settledAt == nil })
      #expect(store.state.taskRecords.allSatisfy { $0.snoozedUntil == nil })
      #expect(store.state.taskRecords.allSatisfy { $0.pinnedAt == nil })
    }
  }

  // MARK: - The → escape hatch

  /// Bare → moves focus from the row into the task's terminal. It re-emits the
  /// focus delegate the selection already resolves, and deliberately does *not*
  /// re-stamp `lastVisitedAt`: leaving the sidebar is not a fresh visit, and a
  /// stamp here would clear a Done pill the user never looked at.
  @Test func theEscapeHatchFocusesTheTaskSurfaceWithoutReStampingTheVisit() async throws {
    let sandbox = try makeSandbox()
    let directory = try sandbox.makeDirectory("mine", activityAt: Self.freshDate)
    let surfaceID = UUID()
    var state = TaskInboxFixture.makeState(
      sandbox: sandbox,
      directories: [directory],
      surfacesPerRow: [directory: [surfaceID]],
      hasLoadedTasks: true
    )
    let record = TaskInboxFixture.makeRecord(directory: directory, surfaceIDs: [surfaceID])
    state.taskRecords = [record]
    state.selection = .task(record.id)
    state.taskNow = Self.now
    state.applyPostReduceCacheRecomputes(.all)

    try await withTasksTab {
      let store = makeStore(state, sandbox: sandbox)

      await store.send(.tasks(.focusSelectedSurface))
      await store.receive(\.delegate.focusTaskSurface)
      await store.finish()

      #expect(store.state.taskRecords[id: record.id]?.lastVisitedAt == nil)
      #expect(store.state.selection == .task(record.id))
    }
  }
}

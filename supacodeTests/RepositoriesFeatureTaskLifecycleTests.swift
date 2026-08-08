import ComposableArchitecture
import Dependencies
import DependenciesTestSupport
import Foundation
import IdentifiedCollections
import Sharing
import Testing

@testable import SupacodeSettingsShared
@testable import supacode

/// Phase-4 lifecycle wiring: snooze, pin, keep-active, the two wake clocks, the
/// derived raised hand, and forward navigation — assertions A16 (wired) and
/// A23–A26 of `plans/task-inbox-sidebar-plan.md`, plus A18b's reducer-side
/// affordance guards.
///
/// The pure halves (`TaskSnooze`, `TaskSettlement`, `TaskForwardNavigation`) are
/// covered by their own suites. This file only asserts the wiring: which arm
/// writes which field, which effect is armed when, and what the cached
/// `TasksSidebarStructure` ends up saying.
///
/// Time is injected twice over, on purpose (A23): `\.date.now` stamps the
/// records, and `\.continuousClock` drives the coarse tick and the
/// boundary-armed wake. No `Task.sleep` anywhere.
@MainActor
struct RepositoriesFeatureTaskLifecycleTests {
  private typealias Sandbox = TaskInboxSandbox
  private static let now = TaskInboxFixture.now
  private static let freshDate = TaskInboxFixture.freshDate
  private static let staleDate = TaskInboxFixture.staleDate
  private static let hour: TimeInterval = 60 * 60

  // MARK: - Fixture

  private func makeSandbox() throws -> Sandbox {
    try Sandbox(name: "RepositoriesFeatureTaskLifecycleTests")
  }

  private func makeStore(
    _ state: RepositoriesFeature.State,
    sandbox: Sandbox,
    clock: TestClock<Duration> = TestClock()
  ) -> TestStoreOf<RepositoriesFeature> {
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    } withDependencies: {
      $0.settingsFileStorage = sandbox.storage
      $0.date.now = Self.now
      $0.continuousClock = clock
    }
    store.exhaustivity = .off
    return store
  }

  private func makeRecord(
    directory: URL,
    id: TaskID = TaskID(),
    surfaceIDs: Set<UUID> = [],
    createdAt: Date = TaskInboxFixture.freshDate,
    settledAt: Date? = nil,
    settledOverride: TaskRecord.SettledOverride? = nil,
    snoozedUntil: Date? = nil,
    snoozedAt: Date? = nil,
    pinnedAt: Date? = nil,
    lastVisitedAt: Date? = nil
  ) -> TaskRecord {
    TaskRecord(
      id: id,
      title: directory.lastPathComponent,
      directoryPath: TaskDirectoryPath.canonical(directory),
      createdAt: createdAt,
      settledAt: settledAt,
      settledOverride: settledOverride,
      snoozedUntil: snoozedUntil,
      snoozedAt: snoozedAt,
      pinnedAt: pinnedAt,
      lastVisitedAt: lastVisitedAt,
      surfaceIDs: surfaceIDs
    )
  }

  /// One directory, one task, caches converged — the shape most of these tests
  /// start from.
  private struct SingleTask {
    var state: RepositoriesFeature.State
    var record: TaskRecord
  }

  private func makeSingleTaskState(
    sandbox: Sandbox,
    record: (URL) -> TaskRecord
  ) throws -> SingleTask {
    let directory = try sandbox.makeDirectory("mine", activityAt: Self.freshDate)
    var state = TaskInboxFixture.makeState(
      sandbox: sandbox,
      directories: [directory],
      hasLoadedTasks: true
    )
    let record = record(directory)
    state.taskRecords = [record]
    state.taskNow = Self.now
    state.applyPostReduceCacheRecomputes(.all)
    return SingleTask(state: state, record: record)
  }

  // MARK: - A16: snooze writes

  @Test func snoozeParksTheTaskAndPersistsBothStamps() async throws {
    let sandbox = try makeSandbox()
    let fixture = try makeSingleTaskState(sandbox: sandbox) { makeRecord(directory: $0) }
    let store = makeStore(fixture.state, sandbox: sandbox)
    let wake = Self.now.addingTimeInterval(4 * Self.hour)

    await store.send(.tasks(.snooze(fixture.record.id, until: wake)))
    await store.send(.tasks(.stopTimers))
    await store.finish()

    let parked = try #require(store.state.taskRecords[id: fixture.record.id])
    #expect(parked.snoozedUntil == wake)
    // `snoozedAt` is what every raised-hand freshness rule measures against
    // (A25), so it is stamped separately and never derived from `until`.
    #expect(parked.snoozedAt == Self.now)
    #expect(store.state.tasksSidebarStructure.activeTaskIDs.isEmpty)
    #expect(store.state.tasksSidebarStructure.snoozedTotalCount == 1)
    // A11: it survives the round-trip to disk.
    let persisted = try #require(sandbox.loadFile()?.tasks.first)
    #expect(persisted.snoozedUntil == wake)
    #expect(persisted.snoozedAt == Self.now)
  }

  /// Re-snoozing to the same instant must not re-stamp `snoozedAt`: that would
  /// silently reset every freshness comparison and un-raise a hand the user
  /// already saw go up.
  @Test func reSnoozingToTheSameInstantIsANoOp() async throws {
    let sandbox = try makeSandbox()
    let wake = Self.now.addingTimeInterval(4 * Self.hour)
    let fixture = try makeSingleTaskState(sandbox: sandbox) {
      makeRecord(directory: $0, snoozedUntil: wake, snoozedAt: Self.staleDate)
    }
    let store = makeStore(fixture.state, sandbox: sandbox)

    await store.send(.tasks(.snooze(fixture.record.id, until: wake)))
    await store.send(.tasks(.stopTimers))
    await store.finish()

    #expect(store.state.taskRecords[id: fixture.record.id]?.snoozedAt == Self.staleDate)
    #expect(!sandbox.didWriteTasksFile)
  }

  /// A16: snooze KEEPS the pin. The two are orthogonal instructions — "not now"
  /// and "always up top" — so waking restores the pinned position.
  @Test func snoozeKeepsThePin() async throws {
    let sandbox = try makeSandbox()
    let fixture = try makeSingleTaskState(sandbox: sandbox) {
      makeRecord(directory: $0, pinnedAt: Self.staleDate)
    }
    let store = makeStore(fixture.state, sandbox: sandbox)

    await store.send(.tasks(.snooze(fixture.record.id, until: Self.now.addingTimeInterval(Self.hour))))
    await store.send(.tasks(.stopTimers))
    await store.finish()

    #expect(store.state.taskRecords[id: fixture.record.id]?.pinnedAt == Self.staleDate)
    #expect(store.state.tasksSidebarStructure.pinnedTaskIDs == [fixture.record.id])
  }

  /// The Phase-4 answer to the open question `canSnooze` carried: snoozing a
  /// settled task un-settles it. The user is saying "bring this back later",
  /// which is only true if it comes back to the active section rather than to
  /// the tail it was already in.
  @Test func snoozingASettledTaskUnsettlesIt() async throws {
    let sandbox = try makeSandbox()
    let fixture = try makeSingleTaskState(sandbox: sandbox) {
      makeRecord(directory: $0, settledAt: Self.staleDate)
    }
    let store = makeStore(fixture.state, sandbox: sandbox)

    await store.send(.tasks(.snooze(fixture.record.id, until: Self.now.addingTimeInterval(Self.hour))))
    await store.send(.tasks(.stopTimers))
    await store.finish()

    let parked = try #require(store.state.taskRecords[id: fixture.record.id])
    #expect(parked.settledAt == nil)
    // The explicit `.active` override is what stops Phase 5's inactivity
    // cascade from re-settling it the moment it wakes.
    #expect(parked.settledOverride == .active)
    #expect(store.state.tasksSidebarStructure.settledTotalCount == 0)
    #expect(store.state.tasksSidebarStructure.snoozedTotalCount == 1)
  }

  /// The override is a repair for un-settling, not a side effect of parking.
  /// Stamping `.active` on every snooze would quietly hand a permanent
  /// "keep active" to tasks the user never settled, immunizing them against
  /// Phase 5's inactivity cascade for the rest of their lives.
  @Test func snoozingAnActiveTaskLeavesTheOverrideAlone() async throws {
    let sandbox = try makeSandbox()
    let fixture = try makeSingleTaskState(sandbox: sandbox) { makeRecord(directory: $0) }
    let store = makeStore(fixture.state, sandbox: sandbox)

    await store.send(.tasks(.snooze(fixture.record.id, until: Self.now.addingTimeInterval(Self.hour))))
    await store.send(.tasks(.stopTimers))
    await store.finish()

    let parked = try #require(store.state.taskRecords[id: fixture.record.id])
    #expect(parked.settledOverride == nil)
    #expect(parked.snoozedAt == Self.now)
    #expect(store.state.tasksSidebarStructure.snoozedTotalCount == 1)
  }

  /// An explicit `.settled` override is settled-ness too, so a snooze has to
  /// clear it the same way it clears the stamp — otherwise the task comes back
  /// from the shelf straight into the tail it was parked out of.
  @Test func snoozingAnOverrideSettledTaskUnsettlesIt() async throws {
    let sandbox = try makeSandbox()
    let fixture = try makeSingleTaskState(sandbox: sandbox) {
      makeRecord(directory: $0, settledOverride: .settled)
    }
    let store = makeStore(fixture.state, sandbox: sandbox)

    await store.send(.tasks(.snooze(fixture.record.id, until: Self.now.addingTimeInterval(Self.hour))))
    await store.send(.tasks(.stopTimers))
    await store.finish()

    #expect(store.state.taskRecords[id: fixture.record.id]?.settledOverride == .active)
    #expect(store.state.tasksSidebarStructure.settledTotalCount == 0)
  }

  @Test func snoozeIsRefusedForAnUnknownTask() async throws {
    let sandbox = try makeSandbox()
    let fixture = try makeSingleTaskState(sandbox: sandbox) { makeRecord(directory: $0) }
    let store = makeStore(fixture.state, sandbox: sandbox)

    await store.send(.tasks(.snooze(TaskID("ghost"), until: Self.now.addingTimeInterval(Self.hour))))
    await store.finish()

    #expect(!sandbox.didWriteTasksFile)
  }

  // MARK: - A16: unsnooze

  @Test func unsnoozeClearsBothStampsAndRestoresTheStaticPosition() async throws {
    let sandbox = try makeSandbox()
    let older = try sandbox.makeDirectory("older", activityAt: Self.freshDate)
    let newer = try sandbox.makeDirectory("newer", activityAt: Self.freshDate)
    var state = TaskInboxFixture.makeState(
      sandbox: sandbox,
      directories: [older, newer],
      hasLoadedTasks: true
    )
    let parked = makeRecord(
      directory: older,
      createdAt: Self.now.addingTimeInterval(-2 * Self.hour),
      snoozedUntil: Self.now.addingTimeInterval(Self.hour),
      snoozedAt: Self.staleDate
    )
    let live = makeRecord(directory: newer, createdAt: Self.now.addingTimeInterval(-Self.hour))
    state.taskRecords = [parked, live]
    state.taskNow = Self.now
    state.applyPostReduceCacheRecomputes(.all)
    let store = makeStore(state, sandbox: sandbox)

    await store.send(.tasks(.unsnooze(parked.id)))
    await store.send(.tasks(.stopTimers))
    await store.finish()

    let woken = try #require(store.state.taskRecords[id: parked.id])
    #expect(woken.snoozedUntil == nil)
    #expect(woken.snoozedAt == nil)
    // A24: back where it always was — after the newer row, not on top of it.
    #expect(store.state.tasksSidebarStructure.activeTaskIDs == [live.id, parked.id])
    #expect(store.state.tasksSidebarStructure.snoozedTotalCount == 0)
    // An explicitly un-snoozed task is not "woke": the user did the waking.
    #expect(store.state.tasksSidebarStructure.wokeTaskIDs.isEmpty)
  }

  @Test func unsnoozingATaskThatIsNotSnoozedWritesNothing() async throws {
    let sandbox = try makeSandbox()
    let fixture = try makeSingleTaskState(sandbox: sandbox) { makeRecord(directory: $0) }
    let store = makeStore(fixture.state, sandbox: sandbox)

    await store.send(.tasks(.unsnooze(fixture.record.id)))
    await store.finish()

    #expect(!sandbox.didWriteTasksFile)
  }

  // MARK: - A16: pin / unpin / keep-active

  @Test func pinStampsPinnedAtAndLeadsTheActiveSection() async throws {
    let sandbox = try makeSandbox()
    let older = try sandbox.makeDirectory("older", activityAt: Self.freshDate)
    let newer = try sandbox.makeDirectory("newer", activityAt: Self.freshDate)
    var state = TaskInboxFixture.makeState(
      sandbox: sandbox,
      directories: [older, newer],
      hasLoadedTasks: true
    )
    let old = makeRecord(directory: older, createdAt: Self.now.addingTimeInterval(-2 * Self.hour))
    let new = makeRecord(directory: newer, createdAt: Self.now.addingTimeInterval(-Self.hour))
    state.taskRecords = [old, new]
    state.taskNow = Self.now
    state.applyPostReduceCacheRecomputes(.all)
    let store = makeStore(state, sandbox: sandbox)
    #expect(store.state.tasksSidebarStructure.activeTaskIDs == [new.id, old.id])

    await store.send(.tasks(.pin(old.id)))
    await store.send(.tasks(.stopTimers))
    await store.finish()

    #expect(store.state.taskRecords[id: old.id]?.pinnedAt == Self.now)
    #expect(store.state.tasksSidebarStructure.activeTaskIDs == [old.id, new.id])
    #expect(sandbox.loadFile()?.tasks.first { $0.id == old.id }?.pinnedAt == Self.now)
  }

  /// Idempotent: a second pin must not re-stamp, or a pinned row would jump
  /// inside the pinned block every time the menu item is clicked twice.
  @Test func pinningAnAlreadyPinnedTaskIsANoOp() async throws {
    let sandbox = try makeSandbox()
    let fixture = try makeSingleTaskState(sandbox: sandbox) {
      makeRecord(directory: $0, pinnedAt: Self.staleDate)
    }
    let store = makeStore(fixture.state, sandbox: sandbox)

    await store.send(.tasks(.pin(fixture.record.id)))
    await store.finish()

    #expect(store.state.taskRecords[id: fixture.record.id]?.pinnedAt == Self.staleDate)
    #expect(!sandbox.didWriteTasksFile)
  }

  @Test func unpinClearsTheStamp() async throws {
    let sandbox = try makeSandbox()
    let fixture = try makeSingleTaskState(sandbox: sandbox) {
      makeRecord(directory: $0, pinnedAt: Self.staleDate)
    }
    let store = makeStore(fixture.state, sandbox: sandbox)

    await store.send(.tasks(.unpin(fixture.record.id)))
    await store.send(.tasks(.stopTimers))
    await store.finish()

    #expect(store.state.taskRecords[id: fixture.record.id]?.pinnedAt == nil)
    #expect(store.state.tasksSidebarStructure.pinnedTaskIDs.isEmpty)
  }

  @Test func unpinningAnUnpinnedTaskWritesNothing() async throws {
    let sandbox = try makeSandbox()
    let fixture = try makeSingleTaskState(sandbox: sandbox) { makeRecord(directory: $0) }
    let store = makeStore(fixture.state, sandbox: sandbox)

    await store.send(.tasks(.unpin(fixture.record.id)))
    await store.finish()

    #expect(!sandbox.didWriteTasksFile)
  }

  /// A16, the half Phase 2b deliberately left to the reducer: an explicit
  /// settle CLEARS the pin. Pinning says "keep this in front of me" and
  /// settling says "I am done with it" — the later instruction wins, and a
  /// pinned row surviving in the settled tail would be a row nobody can get rid
  /// of.
  @Test func settleClearsThePin() async throws {
    let sandbox = try makeSandbox()
    let fixture = try makeSingleTaskState(sandbox: sandbox) {
      makeRecord(directory: $0, pinnedAt: Self.staleDate)
    }
    let store = makeStore(fixture.state, sandbox: sandbox)

    await store.send(.tasks(.settle(fixture.record.id)))
    await store.send(.tasks(.stopTimers))
    await store.finish()

    let settled = try #require(store.state.taskRecords[id: fixture.record.id])
    #expect(settled.pinnedAt == nil)
    #expect(settled.settledAt == Self.now)
    #expect(store.state.tasksSidebarStructure.settledTotalCount == 1)
    #expect(store.state.tasksSidebarStructure.pinnedTaskIDs.isEmpty)
    #expect(sandbox.loadFile()?.tasks.first?.pinnedAt == nil)
  }

  /// `keepActive` is the explicit "stop auto-settling this" pin the cascade
  /// reads (A15): it sets the tri-state override to `.active` and clears any
  /// stamp that put the row in the tail.
  @Test func keepActiveSetsTheActiveOverrideAndUnsettles() async throws {
    let sandbox = try makeSandbox()
    let fixture = try makeSingleTaskState(sandbox: sandbox) {
      makeRecord(directory: $0, settledAt: Self.staleDate)
    }
    let store = makeStore(fixture.state, sandbox: sandbox)

    await store.send(.tasks(.keepActive(fixture.record.id)))
    await store.send(.tasks(.stopTimers))
    await store.finish()

    let kept = try #require(store.state.taskRecords[id: fixture.record.id])
    #expect(kept.settledOverride == .active)
    #expect(kept.settledAt == nil)
    #expect(store.state.tasksSidebarStructure.activeTaskIDs == [fixture.record.id])
    #expect(sandbox.loadFile()?.tasks.first?.settledOverride == .active)
  }

  // MARK: - Resolved #13: snooze hibernation

  /// Default off: snooze keeps the sessions live, so undoing it costs nothing.
  @Test func snoozeKeepsSessionsLiveByDefault() async throws {
    let sandbox = try makeSandbox()
    let directory = try sandbox.makeDirectory("mine", activityAt: Self.freshDate)
    let surfaceID = UUID()
    var state = TaskInboxFixture.makeState(
      sandbox: sandbox,
      directories: [directory],
      surfacesPerRow: [directory: [surfaceID]],
      hasLoadedTasks: true
    )
    let record = makeRecord(directory: directory, surfaceIDs: [surfaceID])
    state.taskRecords = [record]
    state.taskNow = Self.now
    state.applyPostReduceCacheRecomputes(.all)
    let store = makeStore(state, sandbox: sandbox)

    await store.send(.tasks(.snooze(record.id, until: Self.now.addingTimeInterval(Self.hour))))
    await store.send(.tasks(.stopTimers))
    await store.finish()

    #expect(store.state.taskRecords[id: record.id]?.surfaceIDs == [surfaceID])
  }

  /// The per-action variant for a long sleep. Same delegate a settle sends, so
  /// the parent has one hibernation path, not two.
  @Test func snoozeAndHibernateRequestsHibernation() async throws {
    let sandbox = try makeSandbox()
    let directory = try sandbox.makeDirectory("mine", activityAt: Self.freshDate)
    let surfaceID = UUID()
    var state = TaskInboxFixture.makeState(
      sandbox: sandbox,
      directories: [directory],
      surfacesPerRow: [directory: [surfaceID]],
      hasLoadedTasks: true
    )
    let record = makeRecord(directory: directory, surfaceIDs: [surfaceID])
    state.taskRecords = [record]
    state.taskNow = Self.now
    state.applyPostReduceCacheRecomputes(.all)
    let store = makeStore(state, sandbox: sandbox)

    await store.send(
      .tasks(.snooze(record.id, until: Self.now.addingTimeInterval(Self.hour), hibernate: true))
    )
    await store.receive(\.delegate.hibernateTaskSurfaces)
    await store.send(.tasks(.stopTimers))
    await store.finish()

    // Hibernating never drops the claim: the task still owns the surfaces it
    // put to sleep, and waking has to find them again (A10b).
    #expect(store.state.taskRecords[id: record.id]?.surfaceIDs == [surfaceID])
  }

  /// The global default flips the *unspecified* case only; an explicit
  /// `hibernate:` on the action always wins.
  @Test func theGlobalDefaultDecidesAnUnspecifiedSnooze() async throws {
    let sandbox = try makeSandbox()
    let directory = try sandbox.makeDirectory("mine", activityAt: Self.freshDate)
    let surfaceID = UUID()
    var state = TaskInboxFixture.makeState(
      sandbox: sandbox,
      directories: [directory],
      surfacesPerRow: [directory: [surfaceID]],
      hasLoadedTasks: true
    )
    let record = makeRecord(directory: directory, surfaceIDs: [surfaceID])
    state.taskRecords = [record]
    state.taskNow = Self.now
    state.applyPostReduceCacheRecomputes(.all)

    try withDependencies {
      $0.settingsFileStorage = sandbox.storage
    } operation: {
      @Shared(.settingsFile) var settingsFile
      $settingsFile.withLock { $0.global.snoozeHibernatesSessions = true }
    }

    let store = makeStore(state, sandbox: sandbox)
    await store.send(.tasks(.snooze(record.id, until: Self.now.addingTimeInterval(Self.hour))))
    await store.receive(\.delegate.hibernateTaskSurfaces)

    await store.send(
      .tasks(.snooze(record.id, until: Self.now.addingTimeInterval(2 * Self.hour), hibernate: false))
    )
    await store.send(.tasks(.stopTimers))
    await store.finish()
  }

  // MARK: - A18b: affordance guards

  /// The blocked-settle guard, reducer-side. A18b puts the refusal at the
  /// affordance, but the arm has to hold the same line — a settle that arrives
  /// anyway (hotkey, menu race, script) must no-op rather than park a task that
  /// is asking the user a question.
  @Test func settleIsRefusedWhileAnAgentIsAwaitingInput() async throws {
    let sandbox = try makeSandbox()
    let directory = try sandbox.makeDirectory("mine", activityAt: Self.freshDate)
    let surfaceID = UUID()
    var state = TaskInboxFixture.makeState(
      sandbox: sandbox,
      directories: [directory],
      surfacesPerRow: [directory: [surfaceID]],
      hasLoadedTasks: true
    )
    let record = makeRecord(directory: directory, surfaceIDs: [surfaceID])
    state.taskRecords = [record]
    state.taskNow = Self.now
    state.sidebarItems[id: WorktreeID(directory.path(percentEncoded: false))]?.agentSnapshot =
      AgentPresenceFeature.RowSnapshot(
        agents: [AgentPresenceFeature.AgentInstance(agent: .claude, activity: .awaitingInput)]
      )
    state.applyPostReduceCacheRecomputes(.all)
    let store = makeStore(state, sandbox: sandbox)

    #expect(!TaskSettlement.canSettle(store.state.taskSettlementInput(for: record.id)))

    await store.send(.tasks(.settle(record.id)))
    await store.finish()

    #expect(store.state.taskRecords[id: record.id]?.settledAt == nil)
    #expect(!sandbox.didWriteTasksFile)
  }

  @Test func snoozeIsRefusedWhileAnAgentIsAwaitingInput() async throws {
    let sandbox = try makeSandbox()
    let directory = try sandbox.makeDirectory("mine", activityAt: Self.freshDate)
    let surfaceID = UUID()
    var state = TaskInboxFixture.makeState(
      sandbox: sandbox,
      directories: [directory],
      surfacesPerRow: [directory: [surfaceID]],
      hasLoadedTasks: true
    )
    let record = makeRecord(directory: directory, surfaceIDs: [surfaceID])
    state.taskRecords = [record]
    state.taskNow = Self.now
    state.sidebarItems[id: WorktreeID(directory.path(percentEncoded: false))]?.agentSnapshot =
      AgentPresenceFeature.RowSnapshot(
        agents: [AgentPresenceFeature.AgentInstance(agent: .claude, activity: .awaitingInput)]
      )
    state.applyPostReduceCacheRecomputes(.all)
    let store = makeStore(state, sandbox: sandbox)

    await store.send(.tasks(.snooze(record.id, until: Self.now.addingTimeInterval(Self.hour))))
    await store.finish()

    #expect(store.state.taskRecords[id: record.id]?.snoozedUntil == nil)
    #expect(!sandbox.didWriteTasksFile)
  }

  /// The other side of the A18b pair: a working agent is a perfectly good
  /// snooze target (park it, let it wake you), even though it blocks settle.
  @Test func snoozeIsAllowedWhileAnAgentIsWorking() async throws {
    let sandbox = try makeSandbox()
    let directory = try sandbox.makeDirectory("mine", activityAt: Self.freshDate)
    let surfaceID = UUID()
    var state = TaskInboxFixture.makeState(
      sandbox: sandbox,
      directories: [directory],
      surfacesPerRow: [directory: [surfaceID]],
      hasLoadedTasks: true
    )
    let record = makeRecord(directory: directory, surfaceIDs: [surfaceID])
    state.taskRecords = [record]
    state.taskNow = Self.now
    state.sidebarItems[id: WorktreeID(directory.path(percentEncoded: false))]?.agentSnapshot =
      AgentPresenceFeature.RowSnapshot(
        agents: [AgentPresenceFeature.AgentInstance(agent: .claude, activity: .busy)],
        isWorking: true
      )
    state.applyPostReduceCacheRecomputes(.all)
    let store = makeStore(state, sandbox: sandbox)

    await store.send(.tasks(.snooze(record.id, until: Self.now.addingTimeInterval(Self.hour))))
    await store.send(.tasks(.stopTimers))
    await store.finish()

    #expect(store.state.taskRecords[id: record.id]?.snoozedUntil != nil)
  }

  // MARK: - A23 / A24: the two wake clocks

  /// Both clocks are armed by the load that populates the inbox, not by the
  /// first snooze: a relaunch with parked tasks has to re-evaluate them (A23's
  /// "re-evaluated on launch") without waiting for the user to touch anything.
  @Test func loadArmsTheCoarseTickAndWakesExpiredSnoozesImmediately() async throws {
    let sandbox = try makeSandbox()
    let directory = try sandbox.makeDirectory("mine", activityAt: Self.freshDate)
    // Persisted parked, with a wake time that passed while the app was closed.
    let expired = makeRecord(
      directory: directory,
      snoozedUntil: Self.now.addingTimeInterval(-Self.hour),
      snoozedAt: Self.now.addingTimeInterval(-4 * Self.hour)
    )
    try sandbox.save(TaskStoreFile(didSeedTasks: true, tasks: [expired]))
    let state = TaskInboxFixture.makeState(sandbox: sandbox, directories: [directory])
    let clock = TestClock()
    let store = makeStore(state, sandbox: sandbox, clock: clock)

    await store.send(.tasks(.load))
    await store.receive(\.tasks.loaded)
    await store.receive(\.tasks.seedIfNeeded)

    #expect(store.state.tasksSidebarStructure.activeTaskIDs == [expired.id])
    #expect(store.state.tasksSidebarStructure.snoozedTotalCount == 0)
    // A24: never visited since the wake, so the row still owes the user a look.
    #expect(store.state.tasksSidebarStructure.wokeTaskIDs == [expired.id])
    // Nothing is left parked, so there is no boundary to arm.
    #expect(store.state.armedTaskWakeBoundary == nil)

    // The coarse tick keeps running regardless: it is what re-evaluates
    // inactivity auto-settle and long-parked rows.
    await clock.advance(by: .seconds(60))
    await store.receive(\.tasks.classificationTick)

    await store.send(.tasks(.stopTimers))
    await store.finish()
  }

  /// A24's headline: advance past the wake and the row comes back where it was.
  @Test func advancingPastTheBoundaryWakesTheTaskIntoItsStaticPosition() async throws {
    let sandbox = try makeSandbox()
    let older = try sandbox.makeDirectory("older", activityAt: Self.freshDate)
    let newer = try sandbox.makeDirectory("newer", activityAt: Self.freshDate)
    var state = TaskInboxFixture.makeState(
      sandbox: sandbox,
      directories: [older, newer],
      hasLoadedTasks: true
    )
    let parked = makeRecord(directory: older, createdAt: Self.now.addingTimeInterval(-2 * Self.hour))
    let live = makeRecord(directory: newer, createdAt: Self.now.addingTimeInterval(-Self.hour))
    state.taskRecords = [parked, live]
    state.taskNow = Self.now
    state.applyPostReduceCacheRecomputes(.all)
    let clock = TestClock()
    let wake = Self.now.addingTimeInterval(Self.hour)
    let store = makeStore(state, sandbox: sandbox, clock: clock)

    await store.send(.tasks(.snooze(parked.id, until: wake)))
    #expect(store.state.tasksSidebarStructure.activeTaskIDs == [live.id])
    #expect(store.state.armedTaskWakeBoundary == wake)

    // The wall clock has to move too: the boundary effect only *triggers* the
    // re-evaluation, it does not decide the answer.
    store.dependencies.date.now = wake
    // +50ms overshoot (A23), so the effect always lands on the wake side of an
    // inclusive boundary rather than one tick short of it.
    await clock.advance(by: .seconds(Self.hour) + .milliseconds(50))
    await store.receive(\.tasks.wakeBoundaryReached)

    #expect(store.state.tasksSidebarStructure.activeTaskIDs == [live.id, parked.id])
    #expect(store.state.tasksSidebarStructure.snoozedTotalCount == 0)
    #expect(store.state.tasksSidebarStructure.wokeTaskIDs == [parked.id])
    // Waking is classification, not mutation (A25): the record keeps the stamps
    // the user wrote, so a re-snooze never has to ask for the time again.
    #expect(store.state.taskRecords[id: parked.id]?.snoozedUntil == wake)
    #expect(store.state.armedTaskWakeBoundary == nil)

    await store.send(.tasks(.stopTimers))
    await store.finish()
  }

  /// A24: the boundary re-arms when the *earliest* wake changes. Snoozing a
  /// second task to a nearer instant has to pull the alarm in, or the nearer
  /// row waits for the further one's timer.
  @Test func aNearerSnoozeReArmsTheBoundary() async throws {
    let sandbox = try makeSandbox()
    let first = try sandbox.makeDirectory("first", activityAt: Self.freshDate)
    let second = try sandbox.makeDirectory("second", activityAt: Self.freshDate)
    var state = TaskInboxFixture.makeState(
      sandbox: sandbox,
      directories: [first, second],
      hasLoadedTasks: true
    )
    let far = makeRecord(directory: first, createdAt: Self.now.addingTimeInterval(-2 * Self.hour))
    let near = makeRecord(directory: second, createdAt: Self.now.addingTimeInterval(-Self.hour))
    state.taskRecords = [far, near]
    state.taskNow = Self.now
    state.applyPostReduceCacheRecomputes(.all)
    let clock = TestClock()
    let store = makeStore(state, sandbox: sandbox, clock: clock)

    await store.send(.tasks(.snooze(far.id, until: Self.now.addingTimeInterval(4 * Self.hour))))
    #expect(store.state.armedTaskWakeBoundary == Self.now.addingTimeInterval(4 * Self.hour))

    let nearWake = Self.now.addingTimeInterval(Self.hour)
    await store.send(.tasks(.snooze(near.id, until: nearWake)))
    #expect(store.state.armedTaskWakeBoundary == nearWake)

    store.dependencies.date.now = nearWake
    await clock.advance(by: .seconds(Self.hour) + .milliseconds(50))
    await store.receive(\.tasks.wakeBoundaryReached)

    #expect(store.state.tasksSidebarStructure.activeTaskIDs == [near.id])
    #expect(store.state.tasksSidebarStructure.snoozedTotalCount == 1)
    // Re-armed on the survivor, not cancelled.
    #expect(store.state.armedTaskWakeBoundary == Self.now.addingTimeInterval(4 * Self.hour))

    await store.send(.tasks(.stopTimers))
    await store.finish()
  }

  /// A further snooze must NOT push the alarm out: the earliest wake is still
  /// the one that matters.
  @Test func aFurtherSnoozeLeavesTheBoundaryWhereItIs() async throws {
    let sandbox = try makeSandbox()
    let first = try sandbox.makeDirectory("first", activityAt: Self.freshDate)
    let second = try sandbox.makeDirectory("second", activityAt: Self.freshDate)
    var state = TaskInboxFixture.makeState(
      sandbox: sandbox,
      directories: [first, second],
      hasLoadedTasks: true
    )
    let near = makeRecord(directory: first)
    let far = makeRecord(directory: second, createdAt: Self.now.addingTimeInterval(-2 * Self.hour))
    state.taskRecords = [near, far]
    state.taskNow = Self.now
    state.applyPostReduceCacheRecomputes(.all)
    let store = makeStore(state, sandbox: sandbox)
    let nearWake = Self.now.addingTimeInterval(Self.hour)

    await store.send(.tasks(.snooze(near.id, until: nearWake)))
    await store.send(.tasks(.snooze(far.id, until: Self.now.addingTimeInterval(8 * Self.hour))))
    #expect(store.state.armedTaskWakeBoundary == nearWake)

    await store.send(.tasks(.stopTimers))
    await store.finish()
  }

  /// Un-snoozing the earliest row moves the horizon out, which has to re-arm
  /// too — an alarm left on a wake time nobody is waiting for would fire a
  /// pointless recompute and, worse, leave the *real* next wake unarmed.
  @Test func unsnoozingTheEarliestTaskReArmsTheBoundary() async throws {
    let sandbox = try makeSandbox()
    let first = try sandbox.makeDirectory("first", activityAt: Self.freshDate)
    let second = try sandbox.makeDirectory("second", activityAt: Self.freshDate)
    var state = TaskInboxFixture.makeState(
      sandbox: sandbox,
      directories: [first, second],
      hasLoadedTasks: true
    )
    let near = makeRecord(
      directory: first,
      snoozedUntil: Self.now.addingTimeInterval(Self.hour),
      snoozedAt: Self.now
    )
    let far = makeRecord(
      directory: second,
      createdAt: Self.now.addingTimeInterval(-2 * Self.hour),
      snoozedUntil: Self.now.addingTimeInterval(4 * Self.hour),
      snoozedAt: Self.now
    )
    state.taskRecords = [near, far]
    state.taskNow = Self.now
    state.applyPostReduceCacheRecomputes(.all)
    let store = makeStore(state, sandbox: sandbox)

    await store.send(.tasks(.unsnooze(near.id)))
    #expect(store.state.armedTaskWakeBoundary == Self.now.addingTimeInterval(4 * Self.hour))

    await store.send(.tasks(.unsnooze(far.id)))
    #expect(store.state.armedTaskWakeBoundary == nil)

    await store.send(.tasks(.stopTimers))
    await store.finish()
  }

  /// The coarse tick is the safety net: it re-evaluates every parked row on its
  /// own schedule, so a wake that the boundary missed (a re-arm that raced, a
  /// machine that slept through the alarm) is at most one tick late instead of
  /// never.
  @Test func theCoarseTickWakesATaskWhoseBoundaryNeverFired() async throws {
    let sandbox = try makeSandbox()
    let directory = try sandbox.makeDirectory("mine", activityAt: Self.freshDate)
    let parked = makeRecord(
      directory: directory,
      snoozedUntil: Self.now.addingTimeInterval(30),
      snoozedAt: Self.now.addingTimeInterval(-Self.hour)
    )
    try sandbox.save(TaskStoreFile(didSeedTasks: true, tasks: [parked]))
    let state = TaskInboxFixture.makeState(sandbox: sandbox, directories: [directory])
    let clock = TestClock()
    let store = makeStore(state, sandbox: sandbox, clock: clock)

    await store.send(.tasks(.load))
    await store.receive(\.tasks.loaded)
    await store.receive(\.tasks.seedIfNeeded)
    #expect(store.state.tasksSidebarStructure.snoozedTotalCount == 1)

    // Only the wall clock moves past the wake; the tick is what notices.
    store.dependencies.date.now = Self.now.addingTimeInterval(60)
    await clock.advance(by: .seconds(60))
    await store.receive(\.tasks.classificationTick)
    #expect(store.state.tasksSidebarStructure.activeTaskIDs == [parked.id])

    await store.send(.tasks(.stopTimers))
    await store.finish()
  }

  @Test func anInboxWithNothingParkedArmsNoBoundary() async throws {
    let sandbox = try makeSandbox()
    let fixture = try makeSingleTaskState(sandbox: sandbox) { makeRecord(directory: $0) }
    let store = makeStore(fixture.state, sandbox: sandbox)

    await store.send(.tasks(.classificationTick))
    #expect(store.state.armedTaskWakeBoundary == nil)

    await store.send(.tasks(.stopTimers))
    await store.finish()
  }

  /// The Woke pill clears on a visit, and nothing else: it is derived from
  /// `lastVisitedAt` against the wake instant, so no separate acknowledgement
  /// field can drift out of sync with it (A24, A28's "clears on visit").
  @Test func visitingAWokenTaskClearsThePill() async throws {
    let sandbox = try makeSandbox()
    let wake = Self.now.addingTimeInterval(-Self.hour)
    let fixture = try makeSingleTaskState(sandbox: sandbox) {
      makeRecord(directory: $0, snoozedUntil: wake, snoozedAt: Self.staleDate)
    }
    let store = makeStore(fixture.state, sandbox: sandbox)
    #expect(store.state.tasksSidebarStructure.wokeTaskIDs == [fixture.record.id])

    await store.send(.tasks(.select(fixture.record.id)))
    await store.receive(\.selectionChanged)
    await store.send(.tasks(.stopTimers))
    await store.finish()

    #expect(store.state.taskRecords[id: fixture.record.id]?.lastVisitedAt == Self.now)
    #expect(store.state.tasksSidebarStructure.wokeTaskIDs.isEmpty)
  }

  // MARK: - A25: the derived raised hand

  /// No clock advance at all: the presence transition lands, the leaf projects
  /// it, and the recompute reclassifies the row on that same action.
  @Test func anAgentAwaitingInputUnsnoozesWithoutAnyClockAdvance() async throws {
    let sandbox = try makeSandbox()
    let directory = try sandbox.makeDirectory("mine", activityAt: Self.freshDate)
    let surfaceID = UUID()
    var state = TaskInboxFixture.makeState(
      sandbox: sandbox,
      directories: [directory],
      surfacesPerRow: [directory: [surfaceID]],
      hasLoadedTasks: true
    )
    let parked = makeRecord(
      directory: directory,
      surfaceIDs: [surfaceID],
      snoozedUntil: Self.now.addingTimeInterval(4 * Self.hour),
      snoozedAt: Self.now
    )
    state.taskRecords = [parked]
    state.taskNow = Self.now
    state.applyPostReduceCacheRecomputes(.all)
    let store = makeStore(state, sandbox: sandbox)
    #expect(store.state.tasksSidebarStructure.snoozedTotalCount == 1)

    await store.send(
      .tasks(
        .agentSnapshotChanged(
          taskID: parked.id,
          snapshot: AgentPresenceFeature.RowSnapshot(
            agents: [AgentPresenceFeature.AgentInstance(agent: .claude, activity: .awaitingInput)]
          )
        )
      )
    )

    #expect(store.state.tasksSidebarStructure.activeTaskIDs == [parked.id])
    #expect(store.state.tasksSidebarStructure.snoozedTotalCount == 0)
    #expect(store.state.tasksSidebarStructure.wokeTaskIDs == [parked.id])
    // The snooze itself is untouched — classification, never mutation.
    #expect(store.state.taskRecords[id: parked.id]?.snoozedUntil != nil)
    await store.finish()
  }

  /// An error that predates the snooze is exactly what the user was snoozing
  /// away from. It must not bring the row back.
  @Test func aPreSnoozeErrorDoesNotUnsnooze() throws {
    let sandbox = try makeSandbox()
    let directory = try sandbox.makeDirectory("mine", activityAt: Self.freshDate)
    let surfaceID = UUID()
    var state = TaskInboxFixture.makeState(
      sandbox: sandbox,
      directories: [directory],
      surfacesPerRow: [directory: [surfaceID]],
      hasLoadedTasks: true
    )
    let parked = makeRecord(
      directory: directory,
      surfaceIDs: [surfaceID],
      snoozedUntil: Self.now.addingTimeInterval(4 * Self.hour),
      snoozedAt: Self.now
    )
    state.taskRecords = [parked]
    state.taskNow = Self.now
    state.sidebarItems[id: WorktreeID(directory.path(percentEncoded: false))]?.agentSnapshot =
      AgentPresenceFeature.RowSnapshot(
        agents: [AgentPresenceFeature.AgentInstance(agent: .claude, activity: .error)],
        hasError: true,
        errorAt: Self.now.addingTimeInterval(-Self.hour)
      )
    state.applyPostReduceCacheRecomputes(.all)

    #expect(state.taskLeaves[id: parked.id]?.errorAt == Self.now.addingTimeInterval(-Self.hour))
    #expect(state.tasksSidebarStructure.snoozedTotalCount == 1)
  }

  @Test func anErrorRaisedAfterTheSnoozeUnsnoozes() throws {
    let sandbox = try makeSandbox()
    let directory = try sandbox.makeDirectory("mine", activityAt: Self.freshDate)
    let surfaceID = UUID()
    var state = TaskInboxFixture.makeState(
      sandbox: sandbox,
      directories: [directory],
      surfacesPerRow: [directory: [surfaceID]],
      hasLoadedTasks: true
    )
    let parked = makeRecord(
      directory: directory,
      surfaceIDs: [surfaceID],
      snoozedUntil: Self.now.addingTimeInterval(4 * Self.hour),
      snoozedAt: Self.now
    )
    state.taskRecords = [parked]
    state.taskNow = Self.now
    state.sidebarItems[id: WorktreeID(directory.path(percentEncoded: false))]?.agentSnapshot =
      AgentPresenceFeature.RowSnapshot(
        agents: [AgentPresenceFeature.AgentInstance(agent: .claude, activity: .error)],
        hasError: true,
        errorAt: Self.now.addingTimeInterval(60)
      )
    state.applyPostReduceCacheRecomputes(.all)

    #expect(state.tasksSidebarStructure.activeTaskIDs == [parked.id])
  }

  /// Resolved #7: the OSC-notification path is the primary wake trigger, and it
  /// works for a task with no agent hooks at all. The leaf reads the newest
  /// UNREAD notification on the surfaces the task owns, so a notification on a
  /// sibling task's surface in the same directory cannot wake this one.
  @Test func aTerminalNotificationOnAnOwnedSurfaceUnsnoozes() throws {
    let sandbox = try makeSandbox()
    let directory = try sandbox.makeDirectory("mine", activityAt: Self.freshDate)
    let ownedSurface = UUID()
    let otherSurface = UUID()
    var state = TaskInboxFixture.makeState(
      sandbox: sandbox,
      directories: [directory],
      surfacesPerRow: [directory: [ownedSurface, otherSurface]],
      hasLoadedTasks: true
    )
    let parked = makeRecord(
      directory: directory,
      surfaceIDs: [ownedSurface],
      snoozedUntil: Self.now.addingTimeInterval(4 * Self.hour),
      snoozedAt: Self.now
    )
    state.taskRecords = [parked]
    state.taskNow = Self.now
    let rowID = WorktreeID(directory.path(percentEncoded: false))
    state.sidebarItems[id: rowID]?.notifications = [
      WorktreeTerminalNotification(
        surfaceID: otherSurface,
        title: "not mine",
        body: "",
        createdAt: Self.now.addingTimeInterval(120)
      )
    ]
    state.sidebarItems[id: rowID]?.hasUnseenNotifications = true
    state.applyPostReduceCacheRecomputes(.all)
    #expect(state.taskLeaves[id: parked.id]?.notifiedAt == nil)
    #expect(state.tasksSidebarStructure.snoozedTotalCount == 1)

    state.sidebarItems[id: rowID]?.notifications.append(
      WorktreeTerminalNotification(
        surfaceID: ownedSurface,
        title: "build finished",
        body: "",
        createdAt: Self.now.addingTimeInterval(60)
      )
    )
    state.applyPostReduceCacheRecomputes(.all)

    #expect(state.taskLeaves[id: parked.id]?.notifiedAt == Self.now.addingTimeInterval(60))
    #expect(state.tasksSidebarStructure.activeTaskIDs == [parked.id])
  }

  /// A notification the user already read is not news. It must not hold a row
  /// out of the shelf forever.
  @Test func anAlreadyReadNotificationDoesNotUnsnooze() throws {
    let sandbox = try makeSandbox()
    let directory = try sandbox.makeDirectory("mine", activityAt: Self.freshDate)
    let surfaceID = UUID()
    var state = TaskInboxFixture.makeState(
      sandbox: sandbox,
      directories: [directory],
      surfacesPerRow: [directory: [surfaceID]],
      hasLoadedTasks: true
    )
    let parked = makeRecord(
      directory: directory,
      surfaceIDs: [surfaceID],
      snoozedUntil: Self.now.addingTimeInterval(4 * Self.hour),
      snoozedAt: Self.now
    )
    state.taskRecords = [parked]
    state.taskNow = Self.now
    state.sidebarItems[id: WorktreeID(directory.path(percentEncoded: false))]?.notifications = [
      WorktreeTerminalNotification(
        surfaceID: surfaceID,
        title: "seen it",
        body: "",
        createdAt: Self.now.addingTimeInterval(60),
        isRead: true
      )
    ]
    state.applyPostReduceCacheRecomputes(.all)

    #expect(state.taskLeaves[id: parked.id]?.notifiedAt == nil)
    #expect(state.tasksSidebarStructure.snoozedTotalCount == 1)
  }

  /// A task with no owned surfaces inherits no signals at all — the leaf's
  /// existing rule (`surfaceIDs.isEmpty` projects nothing), applied to the new
  /// timestamps so a directory-mate's error cannot wake an unowned task.
  @Test func aTaskWithNoOwnedSurfacesInheritsNoSignals() throws {
    let sandbox = try makeSandbox()
    let directory = try sandbox.makeDirectory("mine", activityAt: Self.freshDate)
    let surfaceID = UUID()
    var state = TaskInboxFixture.makeState(
      sandbox: sandbox,
      directories: [directory],
      surfacesPerRow: [directory: [surfaceID]],
      hasLoadedTasks: true
    )
    let parked = makeRecord(
      directory: directory,
      snoozedUntil: Self.now.addingTimeInterval(4 * Self.hour),
      snoozedAt: Self.now
    )
    state.taskRecords = [parked]
    state.taskNow = Self.now
    state.sidebarItems[id: WorktreeID(directory.path(percentEncoded: false))]?.agentSnapshot =
      AgentPresenceFeature.RowSnapshot(
        agents: [AgentPresenceFeature.AgentInstance(agent: .claude, activity: .awaitingInput)]
      )
    state.applyPostReduceCacheRecomputes(.all)

    #expect(state.tasksSidebarStructure.snoozedTotalCount == 1)
  }

  // MARK: - A26: forward navigation

  /// Settling the row you are looking at moves you to the next one you can
  /// actually work on — the plan is computed over the VISIBLE order, before the
  /// mutation, so the answer is the row the user could see below the one they
  /// just cleared.
  @Test func settlingTheOpenTaskAdvancesToTheNextVisibleRow() async throws {
    let sandbox = try makeSandbox()
    let first = try sandbox.makeDirectory("first", activityAt: Self.freshDate)
    let second = try sandbox.makeDirectory("second", activityAt: Self.freshDate)
    var state = TaskInboxFixture.makeState(
      sandbox: sandbox,
      directories: [first, second],
      hasLoadedTasks: true
    )
    let open = makeRecord(directory: first, createdAt: Self.now.addingTimeInterval(-Self.hour))
    let next = makeRecord(directory: second, createdAt: Self.now.addingTimeInterval(-2 * Self.hour))
    state.taskRecords = [open, next]
    state.taskNow = Self.now
    state.selection = .task(open.id)
    state.applyPostReduceCacheRecomputes(.all)
    let store = makeStore(state, sandbox: sandbox)
    #expect(store.state.tasksSidebarStructure.visibleTaskIDs == [open.id, next.id])

    await store.send(.tasks(.settle(open.id)))
    await store.receive(\.tasks.select)
    await store.receive(\.selectionChanged)
    await store.send(.tasks(.stopTimers))
    await store.finish()

    #expect(store.state.selection == .task(next.id))
  }

  @Test func snoozingTheOpenTaskAdvancesToTheNextVisibleRow() async throws {
    let sandbox = try makeSandbox()
    let first = try sandbox.makeDirectory("first", activityAt: Self.freshDate)
    let second = try sandbox.makeDirectory("second", activityAt: Self.freshDate)
    var state = TaskInboxFixture.makeState(
      sandbox: sandbox,
      directories: [first, second],
      hasLoadedTasks: true
    )
    let open = makeRecord(directory: first, createdAt: Self.now.addingTimeInterval(-Self.hour))
    let next = makeRecord(directory: second, createdAt: Self.now.addingTimeInterval(-2 * Self.hour))
    state.taskRecords = [open, next]
    state.taskNow = Self.now
    state.selection = .task(open.id)
    state.applyPostReduceCacheRecomputes(.all)
    let store = makeStore(state, sandbox: sandbox)

    await store.send(.tasks(.snooze(open.id, until: Self.now.addingTimeInterval(Self.hour))))
    await store.receive(\.tasks.select)
    await store.receive(\.selectionChanged)
    await store.send(.tasks(.stopTimers))
    await store.finish()

    #expect(store.state.selection == .task(next.id))
  }

  /// Settling something in the background is bookkeeping, not navigation: it
  /// must never yank the user off the row they are working in.
  @Test func settlingABackgroundTaskDoesNotNavigate() async throws {
    let sandbox = try makeSandbox()
    let first = try sandbox.makeDirectory("first", activityAt: Self.freshDate)
    let second = try sandbox.makeDirectory("second", activityAt: Self.freshDate)
    var state = TaskInboxFixture.makeState(
      sandbox: sandbox,
      directories: [first, second],
      hasLoadedTasks: true
    )
    let open = makeRecord(directory: first, createdAt: Self.now.addingTimeInterval(-Self.hour))
    let background = makeRecord(
      directory: second,
      createdAt: Self.now.addingTimeInterval(-2 * Self.hour)
    )
    state.taskRecords = [open, background]
    state.taskNow = Self.now
    state.selection = .task(open.id)
    state.applyPostReduceCacheRecomputes(.all)
    let store = makeStore(state, sandbox: sandbox)

    await store.send(.tasks(.settle(background.id)))
    await store.send(.tasks(.stopTimers))
    await store.finish()

    #expect(store.state.selection == .task(open.id))
  }

  /// A26: a mutation that was refused never navigates. The affordance guard and
  /// the navigation share one exit — the arm returns before either happens.
  @Test func aRefusedSettleDoesNotNavigate() async throws {
    let sandbox = try makeSandbox()
    let first = try sandbox.makeDirectory("first", activityAt: Self.freshDate)
    let second = try sandbox.makeDirectory("second", activityAt: Self.freshDate)
    let surfaceID = UUID()
    var state = TaskInboxFixture.makeState(
      sandbox: sandbox,
      directories: [first, second],
      surfacesPerRow: [first: [surfaceID]],
      hasLoadedTasks: true
    )
    let open = makeRecord(
      directory: first,
      surfaceIDs: [surfaceID],
      createdAt: Self.now.addingTimeInterval(-Self.hour)
    )
    let next = makeRecord(directory: second, createdAt: Self.now.addingTimeInterval(-2 * Self.hour))
    state.taskRecords = [open, next]
    state.taskNow = Self.now
    state.selection = .task(open.id)
    state.sidebarItems[id: WorktreeID(first.path(percentEncoded: false))]?.agentSnapshot =
      AgentPresenceFeature.RowSnapshot(
        agents: [AgentPresenceFeature.AgentInstance(agent: .claude, activity: .awaitingInput)]
      )
    state.applyPostReduceCacheRecomputes(.all)
    let store = makeStore(state, sandbox: sandbox)

    await store.send(.tasks(.settle(open.id)))
    await store.finish()

    #expect(store.state.selection == .task(open.id))
    #expect(store.state.taskRecords[id: open.id]?.settledAt == nil)
  }

  /// The supacode call on t3's "navigate home" fallback (A26): there is no
  /// home, so the selection stays on the row that was just settled — which A8
  /// keeps visible in the collapsed tail.
  @Test func noNextTaskLeavesTheSelectionOnTheJustSettledRow() async throws {
    let sandbox = try makeSandbox()
    let fixture = try makeSingleTaskState(sandbox: sandbox) { makeRecord(directory: $0) }
    var state = fixture.state
    state.selection = .task(fixture.record.id)
    state.applyPostReduceCacheRecomputes(.all)
    let store = makeStore(state, sandbox: sandbox)

    await store.send(.tasks(.settle(fixture.record.id)))
    await store.send(.tasks(.stopTimers))
    await store.finish()

    #expect(store.state.selection == .task(fixture.record.id))
    // A8: still on screen, in a shelf that is otherwise collapsed.
    #expect(!store.state.isSettledTailExpanded)
    #expect(store.state.tasksSidebarStructure.visibleTaskIDs == [fixture.record.id])
  }

  /// Forward navigation lands on a row the user can work on: settled and
  /// snoozed rows are skipped even though they are visible.
  @Test func forwardNavigationSkipsSettledAndSnoozedRows() async throws {
    let sandbox = try makeSandbox()
    let openDir = try sandbox.makeDirectory("open", activityAt: Self.freshDate)
    let parkedDir = try sandbox.makeDirectory("parked", activityAt: Self.freshDate)
    let doneDir = try sandbox.makeDirectory("done", activityAt: Self.freshDate)
    let liveDir = try sandbox.makeDirectory("live", activityAt: Self.freshDate)
    var state = TaskInboxFixture.makeState(
      sandbox: sandbox,
      directories: [openDir, parkedDir, doneDir, liveDir],
      hasLoadedTasks: true
    )
    let open = makeRecord(directory: openDir, createdAt: Self.now.addingTimeInterval(-Self.hour))
    let parked = makeRecord(
      directory: parkedDir,
      createdAt: Self.now.addingTimeInterval(-2 * Self.hour),
      snoozedUntil: Self.now.addingTimeInterval(4 * Self.hour),
      snoozedAt: Self.now
    )
    let done = makeRecord(
      directory: doneDir,
      createdAt: Self.now.addingTimeInterval(-3 * Self.hour),
      settledAt: Self.staleDate
    )
    let live = makeRecord(directory: liveDir, createdAt: Self.now.addingTimeInterval(-4 * Self.hour))
    state.taskRecords = [open, parked, done, live]
    state.taskNow = Self.now
    state.selection = .task(open.id)
    state.isSettledTailExpanded = true
    state.isSnoozedShelfExpanded = true
    state.applyPostReduceCacheRecomputes(.all)
    let store = makeStore(state, sandbox: sandbox)
    #expect(
      store.state.tasksSidebarStructure.visibleTaskIDs == [open.id, live.id, parked.id, done.id]
    )

    await store.send(.tasks(.settle(open.id)))
    await store.receive(\.tasks.select)
    await store.receive(\.selectionChanged)
    await store.send(.tasks(.stopTimers))
    await store.finish()

    #expect(store.state.selection == .task(live.id))
  }

  // MARK: - Shelf paging

  @Test func togglingTheSnoozedShelfChangesOnlyItsVisibility() async throws {
    let sandbox = try makeSandbox()
    let fixture = try makeSingleTaskState(sandbox: sandbox) {
      makeRecord(
        directory: $0,
        snoozedUntil: Self.now.addingTimeInterval(Self.hour),
        snoozedAt: Self.now
      )
    }
    let store = makeStore(fixture.state, sandbox: sandbox)
    #expect(!store.state.isSnoozedShelfExpanded)
    #expect(store.state.tasksSidebarStructure.visibleSnoozedEntries.isEmpty)

    await store.send(.tasks(.setSnoozedShelfExpanded(true)))
    #expect(
      store.state.tasksSidebarStructure.visibleSnoozedEntries.map(\.id) == [fixture.record.id]
    )
    // Presentation only: no record was touched, so nothing was written.
    #expect(!sandbox.didWriteTasksFile)

    await store.send(.tasks(.setSnoozedShelfExpanded(false)))
    #expect(store.state.tasksSidebarStructure.visibleSnoozedEntries.isEmpty)

    await store.send(.tasks(.stopTimers))
    await store.finish()
  }
}

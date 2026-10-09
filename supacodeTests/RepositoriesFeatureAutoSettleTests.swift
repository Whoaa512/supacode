import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import Sharing
import Testing

@testable import SupacodeSettingsShared
@testable import supacode

@MainActor
struct RepositoriesFeatureAutoSettleTests {
  private let now = Date(timeIntervalSince1970: 1_000_000)

  private func summary(_ id: String = "old", count: Int = 5) -> SessionSummary {
    SessionSummary(
      harness: .pi, sessionID: id, createdAt: now.addingTimeInterval(-4 * 86_400),
      cwd: "/fixture", title: id, messageCount: count,
      lastActivity: now.addingTimeInterval(-3 * 86_400))
  }

  private func state() -> RepositoriesFeature.State {
    var state = RepositoriesFeature.State()
    state.$sessions = Shared(value: [:])
    state.$sidebar = Shared(value: SidebarState())
    state.$persistedLayouts = SharedReader(value: TaskLayoutsFile())
    state.sessionsStarted = true
    return state
  }

  private func store() -> TestStoreOf<RepositoriesFeature> {
    let store = TestStore(initialState: state()) {
      RepositoriesFeature()
    } withDependencies: {
      $0.date.now = now
      $0.continuousClock = TestClock()
      $0.defaultAppStorage = .inMemory
    }
    store.exhaustivity = .off
    return store
  }

  @Test(.dependencies) func unrelatedActionsDoNotReadTheSessionClock() async {
    let store = TestStore(initialState: state()) { RepositoriesFeature() }
    await store.send(.sessionsLiveKeysChanged([]))
    await store.send(.sessionsStopped)
    await store.finish()
  }

  @Test(.dependencies) func restoreGateAndRawLiveKeysProtectUnlinkedAgents() async {
    let row = summary()
    let store = store()
    await store.send(.sessionsCacheLoaded([row]))
    #expect(store.state.sessions[row.id] == nil)
    await store.send(.sessionsRefreshCompleted([row]))
    #expect(store.state.sessions[row.id] == nil)
    await store.send(.sessionsRestorationCompleted([row.id]))
    #expect(store.state.sessions[row.id] == nil)
    await store.send(.sessionsLiveKeysChanged([]))
    await store.send(.sessionsRefreshCompleted([row]))
    #expect(store.state.sessions[row.id]?.settledAt == now)
    #expect(store.state.sessionItems[id: .session(row.id)]?.lifecycle == .settled)
    await store.finish()
  }

  @Test(.dependencies) func failedRefreshCannotReleaseRestoreGateOrSettle() async {
    let row = summary()
    let store = store()
    await store.send(.sessionsCacheLoaded([row]))
    await store.send(.sessionsRefreshCompleted([row]))
    await store.send(.sessionsRefreshFailed)
    await store.send(.sessionsRestorationCompleted([]))
    #expect(store.state.sessions[row.id] == nil)
    #expect(store.state.sessionItems.count == 1)
    await store.send(.sessionsRefreshCompleted([row]))
    #expect(store.state.sessions[row.id]?.settledAt == now)
    await store.finish()
  }

  @Test(.dependencies) func manualHoldPersistsUntilNewMessageActivityNotRename() async {
    var row = summary(count: 3)
    let store = store()
    await store.send(.sessionsCacheLoaded([row]))
    await store.send(.unsettleSession(row.id))
    await store.send(.sessionsRestorationCompleted([]))
    row.title = "Renamed"
    await store.send(.sessionsRefreshCompleted([row]))
    #expect(store.state.sessions[row.id]?.manualUnsettledAtActivity == row.lastActivity)
    #expect(store.state.sessions[row.id]?.settledAt == nil)
    row.lastActivity = now.addingTimeInterval(-7_200)
    await store.send(.sessionsRefreshCompleted([row]))
    #expect(store.state.sessions[row.id]?.manualUnsettledAtActivity == nil)
    #expect(store.state.sessions[row.id]?.settledAt == now)
    await store.finish()
  }

  @Test(.dependencies) func provisionalAndUnknownSummariesNeverAutoSettle() async {
    let row = summary()
    let store = store()
    let surface = UUID()
    let snapshot = SessionLiveSnapshot(
      harness: .pi, sessionRef: nil, cwd: "/fixture",
      location: SessionLocation(
        layoutID: "/fixture", directoryID: "/fixture", tabID: TabID(rawValue: surface), surfaceID: surface))
    await store.send(.sessionSnapshotsChanged([snapshot]))
    await store.receive(\.sessionsRefreshRequested)
    await store.send(.sessionsRestorationCompleted([]))
    await store.send(.sessionsRefreshCompleted([row]))
    #expect(store.state.sessions.isEmpty)
    await store.send(.sessionsStopped)
    await store.finish()
  }

  @Test(.dependencies) func provisionalInDirABlocksOldDirAButOldDirBSettles() async {
    let rowA = summary("session-a")
    var rowB = summary("session-b")
    rowB.cwd = "/other"
    let store = store()
    let surface = UUID()
    let snapshot = SessionLiveSnapshot(
      harness: .pi, sessionRef: nil, cwd: "/fixture",
      location: SessionLocation(
        layoutID: "/fixture", directoryID: "/fixture", tabID: TabID(rawValue: surface), surfaceID: surface))
    await store.send(.sessionSnapshotsChanged([snapshot]))
    await store.receive(\.sessionsRefreshRequested)
    await store.send(.sessionsRestorationCompleted([]))
    await store.send(.sessionsRefreshCompleted([rowA, rowB]))
    #expect(store.state.sessions[rowA.id] == nil, "dir-a blocked by provisional")
    #expect(store.state.sessions[rowB.id]?.settledAt == now, "dir-b settles independently")
    await store.send(.sessionsStopped)
    await store.finish()
  }

  @Test(.dependencies) func turnActivityClearsHoldOnlyWhenNewerAndNeverUnsettles() async {
    let row = summary()
    let store = store()
    await store.send(.sessionsCacheLoaded([row]))
    await store.send(.unsettleSession(row.id))
    await store.send(.sessionActivityObserved(row.id, row.lastActivity))
    #expect(store.state.sessions[row.id]?.manualUnsettledAtActivity == row.lastActivity)
    await store.send(.sessionActivityObserved(row.id, now))
    #expect(store.state.sessions[row.id]?.manualUnsettledAtActivity == nil)
    await store.send(.settleSession(row.id))
    await store.send(.sessionActivityObserved(row.id, now.addingTimeInterval(1)))
    #expect(store.state.sessions[row.id]?.settledAt == now)
    await store.finish()
  }

  @Test(.dependencies) func zeroDisablesBothIdleAndShortSessionRules() async {
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global.sessionIdleDays = 0 }
    let row = summary(count: 0)
    let store = store()
    await store.send(.sessionsRestorationCompleted([]))
    await store.send(.sessionsRefreshCompleted([row]))
    #expect(store.state.sessions[row.id] == nil)
    await store.finish()
  }

  @Test(.dependencies) func unverifiedSummaryFromFailedReadDoesNotAutoSettle() async {
    var row = summary()
    row.isVerified = false
    let store = store()
    await store.send(.sessionsRestorationCompleted([]))
    await store.send(.sessionsRefreshCompleted([row]))
    #expect(store.state.sessions[row.id] == nil, "unverified stale summary must not auto-settle")
    row.isVerified = true
    await store.send(.sessionsRefreshCompleted([row]))
    #expect(store.state.sessions[row.id]?.settledAt == now, "verified summary settles after 3 idle days")
    await store.finish()
  }

  @Test(.dependencies) func tempFixtureDrivesUnverifiedRetentionThenVerifiedSettlement() async throws {
    let base = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let root = base.appending(path: "sessions")
    let dir = root.appending(path: "project")
    let cacheURL = base.appending(path: "state/index.json")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }

    let hdr =
      "{\"type\":\"session\",\"id\":\"abcfix\","
      + "\"timestamp\":\"2026-01-01T00:00:00.000Z\",\"cwd\":\"/fixtures\"}"
    let msg =
      "{\"type\":\"message\",\"timestamp\":\"2026-01-02T00:00:00.000Z\","
      + "\"message\":{\"role\":\"user\",\"content\":\"hello\"}}"
    let content = hdr + "\n" + String(repeating: msg + "\n", count: 5)
    let file = dir.appending(path: "one.jsonl")
    try Data(content.utf8).write(to: file)

    let testNow = ISO8601DateFormatter().date(from: "2026-01-06T00:00:00Z")!
    let source = PiSessionSource(root: root, cacheURL: cacheURL)

    // First sessions() → verified; populates internal cache
    let baseline = try await source.sessions()
    #expect(baseline.count == 1)
    #expect(baseline.first?.isVerified == true)

    // Mutate file then chmod0 → source cannot re-parse; returns stale unverified entry
    try Data((content + msg + "\n").utf8).write(to: file)
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }
    let staleSummaries = try await source.sessions()
    #expect(staleSummaries.count == 1)
    #expect(staleSummaries.first?.isVerified == false)

    var initial = RepositoriesFeature.State()
    initial.$sessions = Shared(value: [:])
    initial.$sidebar = Shared(value: SidebarState())
    initial.$persistedLayouts = SharedReader(value: TaskLayoutsFile())
    initial.sessionsStarted = true
    let testStore = TestStore(initialState: initial) {
      RepositoriesFeature()
    } withDependencies: {
      $0.date.now = testNow
      $0.continuousClock = TestClock()
      $0.defaultAppStorage = .inMemory
    }
    testStore.exhaustivity = .off

    // Open restore gate then send unverified summaries → row visible, not settled
    let key = staleSummaries[0].id
    await testStore.send(.sessionsRestorationCompleted([]))
    await testStore.send(.sessionsRefreshCompleted(staleSummaries))
    #expect(testStore.state.sessions[key] == nil, "unverified must not auto-settle")
    #expect(testStore.state.sessionItems.count == 1, "row retained in sidebar")

    // Restore readability → sessions() re-parses → verified
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    let recovered = try await source.sessions()
    #expect(recovered.first?.isVerified == true)

    // Send verified summaries → reducer settles
    await testStore.send(.sessionsRefreshCompleted(recovered))
    #expect(testStore.state.sessions[key]?.settledAt == testNow, "verified summary settles")
    await testStore.finish()
  }

  @Test(.dependencies)
  func twoMessageSessionWithRecentActivityIsNotAutoSettledAfterReload() async {
    var row = summary(count: 2)
    row.lastActivity = now.addingTimeInterval(-1_800)
    let store = store()
    await store.send(.sessionsRestorationCompleted([]))
    await store.send(.sessionsRefreshCompleted([row]))
    #expect(store.state.sessions[row.id] == nil)
    await store.finish()
  }

  @Test(.dependencies, arguments: [false, true])
  func coarseClockRefreshesAtFifteenMinutesAndCancels(failSecondRefresh: Bool) async {
    enum Failure: Error { case unavailable }
    let clock = TestClock()
    let calls = LockIsolated(0)
    var initial = state()
    initial.sessionsStarted = false
    initial.sessionsRestorationFinished = true
    var row = summary()
    row.lastActivity = now.addingTimeInterval(-3 * 86_400 + 900)
    let indexed = row
    let time = LockIsolated(now)
    let store = TestStore(initialState: initial) {
      RepositoriesFeature()
    } withDependencies: {
      $0.date = DateGenerator { time.value }
      $0.continuousClock = clock
      $0.defaultAppStorage = .inMemory
      $0.sessionIndex.cached = { [] }
      $0.sessionIndex.refresh = {
        let count = calls.withValue {
          $0 += 1
          return $0
        }
        if failSecondRefresh, count == 2 { throw Failure.unavailable }
        return [indexed]
      }
    }
    store.exhaustivity = .off
    await store.send(.sessionsStarted)
    await store.receive(\.sessionsCacheLoaded)
    await store.receive(\.sessionsRefreshCompleted)
    #expect(store.state.sessions[row.id] == nil)
    await clock.advance(by: .seconds(899))
    #expect(calls.value == 1)
    time.withValue { $0 = now.addingTimeInterval(900) }
    await clock.advance(by: .seconds(1))
    await store.receive(\.sessionsCoarseClockFired)
    await store.receive(\.sessionsRefreshRequested)
    await clock.advance(by: .milliseconds(500))
    await store.receive(\.sessionsRefreshDebounced)
    if failSecondRefresh {
      await store.receive(\.sessionsRefreshFailed)
      #expect(store.state.sessions[row.id] == nil)
      await store.send(.sessionsRefreshRequested)
      await clock.advance(by: .milliseconds(500))
      await store.receive(\.sessionsRefreshDebounced)
    }
    await store.receive(\.sessionsRefreshCompleted)
    let expectedCalls = failSecondRefresh ? 3 : 2
    #expect(calls.value == expectedCalls)
    #expect(store.state.sessions[row.id]?.settledAt == time.value)
    await store.send(.sessionsStopped)
    await clock.advance(by: .seconds(1800))
    #expect(calls.value == expectedCalls)
    await store.finish()
  }

  // MARK: - A task is judged as a whole

  private let task = LayoutID(task: UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!)

  private func liveAgent(ref: String?, in layoutID: LayoutID) -> SessionLiveSnapshot {
    let surface = UUID()
    return SessionLiveSnapshot(
      harness: .pi, sessionRef: ref, cwd: "/elsewhere",
      location: SessionLocation(
        layoutID: layoutID, directoryID: "/elsewhere", tabID: TabID(rawValue: surface), surfaceID: surface))
  }

  /// Runs a refresh over `rows` with the given task membership and live agents.
  private func sidecarAfterRefresh(
    _ rows: [SessionSummary], taskSessions: [LayoutID: [SessionKey]], live: [SessionLiveSnapshot] = [],
    open: [LayoutID] = [], sidecar: SessionSidecar = [:]
  ) async -> [SessionKey: SessionSidecarEntry] {
    let store = store()
    store.state.$sessions.withLock { $0 = sidecar }
    await store.send(.sessionsCacheLoaded(rows))
    await store.send(.taskSessionsChanged(taskSessions))
    await store.send(.taskSnapshotsChanged(open.map(openTab)))
    await store.send(.sessionSnapshotsChanged(live))
    let liveKeys = Set(live.compactMap { $0.sessionRef.map { SessionKey(harness: .pi, sessionID: $0) } })
    await store.send(.sessionsRestorationCompleted(liveKeys))
    await store.send(.sessionsRefreshCompleted(rows))
    await store.skipInFlightEffects(strict: false)
    return store.state.sessions
  }

  /// A task with a tab open, whatever runs in it.
  private func openTab(in layoutID: LayoutID) -> TaskLiveSnapshot {
    let surface = UUID()
    return TaskLiveSnapshot(
      title: "task", cwd: "/elsewhere", createdAt: nil,
      location: SessionLocation(
        layoutID: layoutID, directoryID: "/elsewhere", tabID: TabID(rawValue: surface), surfaceID: surface))
  }

  /// Auto-settle closes nothing, so a task that still shows a tab (a shell,
  /// or an agent's tab after the agent ended) is left alone however idle.
  @Test(.dependencies, arguments: [1, 2])
  func aTaskWithATabStillOpenIsNotAutoSettled(sessions: Int) async {
    let rows = [summary("primary"), summary("tangent")].prefix(sessions) + [summary("x")]
    let members = rows.dropLast().map(\.id)

    let open = await sidecarAfterRefresh(Array(rows), taskSessions: [task: members], open: [task])
    for member in members { #expect(open[member] == nil) }
    #expect(open[summary("x").id]?.settledAt == now, "settlement ran; only the task was held back")

    // With its last tab closed the same task settles, by mark alone.
    let closed = await sidecarAfterRefresh(Array(rows), taskSessions: [task: members])
    for member in members { #expect(closed[member]?.settledAt == now) }
  }

  @Test(.dependencies) func anotherTasksOpenTabHoldsNothingBack() async {
    let primary = summary("primary")

    let sidecar = await sidecarAfterRefresh(
      [primary], taskSessions: [task: [primary.id]], open: [LayoutID(task: UUID())])

    #expect(sidecar[primary.id]?.settledAt == now)
  }

  @Test(.dependencies) func idleMembersDoNotAutoSettleWhileATangentOfTheirTaskIsLive() async {
    let (primary, idle, tangent, unrelated) = (summary("primary"), summary("idle"), summary("tangent"), summary("x"))

    let sidecar = await sidecarAfterRefresh(
      [primary, idle, tangent, unrelated],
      taskSessions: [task: [primary.id, idle.id, tangent.id]],
      live: [liveAgent(ref: "tangent", in: task)])

    #expect(sidecar[primary.id] == nil)
    #expect(sidecar[idle.id] == nil)
    #expect(sidecar[tangent.id] == nil)
    #expect(sidecar[unrelated.id]?.settledAt == now, "settlement ran; only the task was held back")
  }

  @Test(.dependencies) func anAgentThatHasNotReportedItsSessionHoldsItsTaskToo() async {
    let (primary, unrelated) = (summary("primary"), summary("x"))

    let sidecar = await sidecarAfterRefresh(
      [primary, unrelated], taskSessions: [task: [primary.id]], live: [liveAgent(ref: nil, in: task)])

    #expect(sidecar[primary.id] == nil, "the agent runs in another directory, so only its task protects it")
    #expect(sidecar[unrelated.id]?.settledAt == now)
  }

  @Test(.dependencies) func aTaskIsOnlyAsIdleAsItsMostRecentlyActiveMember() async {
    let primary = summary("primary")
    var tangent = summary("tangent")
    tangent.lastActivity = now.addingTimeInterval(-60)

    let recent = await sidecarAfterRefresh([primary, tangent], taskSessions: [task: [primary.id, tangent.id]])
    #expect(recent[primary.id] == nil)
    #expect(recent[tangent.id] == nil)

    // Without the task the primary is old enough on its own.
    let alone = await sidecarAfterRefresh([primary, tangent], taskSessions: [:])
    #expect(alone[primary.id]?.settledAt == now)
    #expect(alone[tangent.id] == nil)
  }

  @Test(.dependencies) func aTaskWhoseMembersAreAllIdleSettlesThemAll() async {
    let (primary, tangent) = (summary("primary"), summary("tangent"))

    let sidecar = await sidecarAfterRefresh([primary, tangent], taskSessions: [task: [primary.id, tangent.id]])

    #expect(sidecar[primary.id]?.settledAt == now)
    #expect(sidecar[tangent.id]?.settledAt == now)
  }

  private func summary(_ id: String, count: Int, idle: TimeInterval) -> SessionSummary {
    var summary = summary(id, count: count)
    summary.lastActivity = now.addingTimeInterval(-idle)
    return summary
  }

  /// The short-session rule is the task's too: a primary of one message
  /// does not settle a task whose tangent did the work.
  @Test(.dependencies) func aShortPrimaryDoesNotSettleATaskWithASubstantiveTangent() async {
    let primary = summary("primary", count: 1, idle: 2 * 3_600)
    let tangent = summary("tangent", count: 100, idle: 2 * 3_600)

    let together = await sidecarAfterRefresh([primary, tangent], taskSessions: [task: [primary.id, tangent.id]])
    #expect(together[primary.id] == nil, "the task is settled exactly when its primary is")
    #expect(together[tangent.id] == nil)

    // Whichever of the two leads.
    let swapped = await sidecarAfterRefresh([primary, tangent], taskSessions: [task: [tangent.id, primary.id]])
    #expect(swapped[primary.id] == nil)
    #expect(swapped[tangent.id] == nil)

    // On its own the primary is short enough to go after an hour.
    let alone = await sidecarAfterRefresh([primary, tangent], taskSessions: [:])
    #expect(alone[primary.id]?.settledAt == now)
    #expect(alone[tangent.id] == nil)
  }

  @Test(.dependencies, arguments: [[1, 2], [2, 2]])
  func aTaskIsShortOnlyWhenAllItsSessionsTogetherAre(counts: [Int]) async {
    let primary = summary("primary", count: counts[0], idle: 2 * 3_600)
    let tangent = summary("tangent", count: counts[1], idle: 2 * 3_600)
    let isShort = counts.reduce(0, +) < 4

    let sidecar = await sidecarAfterRefresh([primary, tangent], taskSessions: [task: [primary.id, tangent.id]])

    #expect(sidecar[primary.id]?.settledAt == (isShort ? now : nil))
    #expect(sidecar[tangent.id]?.settledAt == (isShort ? now : nil))
  }

  /// A session the user unsettled holds until it has new activity of its
  /// own; another member's newer activity must not lift that.
  @Test(.dependencies, arguments: ["primary", "tangent"])
  func aMemberTheUserUnsettledHoldsItsWholeTask(held: String) async {
    let primary = summary("primary", count: 5, idle: 5 * 86_400)
    let tangent = summary("tangent", count: 5, idle: 4 * 86_400)
    let heldRow = held == "primary" ? primary : tangent
    let hold = SessionSidecarEntry(manualUnsettledAtActivity: heldRow.lastActivity)

    let sidecar = await sidecarAfterRefresh(
      [primary, tangent], taskSessions: [task: [primary.id, tangent.id]], sidecar: [heldRow.id: hold])

    #expect(sidecar[primary.id]?.settledAt == nil)
    #expect(sidecar[tangent.id]?.settledAt == nil)
    #expect(sidecar[heldRow.id]?.manualUnsettledAtActivity == heldRow.lastActivity, "still held")
  }

  /// A member whose activity was not read this refresh may be the task's
  /// newest, so nothing in the task settles until it is read.
  @Test(.dependencies, arguments: [false, true])
  func anUnreadMemberHoldsItsWholeTaskUntilItIsRead(tangentLeads: Bool) async {
    let (primary, unrelated) = (summary("primary"), summary("x"))
    var tangent = summary("tangent")
    tangent.isVerified = false
    let members = tangentLeads ? [tangent.id, primary.id] : [primary.id, tangent.id]
    let store = store()
    await store.send(.taskSessionsChanged([task: members]))
    await store.send(.sessionsRestorationCompleted([]))

    await store.send(.sessionsRefreshCompleted([primary, tangent, unrelated]))
    #expect(store.state.sessions[primary.id] == nil, "the unread tangent may be newer")
    #expect(store.state.sessions[tangent.id] == nil)
    #expect(store.state.sessions[unrelated.id]?.settledAt == now, "only the task was held back")

    tangent.isVerified = true
    await store.send(.sessionsRefreshCompleted([primary, tangent, unrelated]))
    #expect(store.state.sessions[primary.id]?.settledAt == now)
    #expect(store.state.sessions[tangent.id]?.settledAt == now)
    await store.skipInFlightEffects(strict: false)
  }

  /// A member the refresh lists nothing for is unread too: a file that
  /// could not be parsed is left out the same way one that is gone is.
  @Test(.dependencies, arguments: [false, true])
  func aMemberMissingFromTheSummariesHoldsItsWholeTask(missingLeads: Bool) async {
    let (primary, tangent) = (summary("primary"), summary("tangent"))
    let missing = SessionKey(harness: .pi, sessionID: "missing")
    let members = missingLeads ? [missing, primary.id, tangent.id] : [primary.id, tangent.id, missing]

    let partial = await sidecarAfterRefresh([primary, tangent], taskSessions: [task: members])
    #expect(partial[primary.id] == nil)
    #expect(partial[tangent.id] == nil)

    // A task of one session has no other member to wait for.
    let alone = await sidecarAfterRefresh([primary], taskSessions: [task: [primary.id]])
    #expect(alone[primary.id]?.settledAt == now)
  }
}

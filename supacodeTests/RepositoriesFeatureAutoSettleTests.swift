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
}

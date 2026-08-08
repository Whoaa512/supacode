import ComposableArchitecture
import Dependencies
import DependenciesTestSupport
import Foundation
import IdentifiedCollections
import Sharing
import Testing

@testable import SupacodeSettingsShared
@testable import supacode

/// RED half of Phase 5: the signals a task row reports and the settings that
/// decide what they mean — plan assertions A15, A27, A28, A29, A29b, A30 and
/// Resolved #4/#5.
///
/// Every PR assertion here is driven from the *actual* writer: the batch result
/// action the repository refresh dispatches, through the row reducer that
/// already owns the stale-branch guard, into the task leaf. Nothing hand-builds
/// a `TaskPullRequestState` — a projection asserted from a literal proves only
/// that the literal was copied, and three of Phase 4's four defects lived in
/// exactly that seam.
///
/// The API this file specifies (none of it exists yet):
/// - `TaskLeafState.pullRequest: TaskPullRequestState`, `.pullRequestChangedAt`,
///   `.lastActivityAt`, `.isDoneUnread`, `.isWoke`, `.status`, `.needsHuman`,
///   `.isReceded`.
/// - `TasksSidebarStructure.Signals` gains `pullRequest`, `lastActivityAt`,
///   `pullRequestChangedAt`, and `compute` gains `policy:`.
/// - `TaskSettlement.Policy` + `TaskSettlement.Input.settledAt`.
/// - `@Shared(.taskAutoSettleEnabled)` (default true),
///   `@Shared(.taskAutoSettleOnFinishedPullRequest)` (default true),
///   `@Shared(.taskInactivityWindowDays)` (default 7), and
///   `RepositoriesFeature.TaskInboxAction.autoSettleSettingsChanged`, fired by
///   the Tasks panel's `.onChange` the way `.sidebarGroupingTogglesChanged` is.
@MainActor
struct RepositoriesFeatureTaskSignalsTests {
  private typealias Sandbox = TaskInboxSandbox
  private static let now = TaskInboxFixture.now

  // MARK: - Fixture

  private func makeSandbox() throws -> Sandbox {
    try Sandbox(name: "RepositoriesFeatureTaskSignalsTests")
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

  private static func pullRequest(state: String, headRefName: String) -> GithubPullRequest {
    GithubPullRequest(
      number: 7,
      title: "PR",
      state: state,
      additions: 1,
      deletions: 0,
      isDraft: false,
      reviewDecision: nil,
      mergeable: nil,
      mergeStateStatus: nil,
      updatedAt: nil,
      url: "https://github.com/o/r/pull/7",
      headRefName: headRefName,
      baseRefName: "main",
      commitsCount: nil,
      authorLogin: nil,
      statusCheckRollup: nil,
      mergeQueueEntry: nil
    )
  }

  /// One task owning one directory's single surface, with the auto-settle
  /// settings in a known state. Everything in this suite starts here so a
  /// leaked app-storage value from another test can't decide a settle.
  private struct Fixture {
    let sandbox: Sandbox
    let directory: URL
    let record: TaskRecord
    var state: RepositoriesFeature.State
    var rowID: WorktreeID { WorktreeID(directory.path(percentEncoded: false)) }
    var repositoryID: RepositoryID { RepositoryID(sandbox.rootURL.path(percentEncoded: false)) }
    var branch: String { state.sidebarItems[id: rowID]?.branchName ?? "" }
  }

  private func makeFixture(
    createdAt: Date = TaskInboxFixture.freshDate,
    snoozedUntil: Date? = nil,
    snoozedAt: Date? = nil,
    lastVisitedAt: Date? = nil
  ) throws -> Fixture {
    let sandbox = try makeSandbox()
    let directory = try sandbox.makeDirectory("work", activityAt: TaskInboxFixture.freshDate)
    let surfaceID = UUID()
    var state = TaskInboxFixture.makeState(
      sandbox: sandbox,
      directories: [directory],
      surfacesPerRow: [directory: [surfaceID]]
    )
    var record = TaskInboxFixture.makeRecord(
      directory: directory, surfaceIDs: [surfaceID], createdAt: createdAt)
    record.snoozedUntil = snoozedUntil
    record.snoozedAt = snoozedAt
    record.lastVisitedAt = lastVisitedAt
    state.taskRecords = [record]
    state.taskNow = Self.now
    // The tail is collapsed by default and renders nothing but the open task
    // (A8), so a suite that asserts on `visibleSettledTail` has to open it.
    state.isSettledTailExpanded = true
    state.applyPostReduceCacheRecomputes(.all)
    return Fixture(sandbox: sandbox, directory: directory, record: record, state: state)
  }

  /// The settings live in app storage, so every test that reads them runs
  /// against an in-memory store seeded with the values it means to assert.
  private func withSettings(
    autoSettle: Bool = true,
    settlesOnFinishedPullRequest: Bool = true,
    inactivityWindowDays: Int = 7,
    _ body: @MainActor () async throws -> Void
  ) async throws {
    try await withDependencies {
      $0.defaultAppStorage = .inMemory
    } operation: {
      @Shared(.taskAutoSettleEnabled) var isAutoSettleEnabled
      @Shared(.taskAutoSettleOnFinishedPullRequest) var settlesOnPullRequest
      @Shared(.taskInactivityWindowDays) var inactivityDays
      $isAutoSettleEnabled.withLock { $0 = autoSettle }
      $settlesOnPullRequest.withLock { $0 = settlesOnFinishedPullRequest }
      $inactivityDays.withLock { $0 = inactivityWindowDays }
      try await body()
    }
  }

  /// The real dispatch the repository refresh makes when a batch query lands.
  private func deliverPullRequest(
    _ pullRequest: GithubPullRequest?,
    to fixture: Fixture,
    store: TestStoreOf<RepositoriesFeature>
  ) async {
    await store.send(
      .repositoryPullRequestsLoaded(
        repositoryID: fixture.repositoryID,
        pullRequestsByWorktreeID: [fixture.rowID: pullRequest]
      )
    )
    await store.finish()
    // The batch result reaches the row — and the row the task leaf — through a
    // dispatched child action. `finish()` waits for in-flight effects but does
    // not drain the actions they sent, and a non-exhaustive store only drains
    // that on the *next* `send`, so without this a single-delivery test would
    // assert against the state as it was before the PR landed.
    await store.skipReceivedActions(strict: false)
  }

  // MARK: - A29: the PR projection reaches the task

  /// Producer seam: a real batch result, through the row reducer that owns the
  /// PR state, onto the leaf. No second poller — the task reads whatever the
  /// worktree row already learned.
  @Test(arguments: [
    ("OPEN", TaskPullRequestState.open),
    ("MERGED", .merged),
    ("CLOSED", .closed),
    ("SOMETHING_NEW", .unknown),
  ])
  func aBatchResultProjectsAnExplicitStateOntoTheOwningTask(
    rawState: String,
    expected: TaskPullRequestState
  ) async throws {
    let fixture = try makeFixture()
    let store = makeStore(fixture.state, sandbox: fixture.sandbox)

    await deliverPullRequest(
      Self.pullRequest(state: rawState, headRefName: fixture.branch), to: fixture, store: store)

    #expect(store.state.taskLeaves[id: fixture.record.id]?.pullRequest == expected)
  }

  /// A29's three-way distinction, bottom end: no PR is not the same answer as
  /// "we have not asked yet", and neither may be read as a finished PR.
  @Test func aTaskWithNoPullRequestReadsAsNoneNotUnknown() throws {
    let fixture = try makeFixture()

    #expect(fixture.state.taskLeaves[id: fixture.record.id]?.pullRequest == TaskPullRequestState.none)
  }

  @Test func aQueryInFlightReadsAsLoading() async throws {
    let fixture = try makeFixture()
    let store = makeStore(fixture.state, sandbox: fixture.sandbox)

    await store.send(
      .sidebarItems(.element(id: fixture.rowID, action: .pullRequestQueryStarted(branch: fixture.branch)))
    )
    await store.finish()

    #expect(store.state.taskLeaves[id: fixture.record.id]?.pullRequest == .loading)
  }

  /// A29's last clause, driven through the guard that actually enforces it: the
  /// row drops a result for a branch it no longer represents, so the task can
  /// never inherit a PR belonging to work that moved on.
  @Test func aLateResultForAStaleBranchCannotMutateTheTask() async throws {
    let fixture = try makeFixture()
    let store = makeStore(fixture.state, sandbox: fixture.sandbox)
    let stalePullRequest = Self.pullRequest(state: "MERGED", headRefName: "gone")

    await store.send(
      .sidebarItems(
        .element(
          id: fixture.rowID,
          action: .pullRequestChanged(stalePullRequest, branchAtQueryTime: "gone")
        )
      )
    )
    await store.finish()

    #expect(store.state.taskLeaves[id: fixture.record.id]?.pullRequest == TaskPullRequestState.none)
  }

  // MARK: - A15/A30: the settings decide what a finished PR means

  /// Resolved #4's other half, which ships with the query change or not at all:
  /// a finished PR settles the task, but only once the task has also been quiet
  /// for the idle window — a merge signal never clears, so without the guard a
  /// follow-up message would snap back into the tail the moment its turn ended.
  @Test func aMergedPullRequestSettlesAQuietTask() async throws {
    try await withSettings {
      let fixture = try makeFixture(createdAt: TaskInboxFixture.staleDate)
      let store = makeStore(fixture.state, sandbox: fixture.sandbox)

      await deliverPullRequest(
        Self.pullRequest(state: "MERGED", headRefName: fixture.branch), to: fixture, store: store)
      await store.send(.tasks(.classificationTick))
      await store.finish()

      #expect(
        store.state.tasksSidebarStructure.visibleSettledTail.map(\.id) == [fixture.record.id])
      #expect(store.state.tasksSidebarStructure.activeTaskIDs.isEmpty)
    }
  }

  /// A30: the global switch kills the auto path and nothing else. The same
  /// merged PR, the same clock — the row stays active, and the user can still
  /// settle it by hand.
  @Test func theGlobalOffSwitchLeavesAMergedTaskActiveAndStillSettlesOnRequest() async throws {
    try await withSettings(autoSettle: false) {
      let fixture = try makeFixture(createdAt: TaskInboxFixture.staleDate)
      let store = makeStore(fixture.state, sandbox: fixture.sandbox)

      await deliverPullRequest(
        Self.pullRequest(state: "MERGED", headRefName: fixture.branch), to: fixture, store: store)
      await store.send(.tasks(.classificationTick))
      await store.finish()
      #expect(store.state.tasksSidebarStructure.activeTaskIDs == [fixture.record.id])

      await store.send(.tasks(.settle(fixture.record.id)))
      await store.finish()
      #expect(
        store.state.tasksSidebarStructure.visibleSettledTail.map(\.id) == [fixture.record.id])
    }
  }

  /// Only the finished-PR toggle is off: the global switch is still on, so the
  /// inactivity path is untouched and this row is held active by its open PR
  /// rather than by the settings.
  @Test func theFinishedPullRequestToggleIsIndependentOfTheGlobalSwitch() async throws {
    try await withSettings(settlesOnFinishedPullRequest: false) {
      let fixture = try makeFixture(createdAt: TaskInboxFixture.staleDate)
      let store = makeStore(fixture.state, sandbox: fixture.sandbox)

      await deliverPullRequest(
        Self.pullRequest(state: "MERGED", headRefName: fixture.branch), to: fixture, store: store)
      await store.send(.tasks(.classificationTick))
      await store.finish()

      // The inactivity window still owns this row, and a merged PR does not
      // block it — the *open* one does.
      #expect(store.state.tasksSidebarStructure.visibleSettledTail.map(\.id) == [fixture.record.id])
    }
  }

  @Test func anOpenPullRequestHoldsAStaleTaskOutOfTheTail() async throws {
    try await withSettings {
      let fixture = try makeFixture(createdAt: TaskInboxFixture.staleDate)
      let store = makeStore(fixture.state, sandbox: fixture.sandbox)

      await deliverPullRequest(
        Self.pullRequest(state: "OPEN", headRefName: fixture.branch), to: fixture, store: store)
      await store.send(.tasks(.classificationTick))
      await store.finish()

      #expect(store.state.tasksSidebarStructure.activeTaskIDs == [fixture.record.id])
    }
  }

  /// A30's second clause: a settings change recomputes immediately. The panel
  /// fires the arm on `.onChange`, exactly like the sidebar grouping toggles —
  /// waiting for the next coarse classification tick would leave the user
  /// staring at a list that disagrees with the switch they just flipped.
  @Test func aSettingsChangeRecomputesWithoutWaitingForATick() async throws {
    try await withSettings(autoSettle: false) {
      let fixture = try makeFixture(createdAt: TaskInboxFixture.staleDate)
      let store = makeStore(fixture.state, sandbox: fixture.sandbox)
      #expect(store.state.tasksSidebarStructure.activeTaskIDs == [fixture.record.id])

      @Shared(.taskAutoSettleEnabled) var isAutoSettleEnabled
      $isAutoSettleEnabled.withLock { $0 = true }
      await store.send(.tasks(.autoSettleSettingsChanged))
      await store.finish()

      #expect(store.state.tasksSidebarStructure.visibleSettledTail.map(\.id) == [fixture.record.id])
    }
  }

  // MARK: - A29b: a PR change raises a snoozed task's hand

  @Test func aPullRequestMergingRaisesASnoozedTasksHand() async throws {
    let fixture = try makeFixture(
      snoozedUntil: Self.now.addingTimeInterval(3600),
      snoozedAt: Self.now.addingTimeInterval(-3600)
    )
    let store = makeStore(fixture.state, sandbox: fixture.sandbox)

    await deliverPullRequest(
      Self.pullRequest(state: "OPEN", headRefName: fixture.branch), to: fixture, store: store)
    #expect(store.state.tasksSidebarStructure.snoozedTotalCount == 1)

    await deliverPullRequest(
      Self.pullRequest(state: "MERGED", headRefName: fixture.branch), to: fixture, store: store)

    #expect(store.state.taskLeaves[id: fixture.record.id]?.pullRequestChangedAt == Self.now)
    #expect(store.state.tasksSidebarStructure.activeTaskIDs == [fixture.record.id])
    // A25: the raise never clears the record, so taking the snooze back is
    // still the affordance the row offers.
    #expect(store.state.tasksSidebarStructure.snoozedTaskIDs == [fixture.record.id])
  }

  /// Learning that a PR exists is not the PR changing. A batch refresh after a
  /// relaunch observes every task's PR for the first time; if that counted as a
  /// change, every snoozed row in the app would pop back on launch.
  @Test func firstObservingAPullRequestDoesNotRaiseAHand() async throws {
    let fixture = try makeFixture(
      snoozedUntil: Self.now.addingTimeInterval(3600),
      snoozedAt: Self.now.addingTimeInterval(-3600)
    )
    let store = makeStore(fixture.state, sandbox: fixture.sandbox)

    await deliverPullRequest(
      Self.pullRequest(state: "OPEN", headRefName: fixture.branch), to: fixture, store: store)

    #expect(store.state.taskLeaves[id: fixture.record.id]?.pullRequestChangedAt == nil)
    #expect(store.state.tasksSidebarStructure.snoozedTotalCount == 1)
  }

  // MARK: - A28: the Done pill

  /// The pill is "finished while you weren't looking", and the visit is what
  /// clears it. Driven through the row's agent snapshot, which is where the
  /// completion instant is actually produced.
  @Test func aTurnThatFinishedAfterTheLastVisitShowsAsUnreadDone() async throws {
    let fixture = try makeFixture(lastVisitedAt: Self.now.addingTimeInterval(-7200))
    let store = makeStore(fixture.state, sandbox: fixture.sandbox)

    await store.send(
      .tasks(
        .agentSnapshotChanged(
          taskID: fixture.record.id,
          snapshot: .init(
            agents: [.init(agent: .claude, activity: .idle, isDoneUnseen: true)],
            completedTurnAt: Self.now.addingTimeInterval(-60)
          )
        )
      )
    )
    await store.finish()

    let leaf = try #require(store.state.taskLeaves[id: fixture.record.id])
    #expect(leaf.isDoneUnread)
    #expect(!leaf.isReceded)
  }

  @Test func aVisitAfterTheTurnEndedClearsTheDonePill() async throws {
    let fixture = try makeFixture(lastVisitedAt: Self.now)
    let store = makeStore(fixture.state, sandbox: fixture.sandbox)

    await store.send(
      .tasks(
        .agentSnapshotChanged(
          taskID: fixture.record.id,
          snapshot: .init(
            agents: [.init(agent: .claude, activity: .idle, isDoneUnseen: true)],
            completedTurnAt: Self.now.addingTimeInterval(-60)
          )
        )
      )
    )
    await store.finish()

    #expect(store.state.taskLeaves[id: fixture.record.id]?.isDoneUnread == false)
  }

  /// A28's zero-pill seed check, and the reconciliation of the Phase-1 rule:
  /// a never-visited task reads as *read*. A first launch that seeds fifty
  /// stale directories must not open on fifty unread badges — that is an inbox
  /// nobody trusts by the second screenful.
  @Test func aFreshSeedOfStaleTasksShowsNoDonePills() async throws {
    let sandbox = try makeSandbox()
    let directories = try (0..<5).map { index in
      try sandbox.makeDirectory("stale-\(index)", activityAt: TaskInboxFixture.staleDate)
    }
    var state = TaskInboxFixture.makeState(sandbox: sandbox, directories: directories)
    state.taskNow = Self.now
    let store = makeStore(state, sandbox: sandbox)

    await store.send(.tasks(.load))
    await store.receive(\.tasks.loaded)
    await store.receive(\.tasks.seedIfNeeded)
    await store.receive(\.tasks.seeded)
    await store.send(.tasks(.stopTimers))
    await store.finish()

    #expect(store.state.taskRecords.count == directories.count)
    #expect(store.state.taskLeaves.allSatisfy { !$0.isDoneUnread })
    #expect(store.state.taskRecords.allSatisfy { $0.lastVisitedAt == nil })
  }

  // MARK: - Per-surface scoping of the row's other signals

  /// A sibling task's unread terminal in the same directory must not light this
  /// task's row. `unseenSurfaces` is per-surface, so the scoping is provable
  /// rather than approximated by the row-wide flag.
  @Test func unseenNotificationsAreScopedToTheSurfacesTheTaskOwns() throws {
    let sandbox = try makeSandbox()
    let directory = try sandbox.makeDirectory("work", activityAt: TaskInboxFixture.freshDate)
    let owned = UUID()
    let unowned = UUID()
    var state = TaskInboxFixture.makeState(
      sandbox: sandbox,
      directories: [directory],
      surfacesPerRow: [directory: [owned, unowned]]
    )
    let record = TaskInboxFixture.makeRecord(directory: directory, surfaceIDs: [owned])
    state.taskRecords = [record]
    state.taskNow = Self.now
    let rowID = WorktreeID(directory.path(percentEncoded: false))
    state.sidebarItems[id: rowID]?.hasUnseenNotifications = true
    state.sidebarItems[id: rowID]?.unseenSurfaces = [.init(id: unowned, count: 2)]
    state.applyPostReduceCacheRecomputes(.all)

    #expect(state.taskLeaves[id: record.id]?.hasUnseenNotifications == false)

    state.sidebarItems[id: rowID]?.unseenSurfaces = [
      .init(id: unowned, count: 2), .init(id: owned, count: 1),
    ]
    state.applyPostReduceCacheRecomputes(.all)

    #expect(state.taskLeaves[id: record.id]?.hasUnseenNotifications == true)
  }

  // MARK: - A27: exactly one status per visible task

  /// The status strip's whole contract. Approval is absent on purpose: nothing
  /// in the hook wire protocol can distinguish a permission prompt from a
  /// question yet (Resolved #1), so an agent that cannot report it reads as
  /// `input` — never as a guessed approval.
  @Test(arguments: [
    (AgentPresenceFeature.Activity.busy, TaskStatusModel.Status.working),
    (.compacting, .working),
    (.awaitingInput, .input),
    (.error, .failed),
    (.idle, .ready),
  ])
  func aTaskReportsExactlyOneStatusForItsAgentActivity(
    activity: AgentPresenceFeature.Activity,
    expected: TaskStatusModel.Status
  ) async throws {
    let fixture = try makeFixture()
    let store = makeStore(fixture.state, sandbox: fixture.sandbox)

    await store.send(
      .tasks(
        .agentSnapshotChanged(
          taskID: fixture.record.id,
          snapshot: .init(
            agents: [.init(agent: .claude, activity: activity)],
            isWorking: activity.isWorking,
            hasError: activity == .error
          )
        )
      )
    )
    await store.finish()

    #expect(store.state.taskLeaves[id: fixture.record.id]?.status == expected)
  }

  /// A28's hard rule at the row level: the two statuses that are parked on a
  /// person are never faded, whatever else the row knows.
  @Test(arguments: [AgentPresenceFeature.Activity.awaitingInput, .error])
  func aRowAskingForSomethingIsNeverReceded(activity: AgentPresenceFeature.Activity) async throws {
    let fixture = try makeFixture()
    let store = makeStore(fixture.state, sandbox: fixture.sandbox)

    await store.send(
      .tasks(
        .agentSnapshotChanged(
          taskID: fixture.record.id,
          snapshot: .init(
            agents: [.init(agent: .claude, activity: activity)],
            hasError: activity == .error
          )
        )
      )
    )
    await store.finish()

    let leaf = try #require(store.state.taskLeaves[id: fixture.record.id])
    #expect(leaf.needsHuman)
    #expect(!leaf.isReceded)
  }

  /// A24 meets A28: the Woke pill and the row's contrast read the same answer,
  /// so a woken row is never faded out from under the pill announcing it.
  @Test func aWokenRowIsNotReceded() async throws {
    let fixture = try makeFixture(
      snoozedUntil: Self.now.addingTimeInterval(-60),
      snoozedAt: Self.now.addingTimeInterval(-3600)
    )
    let store = makeStore(fixture.state, sandbox: fixture.sandbox)

    await store.send(.tasks(.classificationTick))
    await store.finish()

    #expect(store.state.tasksSidebarStructure.wokeTaskIDs == [fixture.record.id])
    let leaf = try #require(store.state.taskLeaves[id: fixture.record.id])
    #expect(leaf.isWoke)
    #expect(!leaf.isReceded)
  }

  @Test func aQuietTaskWithNothingPendingRecedes() async throws {
    let fixture = try makeFixture()
    let store = makeStore(fixture.state, sandbox: fixture.sandbox)

    await store.send(.tasks(.classificationTick))
    await store.finish()

    let leaf = try #require(store.state.taskLeaves[id: fixture.record.id])
    #expect(leaf.status == .ready)
    #expect(leaf.isReceded)
  }
}

import ComposableArchitecture
import Darwin
import Dependencies
import DependenciesTestSupport
import Foundation
import IdentifiedCollections
import Sharing
import Testing

@testable import SupacodeSettingsFeature
@testable import SupacodeSettingsShared
@testable import supacode

/// RED half of the per-surface task projection (tracked task #13) and of
/// Resolved #5's working-elapsed stamp, driven end to end from the wire.
///
/// Both live here rather than in the repositories suite because presence
/// records are keyed by `(agent, surfaceID)` and only `AppFeature` holds them:
/// the task leaf's activity has to be projected where the per-surface records
/// are, not guessed downstream from a whole-row snapshot that carries no
/// surface id. The API this specifies:
///
/// - `AppFeature` fans `RepositoriesFeature.TaskInboxAction.agentSnapshotChanged(taskID:snapshot:)`
///   for every task owning a changed surface, computed with
///   `presence.rowSnapshot(across: record.surfaceIDs, badgesEnabled:)`.
/// - `RepositoriesFeature.State.taskAgentSnapshots: [TaskID: RowSnapshot]` is
///   what `recomputeTaskLeavesIfChanged` projects onto the leaf — so the leaf
///   stays a pure function of reducer state (`expectCachesConverged`) instead
///   of becoming push-only state a recompute would clobber.
/// - `AgentPresenceFeature.RowSnapshot.workingSince`, projected onto
///   `TaskLeafState.workingSince`.
@MainActor
struct AppFeatureTaskPresenceTests {
  private typealias Sandbox = TaskInboxSandbox
  private static let now = TaskInboxFixture.now

  private func makeStore(
    _ repositories: RepositoriesFeature.State,
    sandbox: Sandbox
  ) -> TestStoreOf<AppFeature> {
    let store = TestStore(
      initialState: AppFeature.State(repositories: repositories, settings: SettingsFeature.State())
    ) {
      AppFeature()
    } withDependencies: {
      $0.settingsFileStorage = sandbox.storage
      $0.date.now = Self.now
      $0.continuousClock = TestClock()
      $0.terminalClient.saveLayoutsWithAgents = { _ in }
      $0.terminalClient.send = { _ in }
    }
    store.exhaustivity = .off
    return store
  }

  private func hookEvent(
    _ event: AgentHookEvent.EventName,
    surfaceID: UUID,
    agent: SkillAgent = .claude,
    at timestamp: Date? = nil
  ) -> AgentHookEvent {
    AgentHookEvent(
      agent: agent.rawValue,
      event: event.rawValue,
      surfaceID: surfaceID,
      pid: getpid(),
      timestamp: timestamp
    )
  }

  private func send(
    _ event: AgentHookEvent,
    to store: TestStoreOf<AppFeature>
  ) async {
    await store.send(.terminalEvent(.agentHookEventReceived(event)))
    await store.finish()
  }

  // MARK: - Task #13: two tasks in one directory report different activity

  /// The blur Phase 3 documented and Phase 5 closes. Two tasks share a
  /// directory — `~/work/cj` legitimately wants that (Resolved #11) — and each
  /// owns its own surfaces. A turn running on one task's surface must not light
  /// up the other's row: the whole point of the inbox is that a row's state is
  /// that row's state.
  @Test func twoTasksInOneDirectoryReportTheirOwnSurfacesActivity() async throws {
    let sandbox = try Sandbox(name: "AppFeatureTaskPresenceTests-scoping")
    let directory = try sandbox.makeDirectory("shared", activityAt: TaskInboxFixture.freshDate)
    let mineSurface = UUID()
    let theirSurface = UUID()
    var repositories = TaskInboxFixture.makeState(
      sandbox: sandbox,
      directories: [directory],
      surfacesPerRow: [directory: [mineSurface, theirSurface]]
    )
    let mine = TaskInboxFixture.makeRecord(directory: directory, surfaceIDs: [mineSurface])
    let theirs = TaskInboxFixture.makeRecord(directory: directory, surfaceIDs: [theirSurface])
    repositories.taskRecords = [mine, theirs]
    repositories.taskNow = Self.now
    repositories.applyPostReduceCacheRecomputes(.all)
    let store = makeStore(repositories, sandbox: sandbox)

    await send(hookEvent(.sessionStart, surfaceID: mineSurface), to: store)
    await send(hookEvent(.busy, surfaceID: mineSurface, at: Self.now), to: store)

    let leaves = store.state.repositories.taskLeaves
    #expect(leaves[id: mine.id]?.agentSnapshot.isWorking == true)
    #expect(leaves[id: theirs.id]?.agentSnapshot.isWorking == false)
    #expect(leaves[id: theirs.id]?.agentSnapshot.agents.isEmpty == true)
    #expect(leaves[id: mine.id]?.status == .working)
    #expect(leaves[id: theirs.id]?.status == .ready)
  }

  /// The same scoping for the two instants the snooze rules read: an error on a
  /// surface this task does not own can never re-wake it (A25's "only news
  /// about *this* task counts").
  @Test func anErrorOnAnUnownedSurfaceDoesNotReachTheTask() async throws {
    let sandbox = try Sandbox(name: "AppFeatureTaskPresenceTests-error")
    let directory = try sandbox.makeDirectory("shared", activityAt: TaskInboxFixture.freshDate)
    let owned = UUID()
    let unowned = UUID()
    var repositories = TaskInboxFixture.makeState(
      sandbox: sandbox,
      directories: [directory],
      surfacesPerRow: [directory: [owned, unowned]]
    )
    let record = TaskInboxFixture.makeRecord(directory: directory, surfaceIDs: [owned])
    repositories.taskRecords = [record]
    repositories.taskNow = Self.now
    repositories.applyPostReduceCacheRecomputes(.all)
    let store = makeStore(repositories, sandbox: sandbox)

    await send(hookEvent(.sessionStart, surfaceID: unowned), to: store)
    await send(hookEvent(.busy, surfaceID: unowned, at: Self.now), to: store)
    await send(
      hookEvent(.error, surfaceID: unowned, at: Self.now.addingTimeInterval(30)), to: store)

    let leaf = try #require(store.state.repositories.taskLeaves[id: record.id])
    #expect(leaf.errorAt == nil)
    #expect(leaf.status == .ready)
  }

  // MARK: - Resolved #5: the working-elapsed start instant reaches the leaf

  /// The leaf-local `TimelineView` renders elapsed from this instant. The timer
  /// itself is a view concern and untestable here; the projection is the part
  /// that can silently break, so it is the part that is pinned.
  @Test func aStartedTurnPutsItsStartInstantOnTheOwningTaskLeaf() async throws {
    let sandbox = try Sandbox(name: "AppFeatureTaskPresenceTests-workingSince")
    let directory = try sandbox.makeDirectory("work", activityAt: TaskInboxFixture.freshDate)
    let surfaceID = UUID()
    var repositories = TaskInboxFixture.makeState(
      sandbox: sandbox,
      directories: [directory],
      surfacesPerRow: [directory: [surfaceID]]
    )
    let record = TaskInboxFixture.makeRecord(directory: directory, surfaceIDs: [surfaceID])
    repositories.taskRecords = [record]
    repositories.taskNow = Self.now
    repositories.applyPostReduceCacheRecomputes(.all)
    let store = makeStore(repositories, sandbox: sandbox)
    let startedAt = Self.now.addingTimeInterval(-300)

    await send(hookEvent(.sessionStart, surfaceID: surfaceID), to: store)
    await send(hookEvent(.busy, surfaceID: surfaceID, at: startedAt), to: store)

    #expect(store.state.repositories.taskLeaves[id: record.id]?.workingSince == startedAt)

    await send(hookEvent(.idle, surfaceID: surfaceID, at: Self.now), to: store)

    // A row that is not working renders no timer — never a fabricated 0s.
    let leaf = try #require(store.state.repositories.taskLeaves[id: record.id])
    #expect(leaf.workingSince == nil)
    #expect(leaf.status == .ready)
  }
}

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

  /// A store that can answer the promote arm's two live-terminal questions.
  /// Promotion resolves its target through `TerminalClient`, never through the
  /// persisted layout, so a fixture that skipped these would claim nothing.
  private func makeStore(
    _ repositories: RepositoriesFeature.State,
    sandbox: Sandbox,
    liveTabs: [TerminalTabID: Set<UUID>],
    selectedTabID: TerminalTabID? = nil
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
      $0.terminalClient.selectedTabID = { _ in selectedTabID }
      $0.terminalClient.tabSurfaceIDs = { _, tabID in liveTabs[tabID] ?? [] }
      $0.terminalClient.tabID = { _, surfaceID in
        liveTabs.first { $0.value.contains(surfaceID) }?.key
      }
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
    // `finish()` waits for in-flight effects; it does NOT drain the queue of
    // actions those effects sent, and a non-exhaustive store only drains that
    // on the *next* `send`. A hook event reaches a task leaf through three
    // hops (terminal event → presence → `surfacesChanged` → per-task
    // snapshot), so without this every assertion below would read the state one
    // event behind and pass or fail for the wrong reason.
    await store.skipReceivedActions(strict: false)
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

  /// A27/A28 against the badge preference. `agentPresenceBadgesEnabled` decides
  /// whether a *worktree row* draws agent badges, and the error rides that badge
  /// — so a task leaf reading `hasError` inherits a display preference. A user
  /// who turned badges off would then be told a broken task is `ready`, and A28
  /// would fade it for being quiet.
  ///
  /// Driven from the wire, because the gate lives in the projection: only a real
  /// `.error` hook event through `AgentPresenceFeature` and the per-task fan-out
  /// exercises the `badgesEnabled:` argument that silences it.
  @Test func aTaskReportsAFailureEvenWhileAgentBadgesAreOff() async throws {
    let sandbox = try Sandbox(name: "AppFeatureTaskPresenceTests-badgesOff")
    try await withDependencies {
      $0.settingsFileStorage = sandbox.storage
    } operation: {
      @Shared(.settingsFile) var settingsFile: SettingsFile
      $settingsFile.withLock { $0.global.agentPresenceBadgesEnabled = false }

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

      await send(hookEvent(.sessionStart, surfaceID: surfaceID), to: store)
      await send(hookEvent(.busy, surfaceID: surfaceID, at: Self.now), to: store)
      await send(hookEvent(.error, surfaceID: surfaceID, at: Self.now.addingTimeInterval(30)), to: store)

      let leaf = try #require(store.state.repositories.taskLeaves[id: record.id])
      // The preference really is off: no badges, and no badge-borne error.
      #expect(leaf.agentSnapshot.agents.isEmpty)
      #expect(leaf.agentSnapshot.hasError == false)
      // The task still tells the truth about itself.
      #expect(leaf.agentSnapshot.isErrored)
      #expect(leaf.status == .failed)
      #expect(leaf.isReceded == false)
      // A25 keeps working too: the instant is what re-surfaces a snoozed row.
      #expect(leaf.errorAt == Self.now.addingTimeInterval(30))
    }
  }

  /// The badge toggle re-broadcasts every *row's* snapshot so cached state
  /// drains without waiting for a hook event. Task leaves hold their own
  /// snapshot, projected across the surfaces the record owns, so leaving them
  /// out left a task wearing the badge list it had when the switch flipped —
  /// until the next hook event happened to touch one of its surfaces, which for
  /// a quiet task is never.
  @Test func flippingTheBadgeToggleReDrainsTaskLeavesToo() async throws {
    let sandbox = try Sandbox(name: "AppFeatureTaskPresenceTests-badgeFanOut")
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

    await send(hookEvent(.sessionStart, surfaceID: surfaceID), to: store)
    await send(hookEvent(.busy, surfaceID: surfaceID, at: Self.now), to: store)
    #expect(store.state.repositories.taskLeaves[id: record.id]?.childAgents.count == 1)

    var settings = GlobalSettings.default
    settings.agentPresenceBadgesEnabled = false
    await store.send(.settings(.delegate(.settingsChanged(settings))))
    await store.finish()
    await store.skipReceivedActions(strict: false)

    let leaf = try #require(store.state.repositories.taskLeaves[id: record.id])
    #expect(leaf.childAgents.isEmpty)
    // The shimmer is not a badge, so the toggle must not take the work with it.
    #expect(leaf.status == .working)
  }

  // MARK: - Ownership moves are a projection change the surface fan-out cannot see

  /// The producer seam for a claim. The surface-keyed fan-out fires on presence
  /// deltas, and a promote is not one: the surfaces did not change, the *claim*
  /// did. An agent that was already parked on the user before the tab was
  /// promoted must therefore reach the task without a new hook event — otherwise
  /// the row reads `ready` until the agent happens to say something again, which
  /// for an agent waiting on you is never.
  @Test func promotingATabProjectsAnAlreadyWaitingAgentOntoTheTask() async throws {
    let sandbox = try Sandbox(name: "AppFeatureTaskPresenceTests-promote")
    let directory = try sandbox.makeDirectory("work", activityAt: TaskInboxFixture.freshDate)
    let owned = UUID()
    let claimed = UUID()
    // A third surface nobody claims, and the reason this is a producer-seam
    // test: the leaf's fallback only borrows the worktree row's snapshot when
    // the task owns *every* surface the row has. Leave that true and the promote
    // would pass on the fallback alone, proving nothing about the re-projection.
    let unowned = UUID()
    let claimedTab = TerminalTabID()
    var repositories = TaskInboxFixture.makeState(
      sandbox: sandbox,
      directories: [directory],
      surfacesPerRow: [directory: [owned, claimed, unowned]],
      hasLoadedTasks: true
    )
    let record = TaskInboxFixture.makeRecord(directory: directory, surfaceIDs: [owned])
    repositories.taskRecords = [record]
    repositories.taskNow = Self.now
    repositories.applyPostReduceCacheRecomputes(.all)
    let store = makeStore(
      repositories, sandbox: sandbox, liveTabs: [claimedTab: [claimed]], selectedTabID: claimedTab)

    // The agent parks on the user *before* the task owns its surface.
    await send(hookEvent(.sessionStart, surfaceID: claimed), to: store)
    await send(hookEvent(.awaitingInput, surfaceID: claimed, at: Self.now), to: store)
    #expect(store.state.repositories.taskLeaves[id: record.id]?.status == .ready)

    await store.send(
      .repositories(
        .tasks(
          .promoteTab(
            worktreeID: WorktreeID(directory.path(percentEncoded: false)), tabID: claimedTab)
        )
      )
    )
    await store.finish()
    await store.skipReceivedActions(strict: false)

    let leaf = try #require(store.state.repositories.taskLeaves[id: record.id])
    #expect(leaf.status == .input)
    #expect(leaf.needsHuman)
  }

  /// The other end of the same seam, and the reason the snapshot prune is safe:
  /// a task that loses its last surface must stop reporting the work that ran on
  /// it. Ownership reconciliation drops the dead surface from the record, and the
  /// same re-projection re-takes the snapshot across what is left — so the order
  /// the surface-close fan-out and the reconcile happen to arrive in cannot
  /// decide whether the row still shimmers.
  @Test func closingATasksLastSurfaceClearsItsWorkingLeaf() async throws {
    let sandbox = try Sandbox(name: "AppFeatureTaskPresenceTests-surfaceClose")
    let directory = try sandbox.makeDirectory("work", activityAt: TaskInboxFixture.freshDate)
    let surfaceID = UUID()
    var repositories = TaskInboxFixture.makeState(
      sandbox: sandbox,
      directories: [directory],
      surfacesPerRow: [directory: [surfaceID]],
      hasLoadedTasks: true
    )
    let record = TaskInboxFixture.makeRecord(directory: directory, surfaceIDs: [surfaceID])
    repositories.taskRecords = [record]
    repositories.taskNow = Self.now
    repositories.applyPostReduceCacheRecomputes(.all)
    let store = makeStore(repositories, sandbox: sandbox)

    await send(hookEvent(.sessionStart, surfaceID: surfaceID), to: store)
    await send(hookEvent(.busy, surfaceID: surfaceID, at: Self.now), to: store)
    #expect(store.state.repositories.taskLeaves[id: record.id]?.status == .working)

    // The row loses the surface through its real writer, then ownership
    // reconciles against the emptied projection.
    await store.send(
      .repositories(
        .sidebarItems(
          .element(
            id: WorktreeID(directory.path(percentEncoded: false)),
            action: .terminalProjectionChanged(
              WorktreeRowProjection(
                surfaceIDs: [],
                isProgressBusy: false,
                hasUnseenNotifications: false,
                notifications: []
              )
            )
          )
        )
      )
    )
    await store.send(.repositories(.tasks(.reconcileSurfaceOwnership)))
    await store.finish()
    await store.skipReceivedActions(strict: false)

    #expect(store.state.repositories.taskRecords[id: record.id]?.surfaceIDs.isEmpty == true)
    let leaf = try #require(store.state.repositories.taskLeaves[id: record.id])
    #expect(leaf.status == .ready)
    #expect(leaf.workingSince == nil)
    #expect(leaf.agentSnapshot == .init())
  }

  /// The fan-out is diffed against what the reducer already holds. Both
  /// whole-roster callers walk every task in the app, and an action that
  /// resolves to the state a task is already in still costs a full reduce plus a
  /// post-reduce cache pass per task.
  @Test func aReProjectionThatChangesNothingSendsNothing() async throws {
    let sandbox = try Sandbox(name: "AppFeatureTaskPresenceTests-dedupe")
    let directory = try sandbox.makeDirectory("work", activityAt: TaskInboxFixture.freshDate)
    let surfaceID = UUID()
    var repositories = TaskInboxFixture.makeState(
      sandbox: sandbox,
      directories: [directory],
      surfacesPerRow: [directory: [surfaceID]],
      hasLoadedTasks: true
    )
    let record = TaskInboxFixture.makeRecord(directory: directory, surfaceIDs: [surfaceID])
    repositories.taskRecords = [record]
    repositories.taskNow = Self.now
    // What an idle projection resolves to, already on record.
    repositories.taskAgentSnapshots[record.id] = .init()
    repositories.applyPostReduceCacheRecomputes(.all)
    let store = makeStore(repositories, sandbox: sandbox)
    // Exhaustive on purpose: an unexpected received action is the failure this
    // test is looking for, and only exhaustivity can see one.
    store.exhaustivity = .on

    await store.send(.repositories(.tasks(.reconcileSurfaceOwnership)))
    await store.finish()
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

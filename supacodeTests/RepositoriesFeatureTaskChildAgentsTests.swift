import ComposableArchitecture
import Dependencies
import DependenciesTestSupport
import Foundation
import IdentifiedCollections
import Sharing
import Testing

@testable import SupacodeSettingsShared
@testable import supacode

/// Phase-3 assertion A22: hook-reported agents on a task's surfaces render as
/// indented child rows under the owning task row.
///
/// Two halves. The projection half is pure — `TaskLeafState.childAgents` is a
/// function of the leaf's snapshot and nothing else, so those tests build a leaf
/// directly. The plumbing half asserts the leaf actually receives the agents
/// through the reducer, and that a tick reaches exactly one leaf (A10).
@MainActor
struct RepositoriesFeatureTaskChildAgentsTests {
  private typealias Sandbox = TaskInboxSandbox

  private func makeSandbox() throws -> Sandbox {
    try Sandbox(name: "RepositoriesFeatureTaskChildAgentsTests")
  }

  private func makeStore(
    _ state: RepositoriesFeature.State,
    sandbox: Sandbox
  ) -> TestStoreOf<RepositoriesFeature> {
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    } withDependencies: {
      $0.settingsFileStorage = sandbox.storage
      $0.date.now = TaskInboxFixture.now
    }
    store.exhaustivity = .off
    return store
  }

  private func makeLeaf(_ agents: [AgentPresenceFeature.AgentInstance]) -> TaskLeafState {
    var leaf = TaskLeafState(id: TaskID())
    leaf.agentSnapshot = AgentPresenceFeature.RowSnapshot(agents: agents)
    return leaf
  }

  // MARK: - A22: the projection

  @Test func aTaskWithNoReportedAgentsHasNoChildRows() {
    #expect(makeLeaf([]).childAgents.isEmpty)
  }

  /// The order the child rows render in, locked: triage rank first (the Agents
  /// tab's `AgentDashboardState` ordering, so a blocked agent is never buried
  /// under an idle one), then the displayed name, then the agent kind as the
  /// final deterministic tie-break.
  @Test func childRowsAreOrderedByTriageRank() {
    let leaf = makeLeaf([
      .init(agent: .hermes, activity: .idle),
      .init(agent: .claude, activity: .idle, isDoneUnseen: true),
      .init(agent: .codex, activity: .busy),
      .init(agent: .grok, activity: .awaitingInput),
    ])

    #expect(leaf.childAgents.map(\.agent) == [.grok, .codex, .claude, .hermes])
    #expect(leaf.childAgents.map(\.state) == [.blocked, .working, .done, .idle])
  }

  /// Same rank: the name the row actually shows breaks the tie, so the visible
  /// order matches what the user reads rather than the internal raw value.
  @Test func childRowsAtTheSameRankAreOrderedByDisplayedName() {
    let leaf = makeLeaf([
      .init(agent: .claude, activity: .busy, name: "Zebra"),
      .init(agent: .codex, activity: .busy, name: "Alpha"),
    ])

    #expect(leaf.childAgents.map(\.displayName) == ["Alpha", "Zebra"])
  }

  /// A task can own several surfaces running the same agent kind. They collapse
  /// into one child row carrying the most urgent state — same rollup the Agents
  /// tab applies per worktree, so the two panels can never disagree.
  @Test func severalSurfacesRunningOneAgentKindCollapseToOneChildRow() {
    let leaf = makeLeaf([
      .init(agent: .claude, activity: .idle),
      .init(agent: .claude, activity: .busy, name: "Fixer"),
    ])

    #expect(leaf.childAgents.count == 1)
    #expect(leaf.childAgents.first?.state == .working)
    #expect(leaf.childAgents.first?.displayName == "Fixer")
  }

  /// An unnamed agent falls back to its kind, so a child row always has
  /// something honest to render.
  @Test func anUnnamedChildRowFallsBackToTheAgentKind() {
    let leaf = makeLeaf([.init(agent: .codex, activity: .idle)])

    #expect(leaf.childAgents.first?.displayName == SkillAgent.codex.displayName)
  }

  // MARK: - A22: the plumbing

  @Test func anAgentTickPutsTheReportedAgentsUnderTheOwningTask() async throws {
    let sandbox = try makeSandbox()
    let directory = try sandbox.makeDirectory("work", activityAt: TaskInboxFixture.freshDate)
    let surfaceID = UUID()
    var state = TaskInboxFixture.makeState(
      sandbox: sandbox,
      directories: [directory],
      surfacesPerRow: [directory: [surfaceID]]
    )
    let record = TaskInboxFixture.makeRecord(directory: directory, surfaceIDs: [surfaceID])
    state.taskRecords = [record]
    state.applyPostReduceCacheRecomputes(.all)
    let store = makeStore(state, sandbox: sandbox)

    await store.send(
      .tasks(
        .agentSnapshotChanged(
          taskID: record.id,
          snapshot: .init(
            agents: [.init(agent: .claude, activity: .busy, name: "Fixer")], isWorking: true)
        )
      )
    )
    await store.finish()

    let children = try #require(store.state.taskLeaves[id: record.id]?.childAgents)
    #expect(children.map(\.displayName) == ["Fixer"])
    #expect(children.map(\.state) == [.working])
  }

  /// The other side of the same seam, and the one nothing else covers: a task
  /// that owns *every* surface its row has, before `AppFeature` has projected
  /// anything for it. The row's union over its surfaces IS this task's
  /// projection then, so the leaf borrows it — that is what stops a fresh launch
  /// showing an empty task row until the next hook event happens to fire.
  ///
  /// Driven from the row action on purpose. The per-task arm would bypass the
  /// fallback entirely, and the fallback is the part that silently stops
  /// working if its exact-ownership condition is ever loosened or dropped.
  @Test func aTaskOwningEveryRowSurfaceBorrowsTheRowsSnapshotUntilItIsProjected() async throws {
    let sandbox = try makeSandbox()
    let directory = try sandbox.makeDirectory("work", activityAt: TaskInboxFixture.freshDate)
    let owned = UUID()
    var state = TaskInboxFixture.makeState(
      sandbox: sandbox,
      directories: [directory],
      surfacesPerRow: [directory: [owned]]
    )
    let record = TaskInboxFixture.makeRecord(directory: directory, surfaceIDs: [owned])
    state.taskRecords = [record]
    state.applyPostReduceCacheRecomputes(.all)
    let store = makeStore(state, sandbox: sandbox)

    await store.send(
      .sidebarItems(
        .element(
          id: WorktreeID(directory.path(percentEncoded: false)),
          action: .agentSnapshotChanged(
            .init(agents: [.init(agent: .codex, activity: .busy)], isWorking: true)
          )
        )
      )
    )
    await store.finish()

    let leaf = try #require(store.state.taskLeaves[id: record.id])
    #expect(leaf.childAgents.map(\.agent) == [.codex])
    #expect(leaf.status == .working)
  }

  /// Phase 5 closes the Phase-3 blur this test used to document. The leaf's
  /// presence no longer comes from the whole-row snapshot (which carries no
  /// surface id, so it could only ever be the union of every agent in the
  /// directory) — it comes from the per-task snapshot `AppFeature` projects
  /// across the surfaces the record actually owns. A row-wide tick therefore
  /// reaches the row and stops there.
  ///
  /// The producer half — a real hook event on an unowned surface, scoped away
  /// before it ever reaches this reducer — is in `AppFeatureTaskPresenceTests`.
  @Test func aRowWideTickNoLongerLeaksEveryAgentIntoAPartialOwnersLeaf() async throws {
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
    state.applyPostReduceCacheRecomputes(.all)
    let store = makeStore(state, sandbox: sandbox)

    await store.send(
      .sidebarItems(
        .element(
          id: WorktreeID(directory.path(percentEncoded: false)),
          action: .agentSnapshotChanged(
            .init(agents: [.init(agent: .codex, activity: .busy)], isWorking: true)
          )
        )
      )
    )
    await store.finish()

    #expect(store.state.taskLeaves[id: record.id]?.childAgents.isEmpty == true)

    // The per-task arm is the one that moves the leaf, and it carries only what
    // was projected across the owned surface.
    await store.send(
      .tasks(
        .agentSnapshotChanged(
          taskID: record.id,
          snapshot: .init(agents: [.init(agent: .claude, activity: .busy)], isWorking: true)
        )
      )
    )
    await store.finish()

    #expect(store.state.taskLeaves[id: record.id]?.childAgents.map(\.agent) == [.claude])
  }

  /// A10 for the child rows: they are read from the leaf one level down, inside
  /// the row view, so a tick on one task can move that task's children and
  /// nothing else — not a sibling's leaf, not the cached render plan.
  @Test func anAgentTickMovesOnlyTheTickedTasksChildRows() async throws {
    let sandbox = try makeSandbox()
    let mine = try sandbox.makeDirectory("mine", activityAt: TaskInboxFixture.freshDate)
    let other = try sandbox.makeDirectory("other", activityAt: TaskInboxFixture.freshDate)
    let mineSurface = UUID()
    let otherSurface = UUID()
    var state = TaskInboxFixture.makeState(
      sandbox: sandbox,
      directories: [mine, other],
      surfacesPerRow: [mine: [mineSurface], other: [otherSurface]]
    )
    let mineRecord = TaskInboxFixture.makeRecord(directory: mine, surfaceIDs: [mineSurface])
    let otherRecord = TaskInboxFixture.makeRecord(directory: other, surfaceIDs: [otherSurface])
    state.taskRecords = [mineRecord, otherRecord]
    state.applyPostReduceCacheRecomputes(.all)
    let store = makeStore(state, sandbox: sandbox)

    let structureBefore = store.state.tasksSidebarStructure
    let otherLeafBefore = store.state.taskLeaves[id: otherRecord.id]

    await store.send(
      .tasks(
        .agentSnapshotChanged(
          taskID: mineRecord.id,
          snapshot: .init(agents: [.init(agent: .claude, activity: .busy)], isWorking: true)
        )
      )
    )
    await store.finish()

    #expect(store.state.taskLeaves[id: mineRecord.id]?.childAgents.map(\.agent) == [.claude])
    #expect(store.state.taskLeaves[id: otherRecord.id] == otherLeafBefore)
    #expect(store.state.taskLeaves[id: otherRecord.id]?.childAgents.isEmpty == true)
    #expect(store.state.tasksSidebarStructure == structureBefore)
  }
}

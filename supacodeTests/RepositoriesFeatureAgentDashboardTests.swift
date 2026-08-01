import ComposableArchitecture
import Foundation
import IdentifiedCollections
import Testing

@testable import SupacodeSettingsShared
@testable import supacode

/// Coverage for `RepositoriesFeature.State.computeAgentDashboardStructure()`:
/// activity → state mapping, triage ordering, custom-title fallback, the
/// per-(worktree, agent) collapse, and the empty case.
@MainActor
struct RepositoriesFeatureAgentDashboardTests {
  private let repoRoot = URL(fileURLWithPath: "/tmp/dash-repo")

  private func makeWorktree(id: String, name: String) -> Worktree {
    Worktree(
      id: WorktreeID(id),
      name: name,
      detail: "",
      workingDirectory: URL(fileURLWithPath: id),
      repositoryRootURL: repoRoot
    )
  }

  private func makeState(worktrees: [Worktree]) -> RepositoriesFeature.State {
    let repository = Repository(
      id: RepositoryID(repoRoot.path(percentEncoded: false)),
      rootURL: repoRoot,
      name: "dash-repo",
      worktrees: IdentifiedArray(uniqueElements: worktrees)
    )
    var state = RepositoriesFeature.State(reconciledRepositories: [repository])
    state.isInitialLoadComplete = true
    return state
  }

  private func setAgents(
    _ state: inout RepositoriesFeature.State,
    id: Worktree.ID,
    _ agents: [AgentPresenceFeature.AgentInstance]
  ) {
    state.sidebarItems[id: id]?.agentSnapshot.agents = agents
  }

  // MARK: - Empty case.

  @Test func noAgentsProducesEmptyStructure() {
    let alpha = makeWorktree(id: "/tmp/dash-repo/alpha", name: "alpha")
    let state = makeState(worktrees: [alpha])

    // `spaces` still lists the repository, so compare the agent list only.
    #expect(state.computeAgentDashboardStructure().entries.isEmpty)
  }

  // MARK: - Activity mapping.

  @Test(
    arguments: [
      (AgentPresenceFeature.Activity.awaitingInput, AgentDashboardState.blocked),
      (.busy, .working),
      (.compacting, .working),
      (.idle, .idle),
      (.error, .blocked),
    ]
  )
  func activityMapsToDashboardState(
    activity: AgentPresenceFeature.Activity,
    expected: AgentDashboardState
  ) {
    let alpha = makeWorktree(id: "/tmp/dash-repo/alpha", name: "alpha")
    var state = makeState(worktrees: [alpha])
    setAgents(&state, id: alpha.id, [.init(agent: .claude, activity: activity)])

    let entries = state.computeAgentDashboardStructure().entries
    #expect(entries.count == 1)
    #expect(entries.first?.state == expected)
    #expect(entries.first?.hasError == (activity == .error))
    #expect(entries.first?.worktreeID == alpha.id)
    #expect(entries.first?.agent == .claude)
  }

  // MARK: - Ordering.

  @Test func ordersBlockedThenWorkingThenIdle() {
    let alpha = makeWorktree(id: "/tmp/dash-repo/alpha", name: "alpha")
    let bravo = makeWorktree(id: "/tmp/dash-repo/bravo", name: "bravo")
    let charlie = makeWorktree(id: "/tmp/dash-repo/charlie", name: "charlie")
    var state = makeState(worktrees: [alpha, bravo, charlie])
    setAgents(&state, id: alpha.id, [.init(agent: .claude, activity: .idle)])
    setAgents(&state, id: bravo.id, [.init(agent: .claude, activity: .busy)])
    setAgents(&state, id: charlie.id, [.init(agent: .claude, activity: .awaitingInput)])

    let entries = state.computeAgentDashboardStructure().entries
    #expect(entries.map(\.worktreeID) == [charlie.id, bravo.id, alpha.id])
    #expect(entries.map(\.state) == [.blocked, .working, .idle])
  }

  @Test func tiesBreakByTitleThenAgentRawValue() {
    let alpha = makeWorktree(id: "/tmp/dash-repo/alpha", name: "alpha")
    let bravo = makeWorktree(id: "/tmp/dash-repo/bravo", name: "bravo")
    var state = makeState(worktrees: [alpha, bravo])
    setAgents(
      &state,
      id: bravo.id,
      [.init(agent: .pi, activity: .busy), .init(agent: .claude, activity: .busy)]
    )
    setAgents(&state, id: alpha.id, [.init(agent: .codex, activity: .busy)])

    let entries = state.computeAgentDashboardStructure().entries
    #expect(entries.map(\.title) == ["alpha", "bravo", "bravo"])
    #expect(entries.map(\.agent) == [.codex, .claude, .pi])
  }

  // MARK: - Display fields.

  @Test func customTitleWinsOverWorktreeName() {
    let alpha = makeWorktree(id: "/tmp/dash-repo/alpha", name: "alpha")
    var state = makeState(worktrees: [alpha])
    state.sidebarItems[id: alpha.id]?.customTitle = "Reviewer"
    setAgents(&state, id: alpha.id, [.init(agent: .claude, activity: .busy)])

    #expect(state.computeAgentDashboardStructure().entries.first?.title == "Reviewer")
  }

  @Test func whitespaceOnlyCustomTitleFallsBackToName() {
    let alpha = makeWorktree(id: "/tmp/dash-repo/alpha", name: "alpha")
    var state = makeState(worktrees: [alpha])
    state.sidebarItems[id: alpha.id]?.customTitle = "   "
    setAgents(&state, id: alpha.id, [.init(agent: .claude, activity: .busy)])

    #expect(state.computeAgentDashboardStructure().entries.first?.title == "alpha")
  }

  @Test func subtitleCombinesRepositoryTitleAndBranch() {
    let alpha = makeWorktree(id: "/tmp/dash-repo/alpha", name: "alpha")
    var state = makeState(worktrees: [alpha])
    state.sidebarItems[id: alpha.id]?.branchName = "feature/dash"
    setAgents(&state, id: alpha.id, [.init(agent: .claude, activity: .busy)])

    #expect(state.computeAgentDashboardStructure().entries.first?.subtitle == "dash-repo · feature/dash")
  }

  // MARK: - Collapse duplicates.

  @Test func sameAgentOnTwoSurfacesCollapsesToWorstState() {
    let alpha = makeWorktree(id: "/tmp/dash-repo/alpha", name: "alpha")
    var state = makeState(worktrees: [alpha])
    setAgents(
      &state,
      id: alpha.id,
      [.init(agent: .claude, activity: .idle), .init(agent: .claude, activity: .awaitingInput)]
    )

    let entries = state.computeAgentDashboardStructure().entries
    #expect(entries.count == 1)
    #expect(entries.first?.state == .blocked)
  }

  @Test func errorOnAnySurfaceMarksEntryAsError() {
    let alpha = makeWorktree(id: "/tmp/dash-repo/alpha", name: "alpha")
    var state = makeState(worktrees: [alpha])
    setAgents(
      &state,
      id: alpha.id,
      [.init(agent: .claude, activity: .busy), .init(agent: .claude, activity: .error)]
    )

    let entries = state.computeAgentDashboardStructure().entries
    #expect(entries.count == 1)
    #expect(entries.first?.hasError == true)
    #expect(entries.first?.state == .blocked)
  }

  // MARK: - Exclusions.

  @Test func terminatingRowsAreExcluded() {
    let alpha = makeWorktree(id: "/tmp/dash-repo/alpha", name: "alpha")
    var state = makeState(worktrees: [alpha])
    setAgents(&state, id: alpha.id, [.init(agent: .claude, activity: .busy)])
    state.sidebarItems[id: alpha.id]?.lifecycle = .deleting

    #expect(state.computeAgentDashboardStructure().entries.isEmpty)
  }

  @Test func missingRowsAreExcluded() {
    let alpha = makeWorktree(id: "/tmp/dash-repo/alpha", name: "alpha")
    var state = makeState(worktrees: [alpha])
    setAgents(&state, id: alpha.id, [.init(agent: .claude, activity: .busy)])
    state.sidebarItems[id: alpha.id]?.isMissing = true

    #expect(state.computeAgentDashboardStructure().entries.isEmpty)
  }

  // MARK: - Done-until-seen.

  @Test func idleAgentWithUnseenFinishMapsToDone() {
    let alpha = makeWorktree(id: "/tmp/dash-repo/alpha", name: "alpha")
    var state = makeState(worktrees: [alpha])
    setAgents(&state, id: alpha.id, [.init(agent: .claude, activity: .idle, isDoneUnseen: true)])

    #expect(state.computeAgentDashboardStructure().entries.first?.state == .done)
  }

  @Test func doneUnseenOnlyPromotesIdleAgents() {
    let alpha = makeWorktree(id: "/tmp/dash-repo/alpha", name: "alpha")
    var state = makeState(worktrees: [alpha])
    setAgents(&state, id: alpha.id, [.init(agent: .claude, activity: .busy, isDoneUnseen: true)])

    #expect(state.computeAgentDashboardStructure().entries.first?.state == .working)
  }

  @Test func doneSortsAfterWorkingAndBeforeIdle() {
    let alpha = makeWorktree(id: "/tmp/dash-repo/alpha", name: "alpha")
    let bravo = makeWorktree(id: "/tmp/dash-repo/bravo", name: "bravo")
    let charlie = makeWorktree(id: "/tmp/dash-repo/charlie", name: "charlie")
    var state = makeState(worktrees: [alpha, bravo, charlie])
    setAgents(&state, id: alpha.id, [.init(agent: .claude, activity: .idle)])
    setAgents(&state, id: bravo.id, [.init(agent: .claude, activity: .idle, isDoneUnseen: true)])
    setAgents(&state, id: charlie.id, [.init(agent: .claude, activity: .busy)])

    let entries = state.computeAgentDashboardStructure().entries
    #expect(entries.map(\.state) == [.working, .done, .idle])
  }

  // MARK: - Grouped projection.

  @Test func flatModeProducesNoSections() {
    let alpha = makeWorktree(id: "/tmp/dash-repo/alpha", name: "alpha")
    var state = makeState(worktrees: [alpha])
    setAgents(&state, id: alpha.id, [.init(agent: .claude, activity: .busy)])

    #expect(state.computeAgentDashboardStructure(groupByState: false).sections.isEmpty)
  }

  @Test func groupedModeOrdersSectionsAndOmitsEmptyOnes() {
    let alpha = makeWorktree(id: "/tmp/dash-repo/alpha", name: "alpha")
    let bravo = makeWorktree(id: "/tmp/dash-repo/bravo", name: "bravo")
    let charlie = makeWorktree(id: "/tmp/dash-repo/charlie", name: "charlie")
    var state = makeState(worktrees: [alpha, bravo, charlie])
    setAgents(&state, id: alpha.id, [.init(agent: .claude, activity: .idle, isDoneUnseen: true)])
    setAgents(&state, id: bravo.id, [.init(agent: .claude, activity: .awaitingInput)])
    setAgents(
      &state,
      id: charlie.id,
      [.init(agent: .claude, activity: .busy), .init(agent: .codex, activity: .busy)]
    )

    let sections = state.computeAgentDashboardStructure(groupByState: true).sections
    #expect(sections.map(\.state) == [.blocked, .working, .done])
    #expect(sections.map(\.count) == [1, 2, 1])
    #expect(sections.last?.entries.map(\.worktreeID) == [alpha.id])
  }

  @Test func groupedModeWithNoAgentsHasNoSections() {
    let alpha = makeWorktree(id: "/tmp/dash-repo/alpha", name: "alpha")
    let state = makeState(worktrees: [alpha])

    #expect(state.computeAgentDashboardStructure(groupByState: true).sections.isEmpty)
  }

  // MARK: - Spaces panel.

  @Test func spacesListsRepositoryWithWorktreeCountAndNoStateWhenAgentless() {
    let alpha = makeWorktree(id: "/tmp/dash-repo/alpha", name: "alpha")
    let bravo = makeWorktree(id: "/tmp/dash-repo/bravo", name: "bravo")
    let state = makeState(worktrees: [alpha, bravo])

    let spaces = state.computeAgentDashboardStructure().spaces
    #expect(spaces.map(\.title) == ["dash-repo"])
    #expect(spaces.first?.worktreeCount == 2)
    #expect(spaces.first?.state == nil)
  }

  @Test func spacesRollUpWorstStateAcrossWorktrees() {
    let alpha = makeWorktree(id: "/tmp/dash-repo/alpha", name: "alpha")
    let bravo = makeWorktree(id: "/tmp/dash-repo/bravo", name: "bravo")
    var state = makeState(worktrees: [alpha, bravo])
    setAgents(&state, id: alpha.id, [.init(agent: .claude, activity: .idle)])
    setAgents(&state, id: bravo.id, [.init(agent: .claude, activity: .busy)])

    #expect(state.computeAgentDashboardStructure().spaces.first?.state == .working)

    setAgents(&state, id: alpha.id, [.init(agent: .claude, activity: .awaitingInput)])
    #expect(state.computeAgentDashboardStructure().spaces.first?.state == .blocked)
  }

  @Test func spacesRollupPrefersDoneOverIdle() {
    let alpha = makeWorktree(id: "/tmp/dash-repo/alpha", name: "alpha")
    let bravo = makeWorktree(id: "/tmp/dash-repo/bravo", name: "bravo")
    var state = makeState(worktrees: [alpha, bravo])
    setAgents(&state, id: alpha.id, [.init(agent: .claude, activity: .idle)])
    setAgents(&state, id: bravo.id, [.init(agent: .claude, activity: .idle, isDoneUnseen: true)])

    #expect(state.computeAgentDashboardStructure().spaces.first?.state == .done)
  }

  @Test func spacesWorktreeCountExcludesMissingRows() {
    let alpha = makeWorktree(id: "/tmp/dash-repo/alpha", name: "alpha")
    let bravo = makeWorktree(id: "/tmp/dash-repo/bravo", name: "bravo")
    var state = makeState(worktrees: [alpha, bravo])
    state.sidebarItems[id: bravo.id]?.isMissing = true

    #expect(state.computeAgentDashboardStructure().spaces.first?.worktreeCount == 1)
  }

  // MARK: - Cache wiring.

  @Test func recomputeStoresStructureOnState() {
    let alpha = makeWorktree(id: "/tmp/dash-repo/alpha", name: "alpha")
    var state = makeState(worktrees: [alpha])
    setAgents(&state, id: alpha.id, [.init(agent: .claude, activity: .busy)])

    state.applyCacheRecomputes(.sidebarStructure)

    #expect(state.agentDashboardStructure.entries.map(\.agent) == [.claude])
  }

  /// `defaultAppStorage = .inMemory` so the toggle write doesn't leak into the
  /// process-global UserDefaults the rest of the suite reads.
  @Test func groupByStateToggleDrivesRecompute() async {
    let alpha = makeWorktree(id: "/tmp/dash-repo/alpha", name: "alpha")
    var state = makeState(worktrees: [alpha])
    setAgents(&state, id: alpha.id, [.init(agent: .claude, activity: .busy)])

    await withDependencies {
      $0.defaultAppStorage = .inMemory
    } operation: {
      @Shared(.sidebarAgentsGroupByState) var groupByState
      state.applyCacheRecomputes(.sidebarStructure)
      #expect(state.agentDashboardStructure.sections.isEmpty)

      $groupByState.withLock { $0 = true }
      state.applyCacheRecomputes(.sidebarStructure)
      #expect(state.agentDashboardStructure.sections.map(\.state) == [.working])
    }
  }

  // MARK: - Agent names.

  @Test func nameReplacesTheAgentKindInTheRowTitle() {
    let alpha = makeWorktree(id: "/tmp/dash-repo/alpha", name: "alpha")
    var state = makeState(worktrees: [alpha])
    setAgents(&state, id: alpha.id, [.init(agent: .claude, activity: .busy, name: "reviewer")])

    let entry = state.computeAgentDashboardStructure().entries.first
    #expect(entry?.name == "reviewer")
    #expect(entry?.displayName == "reviewer")
    // The kind moves to the subtitle so a named row still says what it runs.
    #expect(entry?.subtitle == "dash-repo · alpha · Claude Code")
  }

  @Test func unnamedRowsKeepTheAgentDisplayName() {
    let alpha = makeWorktree(id: "/tmp/dash-repo/alpha", name: "alpha")
    var state = makeState(worktrees: [alpha])
    setAgents(&state, id: alpha.id, [.init(agent: .claude, activity: .busy)])

    let entry = state.computeAgentDashboardStructure().entries.first
    #expect(entry?.displayName == "Claude Code")
    #expect(entry?.subtitle == "dash-repo · alpha")
  }

  @Test func collapsedSurfacesShareTheFirstName() {
    // One agent kind on two surfaces of a worktree renders as one row, so the
    // named instance's name must survive the collapse.
    let alpha = makeWorktree(id: "/tmp/dash-repo/alpha", name: "alpha")
    var state = makeState(worktrees: [alpha])
    setAgents(
      &state,
      id: alpha.id,
      [
        .init(agent: .claude, activity: .idle),
        .init(agent: .claude, activity: .busy, name: "reviewer"),
      ]
    )

    let entries = state.computeAgentDashboardStructure().entries
    #expect(entries.count == 1)
    #expect(entries.first?.name == "reviewer")
    #expect(entries.first?.state == .working)
  }

  // MARK: - Metadata tokens.

  @Test func summaryTokenRidesOntoTheEntryWithoutTouchingState() {
    let alpha = makeWorktree(id: "/tmp/dash-repo/alpha", name: "alpha")
    var state = makeState(worktrees: [alpha])
    setAgents(
      &state,
      id: alpha.id,
      [.init(agent: .claude, activity: .busy, name: "reviewer", summary: "fixing tests")]
    )

    let entry = state.computeAgentDashboardStructure().entries.first
    #expect(entry?.summary == "fixing tests")
    // A token is display-only: state and the Spaces rollup ignore it.
    #expect(entry?.state == .working)
    #expect(state.computeAgentDashboardStructure().spaces.first?.state == .working)
  }

  @Test func rowsWithoutASummaryTokenCarryNoCaption() {
    let alpha = makeWorktree(id: "/tmp/dash-repo/alpha", name: "alpha")
    var state = makeState(worktrees: [alpha])
    setAgents(&state, id: alpha.id, [.init(agent: .claude, activity: .busy)])

    #expect(state.computeAgentDashboardStructure().entries.first?.summary == nil)
  }

  @Test func collapsedSurfacesShareTheFirstSummary() {
    let alpha = makeWorktree(id: "/tmp/dash-repo/alpha", name: "alpha")
    var state = makeState(worktrees: [alpha])
    setAgents(
      &state,
      id: alpha.id,
      [
        .init(agent: .claude, activity: .idle),
        .init(agent: .claude, activity: .busy, summary: "second surface"),
      ]
    )

    let entries = state.computeAgentDashboardStructure().entries
    #expect(entries.count == 1)
    #expect(entries.first?.summary == "second surface")
  }

  @Test func requestRenameAgentSeedsTheSheetWithOtherLiveNames() async {
    let alpha = makeWorktree(id: "/tmp/dash-repo/alpha", name: "alpha")
    let bravo = makeWorktree(id: "/tmp/dash-repo/bravo", name: "bravo")
    var state = makeState(worktrees: [alpha, bravo])
    setAgents(&state, id: alpha.id, [.init(agent: .claude, activity: .busy, name: "reviewer")])
    setAgents(&state, id: bravo.id, [.init(agent: .codex, activity: .busy, name: "builder")])
    state.agentDashboardStructure = state.computeAgentDashboardStructure()

    let entryID = AgentDashboardEntry.EntryID(worktreeID: alpha.id, agent: .claude)
    let store = TestStore(initialState: state) { RepositoriesFeature() }
    store.exhaustivity = .off

    await store.send(.requestRenameAgent(entryID))

    let sheet = store.state.agentRename
    #expect(sheet?.name == "reviewer")
    #expect(sheet?.agent == .claude)
    // Its own name is excluded, so re-saving it unchanged stays valid.
    #expect(sheet?.takenNames == ["builder"])
    #expect(sheet?.canSave == true)
  }

  @Test func renameSheetRejectsInvalidAndDuplicateNames() {
    var sheet = AgentRenameFeature.State(
      worktreeID: WorktreeID("/tmp/dash-repo/alpha"),
      agent: .claude,
      subject: "Claude Code in alpha",
      takenNames: ["builder"],
      name: "Reviewer"
    )
    #expect(!sheet.canSave)

    sheet.name = "builder"
    #expect(sheet.validationError == "Another running agent already uses that name.")

    sheet.name = " reviewer "
    #expect(sheet.canSave)
    #expect(sheet.resolvedName == "reviewer")

    // Empty input is the clear gesture, not an error.
    sheet.name = "  "
    #expect(sheet.canSave)
    #expect(sheet.resolvedName == nil)
  }

  @Test func renameSheetSaveDelegatesUpward() async {
    let state = AgentRenameFeature.State(
      worktreeID: WorktreeID("/tmp/dash-repo/alpha"),
      agent: .claude,
      subject: "Claude Code in alpha",
      takenNames: [],
      name: "reviewer"
    )
    let store = TestStore(initialState: state) { AgentRenameFeature() }

    await store.send(.saveButtonTapped)
    await store.receive(
      .delegate(.save(worktreeID: state.worktreeID, agent: .claude, name: "reviewer"))
    )
  }

  @Test func groupByStateChangedActionInvalidatesSidebarStructure() {
    #expect(
      RepositoriesFeature.Action.sidebarAgentsGroupByStateChanged.cacheInvalidations
        == .sidebarStructure
    )
  }
}

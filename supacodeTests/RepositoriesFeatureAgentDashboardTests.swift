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

    #expect(state.computeAgentDashboardStructure() == .empty)
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

    #expect(state.computeAgentDashboardStructure() == .empty)
  }

  @Test func missingRowsAreExcluded() {
    let alpha = makeWorktree(id: "/tmp/dash-repo/alpha", name: "alpha")
    var state = makeState(worktrees: [alpha])
    setAgents(&state, id: alpha.id, [.init(agent: .claude, activity: .busy)])
    state.sidebarItems[id: alpha.id]?.isMissing = true

    #expect(state.computeAgentDashboardStructure() == .empty)
  }

  // MARK: - Cache wiring.

  @Test func recomputeStoresStructureOnState() {
    let alpha = makeWorktree(id: "/tmp/dash-repo/alpha", name: "alpha")
    var state = makeState(worktrees: [alpha])
    setAgents(&state, id: alpha.id, [.init(agent: .claude, activity: .busy)])

    state.applyCacheRecomputes(.sidebarStructure)

    #expect(state.agentDashboardStructure.entries.map(\.agent) == [.claude])
  }
}

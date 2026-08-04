import ComposableArchitecture
import Foundation
import IdentifiedCollections
import Sharing
import Testing

@testable import SupacodeSettingsShared
@testable import supacode

/// Coverage for the tab-aware sidebar navigation chords: with the Agents panel on
/// screen, ⌃⌘↓/↑ and ⌃1…⌃0 move a focus-free highlight through
/// `agentDashboardStructure.entries`, ↵ jumps to the highlighted worktree, and a
/// row that disappears drops the highlight. Every test scopes
/// `defaultAppStorage = .inMemory`, since the active tab lives in app storage.
@MainActor
struct RepositoriesFeatureAgentKeyboardNavTests {
  private let repoRoot = URL(fileURLWithPath: "/tmp/nav-repo")

  private func makeWorktree(id: String, name: String) -> Worktree {
    Worktree(
      id: WorktreeID(id),
      name: name,
      detail: "",
      workingDirectory: URL(fileURLWithPath: id),
      repositoryRootURL: repoRoot
    )
  }

  /// Three worktrees, one agent each, spanning three triage states so the flat
  /// order also crosses section boundaries when grouping is on:
  /// charlie (blocked) → bravo (working) → alpha (idle).
  private func makeState() -> (RepositoriesFeature.State, [Worktree]) {
    let alpha = makeWorktree(id: "/tmp/nav-repo/alpha", name: "alpha")
    let bravo = makeWorktree(id: "/tmp/nav-repo/bravo", name: "bravo")
    let charlie = makeWorktree(id: "/tmp/nav-repo/charlie", name: "charlie")
    let repository = Repository(
      id: RepositoryID(repoRoot.path(percentEncoded: false)),
      rootURL: repoRoot,
      name: "nav-repo",
      worktrees: IdentifiedArray(uniqueElements: [alpha, bravo, charlie])
    )
    var state = RepositoriesFeature.State(reconciledRepositories: [repository])
    state.isInitialLoadComplete = true
    state.sidebarItems[id: alpha.id]?.agentSnapshot.agents = [.init(agent: .claude, activity: .idle)]
    state.sidebarItems[id: bravo.id]?.agentSnapshot.agents = [.init(agent: .claude, activity: .busy)]
    state.sidebarItems[id: charlie.id]?.agentSnapshot.agents = [
      .init(agent: .claude, activity: .awaitingInput)
    ]
    state.applyPostReduceCacheRecomputes(.sidebarStructure)
    return (state, [charlie, bravo, alpha])
  }

  private func entryID(_ worktreeID: Worktree.ID) -> AgentDashboardEntry.EntryID {
    AgentDashboardEntry.EntryID(worktreeID: worktreeID, agent: .claude)
  }

  private func withTab<T>(_ tab: SidebarTab, _ body: () async throws -> T) async rethrows -> T {
    try await withDependencies {
      $0.defaultAppStorage = .inMemory
    } operation: {
      @Shared(.sidebarTab) var sidebarTabRawValue
      $sidebarTabRawValue.withLock { $0 = tab.rawValue }
      return try await body()
    }
  }

  private func makeStore(_ state: RepositoriesFeature.State) -> TestStoreOf<RepositoriesFeature> {
    TestStore(initialState: state) { RepositoriesFeature() }
  }

  // MARK: - Flat-order movement.

  @Test func nextMovesDownTheFlatOrderAcrossSections() async {
    let (state, order) = makeState()
    await withTab(.agents) {
      let store = makeStore(state)

      await store.send(.selectNextWorktree) {
        $0.agentDashboardSelection = self.entryID(order[0].id)
      }
      await store.send(.selectNextWorktree) {
        $0.agentDashboardSelection = self.entryID(order[1].id)
      }
      await store.send(.selectNextWorktree) {
        $0.agentDashboardSelection = self.entryID(order[2].id)
      }
      // Wraps, exactly like worktree arrow navigation.
      await store.send(.selectNextWorktree) {
        $0.agentDashboardSelection = self.entryID(order[0].id)
      }
    }
  }

  @Test func previousEntersFromTheBottomAndWraps() async {
    let (state, order) = makeState()
    await withTab(.agents) {
      let store = makeStore(state)

      await store.send(.selectPreviousWorktree) {
        $0.agentDashboardSelection = self.entryID(order[2].id)
      }
      await store.send(.selectPreviousWorktree) {
        $0.agentDashboardSelection = self.entryID(order[1].id)
      }
      await store.send(.selectPreviousWorktree) {
        $0.agentDashboardSelection = self.entryID(order[0].id)
      }
      await store.send(.selectPreviousWorktree) {
        $0.agentDashboardSelection = self.entryID(order[2].id)
      }
    }
  }

  /// No agents at all: the chord beeps and leaves the highlight empty.
  @Test func movementWithoutAgentsLeavesSelectionEmpty() async {
    var (state, _) = makeState()
    for id in state.sidebarItems.ids {
      state.sidebarItems[id: id]?.agentSnapshot.agents = []
    }
    state.applyPostReduceCacheRecomputes(.sidebarStructure)

    await withTab(.agents) {
      let store = makeStore(state)
      await store.send(.selectNextWorktree)
      #expect(store.state.agentDashboardSelection == nil)
    }
  }

  // MARK: - Tab awareness.

  /// Agents tab: the chord must not touch the worktree selection, and must not
  /// send the terminal-focusing `.selectWorktree`.
  @Test func agentsTabLeavesWorktreeSelectionUntouched() async {
    let (state, order) = makeState()
    await withTab(.agents) {
      let store = makeStore(state)

      await store.send(.selectNextWorktree) {
        $0.agentDashboardSelection = self.entryID(order[0].id)
      }
      #expect(store.state.selectedWorktreeID == nil)
    }
  }

  /// Worktrees tab: unchanged behavior — the worktree moves, the agent highlight
  /// stays put.
  @Test func worktreesTabMovesWorktreeSelectionOnly() async {
    let (state, _) = makeState()
    await withTab(.worktrees) {
      let store = makeStore(state)
      let firstSlot = state.sidebarStructure.hotkeySlots.first?.id
      #expect(firstSlot != nil)

      await store.send(.selectNextWorktree)
      await store.receive(\.selectWorktree) {
        $0.selection = .worktree(firstSlot!)
        $0.sidebarSelectedWorktreeIDs = [firstSlot!]
        $0.worktreeMRU = [firstSlot!]
        $0.applyPostReduceCacheRecomputes([.selectedWorktreeSlice, .sidebarSelectionSlice])
      }
      await store.receive(\.delegate.selectedWorktreeChanged)
      await store.receive(\.sidebarItems[id: firstSlot!].focusTerminalRequested) {
        $0.sidebarItems[id: firstSlot!]?.shouldFocusTerminal = true
      }

      #expect(store.state.agentDashboardSelection == nil)
    }
  }

  // MARK: - ⌃1…⌃0 slots.

  @Test func hotkeySlotSelectsNthVisibleAgentRow() async {
    let (state, order) = makeState()
    await withTab(.agents) {
      let store = makeStore(state)

      await store.send(.selectWorktreeAtHotkeySlot(1)) {
        $0.agentDashboardSelection = self.entryID(order[1].id)
      }
      #expect(store.state.selectedWorktreeID == nil)
    }
  }

  @Test func hotkeySlotBeyondTheAgentListIsANoOp() async {
    let (state, _) = makeState()
    await withTab(.agents) {
      let store = makeStore(state)
      await store.send(.selectWorktreeAtHotkeySlot(7))
      #expect(store.state.agentDashboardSelection == nil)
    }
  }

  // MARK: - ↵ activation.

  @Test func returnJumpsToTheHighlightedWorktreeAndFocusesIt() async {
    var (state, order) = makeState()
    state.agentDashboardSelection = entryID(order[0].id)
    let target = order[0].id

    await withTab(.agents) {
      let store = makeStore(state)

      await store.send(.activateAgentDashboardSelection)
      await store.receive(\.activateAgentDashboardEntry)
      await store.receive(\.selectionChanged) {
        $0.selection = .worktree(target)
        $0.sidebarSelectedWorktreeIDs = [target]
        $0.worktreeMRU = [target]
        $0.applyPostReduceCacheRecomputes([.selectedWorktreeSlice, .sidebarSelectionSlice])
      }
      // The focus request the click path also sends.
      await store.receive(\.sidebarItems[id: target].focusTerminalRequested) {
        $0.sidebarItems[id: target]?.shouldFocusTerminal = true
      }
      await store.receive(\.delegate.selectedWorktreeChanged)
    }
  }

  @Test func returnWithoutAHighlightDoesNothing() async {
    let (state, _) = makeState()
    await withTab(.agents) {
      let store = makeStore(state)
      await store.send(.activateAgentDashboardSelection)
    }
  }

  // MARK: - Disappearing rows.

  @Test func highlightIsDroppedWhenItsRowDisappears() {
    var (state, order) = makeState()
    let vanishing = order[0].id
    state.agentDashboardSelection = entryID(vanishing)

    // The agent finished and stopped reporting: its row leaves the dashboard.
    state.sidebarItems[id: vanishing]?.agentSnapshot.agents = []
    state.applyPostReduceCacheRecomputes(.sidebarStructure)

    #expect(state.agentDashboardSelection == nil)
  }

  @Test func highlightSurvivesARecomputeThatKeepsTheRow() {
    var (state, order) = makeState()
    state.agentDashboardSelection = entryID(order[0].id)

    state.applyPostReduceCacheRecomputes(.sidebarStructure)

    #expect(state.agentDashboardSelection == entryID(order[0].id))
  }
}

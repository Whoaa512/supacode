import ComposableArchitecture
import Foundation
import IdentifiedCollections
import Sharing
import Testing

@testable import SupacodeSettingsShared
@testable import supacode

/// Coverage for the tab-aware sidebar navigation chords: with the Agents panel on
/// screen, ⌃⌘↓/↑ and ⌃1…⌃0 walk `agentDashboardStructure.entries` and jump the
/// main view to each row's worktree as they go — same contract as the Worktrees
/// tab — ↵ activates the selected row, and a row that disappears drops the
/// selection. Every test scopes `defaultAppStorage = .inMemory`, since the active
/// tab lives in app storage.
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

  /// Movement now fans out into the full jump chain (activate → selectionChanged →
  /// focus request → delegate). Walking it exhaustively per step would bury the
  /// contract under MRU bookkeeping, so these send non-exhaustively and assert the
  /// two things that matter: where the selection landed and which worktree the
  /// main view is showing. `focusesTheTerminalOnMove` pins the focus request.
  private func expectJump(
    _ store: TestStoreOf<RepositoriesFeature>,
    _ action: RepositoriesFeature.Action,
    to worktreeID: Worktree.ID
  ) async {
    await store.send(action)
    await store.receive(\.selectionChanged)
    #expect(store.state.agentDashboardSelection == entryID(worktreeID))
    #expect(store.state.selectedWorktreeID == worktreeID)
  }

  // MARK: - Flat-order movement.

  @Test func nextMovesDownTheFlatOrderAcrossSections() async {
    let (state, order) = makeState()
    await withTab(.agents) {
      let store = makeStore(state)
      store.exhaustivity = .off

      await expectJump(store, .selectNextWorktree, to: order[0].id)
      await expectJump(store, .selectNextWorktree, to: order[1].id)
      await expectJump(store, .selectNextWorktree, to: order[2].id)
      // Wraps, exactly like worktree arrow navigation.
      await expectJump(store, .selectNextWorktree, to: order[0].id)
    }
  }

  @Test func previousEntersFromTheBottomAndWraps() async {
    let (state, order) = makeState()
    await withTab(.agents) {
      let store = makeStore(state)
      store.exhaustivity = .off

      await expectJump(store, .selectPreviousWorktree, to: order[2].id)
      await expectJump(store, .selectPreviousWorktree, to: order[1].id)
      await expectJump(store, .selectPreviousWorktree, to: order[0].id)
      await expectJump(store, .selectPreviousWorktree, to: order[2].id)
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

  /// Agents tab: one chord both moves the selection and lands focus on the row's
  /// terminal, so triage never needs a second keystroke.
  @Test func focusesTheTerminalOnMove() async {
    let (state, order) = makeState()
    let target = order[0].id
    await withTab(.agents) {
      let store = makeStore(state)

      await store.send(.selectNextWorktree)
      await store.receive(\.activateAgentDashboardEntry) {
        $0.agentDashboardSelection = self.entryID(target)
      }
      await store.receive(\.selectionChanged) {
        $0.selection = .worktree(target)
        $0.sidebarSelectedWorktreeIDs = [target]
        $0.worktreeMRU = [target]
        $0.applyPostReduceCacheRecomputes([.selectedWorktreeSlice, .sidebarSelectionSlice])
      }
      await store.receive(\.sidebarItems[id: target].focusTerminalRequested) {
        $0.sidebarItems[id: target]?.shouldFocusTerminal = true
      }
      await store.receive(\.delegate.selectedWorktreeChanged)
    }
  }

  /// Worktrees tab: unchanged behavior — the worktree moves, the agent selection
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

  @Test func hotkeySlotJumpsToNthVisibleAgentRow() async {
    let (state, order) = makeState()
    await withTab(.agents) {
      let store = makeStore(state)
      store.exhaustivity = .off

      await expectJump(store, .selectWorktreeAtHotkeySlot(1), to: order[1].id)
    }
  }

  /// The slot mapping the ⌘-held hint badges render must agree with the chord
  /// that fires, or the hints lie.
  @Test func slotByIDMatchesTheFlatVisualOrder() {
    let (state, order) = makeState()
    let slots = state.agentDashboardStructure.slotByID

    #expect(slots.count == order.count)
    for (index, worktree) in order.enumerated() {
      #expect(slots[entryID(worktree.id)] == index)
      #expect(state.agentDashboardEntryID(atSlot: index) == entryID(worktree.id))
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

  @Test func returnJumpsToTheSelectedWorktreeAndFocusesIt() async {
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

  @Test func returnWithoutASelectionDoesNothing() async {
    let (state, _) = makeState()
    await withTab(.agents) {
      let store = makeStore(state)
      await store.send(.activateAgentDashboardSelection)
    }
  }

  // MARK: - Disappearing rows.

  @Test func selectionIsDroppedWhenItsRowDisappears() {
    var (state, order) = makeState()
    let vanishing = order[0].id
    state.agentDashboardSelection = entryID(vanishing)

    // The agent finished and stopped reporting: its row leaves the dashboard.
    state.sidebarItems[id: vanishing]?.agentSnapshot.agents = []
    state.applyPostReduceCacheRecomputes(.sidebarStructure)

    #expect(state.agentDashboardSelection == nil)
  }

  @Test func selectionSurvivesARecomputeThatKeepsTheRow() {
    var (state, order) = makeState()
    state.agentDashboardSelection = entryID(order[0].id)

    state.applyPostReduceCacheRecomputes(.sidebarStructure)

    #expect(state.agentDashboardSelection == entryID(order[0].id))
  }
}

import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import Testing

@testable import SupacodeSettingsFeature
@testable import SupacodeSettingsShared
@testable import supacode

/// `supacode agent prompt|send-keys|resume` when the agent's surface sits in a
/// task other than the one its directory shows: the bytes have to go through
/// the task that holds the surface.
@MainActor
struct AppFeatureAgentTaskTests {
  private struct Sent: Equatable {
    let layoutID: LayoutID
    let surfaceID: UUID
    let text: String
  }

  private let worktree = Worktree(
    id: WorktreeID("/tmp/repo/wt-1"),
    name: "wt-1",
    detail: "detail",
    workingDirectory: URL(fileURLWithPath: "/tmp/repo/wt-1"),
    repositoryRootURL: URL(fileURLWithPath: "/tmp/repo"),
  )
  /// The task the directory shows.
  private let shown = LayoutID(task: UUID(uuidString: "00000000-0000-0000-0000-0000000000B1")!)
  /// A second task on the same directory; the agent runs here.
  private let other = LayoutID(task: UUID(uuidString: "00000000-0000-0000-0000-0000000000B2")!)
  private let shownSurface = UUID()
  private let agentSurface = UUID()
  private let enter = AgentKeySequence.sequence(for: "enter") ?? "\r"

  private var key: AgentPresenceFeature.PresenceKey { .init(agent: .claude, surfaceID: agentSurface) }

  private func layout(_ id: LayoutID, surface: UUID) -> LayoutFeature.State {
    let pane = PaneID()
    let item = TabItem(
      id: TabID(rawValue: UUID()), title: "Tab",
      content: ContentSnapshot(
        id: ContentID(rawValue: surface), state: .terminal(TerminalContentState(workingDirectory: nil))))
    return LayoutFeature.State(
      id: id,
      layout: PaneLayout(tree: SplitTree(view: pane), panes: [Pane(id: pane, tabs: [item], selectedTabID: item.id)]))
  }

  private func state() -> AppFeature.State {
    var repositories = RepositoriesFeature.State()
    repositories.repositories = [
      Repository(id: "/tmp/repo", rootURL: URL(fileURLWithPath: "/tmp/repo"), name: "repo", worktrees: [worktree])
    ]
    repositories.selection = .worktree(worktree.id)
    repositories.isInitialLoadComplete = true
    repositories.reconcileSidebarForTesting()
    repositories.sidebarItems[id: worktree.id]?.surfaceIDs = [shownSurface, agentSurface]
    var state = AppFeature.State(repositories: repositories, settings: SettingsFeature.State())
    state.terminals.layouts = [layout(shown, surface: shownSurface), layout(other, surface: agentSurface)]
    state.terminals.directories[shown] = TaskRecord.Directory(worktreeID: worktree.id)
    state.terminals.directories[other] = TaskRecord.Directory(worktreeID: worktree.id)
    state.terminals.activeTasks[worktree.id] = shown
    return state
  }

  private func running() -> AppFeature.State {
    var state = state()
    state.agentPresence.records[key] = AgentPresenceFeature.PresenceRecord(pids: [1])
    return state
  }

  private func resumable() -> AppFeature.State {
    var state = state()
    state.agentPresence.resumeCandidates[key] = .init(sessionRef: "abc-123", lastActivity: .idle)
    return state
  }

  /// A surface takes bytes only through the task that holds it, as in the
  /// app. `live: false` is a surface that has gone away or is dormant.
  private func makeStore(
    _ initial: AppFeature.State, live: Bool = true
  ) -> (store: TestStoreOf<AppFeature>, sent: LockIsolated<[Sent]>) {
    let sent = LockIsolated<[Sent]>([])
    let (other, agentSurface) = (other, agentSurface)
    let store = TestStore(initialState: initial) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.sendTextToSurface = { layoutID, surfaceID, text in
        sent.withValue { $0.append(Sent(layoutID: layoutID, surfaceID: surfaceID, text: text)) }
        return live && layoutID == other && surfaceID == agentSurface
      }
    }
    store.exhaustivity = .off
    return (store, sent)
  }

  private func send(_ action: Deeplink.AgentAction, to store: TestStoreOf<AppFeature>) async {
    await store.send(.deeplink(.agent(worktreeID: worktree.id, agent: "claude", action: action)))
    await store.finish()
  }

  private func expected(_ texts: String...) -> [Sent] {
    texts.map { Sent(layoutID: other, surfaceID: agentSurface, text: $0) }
  }

  @Test(.dependencies) func aPromptIsTypedThroughTheTaskThatHoldsTheAgent() async {
    let (store, sent) = makeStore(running())
    await send(.prompt(text: "hello", submit: true), to: store)
    await send(.prompt(text: "draft", submit: false), to: store)
    #expect(sent.value == expected("hello" + enter, "draft"))
    #expect(store.state.alert == nil)
  }

  @Test(.dependencies) func keysAreSentInOrderThroughTheTaskThatHoldsTheAgent() async {
    let (store, sent) = makeStore(running())
    await send(.sendKeys(keys: ["esc", "up", "enter"]), to: store)
    #expect(sent.value == expected("\u{1b}", "\u{1b}[A", "\r"))
    #expect(store.state.alert == nil)
  }

  @Test(.dependencies) func aResumeIsTypedThroughTheTaskThatHeldTheSession() async {
    let (store, sent) = makeStore(resumable())
    await store.send(.deeplink(.agent(worktreeID: worktree.id, agent: "claude", action: .resume)))
    await store.receive(\.agentPresence.resumeCandidateConsumed)
    #expect(sent.value == expected("claude --resume abc-123" + enter))
    #expect(store.state.alert == nil)
    #expect(store.state.agentPresence.resumeCandidates.isEmpty)
  }

  /// The user picked the agent's task or the other one; the terminal has not
  /// echoed it yet. The surface's own task still decides.
  @Test(.dependencies) func aSelectionNotYetEchoedDoesNotMoveTheAgentsBytes() async {
    for selected in [shown, other] {
      var initial = running()
      initial.repositories.selectedTask = SelectedTask(id: selected, directoryID: worktree.id)
      let (store, sent) = makeStore(initial)
      await send(.prompt(text: "hello", submit: false), to: store)
      #expect(sent.value == expected("hello"))
    }
  }

  @Test(.dependencies) func aPromptToASurfaceThatIsNoLongerLiveIsRefused() async {
    let (store, sent) = makeStore(running(), live: false)
    await send(.prompt(text: "hello", submit: true), to: store)
    #expect(sent.value == expected("hello" + enter))
    #expect(store.state.alert != nil)
  }

  @Test(.dependencies) func keysToASurfaceThatIsNoLongerLiveStopAtTheFirst() async {
    let (store, sent) = makeStore(running(), live: false)
    await send(.sendKeys(keys: ["esc", "up", "enter"]), to: store)
    #expect(sent.value == expected("\u{1b}"))
    #expect(store.state.alert != nil)
  }

  @Test(.dependencies) func aResumeIntoASurfaceThatIsNoLongerLiveKeepsTheOffer() async {
    let (store, sent) = makeStore(resumable(), live: false)
    await send(.resume, to: store)
    #expect(sent.value == expected("claude --resume abc-123" + enter))
    #expect(store.state.alert != nil)
    #expect(store.state.agentPresence.resumeCandidates[key] != nil)
  }

  @Test(.dependencies) func aResumeIsRefusedWhileTheAgentRuns() async {
    var initial = resumable()
    initial.agentPresence.records[key] = AgentPresenceFeature.PresenceRecord(pids: [1])
    let (store, sent) = makeStore(initial)
    await send(.resume, to: store)
    #expect(sent.value.isEmpty)
    #expect(store.state.alert != nil)
  }
}

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
    _ initial: AppFeature.State, live: Bool = true, liveSurfaces: [LayoutID: UUID]? = nil
  ) -> (store: TestStoreOf<AppFeature>, sent: LockIsolated<[Sent]>) {
    let sent = LockIsolated<[Sent]>([])
    let liveSurfaces = liveSurfaces ?? [other: agentSurface]
    let store = TestStore(initialState: initial) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.sendTextToSurface = { layoutID, surfaceID, text in
        sent.withValue { $0.append(Sent(layoutID: layoutID, surfaceID: surfaceID, text: text)) }
        return live && liveSurfaces[layoutID] == surfaceID
      }
      // A rename or metadata report persists presence on a debounce.
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.continuousClock = ImmediateClock()
      $0.terminalClient.saveLayoutsWithAgents = { _ in }
    }
    store.exhaustivity = .off
    return (store, sent)
  }

  private func send(_ action: Deeplink.AgentAction, task: LayoutID? = nil, to store: TestStoreOf<AppFeature>) async {
    await store.send(.deeplink(.agent(worktreeID: worktree.id, agent: "claude", action: action, task: task)))
    await store.finish()
  }

  // MARK: - Two agents of one kind on one directory: the task tells them apart.

  private var shownKey: AgentPresenceFeature.PresenceKey { .init(agent: .claude, surfaceID: shownSurface) }

  /// A live `claude` in both tasks of the directory.
  private func twoRunning() -> AppFeature.State {
    var state = running()
    state.agentPresence.records[shownKey] = AgentPresenceFeature.PresenceRecord(pids: [2])
    return state
  }

  private var bothLive: [LayoutID: UUID] { [other: agentSurface, shown: shownSurface] }

  @Test(.dependencies) func aNamedTaskPicksItsAgentAmongTwoOfOneKind() async {
    let (store, sent) = makeStore(twoRunning(), liveSurfaces: bothLive)
    await send(.prompt(text: "to other", submit: false), task: other, to: store)
    await send(.prompt(text: "to shown", submit: false), task: shown, to: store)
    await send(.sendKeys(keys: ["esc"]), task: other, to: store)
    await send(.sendKeys(keys: ["up"]), task: shown, to: store)
    #expect(
      sent.value == [
        Sent(layoutID: other, surfaceID: agentSurface, text: "to other"),
        Sent(layoutID: shown, surfaceID: shownSurface, text: "to shown"),
        Sent(layoutID: other, surfaceID: agentSurface, text: "\u{1b}"),
        Sent(layoutID: shown, surfaceID: shownSurface, text: "\u{1b}[A"),
      ])
    #expect(store.state.alert == nil)
  }

  /// No task named: the shown task's agent, whichever the user picked.
  @Test(.dependencies) func withNoTaskNamedTheShownTasksAgentIsAddressed() async {
    var picked = twoRunning()
    picked.repositories.selectedTask = SelectedTask(id: other, directoryID: worktree.id)
    let (otherShown, sentOther) = makeStore(picked, liveSurfaces: bothLive)
    await send(.prompt(text: "hi", submit: false), to: otherShown)
    #expect(sentOther.value == [Sent(layoutID: other, surfaceID: agentSurface, text: "hi")])

    let (shownShown, sentShown) = makeStore(twoRunning(), liveSurfaces: bothLive)
    await send(.prompt(text: "hi", submit: false), to: shownShown)
    #expect(sentShown.value == [Sent(layoutID: shown, surfaceID: shownSurface, text: "hi")])
  }

  /// `shown` runs a claude; `other` has a dead one to resume. Named, the
  /// resume goes to its task; named at the running one it is refused; bare,
  /// the shown task's running agent refuses it, as today.
  @Test(.dependencies) func aResumeNamedAtATaskSeesThatTaskOnly() async {
    var initial = resumable()
    initial.agentPresence.records[shownKey] = AgentPresenceFeature.PresenceRecord(pids: [2])

    let (toOther, sentOther) = makeStore(initial)
    await toOther.send(.deeplink(.agent(worktreeID: worktree.id, agent: "claude", action: .resume, task: other)))
    await toOther.receive(\.agentPresence.resumeCandidateConsumed)
    #expect(sentOther.value == expected("claude --resume abc-123" + enter))
    #expect(toOther.state.agentPresence.resumeCandidates.isEmpty)
    #expect(toOther.state.alert == nil)

    let (toShown, sentShown) = makeStore(initial)
    await send(.resume, task: shown, to: toShown)
    #expect(sentShown.value.isEmpty)
    #expect(toShown.state.alert != nil, "already running")
    #expect(toShown.state.agentPresence.resumeCandidates[key] != nil)

    let (bare, sentBare) = makeStore(initial)
    await send(.resume, to: bare)
    #expect(sentBare.value.isEmpty)
    #expect(bare.state.alert != nil, "the directory has a running claude")
  }

  @Test(.dependencies) func aTaskOfAnotherDirectoryOrUnknownIsRefusedWithoutWidening() async {
    let elsewhere = LayoutID(task: UUID(uuidString: "00000000-0000-0000-0000-0000000000B3")!)
    var initial = resumable()
    initial.agentPresence.records[shownKey] = AgentPresenceFeature.PresenceRecord(pids: [2])
    initial.seedTask(elsewhere, on: "/tmp/repo/wt-2")
    for named in [elsewhere, LayoutID(task: UUID())] {
      let (store, sent) = makeStore(initial, liveSurfaces: bothLive)
      await send(.prompt(text: "hi", submit: true), task: named, to: store)
      await send(.resume, task: named, to: store)
      #expect(sent.value.isEmpty)
      #expect(store.state.alert != nil)
      #expect(store.state.agentPresence.resumeCandidates[key] != nil, "the offer is kept")
    }
  }

  @Test(.dependencies) func renameAndMetadataNamedAtATaskActOnItsPresenceKey() async {
    let (store, _) = makeStore(twoRunning(), liveSurfaces: bothLive)
    await store.send(
      .deeplink(.agent(worktreeID: worktree.id, agent: "claude", action: .rename(name: "builder"), task: other)))
    await store.receive(\.agentPresence.renameAgent)
    await store.finish()
    #expect(store.state.agentPresence.nameByKey[key] == "builder")
    #expect(store.state.agentPresence.nameByKey[shownKey] == nil)

    await store.send(
      .deeplink(
        .agent(
          worktreeID: worktree.id, agent: "claude", action: .metadata(tokens: ["summary": "x"], clear: false),
          task: shown)))
    await store.receive(\.agentPresence.reportMetadata)
    await store.finish()
    #expect(store.state.agentPresence.metadataByKey[shownKey]?["summary"] == "x")
    #expect(store.state.agentPresence.metadataByKey[key] == nil)
  }

  @Test func agentSurfacesAreNarrowedToTheTaskAndOrderedShownFirst() {
    var state = twoRunning()
    #expect(
      AppFeature.agentSurfaceIDs(worktreeID: worktree.id, task: nil, state: state).ids == [shownSurface, agentSurface])
    state.repositories.selectedTask = SelectedTask(id: other, directoryID: worktree.id)
    #expect(
      AppFeature.agentSurfaceIDs(worktreeID: worktree.id, task: nil, state: state).ids == [agentSurface, shownSurface])
    #expect(AppFeature.agentSurfaceIDs(worktreeID: worktree.id, task: other, state: state).ids == [agentSurface])
    #expect(
      AppFeature.agentSurfaceIDs(worktreeID: worktree.id, task: LayoutID(task: UUID()), state: state).error
        == "Task not found.")
    #expect(
      AppFeature.agentSurfaceIDs(worktreeID: "/tmp/nope", task: nil, state: state).error?.hasPrefix(
        "Worktree not found") == true)
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

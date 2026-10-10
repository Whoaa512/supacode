import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import Sharing
import Testing

@testable import SupacodeSettingsFeature
@testable import SupacodeSettingsShared
@testable import supacode

/// Merge and detach from the app's side: what is sent to the terminal layer,
/// what is refused with a toast, and what is shown once the tabs have moved.
/// The terminal layer's own move is simulated by the reducer action it sends.
@Suite(.serialized)
@MainActor
struct AppFeatureTaskTransferTests {
  private let task = LayoutID(task: UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!)
  private let otherTask = LayoutID(task: UUID(uuidString: "00000000-0000-0000-0000-0000000000A2")!)
  private let primarySurface = UUID(uuidString: "00000000-0000-0000-0000-0000000000B1")!
  private let secondSurface = UUID(uuidString: "00000000-0000-0000-0000-0000000000B2")!
  private let otherSurface = UUID(uuidString: "00000000-0000-0000-0000-0000000000B3")!
  private let now = Date(timeIntervalSince1970: 100)

  private var worktree: Worktree {
    Worktree(
      id: "/workspace", name: "workspace", detail: "",
      workingDirectory: URL(fileURLWithPath: "/workspace"),
      repositoryRootURL: URL(fileURLWithPath: "/workspace"))
  }

  private func key(_ ref: String) -> SessionKey { SessionKey(harness: .pi, sessionID: ref) }

  private func layout(_ id: LayoutID, surfaces: [UUID]) -> LayoutFeature.State {
    let paneID = PaneID()
    let tabs = surfaces.map {
      TabItem(
        id: TabID(rawValue: $0), title: "Tab",
        content: ContentSnapshot(
          id: ContentID(rawValue: $0), state: .terminal(TerminalContentState(workingDirectory: nil))))
    }
    return LayoutFeature.State(
      id: id,
      layout: PaneLayout(
        tree: SplitTree(view: paneID),
        panes: [Pane(id: paneID, tabs: IdentifiedArray(uniqueElements: tabs), selectedTabID: tabs[0].id)],
        focusedPaneID: paneID))
  }

  private func live(_ ref: String?, pid: pid_t = 11) -> AgentPresenceFeature.PresenceRecord {
    var record = AgentPresenceFeature.PresenceRecord(pids: [pid], sessionRef: ref)
    record.currentSessionPID = pid
    return record
  }

  /// `task` holds two tabs: the primary "a" on the first, `second` (if any)
  /// on the second. `otherTask` holds one tab running "other". Both are
  /// hydrated on the fixture directory with the stores loaded.
  private func state(second: AgentPresenceFeature.PresenceRecord? = nil) -> AppFeature.State {
    var repositories = RepositoriesFeature.State()
    repositories.$sessions = Shared(value: [:])
    repositories.$sidebar = Shared(value: SidebarState())
    repositories.repositories = [
      Repository(id: "/workspace", rootURL: worktree.workingDirectory, name: "workspace", worktrees: [worktree])
    ]
    repositories.selection = .worktree(worktree.id)
    repositories.isInitialLoadComplete = true
    repositories.sessionsStarted = true
    var state = AppFeature.State(repositories: repositories, settings: SettingsFeature.State())
    state.terminals.layouts = [
      layout(task, surfaces: [primarySurface, secondSurface]), layout(otherTask, surfaces: [otherSurface]),
    ]
    let directory = TaskRecord.Directory(worktreeID: worktree.id)
    state.terminals.directories = [task: directory, otherTask: directory]
    state.agentPresence.records[.init(agent: .pi, surfaceID: primarySurface)] = live("a")
    state.agentPresence.records[.init(agent: .pi, surfaceID: otherSurface)] = live("other", pid: 31)
    var members: [TaskMember] = [.session(key("a"))]
    if let second {
      state.agentPresence.records[.init(agent: .pi, surfaceID: secondSurface)] = second
      members.append(
        second.sessionRef.map { .session(key($0)) } ?? .provisional(harness: .pi, surfaceID: secondSurface))
    }
    state.terminals.members = [task: members, otherTask: [.session(key("other"))]]
    state.terminals.storedSessions = .loaded
    state.terminals.layoutsLoaded = true
    state.terminals.selectedLayoutID = task
    return state
  }

  private struct Recorded {
    let commands = LockIsolated<[TerminalClient.Command]>([])
    let toasts = LockIsolated<[String]>([])

    var transfers: [TerminalClient.Command] {
      commands.value.filter { if case .transferTabs = $0 { true } else { false } }
    }
    var shown: [LayoutID] {
      commands.value.compactMap {
        guard case .ensureInitialTab(let layoutID, _, _, _) = $0 else { return nil }
        return layoutID
      }
    }
  }

  private func store(_ initial: AppFeature.State, recorded: Recorded) -> TestStoreOf<AppFeature> {
    let store = TestStore(initialState: initial) {
      AppFeature()
    } withDependencies: {
      $0.date.now = now
      $0.uuid = .incrementing
      // Never advanced: a refusal's toast stays up to be read.
      $0.continuousClock = TestClock()
      $0.terminalClient.send = { command in recorded.commands.withValue { $0.append(command) } }
      $0.terminalClient.focusSurface = { _, _, _, _ in }
      $0.terminalClient.markUserCloseIntent = { _, _ in }
      $0.terminalClient.saveLayoutsWithAgents = { _ in }
      $0.worktreeInfoWatcher.send = { _ in }
      $0[LayoutChangeObserver.self].sessionsChanged = { _ in }
      $0[ContentSessionKiller.self] = ContentSessionKiller(kill: { _, _ in })
      $0[LayoutContentFactory.self] = LayoutContentFactory { request in
        InertTabContent(id: request.contentID, state: request.content)
      }
    }
    store.exhaustivity = .off
    return store
  }

  private func send(_ action: AppFeature.Action, to store: TestStoreOf<AppFeature>) async {
    await store.send(action)
    await store.finish()
    await store.skipReceivedActions(strict: false)
  }

  private func expectToast(
    _ text: String, in store: TestStoreOf<AppFeature>, sourceLocation: SourceLocation = #_sourceLocation
  ) async {
    await store.receive(\.repositories.showToast)
    #expect(store.state.repositories.statusToast == .info(text), sourceLocation: sourceLocation)
  }

  /// What the terminal layer does when it accepts the command.
  private func simulateTransfer(_ command: TerminalClient.Command, in store: TestStoreOf<AppFeature>) async {
    guard case .transferTabs(let from, let into, let context, let scope) = command else { return }
    if scope != .all {
      await send(
        .terminals(
          .attachLayout(
            worktreeID: into, directory: TaskRecord.Directory(worktreeID: context.worktreeID, host: context.host),
            titlePrefix: context.name)), to: store)
    }
    await send(.terminals(.transferTabs(from: from, into: into, scope: scope)), to: store)
    let sourceRemoved =
      store.state.terminals.layouts[id: from]?.layout.panes.isEmpty == true
      && store.state.terminals.members[from] == nil
    if sourceRemoved { await send(.terminals(.detachLayout(worktreeID: from)), to: store) }
    let tabIDs: [TabID] =
      if case .tab(let tabID, _) = scope { [tabID] } else {
        [TabID(rawValue: primarySurface), TabID(rawValue: secondSurface)]
      }
    await send(
      .terminalEvent(.tabsTransferred(from: from, into: into, tabIDs: tabIDs, sourceRemoved: sourceRemoved)), to: store)
  }

  // MARK: - Merge (A28, A30)

  @Test(.dependencies) func mergeSendsOneCommandWithTheTargetsContextAndSelectsTheTarget() async throws {
    let recorded = Recorded()
    let store = store(state(second: live("b", pid: 12)), recorded: recorded)

    await send(.mergeTask(task, into: otherTask), to: store)

    let command = try #require(recorded.transfers.first)
    guard case .transferTabs(let from, let into, let context, let scope) = command else { return }
    #expect(from == task && into == otherTask && scope == .all)
    #expect(context.worktreeID == worktree.id && context.host == nil)
    #expect(recorded.transfers.count == 1)

    await simulateTransfer(command, in: store)

    #expect(store.state.terminals.layouts[id: task] == nil)
    #expect(
      store.state.terminals.members[otherTask] == [.session(key("other")), .session(key("a")), .session(key("b"))])
    #expect(store.state.repositories.taskSessions[otherTask] == [key("other"), key("a"), key("b")])
    #expect(store.state.repositories.selectedTask?.id == otherTask)
    #expect(Set(recorded.shown) == [otherTask])
    #expect(store.state.agentPresence.records.count == 3, "presence is keyed by surface, which did not change")
    #expect(store.state.repositories.sessions[key("a")]?.settledAt == nil, "nothing is settled")
    let sent = recorded.commands.value.map { String(describing: $0).lowercased() }
    #expect(
      !sent.contains {
        $0.contains("close") || $0.contains("kill") || $0.contains("terminate") || $0.contains("settle")
      },
      "no close, kill or settle is sent for a moved surface")
  }

  @Test(.dependencies) func mergeOfAMergedTaskStaysFlat() async throws {
    let recorded = Recorded()
    var initial = state(second: live("b", pid: 12))
    let third = LayoutID(task: UUID(uuidString: "00000000-0000-0000-0000-0000000000A3")!)
    let thirdSurface = UUID(uuidString: "00000000-0000-0000-0000-0000000000B4")!
    initial.terminals.layouts.append(layout(third, surfaces: [thirdSurface]))
    initial.terminals.directories[third] = TaskRecord.Directory(worktreeID: worktree.id)
    initial.agentPresence.records[.init(agent: .pi, surfaceID: thirdSurface)] = live("c", pid: 41)
    initial.terminals.members[third] = [.session(key("c"))]
    let store = store(initial, recorded: recorded)

    await send(.mergeTask(task, into: otherTask), to: store)
    await simulateTransfer(try #require(recorded.transfers.last), in: store)
    await send(.mergeTask(otherTask, into: third), to: store)
    await simulateTransfer(try #require(recorded.transfers.last), in: store)

    #expect(store.state.terminals.layouts.map(\.id) == [third])
    #expect(
      store.state.terminals.members == [
        third: [.session(key("c")), .session(key("other")), .session(key("a")), .session(key("b"))]
      ])
    #expect(store.state.terminals.layouts[id: third]?.layout.allContentIDs.count == 4)
    #expect(store.state.repositories.selectedTask?.id == third)
  }

  @Test(.dependencies) func mergeIntoItselfIsRefused() async {
    let recorded = Recorded()
    let store = store(state(), recorded: recorded)
    await store.send(.mergeTask(task, into: task))
    await expectToast("That task is no longer available.", in: store)
    #expect(recorded.transfers.isEmpty)
  }

  @Test(.dependencies) func mergeAcrossHostsIsRefused() async {
    let recorded = Recorded()
    var initial = state()
    initial.terminals.directories[otherTask] = TaskRecord.Directory(
      worktreeID: worktree.id, host: RemoteHost(alias: "box"))
    let store = store(initial, recorded: recorded)
    await store.send(.mergeTask(task, into: otherTask))
    await expectToast("Tasks on different hosts can't be merged.", in: store)
    #expect(recorded.transfers.isEmpty)
  }

  @Test(.dependencies) func mergeWhileALaunchIntoTheSourceIsPendingIsRefused() async {
    let recorded = Recorded()
    var initial = state()
    initial.pendingTaskLaunches = [PendingTaskLaunch(layoutID: task, directoryID: worktree.id)]
    let store = store(initial, recorded: recorded)
    await store.send(.mergeTask(task, into: otherTask))
    await expectToast("A session is still starting in this task.", in: store)
    #expect(recorded.transfers.isEmpty)
  }

  @Test(.dependencies) func mergeWithACloseConfirmationPendingIsRefused() async {
    let recorded = Recorded()
    var initial = state()
    initial.terminals.layouts[id: otherTask]?.alert = AlertState { TextState("Close?") }
    let store = store(initial, recorded: recorded)
    await store.send(.mergeTask(task, into: otherTask))
    await expectToast("Answer the close confirmation first.", in: store)
    #expect(recorded.transfers.isEmpty)
  }

  @Test(.dependencies) func mergeBeforeTheStoreIsReadyIsRefused() async {
    let recorded = Recorded()
    var initial = state()
    initial.terminals.layoutsLoaded = false
    let store = store(initial, recorded: recorded)
    await store.send(.mergeTask(task, into: otherTask))
    await expectToast("Tasks are still loading.", in: store)
    #expect(recorded.transfers.isEmpty)
  }

  @Test(.dependencies) func mergeTheRuntimeRefusedToastsAndSelectsNothing() async {
    let recorded = Recorded()
    let store = store(state(), recorded: recorded)
    await send(.mergeTask(task, into: otherTask), to: store)
    #expect(recorded.transfers.count == 1)

    await store.send(.terminalEvent(.tabsTransferFailed(from: task, into: otherTask, reason: .scriptRunning)))
    await expectToast("Wait for the running script to finish.", in: store)

    #expect(store.state.repositories.selectedTask == nil)
    #expect(recorded.shown.isEmpty)
    #expect(store.state.terminals.layouts.count == 2)
  }

  // MARK: - Detach (A29, A30)

  @Test(.dependencies) func detachMintsATaskForTheTabAndItsSession() async throws {
    let recorded = Recorded()
    let store = store(state(second: live("b", pid: 12)), recorded: recorded)

    await send(.detachTab(task, tabID: TabID(rawValue: secondSurface)), to: store)

    let command = try #require(recorded.transfers.first)
    guard case .transferTabs(let from, let minted, let context, let scope) = command else { return }
    #expect(from == task)
    #expect(minted != task && minted != otherTask, "a fresh id")
    #expect(context.worktreeID == worktree.id, "the source's directory")
    #expect(scope == .tab(TabID(rawValue: secondSurface), members: [.session(key("b"))]))

    await simulateTransfer(command, in: store)

    #expect(store.state.terminals.members[task] == [.session(key("a"))])
    #expect(store.state.terminals.members[minted] == [.session(key("b"))])
    #expect(store.state.repositories.taskSessions[task] == [key("a")])
    #expect(store.state.repositories.taskSessions[minted] == [key("b")])
    #expect(store.state.terminals.layouts[id: minted]?.layout.allContentIDs.map(\.rawValue) == [secondSurface])
    #expect(store.state.terminals.layouts[id: task]?.layout.allContentIDs.map(\.rawValue) == [primarySurface])
    #expect(store.state.repositories.selectedTask?.id == minted)
    #expect(Set(recorded.shown) == [minted])
    #expect(store.state.repositories.sessions[key("b")]?.settledAt == nil)
  }

  @Test(.dependencies) func detachOfAProvisionalMemberOnTheTabMovesIt() async throws {
    let recorded = Recorded()
    let store = store(state(second: live(nil, pid: 12)), recorded: recorded)
    await send(.detachTab(task, tabID: TabID(rawValue: secondSurface)), to: store)
    let command = try #require(recorded.transfers.first)
    guard case .transferTabs(_, _, _, let scope) = command else { return }
    #expect(
      scope == .tab(TabID(rawValue: secondSurface), members: [.provisional(harness: .pi, surfaceID: secondSurface)]))
  }

  @Test(.dependencies) func detachOfAShellTabMakesAShellOnlyTask() async throws {
    let recorded = Recorded()
    let store = store(state(), recorded: recorded)
    await send(.detachTab(task, tabID: TabID(rawValue: secondSurface)), to: store)
    let command = try #require(recorded.transfers.first)
    guard case .transferTabs(_, let minted, _, let scope) = command else { return }
    #expect(scope == .tab(TabID(rawValue: secondSurface), members: []))

    await simulateTransfer(command, in: store)

    #expect(store.state.terminals.members[minted] == nil)
    #expect(store.state.terminals.members[task] == [.session(key("a"))])
    #expect(store.state.repositories.selectedTask?.id == minted)
    #expect(store.state.repositories.sessionItems[id: .task(minted)] != nil, "a shell-only task has a row")
  }

  @Test(.dependencies) func detachingThePrimarysTabIsRefused() async {
    let recorded = Recorded()
    let store = store(state(second: live("b", pid: 12)), recorded: recorded)
    await store.send(.detachTab(task, tabID: TabID(rawValue: primarySurface)))
    await expectToast("The primary session can't be detached. Merge the other way instead.", in: store)
    #expect(recorded.transfers.isEmpty)
    #expect(store.state.terminals.layouts.count == 2)
  }

  @Test(.dependencies) func detachingTheOnlyTabOfAShellOnlyTaskIsRefused() async {
    let recorded = Recorded()
    var initial = state()
    initial.terminals.members[otherTask] = nil
    initial.agentPresence.records[.init(agent: .pi, surfaceID: otherSurface)] = nil
    let store = store(initial, recorded: recorded)
    await store.send(.detachTab(otherTask, tabID: TabID(rawValue: otherSurface)))
    await expectToast("This is the task's only tab.", in: store)
    #expect(recorded.transfers.isEmpty)
  }

  @Test(.dependencies) func detachOfATabThatIsNotThereIsRefused() async {
    let recorded = Recorded()
    let store = store(state(), recorded: recorded)
    await store.send(.detachTab(task, tabID: TabID(rawValue: otherSurface)))
    await expectToast("That task is no longer available.", in: store)
    #expect(recorded.transfers.isEmpty)
  }

  @Test(.dependencies) func detachThatNeverHappenedSelectsNothing() async {
    let recorded = Recorded()
    let store = store(state(second: live("b", pid: 12)), recorded: recorded)
    await send(.detachTab(task, tabID: TabID(rawValue: secondSurface)), to: store)
    guard case .transferTabs(_, let minted, _, _) = recorded.transfers.first else { return }

    await store.send(.terminalEvent(.tabsTransferFailed(from: task, into: minted, reason: .layoutRejected)))
    await expectToast("That task is no longer available.", in: store)

    #expect(store.state.repositories.selectedTask == nil)
    #expect(recorded.shown.isEmpty, "nothing is bootstrapped into the id that was never attached")
  }

  @Test(.dependencies) func detachFocusedTabUsesTheFocusedPanesSelectedTab() async throws {
    let recorded = Recorded()
    var initial = state(second: live("b", pid: 12))
    initial.terminals.layouts[id: task]?.layout.panes[0].selectedTabID = TabID(rawValue: secondSurface)
    let store = store(initial, recorded: recorded)
    await send(.detachFocusedTab, to: store)
    let command = try #require(recorded.transfers.first)
    guard case .transferTabs(let from, _, _, let scope) = command else { return }
    #expect(from == task)
    #expect(scope == .tab(TabID(rawValue: secondSurface), members: [.session(key("b"))]))
  }

  @Test(.dependencies) func detachFocusedTabWithNoShownTaskToasts() async {
    let recorded = Recorded()
    var initial = state()
    initial.terminals.selectedLayoutID = nil
    let store = store(initial, recorded: recorded)
    await store.send(.detachFocusedTab)
    await expectToast("That task is no longer available.", in: store)
    #expect(recorded.transfers.isEmpty)
  }

  @Test(.dependencies) func aSessionReportedAfterTheMenuOpenedMovesWithItsTab() {
    var state = state(second: live(nil, pid: 12))
    #expect(AppFeature.sessions(onSurface: secondSurface, state: state).isEmpty)
    #expect(
      AppFeature.members(onSurface: secondSurface, of: task, state: state) == [
        .provisional(harness: .pi, surfaceID: secondSurface)
      ])

    state.agentPresence.records[.init(agent: .pi, surfaceID: secondSurface)] = live("b", pid: 12)
    state.terminals.members[task] = [.session(key("a")), .session(key("b"))]

    #expect(AppFeature.sessions(onSurface: secondSurface, state: state) == [key("b")])
    #expect(AppFeature.members(onSurface: secondSurface, of: task, state: state) == [.session(key("b"))])
  }
}

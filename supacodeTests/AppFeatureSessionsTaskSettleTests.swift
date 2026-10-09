import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import Sharing
import Testing

@testable import SupacodeSettingsFeature
@testable import SupacodeSettingsShared
@testable import supacode

/// Replacement, quit and settle at the level of a task.
@Suite(.serialized)
@MainActor
struct AppFeatureSessionsTaskSettleTests {
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

  private func key(_ ref: String, _ harness: SkillAgent = .pi) -> SessionKey {
    SessionKey(harness: harness, sessionID: ref)
  }

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
        panes: [Pane(id: paneID, tabs: IdentifiedArray(uniqueElements: tabs), selectedTabID: tabs[0].id)]))
  }

  /// The task's two tabs, one per pane.
  private func splitIntoTwoPanes(_ state: AppFeature.State) throws -> AppFeature.State {
    var state = state
    let first = try #require(state.terminals.layouts[id: task]?.layout.panes.first)
    let moved = try #require(first.tabs[id: TabID(rawValue: secondSurface)])
    let paneID = PaneID()
    var kept = first
    kept.tabs.remove(id: moved.id)
    state.terminals.layouts[id: task]?.layout = PaneLayout(
      tree: try SplitTree(view: first.id).inserting(view: paneID, at: first.id, direction: .right),
      panes: [kept, Pane(id: paneID, tabs: [moved], selectedTabID: moved.id)],
      focusedPaneID: first.id)
    return state
  }

  private func confirmClose(_ mode: ConfirmCloseTabMode) {
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global.confirmCloseTab = mode }
  }

  private func live(_ ref: String?, pid: pid_t? = 11) -> AgentPresenceFeature.PresenceRecord {
    var record = AgentPresenceFeature.PresenceRecord(pids: pid.map { [$0] } ?? [], sessionRef: ref)
    record.currentSessionPID = pid
    return record
  }

  /// A task with two tabs beside another task with one, all on the fixture
  /// directory. The primary runs on the first tab; `second` is the agent on
  /// the second tab, if any; the other task always runs "other".
  private func state(
    primary: SkillAgent = .pi, primaryPID: pid_t? = 11, second: AgentPresenceFeature.PresenceRecord? = nil
  ) -> AppFeature.State {
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
    state.agentPresence.records[.init(agent: primary, surfaceID: primarySurface)] = live("a", pid: primaryPID)
    state.agentPresence.records[.init(agent: .pi, surfaceID: otherSurface)] = live("other", pid: 31)
    var members: [TaskMember] = [.session(key("a", primary))]
    if let second {
      state.agentPresence.records[.init(agent: .pi, surfaceID: secondSurface)] = second
      members.append(
        second.sessionRef.map { .session(key($0)) } ?? .provisional(harness: .pi, surfaceID: secondSurface))
    }
    state.terminals.members = [task: members, otherTask: [.session(key("other"))]]
    state.terminals.storedSessions = .loaded
    return withRows(state)
  }

  private func withRows(_ state: AppFeature.State) -> AppFeature.State {
    var state = state
    state.repositories.sessionSnapshots = AppFeature.sessionSnapshots(state: state)
    state.repositories.taskSnapshots = AppFeature.taskSnapshots(tasks: AppFeature.taskEntries(state: state))
    state.repositories.reconcileSessionItems(now: .distantPast)
    state.repositories.recomputeSessionsSidebarStructureIfChanged()
    return state
  }

  private struct Recorded {
    /// Every surface a close was requested for, the way Cmd-W would.
    let closed = LockIsolated<Set<UUID>>([])
    let written = LockIsolated<[LayoutID]>([])
    let focused = LockIsolated<[LayoutID]>([])
    let commands = LockIsolated<[TerminalClient.Command]>([])

    /// Every task shown through its row, with whatever it had focused.
    var shown: [LayoutID] {
      commands.value.compactMap {
        guard case .ensureInitialTab(let layoutID, _, _, _) = $0 else { return nil }
        return layoutID
      }
    }
  }

  private func store(
    _ initial: AppFeature.State, recorded: Recorded,
    isDescendant: @escaping @Sendable (pid_t, pid_t) -> Bool = { _, _ in false }
  ) -> TestStoreOf<AppFeature> {
    let store = TestStore(initialState: initial) {
      AppFeature()
    } withDependencies: {
      $0.date.now = now
      $0.uuid = .incrementing
      $0.continuousClock = ImmediateClock()
      $0.terminalClient.send = { command in recorded.commands.withValue { $0.append(command) } }
      $0.terminalClient.focusSurface = { layoutID, _, _, _ in recorded.focused.withValue { $0.append(layoutID) } }
      $0.terminalClient.markUserCloseIntent = { _, ids in recorded.closed.withValue { $0.formUnion(ids) } }
      $0.terminalClient.saveLayoutsWithAgents = { _ in }
      $0.worktreeInfoWatcher.send = { _ in }
      $0[LayoutChangeObserver.self].sessionsChanged = { id in recorded.written.withValue { $0.append(id) } }
      $0.processAncestry.isDescendant = isDescendant
      $0[ContentSessionKiller.self] = ContentSessionKiller(kill: { _, _ in })
      $0[LayoutContentFactory.self] = LayoutContentFactory { request in
        InertTabContent(id: request.contentID, state: request.content)
      }
    }
    store.exhaustivity = .off
    return store
  }

  private func send(
    _ event: String, on surface: UUID, ref: String?, pid: pid_t? = 11, reason: String? = nil, agent: String = "pi",
    to store: TestStoreOf<AppFeature>
  ) async {
    await store.send(
      .terminalEvent(
        .agentHookEventReceived(
          AgentHookEvent(
            agent: agent, event: event, surfaceID: surface, pid: pid, sessionRef: ref, shutdownReason: reason))))
    await store.finish()
    await store.skipReceivedActions(strict: false)
  }

  private func settledAt(_ ref: String, _ harness: SkillAgent = .pi, in store: TestStoreOf<AppFeature>) -> Date? {
    store.state.repositories.sessions[key(ref, harness)]?.settledAt
  }

  private func surfaces(of layoutID: LayoutID, in store: TestStoreOf<AppFeature>) -> [UUID] {
    store.state.terminals.layouts[id: layoutID]?.layout.allContentIDs.map(\.rawValue) ?? []
  }

  // MARK: - Replacement is not quit (A37)

  @Test(.dependencies, arguments: ["new", "fork", "resume", "swap"])
  func replacingThePrimaryKeepsTheTaskOpenAndPromotesTheNewSession(how: String) async {
    let recorded = Recorded()
    let store = store(state(second: live("b", pid: 12)), recorded: recorded)

    if how == "swap" {
      // A harness that reports the next session without ending the last.
      await send("busy", on: primarySurface, ref: "n", to: store)
    } else {
      await send("session_end", on: primarySurface, ref: "a", reason: how, to: store)
      #expect(store.state.terminals.members[task] == [.session(key("a")), .session(key("b"))])
      await send("session_start", on: primarySurface, ref: "n", to: store)
    }

    #expect(store.state.terminals.members[task] == [.session(key("n")), .session(key("a")), .session(key("b"))])
    #expect(AppFeature.primarySession(of: task, state: store.state) == key("n"))
    #expect(settledAt("a", in: store) == now, "the replaced session is marked")
    #expect(settledAt("n", in: store) == nil)
    #expect(settledAt("b", in: store) == nil)
    #expect(!AppFeature.isTaskSettled(task, state: store.state), "the task follows its current primary")
    #expect(recorded.closed.value.isEmpty, "no surface closes")
    #expect(surfaces(of: task, in: store) == [primarySurface, secondSurface])
    #expect(recorded.written.value.contains(task), "the new order is stored")
    #expect(store.state.terminals.members[otherTask] == [.session(key("other"))], "no other task changes")
    #expect(store.state.terminals.layouts.count == 2, "and none is minted")
    let row = store.state.repositories.sessionItems[id: .task(task)]
    #expect(row?.primary == key("n"), "the task's row follows its new primary")
    #expect(row?.lifecycle == .active)
    #expect(store.state.repositories.sessionItems[id: .implicit(key("a"))] == nil, "the replaced one has no row")
  }

  /// Presence takes a changed ref from any event, so the first event of the
  /// new session need not be a start or a busy.
  @Test(.dependencies, arguments: ["idle", "awaiting_input", "error", "notification"])
  func aReplacementFirstSeenOnAnotherEventStillTakesTheSlot(first: String) async {
    let recorded = Recorded()
    let store = store(state(second: live("b", pid: 12)), recorded: recorded)

    await send(first, on: primarySurface, ref: "n", to: store)
    await send("busy", on: primarySurface, ref: "n", to: store)

    #expect(store.state.terminals.members[task] == [.session(key("n")), .session(key("a")), .session(key("b"))])
    #expect(settledAt("a", in: store) == now, "the replaced session is marked")
    #expect(settledAt("n", in: store) == nil)
    #expect(!AppFeature.isTaskSettled(task, state: store.state))
    #expect(recorded.closed.value.isEmpty, "no surface closes")
    #expect(surfaces(of: task, in: store) == [primarySurface, secondSurface])
  }

  /// A remote agent's record can be seeded by an activity event alone.
  @Test(.dependencies) func aRemoteReplacementSeededByAnActivityEventTakesTheSlot() async {
    let recorded = Recorded()
    let store = store(state(primaryPID: nil, second: live("b", pid: 12)), recorded: recorded)

    await send("session_end", on: primarySurface, ref: "a", pid: nil, reason: "new", to: store)
    await send("awaiting_input", on: primarySurface, ref: "n", pid: nil, to: store)
    await send("busy", on: primarySurface, ref: "n", pid: nil, to: store)

    #expect(store.state.terminals.members[task] == [.session(key("n")), .session(key("a")), .session(key("b"))])
    #expect(settledAt("a", in: store) == now)
    #expect(recorded.closed.value.isEmpty)
    #expect(store.state.endedSessions.isEmpty)
  }

  @Test(.dependencies) func resumingThePreviousPrimaryAfterANewMakesItThePrimaryAgain() async {
    let recorded = Recorded()
    let store = store(state(second: live("b", pid: 12)), recorded: recorded)
    await send("session_end", on: primarySurface, ref: "a", reason: "new", to: store)
    await send("session_start", on: primarySurface, ref: "n", to: store)
    #expect(store.state.terminals.members[task] == [.session(key("n")), .session(key("a")), .session(key("b"))])

    await send("session_end", on: primarySurface, ref: "n", reason: "resume", to: store)
    await send("session_start", on: primarySurface, ref: "a", to: store)

    #expect(store.state.terminals.members[task] == [.session(key("a")), .session(key("n")), .session(key("b"))])
    #expect(AppFeature.primarySession(of: task, state: store.state) == key("a"))
    #expect(settledAt("a", in: store) == nil, "it is running again")
    #expect(settledAt("n", in: store) == now)
    #expect(!AppFeature.isTaskSettled(task, state: store.state), "the task follows the running primary")
    #expect(recorded.closed.value.isEmpty)
    #expect(surfaces(of: task, in: store) == [primarySurface, secondSurface])
  }

  @Test(.dependencies) func resumingADormantTangentOverThePrimaryPromotesIt() async {
    let recorded = Recorded()
    // "b" is a member with no agent running: the second tab is a shell.
    var initial = state()
    initial.terminals.members[task] = [.session(key("a")), .session(key("b")), .session(key("c"))]
    let store = store(withRows(initial), recorded: recorded)

    await send("session_end", on: primarySurface, ref: "a", reason: "resume", to: store)
    await send("session_start", on: primarySurface, ref: "c", to: store)

    #expect(store.state.terminals.members[task] == [.session(key("c")), .session(key("a")), .session(key("b"))])
    #expect(settledAt("a", in: store) == now)
    #expect(!AppFeature.isTaskSettled(task, state: store.state))
    #expect(recorded.closed.value.isEmpty)
  }

  @Test(.dependencies) func replacingATangentTakesItsSlotAndLeavesThePrimary() async {
    let recorded = Recorded()
    let store = store(state(second: live("b", pid: 12)), recorded: recorded)

    await send("session_end", on: secondSurface, ref: "b", pid: 12, reason: "new", to: store)
    await send("session_start", on: secondSurface, ref: "n", pid: 12, to: store)

    #expect(store.state.terminals.members[task] == [.session(key("a")), .session(key("n")), .session(key("b"))])
    #expect(AppFeature.primarySession(of: task, state: store.state) == key("a"))
    #expect(settledAt("b", in: store) == now)
    #expect(settledAt("a", in: store) == nil)
    #expect(settledAt("n", in: store) == nil)
    #expect(!AppFeature.isTaskSettled(task, state: store.state))
    #expect(recorded.closed.value.isEmpty)
  }

  @Test(.dependencies) func aSessionResumedInPlaceOfAnotherIsNoLongerMarkedSettled() async {
    let recorded = Recorded()
    var initial = state()
    initial.repositories.$sessions.withLock { $0[key("old")] = SessionSidecarEntry(settledAt: .distantPast) }
    let store = store(initial, recorded: recorded)

    await send("session_end", on: primarySurface, ref: "a", reason: "resume", to: store)
    await send("session_start", on: primarySurface, ref: "old", to: store)

    #expect(store.state.terminals.members[task] == [.session(key("old")), .session(key("a"))])
    #expect(settledAt("old", in: store) == nil, "it is the running primary now")
    #expect(!AppFeature.isTaskSettled(task, state: store.state))
  }

  // MARK: - Quit (A37)

  @Test(.dependencies) func thePrimaryQuittingAloneSettlesTheTask() async {
    confirmClose(.never)
    let recorded = Recorded()
    // The second tab is a plain shell.
    let store = store(state(), recorded: recorded)

    await send("session_end", on: primarySurface, ref: "a", reason: "quit", to: store)

    #expect(settledAt("a", in: store) == now)
    #expect(AppFeature.isTaskSettled(task, state: store.state))
    #expect(recorded.closed.value == [primarySurface, secondSurface], "every tab of the task, and no other")
    #expect(store.state.terminals.members[task] == [.session(key("a"))], "still there to reopen")
  }

  /// Until the stored sessions load, whichever agent reported first leads
  /// the run's list, and it may be a tangent of a stored primary.
  @Test(.dependencies) func aQuitBeforeTheStoredSessionsLoadClosesNothing() async {
    confirmClose(.never)
    let recorded = Recorded()
    var initial = state()
    initial.terminals.storedSessions = .pending
    let store = store(initial, recorded: recorded)

    await send("session_end", on: primarySurface, ref: "a", reason: "quit", to: store)

    #expect(settledAt("a", in: store) == now, "the ended session is still marked")
    #expect(recorded.closed.value.isEmpty)
    #expect(surfaces(of: task, in: store) == [primarySurface, secondSurface])
  }

  @Test(.dependencies, arguments: [true, false])
  func thePrimaryQuittingBesideARunningTangentSettlesNothing(tangentHasReported: Bool) async {
    let recorded = Recorded()
    let store = store(state(second: live(tangentHasReported ? "b" : nil, pid: 12)), recorded: recorded)

    await send("session_end", on: primarySurface, ref: "a", reason: "quit", to: store)

    #expect(store.state.repositories.sessions.isEmpty, "nothing settles")
    #expect(!AppFeature.isTaskSettled(task, state: store.state))
    #expect(recorded.closed.value.isEmpty)
    #expect(AppFeature.primarySession(of: task, state: store.state) == key("a"), "a dormant primary stays primary")
    #expect(store.state.agentPresence.records[.init(agent: .pi, surfaceID: primarySurface)] == nil)
  }

  /// A surface's record can track several processes of one harness. The one
  /// that quits must not take the others' tab with it.
  @Test(.dependencies) func thePrimaryQuittingBesideAnotherProcessOnItsOwnSurfaceClosesNothing() async {
    confirmClose(.never)
    let recorded = Recorded()
    var initial = state()
    let presenceKey = AgentPresenceFeature.PresenceKey(agent: .pi, surfaceID: primarySurface)
    initial.agentPresence.records[presenceKey]?.pids = [11, 12]
    initial.agentPresence.records[presenceKey]?.currentSessionPID = 12
    let store = store(initial, recorded: recorded)

    await send("session_end", on: primarySurface, ref: "a", pid: 12, reason: "quit", to: store)

    #expect(recorded.closed.value.isEmpty, "pid 11 still runs on the tab")
    #expect(surfaces(of: task, in: store) == [primarySurface, secondSurface])
    #expect(store.state.agentPresence.records[presenceKey]?.pids == [11])
    #expect(settledAt("a", in: store) == now, "the session that quit is over; only the mark says so")
    #expect(store.state.repositories.sessions.count == 1)
  }

  @Test(.dependencies) func aTangentQuittingSettlesNothing() async {
    let recorded = Recorded()
    let store = store(state(second: live("b", pid: 12)), recorded: recorded)

    await send("session_end", on: secondSurface, ref: "b", pid: 12, reason: "quit", to: store)

    #expect(store.state.repositories.sessions.isEmpty)
    #expect(recorded.closed.value.isEmpty)
    #expect(store.state.terminals.members[task] == [.session(key("a")), .session(key("b"))])
    #expect(AppFeature.primarySession(of: task, state: store.state) == key("a"))
  }

  /// Only a quit the harness names, from a process on this machine, closes
  /// tabs: Claude ends its session on `/clear` as well, and a remote end
  /// carries no process to tell a sub-agent from the surface's own agent.
  @Test(.dependencies, arguments: ["bare", "remote"])
  func anEndThatIsNotAPositivelyIdentifiedQuitClosesNothing(how: String) async {
    let recorded = Recorded()
    let harness: SkillAgent = how == "bare" ? .claude : .pi
    let pid: pid_t? = how == "bare" ? 11 : nil
    let store = store(state(primary: harness, primaryPID: pid), recorded: recorded)

    await send(
      "session_end", on: primarySurface, ref: "a", pid: pid, reason: how == "bare" ? nil : "quit",
      agent: harness.rawValue, to: store)

    #expect(settledAt("a", harness, in: store) == now, "the primary is marked, as before")
    #expect(recorded.closed.value.isEmpty)
    #expect(surfaces(of: task, in: store) == [primarySurface, secondSurface])
  }

  @Test(.dependencies) func aBareEndFollowedByANewSessionIsAReplacement() async {
    let recorded = Recorded()
    let store = store(state(primary: .claude), recorded: recorded)

    await send("session_end", on: primarySurface, ref: "a", agent: "claude", to: store)
    await send("session_start", on: primarySurface, ref: "n", agent: "claude", to: store)

    #expect(
      store.state.terminals.members[task] == [.session(key("n", .claude)), .session(key("a", .claude))])
    #expect(settledAt("a", .claude, in: store) == now)
    #expect(!AppFeature.isTaskSettled(task, state: store.state))
    #expect(recorded.closed.value.isEmpty)
  }

  @Test(.dependencies) func aNewAgentAfterANamedQuitIsNotAReplacement() async {
    let recorded = Recorded()
    let store = store(state(second: live("b", pid: 12)), recorded: recorded)

    await send("session_end", on: primarySurface, ref: "a", reason: "quit", to: store)
    await send("session_start", on: primarySurface, ref: "n", pid: 13, to: store)

    #expect(
      store.state.terminals.members[task] == [.session(key("a")), .session(key("b")), .session(key("n"))],
      "it joins as a tangent")
    #expect(store.state.repositories.sessions.isEmpty)
  }

  // MARK: - An agent inside the agent (workflow sub-agents)

  @Test(.dependencies) func aSubAgentStartingAndEndingLeavesTheSurfacesSessionAlone() async {
    let recorded = Recorded()
    var initial = state()
    initial.repositories.sessionSummaries = [
      SessionSummary(
        harness: .pi, sessionID: "a", createdAt: .distantPast, cwd: "/workspace", title: "Parent",
        messageCount: 9, lastActivity: now)
    ]
    initial = withRows(initial)
    // The child was started by the parent's process and inherits its surface.
    let store = store(initial, recorded: recorded) { pid, ancestor in pid == 22 && ancestor == 11 }
    let presenceKey = AgentPresenceFeature.PresenceKey(agent: .pi, surfaceID: primarySurface)
    let before = store.state.agentPresence.records[presenceKey]

    await send("session_start", on: primarySurface, ref: "child", pid: 22, to: store)
    await send("busy", on: primarySurface, ref: "child", pid: 22, to: store)
    await send("idle", on: primarySurface, ref: "child", pid: 22, to: store)
    await send("session_end", on: primarySurface, ref: "child", pid: 22, reason: "quit", to: store)

    #expect(store.state.agentPresence.records[presenceKey] == before, "the parent is still what runs there")
    #expect(store.state.terminals.members[task] == [.session(key("a"))], "still the primary, and the only member")
    #expect(store.state.repositories.sessions.isEmpty, "nothing settles")
    #expect(recorded.closed.value.isEmpty)
    let row = store.state.repositories.sessionItems[id: .task(task)]
    #expect(row?.title == "Parent")
    #expect(row?.primary == key("a"))
    #expect(row?.lifecycle == .active)
    #expect(row?.location?.surfaceID == primarySurface)
    #expect(store.state.repositories.sessionItems[id: .implicit(key("child"))] == nil)
    #expect(store.state.endedSessions.isEmpty)
  }

  /// The child need not be the parent's harness: Pi can start Claude.
  @Test(.dependencies) func aSubAgentOfAnotherHarnessLeavesTheSurfacesSessionAlone() async {
    let recorded = Recorded()
    let store = store(state(), recorded: recorded) { pid, ancestor in pid == 22 && ancestor == 11 }
    let presence = store.state.agentPresence

    await send("session_start", on: primarySurface, ref: "child", pid: 22, agent: "claude", to: store)
    await send("busy", on: primarySurface, ref: "child", pid: 22, agent: "claude", to: store)
    await send("idle", on: primarySurface, ref: "child", pid: 22, agent: "claude", to: store)
    await send("session_end", on: primarySurface, ref: "child", pid: 22, agent: "claude", to: store)

    #expect(store.state.agentPresence.records == presence.records, "no record for the child, the parent's untouched")
    #expect(store.state.terminals.members[task] == [.session(key("a"))], "the child is no member")
    #expect(store.state.repositories.sessions.isEmpty, "nothing settles")
    #expect(recorded.closed.value.isEmpty)
    #expect(store.state.branchCaptureQueue.isEmpty)
    #expect(!store.state.branchCaptureInFlight, "no branch is captured for it")
    #expect(store.state.repositories.sessionItems[id: .implicit(key("child", .claude))] == nil)
    #expect(store.state.endedSessions.isEmpty)
  }

  @Test(.dependencies) func aSiblingAgentOfAnotherHarnessIsStillItsOwnSession() async {
    let recorded = Recorded()
    let store = store(state(), recorded: recorded) { pid, ancestor in pid == 22 && ancestor == 11 }

    await send("session_start", on: primarySurface, ref: "sibling", pid: 23, agent: "claude", to: store)

    #expect(store.state.agentPresence.records[.init(agent: .claude, surfaceID: primarySurface)]?.pids == [23])
  }

  @Test func onlyAProcessStartedByTheRecordsOwnCountsAsNested() {
    let record = live("a", pid: 11)
    let event = { (pid: pid_t?) in
      AgentHookEvent(agent: "pi", event: "session_start", surfaceID: UUID(), pid: pid, sessionRef: "child")
    }
    let child: (pid_t, pid_t) -> Bool = { pid, ancestor in pid == 22 && ancestor == 11 }

    #expect(record.isFromNestedAgent(event(22), isDescendant: child))
    #expect(!record.isFromNestedAgent(event(23), isDescendant: child), "a sibling started from the shell")
    #expect(!record.isFromNestedAgent(event(11), isDescendant: { _, _ in true }), "the owner itself")
    #expect(!record.isFromNestedAgent(event(nil), isDescendant: { _, _ in true }), "no pid to check")
  }

  // MARK: - Manual settle (A19)

  @Test(.dependencies) func settlingATasksPrimaryClosesEveryTabAndMarksOnlyThePrimary() async {
    confirmClose(.never)
    let recorded = Recorded()
    let store = store(state(second: live("b", pid: 12)), recorded: recorded)

    await store.send(.repositories(.settleSessionRequested(key("a"))))
    await store.finish()

    #expect(recorded.closed.value == [primarySurface, secondSurface])
    #expect(settledAt("a", in: store) == now)
    #expect(settledAt("b", in: store) == nil)
    #expect(settledAt("other", in: store) == nil)
    #expect(AppFeature.isTaskSettled(task, state: store.state))
    #expect(!AppFeature.isTaskSettled(otherTask, state: store.state))
  }

  @Test(.dependencies) func settlingATangentsRowMarksAndClosesOnlyThatSession() async {
    let recorded = Recorded()
    let store = store(state(second: live("b", pid: 12)), recorded: recorded)

    await store.send(.repositories(.settleSessionRequested(key("b"))))
    await store.finish()

    #expect(recorded.closed.value == [secondSurface])
    #expect(settledAt("b", in: store) == now)
    #expect(settledAt("a", in: store) == nil)
    #expect(!AppFeature.isTaskSettled(task, state: store.state))
  }

  @Test(.dependencies) func aTaskIsSettledExactlyWhenItsCurrentPrimaryIs() {
    var state = state(second: live("b", pid: 12))
    #expect(!AppFeature.isTaskSettled(task, state: state))

    state.repositories.$sessions.withLock { $0[key("b")] = SessionSidecarEntry(settledAt: now) }
    #expect(!AppFeature.isTaskSettled(task, state: state), "a tangent's mark is its own")

    state.repositories.$sessions.withLock { $0[key("a")] = SessionSidecarEntry(settledAt: now) }
    #expect(AppFeature.isTaskSettled(task, state: state))

    state.terminals.members[task] = [.provisional(harness: .pi, surfaceID: primarySurface), .session(key("a"))]
    #expect(!AppFeature.isTaskSettled(task, state: state), "a primary that has not reported is not settled")
  }

  // MARK: - Close confirmation across panes (A19)

  @Test(.dependencies, arguments: [ConfirmCloseTabMode.always, .busy])
  func settlingATaskWithTwoPanesAsksOnceAndConfirmingClosesBoth(mode: ConfirmCloseTabMode) async throws {
    confirmClose(mode)
    let recorded = Recorded()
    let store = store(try splitIntoTwoPanes(state(second: live("b", pid: 12))), recorded: recorded)

    await store.send(.repositories(.settleSessionRequested(key("a"))))
    await store.finish()
    await store.skipReceivedActions(strict: false)

    let alert = try #require(store.state.terminals.layouts[id: task]?.alert)
    let confirm = try #require(alert.buttons.compactMap(\.action.action).first)
    #expect(
      confirm
        == .confirmCloseAll(tabs: [TabID(rawValue: primarySurface), TabID(rawValue: secondSurface)]),
      "one confirmation names both panes' tabs")
    #expect(settledAt("a", in: store) == nil, "nothing is settled until the answer")
    #expect(Set(surfaces(of: task, in: store)) == [primarySurface, secondSurface])

    await store.send(.terminals(.layouts(.element(id: task, action: .alert(.presented(confirm))))))
    await store.finish()
    await store.skipReceivedActions(strict: false)

    #expect(surfaces(of: task, in: store).isEmpty, "both panes closed, not only the last asked")
    #expect(settledAt("a", in: store) == now)
    #expect(AppFeature.isTaskSettled(task, state: store.state))
    #expect(surfaces(of: otherTask, in: store) == [otherSurface])
  }

  @Test(.dependencies) func confirmingAfterATabWasAddedAsksAgainAndSettlesOnlyOnceEveryTabCloses() async throws {
    confirmClose(.always)
    let recorded = Recorded()
    let store = store(try splitIntoTwoPanes(state(second: live("b", pid: 12))), recorded: recorded)
    let late = UUID(uuidString: "00000000-0000-0000-0000-0000000000B9")!

    await store.send(.repositories(.settleSessionRequested(key("a"))))
    await store.finish()
    await store.skipReceivedActions(strict: false)
    let alert = try #require(store.state.terminals.layouts[id: task]?.alert)
    let stale = try #require(alert.buttons.compactMap(\.action.action).first)
    let paneID = try #require(store.state.terminals.layouts[id: task]?.layout.panes.first?.id)
    await store.send(
      .terminals(
        .layouts(
          .element(
            id: task,
            action: .newTab(
              inPane: paneID,
              spec: NewTabSpec(
                tabID: TabID(rawValue: late), contentID: ContentID(rawValue: late), title: "Late",
                content: .terminal(TerminalContentState(workingDirectory: nil)), geometry: .fallback))))))
    await store.finish()
    await store.skipReceivedActions(strict: false)
    #expect(Set(surfaces(of: task, in: store)) == [primarySurface, secondSurface, late])
    recorded.closed.setValue([])

    await store.send(.terminals(.layouts(.element(id: task, action: .alert(.presented(stale))))))
    await store.finish()
    await store.skipReceivedActions(strict: false)

    #expect(Set(surfaces(of: task, in: store)) == [primarySurface, secondSurface, late], "the answer named two tabs")
    #expect(settledAt("a", in: store) == nil, "a task with a tab still open is not settled")
    #expect(!AppFeature.isTaskSettled(task, state: store.state))
    let again = try #require(store.state.terminals.layouts[id: task]?.alert)
    let fresh = try #require(again.buttons.compactMap(\.action.action).first)
    guard case .confirmCloseAll(let named) = fresh else {
      Issue.record("expected a close-all confirmation")
      return
    }
    #expect(Set(named.map(\.rawValue)) == [primarySurface, secondSurface, late], "asked again, for every tab")

    await store.send(.terminals(.layouts(.element(id: task, action: .alert(.presented(fresh))))))
    await store.finish()
    await store.skipReceivedActions(strict: false)

    #expect(surfaces(of: task, in: store).isEmpty)
    #expect(settledAt("a", in: store) == now)
    #expect(recorded.closed.value.contains(late), "the late tab closes as a user close too")
  }

  @Test(.dependencies) func cancellingTheTaskCloseConfirmationSettlesAndClosesNothing() async throws {
    confirmClose(.always)
    let recorded = Recorded()
    let store = store(try splitIntoTwoPanes(state(second: live("b", pid: 12))), recorded: recorded)

    await store.send(.repositories(.settleSessionRequested(key("a"))))
    await store.finish()
    await store.skipReceivedActions(strict: false)
    #expect(store.state.terminals.layouts[id: task]?.alert != nil)
    await store.send(.terminals(.layouts(.element(id: task, action: .alert(.dismiss)))))
    await store.finish()
    await store.skipReceivedActions(strict: false)

    #expect(store.state.terminals.layouts[id: task]?.alert == nil)
    #expect(Set(surfaces(of: task, in: store)) == [primarySurface, secondSurface])
    #expect(settledAt("a", in: store) == nil)
    #expect(!AppFeature.isTaskSettled(task, state: store.state))
  }

  @Test(.dependencies) func settlingATaskWithTwoPanesWithoutConfirmationClosesBoth() async throws {
    confirmClose(.never)
    let recorded = Recorded()
    let store = store(try splitIntoTwoPanes(state(second: live("b", pid: 12))), recorded: recorded)

    await store.send(.repositories(.settleSessionRequested(key("a"))))
    await store.finish()
    await store.skipReceivedActions(strict: false)

    #expect(surfaces(of: task, in: store).isEmpty)
    #expect(settledAt("a", in: store) == now)
    #expect(settledAt("b", in: store) == nil)
  }

  @Test(.dependencies) func aQuitMarksThePrimaryEvenWhileTheCloseConfirmationWaits() async throws {
    confirmClose(.always)
    let recorded = Recorded()
    let store = store(try splitIntoTwoPanes(state()), recorded: recorded)

    await send("session_end", on: primarySurface, ref: "a", reason: "quit", to: store)

    #expect(settledAt("a", in: store) == now, "the session is over whatever the answer")
    #expect(store.state.terminals.layouts[id: task]?.alert != nil)
    #expect(Set(surfaces(of: task, in: store)) == [primarySurface, secondSurface])
  }

  @Test(.dependencies) func settlingATaskWithNoTabsOpenOnlyMarksItsPrimary() async {
    let recorded = Recorded()
    var initial = state()
    initial.terminals.layouts.remove(id: task)
    let store = store(initial, recorded: recorded)

    await store.send(.repositories(.settleSessionRequested(key("a"))))
    await store.finish()
    await store.skipReceivedActions(strict: false)

    #expect(settledAt("a", in: store) == now)
    #expect(recorded.closed.value.isEmpty)
  }

  @Test(.dependencies) func settlingATaskRowClosesTheTaskItNamesWhenItsPrimaryLeadsAnother() async {
    confirmClose(.never)
    let recorded = Recorded()
    // Both tasks are led by "a"; by its key alone the settle would pick the first.
    var initial = state(second: live("b", pid: 12))
    initial.agentPresence.records[.init(agent: .pi, surfaceID: otherSurface)] = live("a", pid: 31)
    initial.terminals.members[otherTask] = [.session(key("a"))]
    initial = withRows(initial)
    #expect(AppFeature.taskLed(by: key("a"), state: initial) == task)
    let store = store(initial, recorded: recorded)

    await store.send(.repositories(.settleTaskRequested(otherTask)))
    await store.finish()
    await store.skipReceivedActions(strict: false)

    #expect(recorded.closed.value == [otherSurface])
    #expect(surfaces(of: otherTask, in: store).isEmpty)
    #expect(Set(surfaces(of: task, in: store)) == [primarySurface, secondSurface], "the other task is untouched")
    #expect(settledAt("a", in: store) == now)
    #expect(
      store.state.repositories.sessionItems[id: .task(task)]?.lifecycle == .active,
      "a task with tabs open is never shown settled")
  }

  // MARK: - Settle and advance

  @Test(.dependencies) func settleAndAdvanceLeavesTheSettledTaskForTheNextLiveOne() async {
    confirmClose(.never)
    let recorded = Recorded()
    // The task's row is current; its tangent has no row to advance onto.
    var initial = state(second: live("b", pid: 12))
    initial.repositories.sessionSelection = .task(task)
    let store = store(initial, recorded: recorded)
    let live = store.state.repositories.sessionsSidebarStructure.liveIDs
    #expect(Set(live) == [.task(task), .task(otherTask)])

    await store.send(.settleSessionAndAdvance)
    await store.finish()

    #expect(recorded.closed.value == [primarySurface, secondSurface])
    #expect(settledAt("a", in: store) == now)
    #expect(Set(recorded.shown) == [otherTask], "not the tangent whose tab is closing")
  }

  @Test(.dependencies) func settleAndAdvanceOnAShellOnlyTaskClosesItAndMovesOn() async {
    confirmClose(.never)
    let recorded = Recorded()
    var initial = state()
    initial.agentPresence.records[.init(agent: .pi, surfaceID: primarySurface)] = nil
    initial.terminals.members[task] = nil
    initial = withRows(initial)
    #expect(initial.repositories.sessionItems[id: .task(task)] != nil)
    initial.repositories.sessionSelection = .task(task)
    let store = store(initial, recorded: recorded)

    await store.send(.settleSessionAndAdvance)
    await store.finish()

    #expect(recorded.closed.value == [primarySurface, secondSurface])
    #expect(store.state.repositories.sessions.isEmpty, "a shell-only task has nothing to mark")
    #expect(Set(recorded.shown) == [otherTask])
  }

  // MARK: - Reopen (A19)

  @Test(.dependencies) func reopeningASettledTaskResumesOnlyItsPrimary() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("supacode-tests-\(UUID().uuidString)-reopen", isDirectory: true).standardizedFileURL
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.path(percentEncoded: false)
    let onDisk = Worktree(
      id: Worktree.ID(path), name: "disk", detail: "", workingDirectory: directory, repositoryRootURL: directory)
    var initial = state()
    initial.repositories.repositories = [
      Repository(id: RepositoryID(path), rootURL: directory, name: "disk", worktrees: [onDisk])
    ]
    initial.repositories.selection = .worktree(onDisk.id)
    // Settled: every tab closed, the record and its members kept.
    initial.terminals.layouts = [LayoutFeature.State(id: task, layout: PaneLayout())]
    initial.terminals.directories = [task: TaskRecord.Directory(worktreeID: onDisk.id)]
    initial.terminals.members = [task: [.session(key("a")), .session(key("b"))]]
    initial.agentPresence.records = [:]
    initial.repositories.sessionSnapshots = []
    initial.repositories.taskSnapshots = []
    initial.repositories.$sessions.withLock { $0[key("a")] = SessionSidecarEntry(settledAt: .distantPast) }
    initial.repositories.taskSessions = [task: [key("a"), key("b")]]
    initial.repositories.sessionSummaries = [("a", "Primary"), ("b", "Tangent")].map {
      SessionSummary(
        harness: .pi, sessionID: $0.0, createdAt: .distantPast, cwd: path, title: $0.1, messageCount: 4,
        lastActivity: .distantPast)
    }
    initial.repositories.reconcileSessionItems(now: .distantPast)
    // One row, the task's, in Settled: neither session has a row of its own.
    #expect(initial.repositories.sessionItems.map(\.id) == [.task(task)])
    #expect(initial.repositories.sessionItems.first?.lifecycle == .settled)
    #expect(initial.repositories.sessionItems.first?.title == "Primary")
    let recorded = Recorded()
    let store = store(initial, recorded: recorded)

    await store.send(.repositories(.activateSession(.task(task))))
    await store.receive(\.launchSessionCompleted)
    await store.finish()

    let launches = recorded.commands.value.compactMap { command -> (LayoutID, String)? in
      guard case .createTabWithInput(let layoutID, _, let input, _, _, _, _, _) = command else { return nil }
      return (layoutID, input)
    }
    #expect(launches.map(\.0) == [task], "one tab, in the task that lists it")
    #expect(launches.map(\.1) == ["pi --session a"], "the primary; the tangent waits for its own click")
    #expect(settledAt("a", in: store) == nil)
    #expect(!AppFeature.isTaskSettled(task, state: store.state))
  }

  /// Both fixture tasks closed on a directory that exists, each listing "a"
  /// as its primary: the state a session resumed by hand in a second task
  /// leaves once both are settled.
  private func twoClosedTasksSharingAPrimary(at directory: URL) -> AppFeature.State {
    let path = directory.path(percentEncoded: false)
    let onDisk = Worktree(
      id: Worktree.ID(path), name: "disk", detail: "", workingDirectory: directory, repositoryRootURL: directory)
    var initial = state()
    initial.repositories.repositories = [
      Repository(id: RepositoryID(path), rootURL: directory, name: "disk", worktrees: [onDisk])
    ]
    initial.repositories.selection = .worktree(onDisk.id)
    initial.terminals.layouts = [
      LayoutFeature.State(id: task, layout: PaneLayout()), LayoutFeature.State(id: otherTask, layout: PaneLayout()),
    ]
    let taskDirectory = TaskRecord.Directory(worktreeID: onDisk.id)
    initial.terminals.directories = [task: taskDirectory, otherTask: taskDirectory]
    initial.terminals.members = [task: [.session(key("a"))], otherTask: [.session(key("a"))]]
    initial.agentPresence.records = [:]
    initial.repositories.taskSessions = [task: [key("a")], otherTask: [key("a")]]
    initial.repositories.sessionSummaries = [
      SessionSummary(
        harness: .pi, sessionID: "a", createdAt: .distantPast, cwd: path, title: "Primary", messageCount: 4,
        lastActivity: .distantPast)
    ]
    return withRows(initial)
  }

  private func temporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("supacode-tests-\(UUID().uuidString)-reopen", isDirectory: true).standardizedFileURL
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  private func launchedTasks(_ recorded: Recorded) -> [LayoutID] {
    recorded.commands.value.compactMap {
      guard case .createTabWithInput(let layoutID, _, _, _, _, _, _, _) = $0 else { return nil }
      return layoutID
    }
  }

  @Test(.dependencies) func reopeningATaskThatSharesItsPrimaryReopensTheTaskThatWasClicked() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let initial = twoClosedTasksSharingAPrimary(at: directory)
    #expect(Set(initial.repositories.sessionItems.map(\.id)) == [.task(task), .task(otherTask)])
    #expect(task.persistenceKey < otherTask.persistenceKey, "by the key alone the resume picks the first")
    let recorded = Recorded()
    let store = store(initial, recorded: recorded)

    await store.send(.repositories(.activateSession(.task(otherTask))))
    await store.receive(\.launchSessionCompleted)
    await store.finish()

    #expect(launchedTasks(recorded) == [otherTask])
  }

  @Test(.dependencies) func reopeningATaskWhosePrimaryRunsInAnotherShowsWhereItRuns() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    var initial = twoClosedTasksSharingAPrimary(at: directory)
    initial.terminals.layouts[id: task] = layout(task, surfaces: [primarySurface])
    initial.agentPresence.records[.init(agent: .pi, surfaceID: primarySurface)] = live("a")
    initial = withRows(initial)
    let row = try #require(initial.repositories.sessionItems[id: .task(otherTask)])
    #expect(row.location == nil, "nothing of the clicked task is open")
    let recorded = Recorded()
    let store = store(initial, recorded: recorded)

    await store.send(.repositories(.activateSession(.task(otherTask))))
    await store.finish()
    await store.skipReceivedActions(strict: false)

    #expect(launchedTasks(recorded).isEmpty, "one session never gets a second agent")
    #expect(recorded.focused.value == [task])
    #expect(store.state.pendingSessionLaunch == nil)
  }

  @Test(.dependencies) func aResumeFallsBackToTheKeyWhenTheTaskAskedForNoLongerListsTheSession() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    var state = twoClosedTasksSharingAPrimary(at: directory)
    let directoryID = Worktree.ID(directory.path(percentEncoded: false))
    #expect(
      AppFeature.task(listing: key("a"), onDirectory: directoryID, preferring: otherTask, state: state) == otherTask)
    #expect(AppFeature.task(listing: key("a"), onDirectory: directoryID, state: state) == task)

    state.terminals.members[otherTask] = [.session(key("b"))]
    #expect(AppFeature.task(listing: key("a"), onDirectory: directoryID, preferring: otherTask, state: state) == task)
    state.terminals.members[task] = []
    #expect(AppFeature.task(listing: key("a"), onDirectory: directoryID, preferring: otherTask, state: state) == nil)
  }
}

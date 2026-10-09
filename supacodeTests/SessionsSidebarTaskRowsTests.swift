import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import Observation
import Sharing
import Testing

@testable import SupacodeSettingsShared
@testable import supacode

/// One row per task: its sessions are grouped under it, its status is its
/// most urgent agent's, and only the selected task lists its members.
@MainActor
struct SessionsSidebarTaskRowsTests {
  typealias Status = SessionClassification.Status

  private let now = Date(timeIntervalSince1970: 1_000)
  private let taskA = LayoutID(task: UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!)
  private let taskB = LayoutID(task: UUID(uuidString: "00000000-0000-0000-0000-0000000000A2")!)
  private let directory: Worktree.ID = "/repo/main"

  private func key(_ id: String) -> SessionKey { SessionKey(harness: .pi, sessionID: id) }

  private func surface(_ number: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-0000000000%02d", number))!
  }

  private func location(_ task: LayoutID, _ number: Int) -> SessionLocation {
    SessionLocation(
      layoutID: task, directoryID: directory, tabID: TabID(rawValue: surface(number)), surfaceID: surface(number))
  }

  private func summary(_ id: String, created: TimeInterval, cwd: String = "/repo/main") -> SessionSummary {
    SessionSummary(
      harness: .pi, sessionID: id, createdAt: Date(timeIntervalSince1970: created), cwd: cwd,
      title: "Title \(id)", messageCount: 5, lastActivity: Date(timeIntervalSince1970: created))
  }

  private func agent(
    _ ref: String?, in task: LayoutID, on number: Int, status: Status = .idle, attention: Bool = true
  ) -> SessionLiveSnapshot {
    SessionLiveSnapshot(
      harness: .pi, sessionRef: ref, cwd: "/repo/main", location: location(task, number), status: status,
      allowsAttentionNavigation: attention)
  }

  private func tabs(_ task: LayoutID, on number: Int, created: TimeInterval? = nil) -> TaskLiveSnapshot {
    TaskLiveSnapshot(
      title: "main", cwd: "/repo/main", createdAt: created.map(Date.init(timeIntervalSince1970:)),
      location: location(task, number))
  }

  private func state(sidecar: SessionSidecar = [:]) -> RepositoriesFeature.State {
    var state = RepositoriesFeature.State()
    state.$sessions = Shared(value: sidecar)
    state.$sidebar = Shared(value: SidebarState())
    state.$persistedLayouts = SharedReader(value: TaskLayoutsFile())
    state.sessionsStarted = true
    return state
  }

  private func rebuilt(_ state: RepositoriesFeature.State, dropping: Bool = false) -> RepositoriesFeature.State {
    var state = state
    state.reconcileSessionItems(now: now, droppingUnindexedEnded: dropping)
    state.recomputeSessionsSidebarStructureIfChanged()
    return state
  }

  // MARK: - Grouping

  @Test(.dependencies) func aTasksSessionsAreOneRowAndTheRestAreTheirOwn() {
    var state = state()
    state.sessionSummaries = [summary("a", created: 30), summary("b", created: 20), summary("c", created: 10)]
    state.taskSessions = [taskA: [key("a"), key("b")]]
    state = rebuilt(state)

    #expect(Set(state.sessionItems.ids) == [.task(taskA), .implicit(key("c"))])
    let row = state.sessionItems[id: .task(taskA)]
    #expect(row?.title == "Title a", "the primary titles the task")
    #expect(row?.primary == key("a"))
    #expect(row?.sessionKey == key("a"))
    #expect(row?.createdAt == Date(timeIntervalSince1970: 20), "as old as its oldest session")
    #expect(row?.cwd == "/repo/main")
    #expect(row?.isLive == false, "no tab and no agent: dormant")
    #expect(row?.status == nil)
    #expect(state.sessionItems[id: .implicit(key("c"))]?.sessionKey == key("c"))
    #expect(state.sessionsSidebarStructure.liveIDs.isEmpty)
    #expect(state.sessionsSidebarStructure.allIDs == [.task(taskA), .implicit(key("c"))])
  }

  @Test(.dependencies) func anAgentJoinsTheRowOfTheTaskThatHoldsItsSurface() {
    var state = state()
    state.sessionSummaries = [summary("a", created: 30), summary("late", created: 40)]
    state.taskSessions = [taskA: [key("a")]]
    state.taskSnapshots = [tabs(taskA, on: 1)]
    // Running in the task, reported, but the membership has not caught up;
    // and one that has not reported at all.
    state.sessionSnapshots = [
      agent("late", in: taskA, on: 2, status: .working), agent(nil, in: taskA, on: 3),
    ]
    state = rebuilt(state)

    #expect(state.sessionItems.map(\.id) == [.task(taskA)], "neither gets a row beside its task")
    #expect(state.sessionItems[id: .task(taskA)]?.status == .working)
    #expect(state.sessionItems[id: .task(taskA)]?.title == "Title a")
  }

  @Test(.dependencies) func anAgentOnASurfaceNoKnownTaskHoldsKeepsItsOwnRow() {
    var state = state()
    state.sessionSummaries = [summary("a", created: 30)]
    state.sessionSnapshots = [agent("a", in: taskA, on: 1, status: .working), agent(nil, in: taskA, on: 2)]
    state = rebuilt(state)

    #expect(Set(state.sessionItems.ids) == [.implicit(key("a")), .provisional(.pi, surface(2))])
    #expect(state.sessionItems[id: .implicit(key("a"))]?.location == location(taskA, 1))
  }

  @Test(.dependencies) func aSessionTwoTasksListIsGroupedUnderBoth() {
    var state = state()
    state.sessionSummaries = [summary("a", created: 30), summary("b", created: 20)]
    state.taskSessions = [taskA: [key("a"), key("b")], taskB: [key("b")]]
    state = rebuilt(state)

    #expect(Set(state.sessionItems.ids) == [.task(taskA), .task(taskB)])
    #expect(state.sessionItems[id: .task(taskB)]?.title == "Title b")
  }

  @Test(.dependencies) func aReplacedSessionIsADormantMemberNotARow() {
    // `/new`: "n" took "a"'s slot and "a" was marked settled.
    var state = state(sidecar: [key("a"): SessionSidecarEntry(settledAt: now)])
    state.sessionSummaries = [summary("a", created: 10), summary("n", created: 50)]
    state.taskSessions = [taskA: [key("n"), key("a")]]
    state.taskSnapshots = [tabs(taskA, on: 1)]
    state.sessionSnapshots = [agent("n", in: taskA, on: 1, status: .working)]
    state.sessionSelection = .task(taskA)
    state = rebuilt(state)

    #expect(state.sessionItems.map(\.id) == [.task(taskA)], "the replaced session has no top-level row")
    #expect(state.sessionItems[id: .task(taskA)]?.lifecycle == .active)
    #expect(state.sessionsSidebarStructure.sections.map(\.id) == [.active])
    let subRows = state.sessionsSidebarStructure.subRows
    #expect(subRows.map(\.id) == [.session(key("n")), .session(key("a"))])
    #expect(subRows.map(\.isDormant) == [false, true])
    #expect(subRows.map(\.title) == ["Title n", "Title a"])
  }

  @Test(.dependencies) func shellOnlyTaskIsTitledByItsDirectoryAndHasNoSession() {
    var state = state()
    state.taskSnapshots = [tabs(taskA, on: 1, created: 7)]
    state = rebuilt(state)

    let row = state.sessionItems[id: .task(taskA)]
    #expect(row?.title == "main")
    #expect(row?.sessionKey == nil)
    #expect(row?.status == nil)
    #expect(row?.isSynthetic == false)
    #expect(row?.createdAt == Date(timeIntervalSince1970: 7))
    #expect(row?.location == location(taskA, 1))
    #expect(state.sessionsSidebarStructure.liveIDs == [.task(taskA)])
  }

  @Test(.dependencies) func aTaskWithNothingOpenAndNothingOnDiskHasNoRow() {
    var state = state()
    state.taskSessions = [taskA: [key("never-indexed")]]
    state = rebuilt(state)

    #expect(state.sessionItems.isEmpty)
  }

  @Test(.dependencies) func anEndedUnindexedTaskKeepsItsRowUntilTheNextScan() {
    var state = state()
    state.taskSessions = [taskA: [key("fresh")]]
    state.taskSnapshots = [tabs(taskA, on: 1)]
    state.sessionSnapshots = [agent("fresh", in: taskA, on: 1)]
    state = rebuilt(state)
    #expect(state.sessionItems[id: .task(taskA)]?.title == "New session")
    #expect(state.sessionItems[id: .task(taskA)]?.isSynthetic == true)

    // The agent ended and its tab closed before the index saw a turn.
    state.taskSnapshots = []
    state.sessionSnapshots = []
    state = rebuilt(state)
    #expect(state.sessionItems[id: .task(taskA)]?.isLive == false)
    #expect(state.sessionItems[id: .task(taskA)]?.title == "New session")

    state = rebuilt(state, dropping: true)
    #expect(state.sessionItems.isEmpty, "never had a turn: nothing to resume")
  }

  // MARK: - Shell-only to agent (A27)

  private func activeOrder(_ state: RepositoriesFeature.State) -> [SessionRowID] {
    state.sessionsSidebarStructure.sections.first { $0.id == .active }?.rowIDs ?? []
  }

  @Test(.dependencies) func aShellOnlyTaskTakesItsFirstAgentsTitleOnTheSameRow() {
    var state = state()
    state.sessionSummaries = [summary("free", created: 5)]
    state.taskSnapshots = [tabs(taskA, on: 1, created: 7)]

    func row(_ step: String) -> SessionSidebarItemFeature.State? {
      state = rebuilt(state)
      #expect(Set(state.sessionItems.ids) == [.task(taskA), .implicit(key("free"))], "\(step): no row for the agent")
      #expect(state.sessionsSidebarStructure.liveIDs == [.task(taskA)], "\(step)")
      #expect(state.sessionsSidebarStructure.subRows.isEmpty, "\(step)")
      #expect(state.sessionItems[id: .task(taskA)]?.isLive == true, "\(step)")
      #expect(state.sessionItems[id: .task(taskA)]?.lifecycle == .active, "\(step)")
      return state.sessionItems[id: .task(taskA)]
    }

    let shellOnly = row("shell-only")
    #expect(shellOnly?.title == "main")
    #expect(shellOnly?.primary == nil)
    #expect(shellOnly?.status == nil)
    #expect(shellOnly?.isSynthetic == false)

    state.sessionSnapshots = [agent(nil, in: taskA, on: 1, status: .working)]
    let unreported = row("unreported agent")
    #expect(unreported?.title == "New session")
    #expect(unreported?.primary == nil)
    #expect(unreported?.status == .working)
    #expect(unreported?.isSynthetic == true)

    state.sessionSnapshots = [agent("a", in: taskA, on: 1, status: .working)]
    let reported = row("reported, not listed")
    #expect(reported?.title == "New session")
    #expect(reported?.primary == key("a"), "the row has its primary before the membership arrives")
    #expect(reported?.isSynthetic == true)

    state.taskSessions = [taskA: [key("a")]]
    #expect(row("listed") == reported, "listing the session changes nothing on the row")

    state.sessionSummaries.append(summary("a", created: 900))
    let indexed = row("indexed")
    #expect(indexed?.title == "Title a")
    #expect(indexed?.primary == key("a"))
    #expect(indexed?.status == .working)
    #expect(indexed?.isSynthetic == false)
    #expect(indexed?.createdAt == Date(timeIntervalSince1970: 900))

    state.sessionSnapshots = []
    let ended = row("agent ended, tab open")
    #expect(ended?.title == "Title a")
    #expect(ended?.status == nil)
    #expect(ended?.location == location(taskA, 1))
  }

  @Test(.dependencies) func theRowStaysSelectedWhileAShellOnlyTaskBecomesAnAgentTask() {
    var state = state()
    state.sessionSummaries = [summary("free", created: 5)]
    state.taskSnapshots = [tabs(taskA, on: 1, created: 7), tabs(taskB, on: 9, created: 8)]
    state = rebuilt(state)
    state.selectSessionRow(.task(taskA))

    var orders = [activeOrder(state)]
    func step(_ change: (inout RepositoriesFeature.State) -> Void) {
      change(&state)
      state = rebuilt(state)
      #expect(state.sessionSelection == .task(taskA))
      if orders.last != activeOrder(state) { orders.append(activeOrder(state)) }
    }
    step { $0.sessionSnapshots = [agent(nil, in: taskA, on: 1)] }
    step { $0.sessionSnapshots = [agent("a", in: taskA, on: 1)] }
    step { $0.taskSessions = [taskA: [key("a")]] }
    #expect(orders.count == 1, "nothing moves until the session is on disk")
    step { $0.sessionSummaries.append(summary("a", created: 900)) }

    #expect(orders.count == 2, "the row re-sorts once, when it takes its session's date")
    #expect(orders.allSatisfy { Set($0) == [.task(taskA), .task(taskB), .implicit(key("free"))] })
    let before = orders[0].firstIndex(of: .task(taskA)) ?? 0
    let after = orders[1].firstIndex(of: .task(taskA)) ?? 0
    #expect(after < before, "and moves above the later shell-only task")
  }

  @Test(.dependencies) func aShellOnlyTaskWhoseAgentEndedBeforeAnyTurnIsTitledByItsDirectoryAgain() {
    var state = state()
    state.taskSessions = [taskA: [key("fresh")]]
    state.taskSnapshots = [tabs(taskA, on: 1)]
    state.sessionSnapshots = [agent("fresh", in: taskA, on: 1)]
    state = rebuilt(state)
    #expect(state.sessionItems[id: .task(taskA)]?.title == "New session")

    state.sessionSnapshots = []
    state = rebuilt(state, dropping: true)

    let row = state.sessionItems[id: .task(taskA)]
    #expect(row?.title == "main", "its tab is still open: the row stays, under the directory's name")
    #expect(row?.primary == key("fresh"))
    #expect(row?.isLive == true)
    #expect(row?.lifecycle == .active)
  }

  @Test(.dependencies) func aLaterAgentDoesNotRetitleOrReplaceThePrimary() {
    var state = state()
    state.sessionSummaries = [summary("a", created: 30)]
    state.taskSessions = [taskA: [key("a")]]
    state.taskSnapshots = [tabs(taskA, on: 1)]
    state = rebuilt(state)
    state.selectSessionRow(.task(taskA))

    func expectLedByA(_ step: String) {
      state = rebuilt(state)
      #expect(state.sessionItems.map(\.id) == [.task(taskA)], "\(step)")
      #expect(state.sessionItems[id: .task(taskA)]?.title == "Title a", "\(step)")
      #expect(state.sessionItems[id: .task(taskA)]?.primary == key("a"), "\(step)")
    }
    expectLedByA("first agent ended")
    state.sessionSnapshots = [agent("b", in: taskA, on: 2, status: .working)]
    expectLedByA("second agent running")
    state.taskSessions = [taskA: [key("a"), key("b")]]
    expectLedByA("second agent listed")
    state.sessionSummaries.append(summary("b", created: 950))
    expectLedByA("second agent indexed")

    let subRows = state.sessionsSidebarStructure.subRows
    #expect(subRows.map(\.id) == [.session(key("a")), .session(key("b"))])
    #expect(subRows.map(\.isDormant) == [true, false])
  }

  @Test(.dependencies) func aMarkedSessionJoiningAShellOnlyTaskLeavesTheTaskActiveAndTheMarkAlone() {
    // `pi --resume` typed into a shell, for a session already settled.
    var state = state(sidecar: [key("a"): SessionSidecarEntry(settledAt: now)])
    state.taskSnapshots = [tabs(taskA, on: 1)]
    state = rebuilt(state)

    state.sessionSnapshots = [agent("a", in: taskA, on: 1)]
    state.taskSessions = [taskA: [key("a")]]
    state.sessionSummaries = [summary("a", created: 30)]
    state = rebuilt(state)
    #expect(state.sessionItems[id: .task(taskA)]?.lifecycle == .active)
    #expect(state.sessions[key("a")]?.settledAt == now, "joining writes nothing to the sidecar")

    state.sessionSnapshots = []
    state.taskSnapshots = []
    state = rebuilt(state)
    #expect(state.sessionItems[id: .task(taskA)]?.lifecycle == .settled)
    #expect(state.sessions[key("a")]?.settledAt == now)
  }

  @Test(.dependencies) func aShellOnlyTaskThatClosedAfterItsAgentResumesItsPrimary() async {
    var initial = state()
    initial.sessionSummaries = [summary("a", created: 30)]
    initial.taskSessions = [taskA: [key("a")]]
    initial = rebuilt(initial)
    #expect(initial.sessionItems[id: .task(taskA)]?.isLive == false)
    let store = TestStore(initialState: initial) { RepositoriesFeature() }
    store.exhaustivity = .off

    await store.send(.activateSession(.task(taskA)))
    await store.receive(\.delegate, .resumeSession(key("a"), task: taskA))
    await store.finish()
  }

  // MARK: - Settled

  @Test(.dependencies, arguments: [true, false])
  func aTaskIsSettledByItsPrimaryOnlyOnceNothingIsOpen(tabOpen: Bool) {
    var state = state(sidecar: [key("a"): SessionSidecarEntry(settledAt: now)])
    state.sessionSummaries = [summary("a", created: 30), summary("b", created: 20)]
    state.taskSessions = [taskA: [key("a"), key("b")]]
    if tabOpen { state.taskSnapshots = [tabs(taskA, on: 1)] }
    state = rebuilt(state)

    #expect(state.sessionItems[id: .task(taskA)]?.lifecycle == (tabOpen ? .active : .settled))
    #expect(state.sessionsSidebarStructure.sections.map(\.id) == [tabOpen ? .active : .settled])
  }

  @Test(.dependencies) func aSettledTangentDoesNotSettleItsTask() {
    var state = state(sidecar: [key("b"): SessionSidecarEntry(settledAt: now)])
    state.sessionSummaries = [summary("a", created: 30), summary("b", created: 20)]
    state.taskSessions = [taskA: [key("a"), key("b")]]
    state = rebuilt(state)

    #expect(state.sessionItems[id: .task(taskA)]?.lifecycle == .active)
  }

  // MARK: - Status rollup (A24)

  @Test(
    .dependencies,
    arguments: [
      ([Status.idle, .idle], Status.idle),
      ([.idle, .doneUnseen], .doneUnseen),
      ([.doneUnseen, .working], .working),
      ([.working, .needsYou], .needsYou),
      ([.needsYou, .idle, .working, .doneUnseen], .needsYou),
      ([.idle, .working, .doneUnseen], .working),
      ([.doneUnseen, .idle, .idle], .doneUnseen),
      ([.working], .working),
    ])
  func aTaskShowsItsMostUrgentMember(members: [Status], expected: Status) {
    for statuses in [members, members.reversed()] {
      var state = state()
      state.taskSnapshots = [tabs(taskA, on: 1)]
      state.taskSessions = [taskA: statuses.indices.map { key("s\($0)") }]
      state.sessionSnapshots = statuses.enumerated().map { index, status in
        agent("s\(index)", in: taskA, on: index + 1, status: status)
      }
      state = rebuilt(state)

      let row = state.sessionItems[id: .task(taskA)]
      #expect(row?.status == expected)
      let leading = state.sessionSnapshots.first { $0.location == row?.location }
      #expect(leading?.status == expected, "the row leads to the member it speaks for")
    }
  }

  @Test(.dependencies) func aTaskWithNoAgentHasNoStatusWhateverOtherTasksShow() {
    var state = state()
    state.taskSnapshots = [tabs(taskA, on: 1), tabs(taskB, on: 2)]
    state.sessionSnapshots = [agent("b", in: taskB, on: 2, status: .needsYou)]
    state = rebuilt(state)

    #expect(state.sessionItems[id: .task(taskA)]?.status == nil)
    #expect(state.sessionItems[id: .task(taskB)]?.status == .needsYou)
  }

  @Test(.dependencies) func amongEquallyUrgentMembersTheRowStaysOnTheOneItLedTo() {
    var state = state()
    state.taskSnapshots = [tabs(taskA, on: 1)]
    state.sessionSnapshots = [
      agent("x", in: taskA, on: 1, status: .working), agent("y", in: taskA, on: 2, status: .needsYou),
    ]
    state = rebuilt(state)
    #expect(state.sessionItems[id: .task(taskA)]?.location == location(taskA, 2))

    state.sessionSnapshots[0].status = .needsYou
    state = rebuilt(state)
    #expect(state.sessionItems[id: .task(taskA)]?.location == location(taskA, 2), "it does not hop to the first")

    // One that can be jumped to wins over one that cannot.
    state.sessionSnapshots[1].allowsAttentionNavigation = false
    state = rebuilt(state)
    #expect(state.sessionItems[id: .task(taskA)]?.location == location(taskA, 1))
    #expect(state.sessionItems[id: .task(taskA)]?.allowsAttentionNavigation == true)
  }

  // MARK: - Sub-rows (A23)

  private func twoTasksWithMembers() -> RepositoriesFeature.State {
    var state = state()
    state.sessionSummaries = [
      summary("a", created: 30), summary("b", created: 20), summary("c", created: 10), summary("solo", created: 5),
      summary("free", created: 1),
    ]
    state.taskSessions = [taskA: [key("a"), key("b"), key("c")], taskB: [key("solo")]]
    state.taskSnapshots = [tabs(taskA, on: 1), tabs(taskB, on: 9)]
    state.sessionSnapshots = [
      agent("a", in: taskA, on: 1, status: .idle), agent("c", in: taskA, on: 3, status: .needsYou),
      agent("solo", in: taskB, on: 9, status: .working),
    ]
    return rebuilt(state)
  }

  @Test(.dependencies) func subRowsAreOnlyTheSelectedTasksInMemberOrder() {
    var state = twoTasksWithMembers()
    #expect(state.sessionsSidebarStructure.subRows.isEmpty, "nothing selected")
    #expect(state.sessionsSidebarStructure.subRowsTaskID == nil)

    state.selectSessionRow(.task(taskA))
    let structure = state.sessionsSidebarStructure
    #expect(structure.subRowsTaskID == taskA)
    #expect(structure.subRows.map(\.id) == [.session(key("a")), .session(key("b")), .session(key("c"))])
    #expect(structure.subRows.map(\.title) == ["Title a", "Title b", "Title c"])
    #expect(structure.subRows.map(\.status) == [.idle, nil, .needsYou])
    #expect(structure.subRows.map(\.location) == [location(taskA, 1), nil, location(taskA, 3)])
    #expect(structure.subRows.map(\.isDormant) == [false, true, false], "the closed tangent is dormant")

    // A task of one agent is its own row; a session with no task has no members.
    state.selectSessionRow(.task(taskB))
    #expect(state.sessionsSidebarStructure.subRows.isEmpty)
    #expect(state.sessionsSidebarStructure.subRowsTaskID == nil)
    state.selectSessionRow(.implicit(key("free")))
    #expect(state.sessionsSidebarStructure.subRows.isEmpty)
    state.selectSessionRow(nil)
    #expect(state.sessionsSidebarStructure.subRows.isEmpty)
  }

  @Test(.dependencies) func subRowsListAnUnreportedAgentAfterTheSessions() {
    var state = twoTasksWithMembers()
    state.sessionSnapshots.append(agent(nil, in: taskA, on: 4, status: .working))
    state.sessionSelection = .task(taskA)
    state = rebuilt(state)

    let subRows = state.sessionsSidebarStructure.subRows
    #expect(subRows.last?.id == .provisional(harness: .pi, surfaceID: surface(4)))
    #expect(subRows.last?.title == "New session")
    #expect(subRows.last?.status == .working)
    #expect(subRows.count == 4)
  }

  @Test(.dependencies) func aMemberNeitherRunningNorOnDiskIsNoSubRow() {
    // A ref an earlier build listed for a sub-agent: never indexed, long gone.
    var state = twoTasksWithMembers()
    state.taskSessions = [taskA: [key("a"), key("ghost"), key("c")], taskB: [key("solo"), key("ghost")]]
    state.sessionSelection = .task(taskA)
    state = rebuilt(state)
    #expect(state.sessionsSidebarStructure.subRows.map(\.id) == [.session(key("a")), .session(key("c"))])

    state.selectSessionRow(.task(taskB))
    #expect(state.sessionsSidebarStructure.subRows.isEmpty, "what is left is the task's one agent")
    #expect(SessionQueryResponse.rows(repositories: state).allSatisfy { $0[SessionQueryResponse.Key.id] != "pi:ghost" })
  }

  @Test(.dependencies) func subRowsFollowTheSelectionAndMembershipThroughTheReducer() async {
    var initial = twoTasksWithMembers()
    initial.taskSessions[taskB] = [key("solo")]
    let store = TestStore(initialState: initial) {
      RepositoriesFeature()
    } withDependencies: {
      $0.date.now = now
    }
    store.exhaustivity = .off

    await store.send(.sessionSelectionChanged(.task(taskA)))
    #expect(store.state.sessionsSidebarStructure.subRows.count == 3)

    await store.send(.taskSessionsChanged([taskA: [key("a"), key("c")], taskB: [key("solo"), key("b")]]))
    #expect(store.state.sessionsSidebarStructure.subRows.map(\.id) == [.session(key("a")), .session(key("c"))])
    #expect(Set(store.state.sessionItems.ids) == [.task(taskA), .task(taskB), .implicit(key("free"))])

    await store.send(.sessionSelectionChanged(.task(taskB)))
    #expect(store.state.sessionsSidebarStructure.subRowsTaskID == taskB)
    #expect(store.state.sessionsSidebarStructure.subRows.map(\.isDormant) == [false, true])

    await store.send(.sessionSelectionChanged(.implicit(key("free"))))
    #expect(store.state.sessionsSidebarStructure.subRows.isEmpty)
  }

  // MARK: - Selection survives grouping

  @Test(.dependencies) func aSelectedSessionRowFoldedIntoATaskLeavesTheTaskSelected() {
    var state = state()
    state.sessionSummaries = [summary("a", created: 30), summary("b", created: 20)]
    state = rebuilt(state)
    state.selectSessionRow(.implicit(key("b")))

    state.taskSessions = [taskA: [key("a"), key("b")]]
    state = rebuilt(state)

    #expect(state.sessionSelection == .task(taskA))
    #expect(state.sessionsSidebarStructure.subRowsTaskID == taskA)
  }

  @Test(.dependencies) func aSelectedUnreportedAgentFoldedIntoATaskLeavesTheTaskSelected() {
    var state = state()
    state.sessionSnapshots = [agent(nil, in: taskA, on: 1)]
    state = rebuilt(state)
    state.selectSessionRow(.provisional(.pi, surface(1)))

    state.taskSnapshots = [tabs(taskA, on: 1)]
    state = rebuilt(state)

    #expect(state.sessionItems.map(\.id) == [.task(taskA)])
    #expect(state.sessionSelection == .task(taskA))
  }

  @Test(.dependencies) func aSelectedRowThatIsGoneClearsTheSelection() {
    var state = twoTasksWithMembers()
    state.selectSessionRow(.implicit(key("free")))
    state.sessionSummaries.removeAll { $0.id == key("free") }
    state = rebuilt(state)

    #expect(state.sessionSelection == nil)
  }

  // MARK: - Write avoidance and order (A26)

  @Test(.dependencies) func anUnchangedReconcileWithTasksWritesNothing() {
    var state = twoTasksWithMembers()
    state.selectSessionRow(.task(taskA))
    let before = state
    let wrote = LockIsolated(false)
    withObservationTracking {
      _ = state.sessionItems.count
      _ = state.sessionSelection
      _ = state.sessionsSidebarStructure
      for row in state.sessionItems {
        _ = (row.title, row.cwd, row.createdAt, row.lifecycle, row.location)
        _ = (row.status, row.allowsAttentionNavigation, row.branchAnnotation, row.isSynthetic, row.primary)
      }
    } onChange: {
      wrote.setValue(true)
    }

    state.reconcileSessionItems(now: now.addingTimeInterval(60))
    state.recomputeSessionsSidebarStructureIfChanged()

    #expect(!wrote.value)
    #expect(state == before)

    state.sessionSnapshots[1].status = .idle
    state.reconcileSessionItems(now: now)
    #expect(wrote.value, "the same observation fires for a real change")
  }

  @Test(.dependencies) func rowsComeOutInTheSameOrderWhateverOrderTheTasksAreListedIn() {
    let tasks = (1...8).map { LayoutID(task: surface($0)) }
    var forward = state()
    var backward = state()
    for task in tasks { forward.taskSessions[task] = [key("s-\(task.persistenceKey)")] }
    for task in tasks.reversed() { backward.taskSessions[task] = [key("s-\(task.persistenceKey)")] }
    let summaries = tasks.map { summary("s-\($0.persistenceKey)", created: 10) }
    forward.sessionSummaries = summaries
    backward.sessionSummaries = summaries.reversed()

    #expect(rebuilt(forward).sessionItems.map(\.id) == rebuilt(backward).sessionItems.map(\.id))
    #expect(rebuilt(forward).sessionsSidebarStructure == rebuilt(backward).sessionsSidebarStructure)
  }

  // MARK: - Attention target (A25)

  private func stop(_ task: LayoutID, _ number: Int) -> SessionsSidebarStructure.AttentionTarget {
    .init(rowID: .task(task), location: location(task, number))
  }

  private func target(
    _ state: RepositoriesFeature.State, after row: SessionRowID?, on number: Int? = nil
  ) -> SessionsSidebarStructure.AttentionTarget? {
    state.nextAttentionTarget(after: row, focusedSurfaceID: number.map(surface))
  }

  /// A: `a` idle on 1, `b` needs you on 2. B: `c` working on 3, `d` done unseen on 4.
  private func twoTasksEachWithAMaskedTangent() -> RepositoriesFeature.State {
    var state = state()
    state.taskSnapshots = [tabs(taskA, on: 1, created: 20), tabs(taskB, on: 3, created: 10)]
    state.taskSessions = [taskA: [key("a"), key("b")], taskB: [key("c"), key("d")]]
    state.sessionSnapshots = [
      agent("a", in: taskA, on: 1), agent("b", in: taskA, on: 2, status: .needsYou),
      agent("c", in: taskB, on: 3, status: .working), agent("d", in: taskB, on: 4, status: .doneUnseen),
    ]
    return rebuilt(state)
  }

  @Test(.dependencies) func aTangentMaskedByAWorkingPrimaryIsTheTarget() {
    var state = state()
    state.taskSnapshots = [tabs(taskA, on: 1)]
    state.taskSessions = [taskA: [key("a"), key("b")]]
    state.sessionSnapshots = [
      agent("a", in: taskA, on: 1, status: .working), agent("b", in: taskA, on: 2, status: .doneUnseen),
    ]
    state = rebuilt(state)
    #expect(state.sessionItems[id: .task(taskA)]?.status == .working)

    #expect(target(state, after: nil) == stop(taskA, 2))
  }

  @Test(.dependencies) func aTangentMaskedByAnErroredPrimaryIsTheTarget() {
    var state = state()
    state.taskSnapshots = [tabs(taskA, on: 1)]
    state.taskSessions = [taskA: [key("a"), key("b")]]
    state.sessionSnapshots = [
      agent("a", in: taskA, on: 1, status: .needsYou, attention: false),
      agent("b", in: taskA, on: 2, status: .doneUnseen),
    ]
    state = rebuilt(state)

    #expect(target(state, after: nil) == stop(taskA, 2))
  }

  @Test(.dependencies) func twoAgentsOfOneTaskAreVisitedInMemberOrder() {
    var state = state()
    state.taskSnapshots = [tabs(taskA, on: 1)]
    state.taskSessions = [taskA: [key("a"), key("b")]]
    // `a` is listed first but sits on the later surface.
    state.sessionSnapshots = [
      agent("b", in: taskA, on: 1, status: .needsYou), agent("a", in: taskA, on: 2, status: .needsYou),
    ]
    state = rebuilt(state)

    #expect(target(state, after: .task(taskA)) == stop(taskA, 2))
    #expect(target(state, after: .task(taskA), on: 2) == stop(taskA, 1))
    #expect(target(state, after: .task(taskA), on: 1) == stop(taskA, 2), "it wraps inside the only row")
  }

  @Test(.dependencies) func afterATasksLastAgentTheNextTaskIsTheTarget() {
    let state = twoTasksEachWithAMaskedTangent()
    #expect(state.sessionsSidebarStructure.liveIDs == [.task(taskA), .task(taskB)])

    #expect(target(state, after: .task(taskA), on: 2) == stop(taskB, 4))
    #expect(target(state, after: .task(taskB), on: 4) == stop(taskA, 2))
    #expect(target(state, after: .task(taskB), on: 3) == stop(taskB, 4))
  }

  @Test(.dependencies) func aShellTabOfTheTaskComesBeforeItsAgents() {
    let state = twoTasksEachWithAMaskedTangent()
    #expect(state.sessionsSidebarStructure.liveIDs.last == .task(taskB))

    #expect(target(state, after: .task(taskB), on: 77) == stop(taskB, 4), "its own task first, not the row above")
  }

  @Test(.dependencies) func theOnlyCandidateIsReturnedEvenWhenFocused() {
    var state = state()
    state.taskSnapshots = [tabs(taskA, on: 1)]
    state.sessionSnapshots = [agent("a", in: taskA, on: 1, status: .needsYou)]
    state = rebuilt(state)

    #expect(target(state, after: .task(taskA), on: 1) == stop(taskA, 1))
  }

  @Test(.dependencies, arguments: ["idle", "working", "error", "shell", "empty"])
  func nothingToJumpTo(shape: String) {
    var state = state()
    if shape != "empty" { state.taskSnapshots = [tabs(taskA, on: 1)] }
    switch shape {
    case "idle": state.sessionSnapshots = [agent("a", in: taskA, on: 1), agent("b", in: taskA, on: 2)]
    case "working": state.sessionSnapshots = [agent("a", in: taskA, on: 1, status: .working)]
    case "error": state.sessionSnapshots = [agent("a", in: taskA, on: 1, status: .needsYou, attention: false)]
    default: break
    }
    state = rebuilt(state)
    #expect(state.sessionsSidebarStructure.liveIDs.isEmpty == (shape == "empty"))

    #expect(target(state, after: nil) == nil)
    #expect(target(state, after: .task(taskA), on: 1) == nil)
  }

  @Test(.dependencies) func anUnlistedAgentFollowsListedMembers() {
    var state = state()
    state.taskSnapshots = [tabs(taskA, on: 1)]
    state.taskSessions = [taskA: [key("a")]]
    state.sessionSnapshots = [
      agent("z", in: taskA, on: 1, status: .needsYou), agent("a", in: taskA, on: 2, status: .needsYou),
    ]
    state = rebuilt(state)

    #expect(target(state, after: .task(taskA)) == stop(taskA, 2))
    #expect(target(state, after: .task(taskA), on: 2) == stop(taskA, 1))
  }

  @Test(.dependencies) func ungroupedRowsKeepTheirPlaceAmongTasks() throws {
    var state = state()
    state.sessionSummaries = [summary("free", created: 5)]
    state.taskSnapshots = [tabs(taskA, on: 1)]
    state.sessionSnapshots = [
      agent("a", in: taskA, on: 1, status: .needsYou), agent("free", in: taskB, on: 9, status: .doneUnseen),
    ]
    state = rebuilt(state)
    let free = SessionRowID.implicit(key("free"))
    #expect(Set(state.sessionsSidebarStructure.liveIDs) == [.task(taskA), free])
    let ungrouped = SessionsSidebarStructure.AttentionTarget(rowID: free, location: location(taskB, 9))

    #expect(target(state, after: .task(taskA), on: 1) == ungrouped)
    #expect(target(state, after: free, on: 9) == stop(taskA, 1))
    let first = try #require(state.sessionsSidebarStructure.liveIDs.first)
    #expect(target(state, after: nil)?.rowID == first)
  }

  @Test(.dependencies) func aSessionListedByTwoTasksIsATargetOnlyWhereItRuns() {
    var state = state()
    state.taskSnapshots = [tabs(taskA, on: 1), tabs(taskB, on: 3)]
    state.taskSessions = [taskA: [key("a")], taskB: [key("a"), key("b")]]
    state.sessionSnapshots = [agent("a", in: taskA, on: 1, status: .needsYou), agent("b", in: taskB, on: 3)]
    state = rebuilt(state)

    for row in [nil, SessionRowID.task(taskA), .task(taskB)] {
      #expect(target(state, after: row) == stop(taskA, 1))
    }
    #expect(target(state, after: .task(taskB), on: 3) == stop(taskA, 1))
  }

  @Test(.dependencies) func findingATargetWritesNothing() {
    var state = state()
    state.taskSnapshots = [tabs(taskA, on: 1)]
    state.taskSessions = [taskA: [key("a"), key("b")]]
    state.sessionSnapshots = [agent("a", in: taskA, on: 1, status: .working), agent("b", in: taskA, on: 2)]
    state = rebuilt(state)
    let before = state
    #expect(target(state, after: .task(taskA), on: 1) == nil)
    #expect(state == before)

    // The target is worked out per press: a tangent's flip the row does not show changes no structure.
    state.sessionSnapshots[1].status = .doneUnseen
    state = rebuilt(state)
    #expect(state.sessionItems[id: .task(taskA)]?.status == .working)
    #expect(state.sessionsSidebarStructure == before.sessionsSidebarStructure)
    #expect(target(state, after: .task(taskA), on: 1) == stop(taskA, 2))
  }

  // MARK: - Activation and settle

  @Test(.dependencies) func activatingADormantTaskResumesItsPrimary() async {
    var initial = state(sidecar: [key("a"): SessionSidecarEntry(settledAt: now)])
    initial.sessionSummaries = [summary("a", created: 30), summary("b", created: 20)]
    initial.taskSessions = [taskA: [key("a"), key("b")]]
    initial = rebuilt(initial)
    let store = TestStore(initialState: initial) { RepositoriesFeature() }
    store.exhaustivity = .off

    await store.send(.activateSession(.task(taskA)))
    await store.receive(\.delegate, .resumeSession(key("a"), task: taskA))
    await store.finish()

    #expect(store.state.sessionSelection == .task(taskA))
    #expect(store.state.sessionCwd(for: key("b")) == "/repo/main", "a tangent's directory is still known")
  }

  @Test(.dependencies) func aDormantTaskRowResumesInItsOwnTaskWhenAnotherTaskSharesThePrimary() async {
    var initial = state()
    initial.sessionSummaries = [summary("a", created: 30), summary("b", created: 20), summary("c", created: 10)]
    initial.taskSessions = [taskA: [key("a"), key("b")], taskB: [key("a"), key("c")]]
    initial = rebuilt(initial)
    let store = TestStore(initialState: initial) { RepositoriesFeature() }
    store.exhaustivity = .off

    await store.send(.activateSession(.task(taskB)))
    await store.receive(\.delegate, .resumeSession(key("a"), task: taskB))
    await store.finish()
  }

  // MARK: - Sub-row activation (A23)

  /// `taskA` selected, listing `a` then `b`, with `a` running on surface 1.
  private func selectedTaskWithATangent(running agents: [SessionLiveSnapshot] = []) -> RepositoriesFeature.State {
    var state = state()
    state.sessionSummaries = [summary("a", created: 30), summary("b", created: 20), summary("solo", created: 5)]
    state.taskSessions = [taskA: [key("a"), key("b")], taskB: [key("solo")]]
    state.taskSnapshots = [tabs(taskA, on: 1), tabs(taskB, on: 9)]
    state.sessionSnapshots = [agent("a", in: taskA, on: 1)] + agents
    state.sessionSelection = .task(taskA)
    return rebuilt(state)
  }

  @Test(.dependencies) func activatingALiveSubRowFocusesItsOwnSurface() async {
    let initial = selectedTaskWithATangent(running: [agent("b", in: taskA, on: 2)])
    let store = TestStore(initialState: initial) { RepositoriesFeature() }

    // No state closure under full exhaustivity: a sub-row click writes nothing.
    await store.send(.activateSessionSubRow(task: taskA, member: .session(key("b"))))
    await store.receive(\.delegate, .focusSession(location(taskA, 2)))
    await store.finish()

    #expect(store.state.sessionSelection == .task(taskA))
  }

  @Test(.dependencies) func activatingADormantSubRowResumesItInItsTask() async {
    let store = TestStore(initialState: selectedTaskWithATangent()) { RepositoriesFeature() }

    await store.send(.activateSessionSubRow(task: taskA, member: .session(key("b"))))
    await store.receive(\.delegate, .resumeSession(key("b"), task: taskA))
    await store.finish()
  }

  @Test(.dependencies) func aMemberRunningInAnotherTaskIsShownThereNotStartedAgain() async {
    let initial = selectedTaskWithATangent(running: [agent("b", in: taskB, on: 8)])
    #expect(
      initial.sessionsSidebarStructure.subRows.map(\.isDormant) == [false, true], "dormant here: it runs elsewhere")
    let store = TestStore(initialState: initial) { RepositoriesFeature() }

    await store.send(.activateSessionSubRow(task: taskA, member: .session(key("b"))))
    await store.receive(\.delegate, .focusSession(location(taskB, 8)))
    await store.finish()
  }

  @Test(.dependencies) func anUnreportedAgentSubRowFocusesItsSurface() async {
    let initial = selectedTaskWithATangent(running: [agent(nil, in: taskA, on: 2)])
    let store = TestStore(initialState: initial) { RepositoriesFeature() }

    await store.send(.activateSessionSubRow(task: taskA, member: .provisional(harness: .pi, surfaceID: surface(2))))
    await store.receive(\.delegate, .focusSession(location(taskA, 2)))
    await store.finish()
  }

  @Test(.dependencies) func aSubRowClickForATaskNoLongerSelectedDoesNothing() async {
    let store = TestStore(initialState: selectedTaskWithATangent()) { RepositoriesFeature() }
    store.exhaustivity = .off
    await store.send(.sessionSelectionChanged(.task(taskB)))
    store.exhaustivity = .on

    await store.send(.activateSessionSubRow(task: taskA, member: .session(key("b"))))
    await store.finish()
  }

  @Test(.dependencies) func aSubRowClickForAMemberNoLongerListedDoesNothing() async {
    let store = TestStore(initialState: selectedTaskWithATangent()) { RepositoriesFeature() }

    await store.send(.activateSessionSubRow(task: taskA, member: .session(key("gone"))))
    await store.finish()
  }

  @Test(.dependencies) func activatingALiveTaskShowsItWithoutResuming() async {
    let store = TestStore(initialState: twoTasksWithMembers()) { RepositoriesFeature() }
    store.exhaustivity = .off

    await store.send(.activateSession(.task(taskA)))
    await store.receive(\.delegate, .focusTask(taskA, directory: directory))
    await store.finish()
  }

  @Test(.dependencies) func settlingATaskRowNamesTheTaskNotASession() async {
    let store = TestStore(initialState: twoTasksWithMembers()) { RepositoriesFeature() }
    store.exhaustivity = .off

    await store.send(.settleTaskRequested(taskA))
    await store.receive(\.delegate, .settleTask(taskA))
    await store.finish()

    #expect(store.state.sessions.isEmpty, "marking waits for the tabs to close")
  }

  // MARK: - Session list

  @Test(.dependencies) func theSessionListStillNamesEverySessionOfATask() {
    var state = twoTasksWithMembers()
    state.$sessions.withLock { $0[key("b")] = SessionSidecarEntry(settledAt: now, branches: ["topic"]) }
    state = rebuilt(state)

    let rows = SessionQueryResponse.rows(repositories: state)

    #expect(
      rows.map { $0[SessionQueryResponse.Key.id] } == ["pi:a", "pi:b", "pi:c", "pi:solo", "pi:free"],
      "a task's primary, then its other sessions, in sidebar order")
    let tangent = rows[1]
    #expect(tangent[SessionQueryResponse.Key.title] == "Title b")
    #expect(tangent[SessionQueryResponse.Key.lifecycle] == "settled")
    #expect(tangent[SessionQueryResponse.Key.live] == "")
    #expect(tangent[SessionQueryResponse.Key.branch] == "topic")
    #expect(rows[2][SessionQueryResponse.Key.live] == "1")
    #expect(rows[2][SessionQueryResponse.Key.status] == "needs-you")
    #expect(rows[2][SessionQueryResponse.Key.surfaceID] == surface(3).uuidString)
  }

  private func entry(_ id: String, in rows: [[String: String]]) -> [String: String]? {
    let matches = rows.filter { $0[SessionQueryResponse.Key.id] == id }
    return matches.count == 1 ? matches[0] : nil
  }

  @Test(.dependencies) func aPrimaryAnswersForItselfNotForAMoreUrgentTangent() throws {
    let rows = SessionQueryResponse.rows(repositories: twoTasksWithMembers())

    let primary = try #require(entry("pi:a", in: rows))
    #expect(primary[SessionQueryResponse.Key.status] == "idle")
    #expect(primary[SessionQueryResponse.Key.surfaceID] == surface(1).uuidString)
    #expect(primary[SessionQueryResponse.Key.live] == "1")
  }

  @Test(.dependencies) func aDormantPrimaryIsNotLiveBecauseItsTaskHasTabsOrATangent() throws {
    var state = twoTasksWithMembers()
    state.$sessions.withLock { $0[key("a")] = SessionSidecarEntry(settledAt: now, branches: ["old"]) }
    state.sessionSnapshots.removeAll { $0.sessionKey == key("a") || $0.sessionKey == key("solo") }
    state = rebuilt(state)
    #expect(state.sessionItems[id: .task(taskA)]?.isLive == true)

    let rows = SessionQueryResponse.rows(repositories: state)

    let primary = try #require(entry("pi:a", in: rows))
    #expect(primary[SessionQueryResponse.Key.live] == "")
    #expect(primary[SessionQueryResponse.Key.status] == "")
    #expect(primary[SessionQueryResponse.Key.surfaceID] == "")
    #expect(primary[SessionQueryResponse.Key.lifecycle] == "settled", "the session's own mark, tabs or not")
    #expect(primary[SessionQueryResponse.Key.branch] == "old")
    let shellOnly = try #require(entry("pi:solo", in: rows))
    #expect(shellOnly[SessionQueryResponse.Key.live] == "", "an open shell does not run the session")
    #expect(shellOnly[SessionQueryResponse.Key.surfaceID] == "")
  }

  @Test(.dependencies) func aSessionAnswersWithTheDirectoryItRanInNotItsTasks() throws {
    var state = twoTasksWithMembers()
    state.sessionSummaries[0] = summary("a", created: 30, cwd: "/elsewhere/a")
    state.sessionSummaries[1] = summary("b", created: 20, cwd: "/elsewhere/b")
    state = rebuilt(state)
    #expect(state.sessionItems[id: .task(taskA)]?.cwd == "/repo/main")

    let rows = SessionQueryResponse.rows(repositories: state)

    #expect(try #require(entry("pi:a", in: rows))[SessionQueryResponse.Key.cwd] == "/elsewhere/a")
    #expect(try #require(entry("pi:b", in: rows))[SessionQueryResponse.Key.cwd] == "/elsewhere/b")
    #expect(try #require(entry("pi:a", in: rows))[SessionQueryResponse.Key.title] == "Title a")
  }

  @Test(.dependencies) func twoTasksSharingAPrimaryBothListTheirOtherSessions() {
    var state = twoTasksWithMembers()
    state.taskSessions = [taskA: [key("a"), key("b")], taskB: [key("a"), key("c")]]
    state = rebuilt(state)

    let ids = SessionQueryResponse.rows(repositories: state).compactMap { $0[SessionQueryResponse.Key.id] }

    #expect(ids.count == Set(ids).count, "each session once")
    #expect(Set(ids) == ["pi:a", "pi:b", "pi:c", "pi:solo", "pi:free"])
  }

  @Test(.dependencies) func aReportedAgentItsTaskDoesNotListYetIsStillNamed() throws {
    var state = twoTasksWithMembers()
    state.sessionSnapshots.append(agent("late", in: taskA, on: 4, status: .working))
    state = rebuilt(state)

    let late = try #require(entry("pi:late", in: SessionQueryResponse.rows(repositories: state)))
    #expect(late[SessionQueryResponse.Key.status] == "working")
    #expect(late[SessionQueryResponse.Key.surfaceID] == surface(4).uuidString)
  }

  @Test(.dependencies) func anEndedUnindexedTaskIsStillNamedUntilTheNextScan() {
    var state = state()
    state.taskSessions = [taskA: [key("fresh")]]
    state.sessionSnapshots = [agent("fresh", in: taskA, on: 1)]
    state = rebuilt(state)
    state.sessionSnapshots = []
    state = rebuilt(state)
    #expect(state.sessionItems[id: .task(taskA)] != nil)

    let rows = SessionQueryResponse.rows(repositories: state)
    #expect(rows.map { $0[SessionQueryResponse.Key.id] } == ["pi:fresh"])
    #expect(rows.first?[SessionQueryResponse.Key.live] == "")
  }
}

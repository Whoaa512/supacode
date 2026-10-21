import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import Sharing
import Testing

@testable import SupacodeSettingsShared
@testable import supacode

/// A task's ended tangent can be hidden from its sub-rows. The member stays
/// in the record: the row's roll-up, resume and settle never read the mark.
@MainActor
struct SessionsSidebarHiddenMembersTests {
  private let now = Date(timeIntervalSince1970: 1_000)
  private let taskA = LayoutID(task: UUID(uuidString: "00000000-0000-0000-0000-0000000000B1")!)
  private let directory: Worktree.ID = "/repo/main"

  private func key(_ id: String) -> SessionKey { SessionKey(harness: .pi, sessionID: id) }

  private func surface(_ number: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-0000000000%02d", number))!
  }

  private func location(_ number: Int) -> SessionLocation {
    SessionLocation(
      layoutID: taskA, directoryID: directory, tabID: TabID(rawValue: surface(number)), surfaceID: surface(number))
  }

  private func summary(_ id: String, created: TimeInterval) -> SessionSummary {
    SessionSummary(
      harness: .pi, sessionID: id, createdAt: Date(timeIntervalSince1970: created), cwd: "/repo/main",
      title: "Title \(id)", messageCount: 5, lastActivity: Date(timeIntervalSince1970: created))
  }

  private func agent(_ ref: String, on number: Int, status: SessionClassification.Status = .idle)
    -> SessionLiveSnapshot
  {
    SessionLiveSnapshot(
      harness: .pi, sessionRef: ref, cwd: "/repo/main", location: location(number), status: status,
      allowsAttentionNavigation: true)
  }

  /// Task A: primary "a" running, tangent "b" running, tangent "c" ended.
  private func state(sidecar: SessionSidecar = [:]) -> RepositoriesFeature.State {
    var state = RepositoriesFeature.State()
    state.$sessions = Shared(value: sidecar)
    state.$sidebar = Shared(value: SidebarState())
    state.$persistedLayouts = SharedReader(value: TaskLayoutsFile())
    state.sessionsStarted = true
    state.sessionSummaries = [summary("a", created: 30), summary("b", created: 20), summary("c", created: 10)]
    state.taskSessions = [taskA: [key("a"), key("b"), key("c")]]
    state.taskSnapshots = [
      TaskLiveSnapshot(title: "main", cwd: "/repo/main", createdAt: nil, location: location(1))
    ]
    state.sessionSnapshots = [agent("a", on: 1, status: .working), agent("b", on: 2)]
    state.sessionSelection = .task(taskA)
    return rebuilt(state)
  }

  private func rebuilt(_ state: RepositoriesFeature.State) -> RepositoriesFeature.State {
    var state = state
    state.reconcileSessionItems(now: now)
    state.recomputeSessionsSidebarStructureIfChanged()
    return state
  }

  private func subRows(_ state: RepositoriesFeature.State) -> [SessionsSidebarStructure.SubRow] {
    state.sessionsSidebarStructure.subRows
  }

  @Test(.dependencies) func onlyAnEndedTangentIsHideable() {
    let rows = subRows(state())
    #expect(rows.map(\.id) == [.session(key("a")), .session(key("b")), .session(key("c"))])
    #expect(rows.map(\.hideRefusal) == [.primary, .live, nil])
    #expect(rows.map(\.isHideable) == [false, false, true])
  }

  @Test(.dependencies) func hidingDropsTheSubRowAndCountsItOnTheTaskRow() {
    var state = state()
    state.applyHide(key: key("c"), in: taskA, now: now)
    state = rebuilt(state)

    #expect(subRows(state).map(\.id) == [.session(key("a")), .session(key("b"))])
    #expect(state.sessions[key("c")]?.hiddenAt == now, "the mark lives in the sidecar")
    #expect(state.sessionItems[id: .task(taskA)]?.hiddenCount == 1)
    #expect(state.taskSessions[taskA] == [key("a"), key("b"), key("c")], "the record keeps the member")
  }

  @Test(.dependencies) func thePrimaryAndALiveMemberRefuseToHide() {
    var state = state()
    state.applyHide(key: key("a"), in: taskA, now: now)
    state.applyHide(key: key("b"), in: taskA, now: now)
    state = rebuilt(state)

    #expect(state.sessions[key("a")]?.hiddenAt == nil)
    #expect(state.sessions[key("b")]?.hiddenAt == nil)
    #expect(subRows(state).count == 3)
    #expect(state.hideableMembers(of: taskA) == [key("c")])
  }

  @Test(.dependencies) func theRollUpIgnoresAHiddenMember() {
    var shown = state()
    var hidden = state()
    hidden.applyHide(key: key("c"), in: taskA, now: now)
    hidden = rebuilt(hidden)
    shown = rebuilt(shown)

    let before = shown.sessionItems[id: .task(taskA)]
    let after = hidden.sessionItems[id: .task(taskA)]
    #expect(after?.status == before?.status)
    #expect(after?.title == before?.title)
    #expect(after?.lifecycle == before?.lifecycle)
    #expect(after?.hasTangents == true)
    #expect(after?.primary == key("a"))
  }

  @Test(.dependencies) func revealingListsHiddenMembersDimmed() {
    var state = state()
    state.applyHide(key: key("c"), in: taskA, now: now)
    state.revealedHiddenTaskIDs.insert(taskA)
    state = rebuilt(state)

    let rows = subRows(state)
    #expect(rows.map(\.id) == [.session(key("a")), .session(key("b")), .session(key("c"))])
    #expect(rows.map(\.isHidden) == [false, false, true])
    #expect(rows.last?.isHideable == false)

    state.applyUnhide(key: key("c"))
    state = rebuilt(state)
    #expect(subRows(state).map(\.isHidden) == [false, false, false])
    #expect(state.sessionItems[id: .task(taskA)]?.hiddenCount == 0)
  }

  @Test(.dependencies) func aHiddenMemberThatRunsAgainUnhidesItself() {
    var state = state()
    state.applyHide(key: key("c"), in: taskA, now: now)
    state = rebuilt(state)
    #expect(subRows(state).count == 2)

    state.sessionSnapshots.append(agent("c", on: 3, status: .needsYou))
    state = rebuilt(state)

    #expect(state.sessions[key("c")]?.hiddenAt == nil)
    #expect(subRows(state).map(\.id) == [.session(key("a")), .session(key("b")), .session(key("c"))])
    #expect(subRows(state).last?.status == .needsYou)
    #expect(state.sessionItems[id: .task(taskA)]?.hiddenCount == 0)
  }

  @Test(.dependencies) func theChordHidesEveryEndedTangentOfTheSelectedTask() async {
    var initial = state()
    initial.selectedTask = SelectedTask(id: taskA, directoryID: directory)
    let store = TestStore(initialState: initial) {
      RepositoriesFeature()
    } withDependencies: {
      $0.date = .constant(now)
    }
    store.exhaustivity = .off

    await store.send(.hideInactiveSessionsInSelectedTask)
    #expect(store.state.sessions[key("c")]?.hiddenAt == now)
    #expect(store.state.sessions[key("a")]?.hiddenAt == nil)
    #expect(store.state.sessions[key("b")]?.hiddenAt == nil)
  }
}

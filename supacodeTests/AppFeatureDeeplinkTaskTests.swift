import ComposableArchitecture
import Darwin
import DependenciesTestSupport
import Foundation
import Testing

@testable import SupacodeSettingsFeature
@testable import SupacodeSettingsShared
@testable import supacode

/// Worktree-addressed commands when a directory holds more than one task: an
/// id finds its own task, a task segment picks one, and a bare directory keeps
/// meaning the task the directory shows.
@MainActor
struct AppFeatureDeeplinkTaskTests {
  private let worktree = Worktree(
    id: WorktreeID("/tmp/repo/wt-1"),
    name: "wt-1",
    detail: "detail",
    workingDirectory: URL(fileURLWithPath: "/tmp/repo/wt-1"),
    repositoryRootURL: URL(fileURLWithPath: "/tmp/repo"),
  )
  private let sibling = Worktree(
    id: WorktreeID("/tmp/repo/wt-2"),
    name: "wt-2",
    detail: "detail",
    workingDirectory: URL(fileURLWithPath: "/tmp/repo/wt-2"),
    repositoryRootURL: URL(fileURLWithPath: "/tmp/repo"),
  )

  private struct Fixture {
    let id: LayoutID
    let pane = PaneID()
    let tab = UUID()
    let surface = UUID()

    var layout: LayoutFeature.State {
      let item = TabItem(
        id: TabID(rawValue: tab), title: "Tab",
        content: ContentSnapshot(
          id: ContentID(rawValue: surface), state: .terminal(TerminalContentState(workingDirectory: nil))))
      return LayoutFeature.State(
        id: id,
        layout: PaneLayout(tree: SplitTree(view: pane), panes: [Pane(id: pane, tabs: [item], selectedTabID: item.id)]))
    }
  }

  /// The task the directory shows.
  private let shown = Fixture(id: LayoutID(task: UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!))
  /// A second task on the same directory.
  private let other = Fixture(id: LayoutID(task: UUID(uuidString: "00000000-0000-0000-0000-0000000000A2")!))
  /// A task on the sibling directory.
  private let elsewhere = Fixture(id: LayoutID(task: UUID(uuidString: "00000000-0000-0000-0000-0000000000A3")!))

  private func state() -> AppFeature.State {
    var repositories = RepositoriesFeature.State()
    repositories.repositories = [
      Repository(
        id: "/tmp/repo", rootURL: URL(fileURLWithPath: "/tmp/repo"), name: "repo", worktrees: [worktree, sibling])
    ]
    repositories.selection = .worktree(worktree.id)
    repositories.isInitialLoadComplete = true
    var settings = SettingsFeature.State()
    // Closes confirm by default; these tests are about where a command lands.
    settings.automatedActionPolicy = .always
    var state = AppFeature.State(repositories: repositories, settings: settings)
    state.terminals.layouts = [shown.layout, other.layout, elsewhere.layout]
    state.terminals.directories[shown.id] = TaskRecord.Directory(worktreeID: worktree.id)
    state.terminals.directories[other.id] = TaskRecord.Directory(worktreeID: worktree.id)
    state.terminals.directories[elsewhere.id] = TaskRecord.Directory(worktreeID: sibling.id)
    state.terminals.activeTasks[worktree.id] = shown.id
    state.terminals.activeTasks[sibling.id] = elsewhere.id
    return state
  }

  private func makeStore(
    _ initial: AppFeature.State? = nil
  ) -> (store: TestStoreOf<AppFeature>, sent: LockIsolated<[TerminalClient.Command]>) {
    let initial = initial ?? state()
    let sent = LockIsolated<[TerminalClient.Command]>([])
    // Answered from the fixture layouts, per layout, so a command validated
    // against the wrong task fails the way it would in the app.
    let layouts = Dictionary(uniqueKeysWithValues: initial.terminals.layouts.map { ($0.id, $0.layout) })
    let store = TestStore(initialState: initial) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.send = { command in sent.withValue { $0.append(command) } }
      $0.terminalClient.tabExists = { layoutID, tabID in layouts[layoutID]?.pane(containingTab: tabID) != nil }
      $0.terminalClient.paneExists = { layoutID, token in layouts[layoutID]?.pane(forToken: token) != nil }
      $0.terminalClient.surfaceExistsInWorktree = { layoutID, surfaceID in
        layouts[layoutID]?.tab(containingContent: ContentID(rawValue: surfaceID)) != nil
      }
      $0.terminalClient.surfaceExists = { layoutID, _, surfaceID in
        layouts[layoutID]?.tab(containingContent: ContentID(rawValue: surfaceID)) != nil
      }
      $0.terminalClient.tabCanRename = { _, _ in true }
      $0.terminalClient.idExistsAnywhere = { _ in false }
    }
    store.exhaustivity = .off
    return (store, sent)
  }

  private func targets(_ commands: [TerminalClient.Command]) -> [LayoutID] {
    commands.compactMap {
      switch $0 {
      case .selectTab(let layoutID, _, _): layoutID
      case .createTab(let layoutID, _, _, _, _, _, _): layoutID
      case .destroyTab(let layoutID, _, _): layoutID
      case .focusSurface(let layoutID, _, _, _, _): layoutID
      case .destroySurface(let layoutID, _, _, _, _): layoutID
      case .focusPane(let layoutID, _): layoutID
      case .equalizeSplits(let layoutID): layoutID
      default: nil
      }
    }
  }

  // MARK: - Resolution.

  @Test func aDirectoryAloneMeansTheTaskItShows() {
    let terminals = state().terminals
    #expect(terminals.commandLayoutID(forDirectory: worktree.id) == shown.id)
    #expect(terminals.commandLayoutID(forDirectory: sibling.id) == elsewhere.id)
  }

  @Test func anIDFindsTheTaskThatHoldsItOnThatDirectory() {
    let terminals = state().terminals
    for id in [other.tab, other.surface, other.pane.rawValue] {
      #expect(terminals.commandLayoutID(forDirectory: worktree.id, holding: [id]) == other.id)
    }
    #expect(terminals.commandLayoutID(forDirectory: worktree.id, holding: [shown.surface]) == shown.id)
    // The id wins over a task named beside it: a tab lives in one task only.
    #expect(terminals.commandLayoutID(forDirectory: worktree.id, task: shown.id, holding: [other.tab]) == other.id)
  }

  @Test func anIDOnAnotherDirectoryDoesNotCrossOver() {
    let terminals = state().terminals
    // Not found on this directory, so the directory's own answer stands and
    // the command's validation rejects the id against it.
    #expect(terminals.commandLayoutID(forDirectory: worktree.id, holding: [elsewhere.tab]) == shown.id)
  }

  @Test func aNamedTaskHasToSitOnTheDirectory() {
    let terminals = state().terminals
    #expect(terminals.commandLayoutID(forDirectory: worktree.id, task: other.id) == other.id)
    #expect(terminals.commandLayoutID(forDirectory: worktree.id, task: elsewhere.id) == nil)
    #expect(terminals.commandLayoutID(forDirectory: worktree.id, task: LayoutID(task: UUID())) == nil)
  }

  @Test func aDirectoryWithNoTaskStillResolvesToWhereItsFirstTabLands() {
    var terminals = state().terminals
    terminals.layouts = []
    terminals.directories = [:]
    terminals.activeTasks = [:]
    #expect(terminals.commandLayoutID(forDirectory: worktree.id) == worktree.id.layoutID)
    #expect(terminals.commandLayoutID(forDirectory: worktree.id, holding: [UUID()]) == worktree.id.layoutID)
  }

  @Test func cliIDsResolveAsSent() {
    let state = state()
    let directory = "%2Ftmp%2Frepo%2Fwt-1"
    #expect(state.commandLayoutID(externalWorktreeID: directory, externalTaskID: nil) == shown.id)
    // Both spellings of a path name the same directory.
    #expect(state.commandLayoutID(externalWorktreeID: directory + "%2F", externalTaskID: nil) == shown.id)
    #expect(state.commandLayoutID(externalWorktreeID: directory, externalTaskID: "") == shown.id)
    #expect(state.commandLayoutID(externalWorktreeID: directory, externalTaskID: other.id.externalID) == other.id)
    #expect(state.commandLayoutID(externalWorktreeID: directory, externalTaskID: nil, holding: [other.tab]) == other.id)
    #expect(state.commandLayoutID(externalWorktreeID: directory, externalTaskID: elsewhere.id.externalID) == nil)
    #expect(state.commandLayoutID(externalWorktreeID: "", externalTaskID: nil) == nil)
  }

  @Test func aSurfaceIsReachedThroughTheTaskThatHoldsIt() {
    let state = state()
    #expect(state.layoutID(forDirectory: worktree.id, holding: other.surface) == other.id)
    #expect(state.layoutID(forDirectory: worktree.id, holding: shown.surface) == shown.id)
    // An id nothing holds leaves the directory's own answer.
    #expect(state.layoutID(forDirectory: worktree.id, holding: UUID()) == shown.id)
  }

  // MARK: - Commands.

  @Test(.dependencies) func aBareDirectoryCommandGoesToTheShownTask() async {
    let (store, sent) = makeStore()
    await store.send(.deeplink(.worktree(id: worktree.id, action: .paneEqualize)))
    await store.receive(\.repositories.selectWorktree)
    await store.finish()
    #expect(targets(sent.value) == [shown.id])
  }

  @Test(.dependencies) func aTabIDReachesItsTaskAndShowsIt() async {
    let (store, sent) = makeStore()
    await store.send(.deeplink(.worktree(id: worktree.id, action: .tab(tabID: other.tab))))
    await store.receive(\.repositories.selectTask)
    await store.finish()
    #expect(targets(sent.value).contains(other.id))
    #expect(!targets(sent.value).contains(shown.id))
    #expect(store.state.repositories.selectedTask?.id == other.id)
    #expect(store.state.alert == nil)
  }

  @Test(.dependencies) func aSurfaceIDReachesItsTaskEvenWithAStaleTabID() async {
    let (store, sent) = makeStore()
    // The tab segment is a hint: here it names a tab of the shown task.
    let action = Deeplink.WorktreeAction.surface(tabID: shown.tab, surfaceID: other.surface, input: nil)
    await store.send(.deeplink(.worktree(id: worktree.id, action: action, background: true)))
    await store.finish()
    #expect(targets(sent.value) == [other.id])
  }

  @Test(.dependencies) func aTaskSegmentPicksTheTaskForACommandWithNoID() async {
    let (store, sent) = makeStore()
    await store.send(
      .deeplink(.worktree(id: worktree.id, action: .tabNew(input: nil, id: nil), task: other.id)))
    await store.receive(\.repositories.selectTask)
    await store.finish()
    #expect(targets(sent.value).contains(other.id))
    #expect(!targets(sent.value).contains(shown.id))
  }

  @Test(.dependencies) func aBackgroundCommandOnAnotherTaskLeavesTheSelectionAlone() async {
    let (store, sent) = makeStore()
    await store.send(
      .deeplink(.worktree(id: worktree.id, action: .tabNew(input: nil, id: nil), background: true, task: other.id)))
    await store.finish()
    #expect(targets(sent.value) == [other.id])
    #expect(store.state.repositories.selectedTask == nil)
  }

  @Test(.dependencies) func aTaskThatIsNotTheDirectorysIsRefused() async {
    for task in [elsewhere.id, LayoutID(task: UUID())] {
      let (store, sent) = makeStore()
      await store.send(
        .deeplink(.worktree(id: worktree.id, action: .tabNew(input: nil, id: nil), task: task)))
      await store.finish()
      #expect(sent.value.isEmpty)
      #expect(store.state.alert != nil)
      #expect(store.state.repositories.selectedTask == nil)
    }
  }

  @Test(.dependencies) func closingATabClosesItInItsOwnTaskOnly() async {
    let (store, sent) = makeStore()
    await store.send(
      .deeplink(.worktree(id: worktree.id, action: .tabDestroy(tabID: other.tab), background: true)))
    await store.finish()
    let closed: [(LayoutID, TabID)] = sent.value.compactMap {
      if case .destroyTab(let layoutID, let tabID, _) = $0 { return (layoutID, tabID) }
      return nil
    }
    #expect(closed.count == 1)
    #expect(closed.first?.0 == other.id)
    #expect(closed.first?.1 == TabID(rawValue: other.tab))
  }

  @Test(.dependencies) func closingATabOfAnotherDirectoryClosesNothing() async {
    let (store, sent) = makeStore()
    await store.send(
      .deeplink(.worktree(id: worktree.id, action: .tabDestroy(tabID: elsewhere.tab), background: true)))
    await store.finish()
    #expect(sent.value.isEmpty)
    #expect(store.state.alert != nil)
  }

  @Test(.dependencies) func aNamedTaskSurvivesTheConfirmation() async {
    var initial = state()
    initial.settings.automatedActionPolicy = .never
    let (store, sent) = makeStore(initial)
    let action = Deeplink.WorktreeAction.tabNew(input: "echo hi", id: nil)
    await store.send(.deeplink(.worktree(id: worktree.id, action: action, background: true, task: other.id)))
    #expect(store.state.deeplinkInputConfirmation?.task == other.id)
    #expect(sent.value.isEmpty)
    await withKnownIssue("TCA @Presents dismiss tracking") {
      await store.send(
        .deeplinkInputConfirmation(
          .presented(.delegate(.confirm(worktreeID: worktree.id, action: action, alwaysAllow: false)))))
    }
    await store.finish()
    let created: [LayoutID] = sent.value.compactMap {
      if case .createTabWithInput(let layoutID, _, _, _, _, _, _, _) = $0 { return layoutID }
      return nil
    }
    #expect(created == [other.id])
  }

  // MARK: - Acks.

  @Test(.dependencies) func aTabNewAckWaitsForTheTaskItWasSentTo() async {
    var fds: [Int32] = [0, 0]
    precondition(fds.withUnsafeMutableBufferPointer { Darwin.pipe($0.baseAddress!) } == 0)
    let (readFD, writeFD) = (fds[0], fds[1])
    defer { close(readFD) }
    let newID = UUID()
    let (store, _) = makeStore()

    await store.send(
      .deeplink(
        .worktree(id: worktree.id, action: .tabNew(input: nil, id: newID), background: true, task: other.id),
        // `timeoutSeconds: 0` skips the watchdog, so no clock is needed.
        source: .socket, responseFD: writeFD, timeoutSeconds: 0))
    #expect(store.state.pendingCommandAcks[id: writeFD]?.match == .tabInWorktree(layoutID: other.id, tabID: newID))

    // The same id reported by the task the directory shows is not this command's.
    await store.send(.terminalEvent(.surfaceCreated(layoutID: shown.id, id: newID)))
    #expect(store.state.pendingCommandAcks[id: writeFD] != nil)

    // The directory moving on to another task does not strand the ack.
    await store.send(.terminalEvent(.surfaceCreated(layoutID: other.id, id: newID)))
    await store.finish()
    #expect(store.state.pendingCommandAcks.isEmpty)
  }
}

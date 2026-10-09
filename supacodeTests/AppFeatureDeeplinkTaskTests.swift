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

  /// `gone` names layouts the terminal no longer has although the state still
  /// lists them: a target closed while a confirmation waited.
  private func makeStore(
    _ initial: AppFeature.State? = nil,
    gone: LockIsolated<Set<LayoutID>> = LockIsolated([]),
    running: [LayoutID: [ScriptDefinition]] = [:]
  ) -> (store: TestStoreOf<AppFeature>, sent: LockIsolated<[TerminalClient.Command]>) {
    var initial = initial ?? state()
    // The row mirrors what runs anywhere on its directory, as the terminal's
    // merged projection would have told it.
    initial.repositories.reconcileSidebarForTesting()
    for (directoryID, layoutIDs) in [worktree.id: [shown.id, other.id], sibling.id: [elsewhere.id]] {
      for definition in layoutIDs.flatMap({ running[$0] ?? [] }) {
        initial.repositories.sidebarItems[id: directoryID]?.runningScripts[id: definition.id] =
          .init(id: definition.id, tint: definition.resolvedTintColor)
      }
    }
    let sent = LockIsolated<[TerminalClient.Command]>([])
    // Answered from the fixture layouts, per layout, so a command validated
    // against the wrong task fails the way it would in the app.
    let all = Dictionary(uniqueKeysWithValues: initial.terminals.layouts.map { ($0.id, $0.layout) })
    let layouts = LiveLayouts(all: all, gone: gone)
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
      $0.terminalClient.runningScripts = { running[$0] ?? [] }
      $0.terminalClient.idExistsAnywhere = { _ in false }
      // A surface close fans out to the agent-presence persist effect.
      $0.continuousClock = ImmediateClock()
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.terminalClient.saveLayoutsWithAgents = { _ in }
    }
    store.exhaustivity = .off
    return (store, sent)
  }

  private struct LiveLayouts: Sendable {
    let all: [LayoutID: PaneLayout]
    let gone: LockIsolated<Set<LayoutID>>

    subscript(id: LayoutID) -> PaneLayout? { gone.value.contains(id) ? nil : all[id] }
  }

  private func confirming() -> AppFeature.State {
    var initial = state()
    initial.settings.automatedActionPolicy = .never
    return initial
  }

  private func confirm(_ action: Deeplink.WorktreeAction, in store: TestStoreOf<AppFeature>) async {
    await withKnownIssue("TCA @Presents dismiss tracking") {
      await store.send(
        .deeplinkInputConfirmation(
          .presented(.delegate(.confirm(worktreeID: worktree.id, action: action, alwaysAllow: false)))))
    }
    await store.finish()
  }

  private let runScript = ScriptDefinition(kind: .run, name: "Run", command: "npm start")
  private let testScript = ScriptDefinition(kind: .test, name: "Test", command: "npm test")

  /// Both scripts configured on the repository for the length of `body`.
  private func withScripts(_ body: () async -> Void) async {
    @Shared(.repositorySettings(worktree.repositoryRootURL)) var persisted = .default
    $persisted.withLock { $0.scripts = [runScript, testScript] }
    await body()
    $persisted.withLock { $0.scripts = [] }
  }

  /// Every script start and stop a run of commands asked for, with its layout.
  private func scriptCommands(_ commands: [TerminalClient.Command]) -> [String] {
    commands.compactMap {
      switch $0 {
      case .runBlockingScript(let layoutID, _, .script(let definition), _, _):
        "run \(layoutID.externalID) \(definition.id)"
      case .stopScript(let layoutID, _, let definitionID, _): "stop \(layoutID.externalID) \(definitionID)"
      case .stopRunScript(let layoutID, _, _): "stop-run \(layoutID.externalID)"
      default: nil
      }
    }
  }

  private func socketResponse(_ fileDescriptor: Int32) -> [String: Any]? {
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
      let count = buffer.withUnsafeMutableBufferPointer { Darwin.read(fileDescriptor, $0.baseAddress!, $0.count) }
      guard count > 0 else { break }
      data.append(contentsOf: buffer.prefix(count))
    }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
  }

  private func pipe() -> (read: Int32, write: Int32) {
    var fds: [Int32] = [0, 0]
    precondition(fds.withUnsafeMutableBufferPointer { Darwin.pipe($0.baseAddress!) } == 0)
    return (fds[0], fds[1])
  }

  /// Every close a run of commands asked for, as (layout, target).
  private func closes(_ commands: [TerminalClient.Command]) -> [String] {
    commands.compactMap {
      switch $0 {
      case .destroySurface(let layoutID, _, let tabID, let surfaceID, _):
        "surface \(layoutID.externalID) \(tabID.rawValue) \(surfaceID)"
      case .closePane(let layoutID, let token): "pane \(layoutID.externalID) \(token)"
      case .destroyTab(let layoutID, let tabID, _): "tab \(layoutID.externalID) \(tabID.rawValue)"
      default: nil
      }
    }
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
      case .stopRunScript(let layoutID, _, _): layoutID
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

  // MARK: - A task selected, not yet echoed by the terminal.

  /// The user picked `other`; the directory's active task still says `shown`.
  private func selectedBeforeTheEcho() -> AppFeature.State {
    var initial = state()
    initial.repositories.selectedTask = SelectedTask(id: other.id, directoryID: worktree.id)
    return initial
  }

  @Test func aJustSelectedTaskIsWhatTheDirectoryMeans() {
    let state = selectedBeforeTheEcho()
    let directory = "%2Ftmp%2Frepo%2Fwt-1"
    #expect(state.commandLayoutID(forDirectory: worktree.id) == other.id)
    #expect(state.commandLayoutID(externalWorktreeID: directory, externalTaskID: nil) == other.id)
    #expect(state.layoutID(forDirectory: worktree.id, holding: UUID()) == other.id)
    // An id or a named task still decides first.
    #expect(state.commandLayoutID(forDirectory: worktree.id, holding: [shown.tab]) == shown.id)
    #expect(state.commandLayoutID(forDirectory: worktree.id, task: shown.id) == shown.id)
    #expect(state.commandLayoutID(externalWorktreeID: directory, externalTaskID: shown.id.externalID) == shown.id)
    // The selection is another directory's: it says nothing about this one.
    #expect(state.commandLayoutID(forDirectory: sibling.id) == elsewhere.id)
  }

  @Test(.dependencies) func aBareCommandFollowsAJustSelectedTaskAndDoesNotSelectTheOldOneBack() async {
    let (store, sent) = makeStore(selectedBeforeTheEcho())
    await store.send(.deeplink(.worktree(id: worktree.id, action: .paneEqualize)))
    await store.receive(\.repositories.selectWorktree)
    await store.finish()
    #expect(targets(sent.value).filter { $0 == shown.id || $0 == other.id } == [other.id])
    #expect(store.state.repositories.selectedTask?.id == other.id)
  }

  @Test(.dependencies) func aBareBackgroundCommandFollowsAJustSelectedTask() async {
    let (store, sent) = makeStore(selectedBeforeTheEcho())
    for action in [Deeplink.WorktreeAction.tabNew(input: nil, id: nil), .paneEqualize, .stop] {
      await store.send(.deeplink(.worktree(id: worktree.id, action: action, background: true)))
    }
    await store.finish()
    #expect(targets(sent.value) == [other.id, other.id, other.id])
    #expect(store.state.repositories.selectedTask?.id == other.id)
  }

  @Test(.dependencies) func stoppingTheRunScriptGoesToTheNamedTask() async {
    let (store, sent) = makeStore()
    await store.send(.deeplink(.worktree(id: worktree.id, action: .stop, background: true, task: other.id)))
    await store.finish()
    #expect(targets(sent.value) == [other.id])
  }

  // MARK: - Starting a script.

  @Test(.dependencies) func aBareRunStartsTheRunScriptInTheTaskTheDirectoryShows() async {
    await withScripts {
      for (initial, expected) in [(state(), shown.id), (selectedBeforeTheEcho(), other.id)] {
        for background in [true, false] {
          let (store, sent) = makeStore(initial)
          await store.send(.deeplink(.worktree(id: worktree.id, action: .run, background: background)))
          await store.finish()
          #expect(scriptCommands(sent.value) == ["run \(expected.externalID) \(runScript.id)"])
          #expect(store.state.alert == nil)
        }
      }
    }
  }

  @Test(.dependencies) func aRunNamingATaskStartsTheRunScriptThere() async {
    await withScripts {
      // The selection says `other`; the command names `shown`.
      let (store, sent) = makeStore(selectedBeforeTheEcho())
      await store.send(.deeplink(.worktree(id: worktree.id, action: .run, background: true, task: shown.id)))
      await store.finish()
      #expect(scriptCommands(sent.value) == ["run \(shown.id.externalID) \(runScript.id)"])
    }
  }

  @Test(.dependencies) func aNamedScriptRunsInTheTaskTheCommandNames() async {
    await withScripts {
      let action = Deeplink.WorktreeAction.runScript(scriptID: testScript.id)
      for (initial, task) in [(state(), other.id), (selectedBeforeTheEcho(), shown.id)] {
        let (store, sent) = makeStore(initial)
        await store.send(.deeplink(.worktree(id: worktree.id, action: action, background: true, task: task)))
        await store.finish()
        #expect(scriptCommands(sent.value) == ["run \(task.externalID) \(testScript.id)"])
      }
      // No task named: the one the directory shows.
      for (initial, expected) in [(state(), shown.id), (selectedBeforeTheEcho(), other.id)] {
        let (store, sent) = makeStore(initial)
        await store.send(.deeplink(.worktree(id: worktree.id, action: action, background: true)))
        await store.finish()
        #expect(scriptCommands(sent.value) == ["run \(expected.externalID) \(testScript.id)"])
      }
    }
  }

  @Test(.dependencies) func aNamedScriptWaitsForTheConfirmationThenRunsInTheNamedTask() async {
    await withScripts {
      let action = Deeplink.WorktreeAction.runScript(scriptID: testScript.id)
      let (store, sent) = makeStore(confirming())
      await store.send(.deeplink(.worktree(id: worktree.id, action: action, background: true, task: other.id)))
      #expect(store.state.deeplinkInputConfirmation?.task == other.id)
      #expect(sent.value.isEmpty)
      await confirm(action, in: store)
      #expect(scriptCommands(sent.value) == ["run \(other.id.externalID) \(testScript.id)"])
    }
  }

  @Test(.dependencies) func aCancelledNamedScriptRunsNothing() async {
    await withScripts {
      let action = Deeplink.WorktreeAction.runScript(scriptID: testScript.id)
      let (store, sent) = makeStore(confirming())
      await store.send(.deeplink(.worktree(id: worktree.id, action: action, background: true, task: other.id)))
      #expect(store.state.deeplinkInputConfirmation != nil)
      await withKnownIssue("TCA @Presents dismiss tracking") {
        await store.send(.deeplinkInputConfirmation(.presented(.delegate(.cancel))))
      }
      await store.finish()
      #expect(store.state.deeplinkInputConfirmation == nil)
      #expect(sent.value.isEmpty)
    }
  }

  /// The named task is removed while the dialog waits. The script must not
  /// start in the task the directory shows instead.
  @Test(.dependencies) func aNamedScriptWhoseTaskWentAwayDuringTheConfirmationRunsNothing() async {
    await withScripts {
      let action = Deeplink.WorktreeAction.runScript(scriptID: testScript.id)
      var removed = confirming()
      removed.terminals.layouts.remove(id: other.id)
      removed.terminals.directories[other.id] = nil
      removed.deeplinkInputConfirmation = DeeplinkInputConfirmationFeature.State(
        worktreeID: worktree.id, worktreeName: worktree.name, repositoryName: "repo",
        message: .command(testScript.command), action: action, background: true, task: other.id)
      let (store, sent) = makeStore(removed)
      await confirm(action, in: store)
      #expect(sent.value.isEmpty)
      #expect(store.state.alert != nil)
    }
  }

  @Test(.dependencies) func aScriptAlreadyRunningOnTheDirectoryIsNotStartedInAnotherTask() async {
    await withScripts {
      let (store, sent) = makeStore(running: [shown.id: [testScript]])
      let action = Deeplink.WorktreeAction.runScript(scriptID: testScript.id)
      await store.send(.deeplink(.worktree(id: worktree.id, action: action, background: true, task: other.id)))
      await store.finish()
      #expect(sent.value.isEmpty)
      #expect(store.state.alert != nil)
    }
  }

  // MARK: - Stopping a script that runs in one of the directory's tasks.

  @Test(.dependencies) func stoppingAScriptInATaskThatDoesNotRunItFailsAndLeavesTheOtherTaskAlone() async {
    await withScripts {
      // The script runs in the shown task; the command names the other one.
      let (readFD, writeFD) = pipe()
      defer { close(readFD) }
      let (store, sent) = makeStore(running: [shown.id: [testScript]])
      await store.send(
        .deeplink(
          .worktree(
            id: worktree.id, action: .stopScript(scriptID: testScript.id), background: true, task: other.id),
          source: .socket, responseFD: writeFD, timeoutSeconds: 0))
      await store.finish()
      let response = socketResponse(readFD)
      #expect(response?["ok"] as? Bool == false)
      #expect((response?["error"] as? String)?.isEmpty == false)
      #expect(sent.value.isEmpty)
    }
  }

  @Test(.dependencies) func stoppingAScriptInTheTaskThatRunsItStopsItThereOnly() async {
    await withScripts {
      let (readFD, writeFD) = pipe()
      defer { close(readFD) }
      let (store, sent) = makeStore(running: [other.id: [testScript], shown.id: [runScript]])
      await store.send(
        .deeplink(
          .worktree(
            id: worktree.id, action: .stopScript(scriptID: testScript.id), background: true, task: other.id),
          source: .socket, responseFD: writeFD, timeoutSeconds: 0))
      await store.finish()
      #expect(socketResponse(readFD)?["ok"] as? Bool == true)
      #expect(scriptCommands(sent.value) == ["stop \(other.id.externalID) \(testScript.id)"])
    }
  }

  /// A script runs once on a directory, so a stop that names no task means
  /// that one run, whichever task the directory shows.
  @Test(.dependencies) func aBareScriptStopFindsTheTaskThatRunsIt() async {
    await withScripts {
      for initial in [state(), selectedBeforeTheEcho()] {
        for runner in [shown.id, other.id] {
          let (store, sent) = makeStore(initial, running: [runner: [testScript]])
          await store.send(
            .deeplink(
              .worktree(id: worktree.id, action: .stopScript(scriptID: testScript.id), background: true)))
          await store.finish()
          #expect(scriptCommands(sent.value) == ["stop \(runner.externalID) \(testScript.id)"])
          #expect(store.state.alert == nil)
        }
      }
    }
  }

  @Test(.dependencies) func aScriptStopFailsWhenNoTaskOnTheDirectoryRunsIt() async {
    await withScripts {
      // Running on the sibling directory only.
      let (store, sent) = makeStore(running: [elsewhere.id: [testScript]])
      await store.send(
        .deeplink(.worktree(id: worktree.id, action: .stopScript(scriptID: testScript.id), background: true)))
      await store.finish()
      #expect(sent.value.isEmpty)
      #expect(store.state.alert != nil)
    }
  }

  @Test(.dependencies) func aBareRunStopFindsEveryTaskRunningARunScript() async {
    await withScripts {
      let (store, sent) = makeStore(running: [other.id: [runScript], shown.id: [testScript]])
      await store.send(.deeplink(.worktree(id: worktree.id, action: .stop, background: true)))
      await store.finish()
      #expect(scriptCommands(sent.value) == ["stop-run \(other.id.externalID)"])
    }
  }

  @Test(.dependencies) func aNamedRunStopStaysInThatTask() async {
    await withScripts {
      let (store, sent) = makeStore(running: [other.id: [runScript]])
      await store.send(.deeplink(.worktree(id: worktree.id, action: .stop, background: true, task: shown.id)))
      await store.finish()
      #expect(scriptCommands(sent.value) == ["stop-run \(shown.id.externalID)"])
    }
  }

  /// The toolbar lists what runs anywhere on the directory, so its stop has
  /// to reach the task that runs it, not only the one shown.
  @Test(.dependencies) func theToolbarStopsReachTheTaskThatRunsTheScript() async {
    await withScripts {
      let (store, sent) = makeStore(running: [other.id: [runScript, testScript]])
      await store.send(.stopScript(testScript))
      await store.send(.stopRunScripts)
      await store.finish()
      #expect(
        scriptCommands(sent.value)
          == ["stop \(other.id.externalID) \(testScript.id)", "stop-run \(other.id.externalID)"])
    }
  }

  // MARK: - Surface close.

  @Test(.dependencies) func closingASurfaceClosesItInItsOwnTaskOnlyAndAcksOnThatTask() async {
    let (readFD, writeFD) = pipe()
    defer { close(readFD) }
    let (store, sent) = makeStore()
    // The tab segment is stale: it names a tab of the shown task.
    let action = Deeplink.WorktreeAction.surfaceDestroy(tabID: shown.tab, surfaceID: other.surface)
    await store.send(
      .deeplink(
        .worktree(id: worktree.id, action: action, background: true),
        source: .socket, responseFD: writeFD, timeoutSeconds: 0))
    #expect(closes(sent.value) == ["surface \(other.id.externalID) \(shown.tab) \(other.surface)"])
    #expect(
      store.state.pendingCommandAcks[id: writeFD]?.match
        == .surfaceClosed(layoutID: other.id, surfaceID: other.surface))

    // The shown task reporting that id closed is not this command's ack.
    await store.send(.terminalEvent(.surfacesClosed(layoutID: shown.id, [other.surface])))
    #expect(store.state.pendingCommandAcks[id: writeFD] != nil)
    await store.send(.terminalEvent(.surfacesClosed(layoutID: other.id, [other.surface])))
    await store.finish()
    #expect(store.state.pendingCommandAcks.isEmpty)
    #expect(closes(sent.value).count == 1)
  }

  @Test(.dependencies) func aSurfaceCloseWaitsForTheConfirmationThenClosesInItsOwnTask() async {
    let (store, sent) = makeStore(confirming())
    let action = Deeplink.WorktreeAction.surfaceDestroy(tabID: shown.tab, surfaceID: other.surface)
    await store.send(.deeplink(.worktree(id: worktree.id, action: action, background: true)))
    #expect(store.state.deeplinkInputConfirmation != nil)
    #expect(sent.value.isEmpty)
    await confirm(action, in: store)
    #expect(closes(sent.value) == ["surface \(other.id.externalID) \(shown.tab) \(other.surface)"])
  }

  @Test(.dependencies) func aCancelledCloseClosesNothing() async {
    let actions: [Deeplink.WorktreeAction] = [
      .surfaceDestroy(tabID: other.tab, surfaceID: other.surface),
      .paneDestroy(token: other.pane.rawValue),
      .tabDestroy(tabID: other.tab),
    ]
    for action in actions {
      let (store, sent) = makeStore(confirming())
      await store.send(.deeplink(.worktree(id: worktree.id, action: action, background: true)))
      #expect(store.state.deeplinkInputConfirmation != nil)
      await withKnownIssue("TCA @Presents dismiss tracking") {
        await store.send(.deeplinkInputConfirmation(.presented(.delegate(.cancel))))
      }
      await store.finish()
      #expect(store.state.deeplinkInputConfirmation == nil)
      #expect(sent.value.isEmpty)
    }
  }

  /// The target goes away while the dialog waits. The stale tab hint names a
  /// tab the shown task does hold, which must not turn the close onto it.
  @Test(.dependencies) func aCloseWhoseTargetWentAwayDuringTheConfirmationClosesNothing() async {
    let actions: [Deeplink.WorktreeAction] = [
      .surfaceDestroy(tabID: shown.tab, surfaceID: other.surface),
      .surfaceDestroy(tabID: other.tab, surfaceID: other.surface),
      .paneDestroy(token: other.pane.rawValue),
      .paneDestroy(token: other.tab),
      .tabDestroy(tabID: other.tab),
    ]
    for action in actions {
      // The terminal dropped the task; the state has not caught up.
      let gone = LockIsolated<Set<LayoutID>>([])
      let (store, sent) = makeStore(confirming(), gone: gone)
      await store.send(.deeplink(.worktree(id: worktree.id, action: action, background: true)))
      #expect(store.state.deeplinkInputConfirmation != nil)
      gone.setValue([other.id])
      await confirm(action, in: store)
      #expect(sent.value.isEmpty, "\(action)")
      #expect(store.state.alert != nil, "\(action)")

      // The state caught up too: the task is gone from it, so the directory
      // resolves to the shown task, which holds none of these targets.
      var removed = confirming()
      removed.terminals.layouts.remove(id: other.id)
      removed.terminals.directories[other.id] = nil
      let (late, lateSent) = makeStore(removed)
      await confirm(action, in: late)
      #expect(lateSent.value.isEmpty, "\(action)")
      #expect(late.state.alert != nil, "\(action)")
    }
  }

  @Test(.dependencies) func closingASurfaceOrPaneOfAnotherDirectoryClosesNothing() async {
    let actions: [Deeplink.WorktreeAction] = [
      .surfaceDestroy(tabID: elsewhere.tab, surfaceID: elsewhere.surface),
      // A tab of this directory beside a surface of the other one.
      .surfaceDestroy(tabID: other.tab, surfaceID: elsewhere.surface),
      .paneDestroy(token: elsewhere.pane.rawValue),
      .paneDestroy(token: elsewhere.surface),
    ]
    for action in actions {
      let (store, sent) = makeStore()
      await store.send(.deeplink(.worktree(id: worktree.id, action: action, background: true)))
      await store.finish()
      #expect(sent.value.isEmpty, "\(action)")
      #expect(store.state.alert != nil, "\(action)")
      #expect(store.state.pendingCommandAcks.isEmpty)
    }
  }

  // MARK: - Pane close.

  @Test(.dependencies) func closingAPaneClosesItInItsOwnTaskOnly() async {
    // A pane token is a pane, tab or content id.
    for token in [other.pane.rawValue, other.tab, other.surface] {
      let (store, sent) = makeStore()
      await store.send(
        .deeplink(.worktree(id: worktree.id, action: .paneDestroy(token: token), background: true)))
      await store.finish()
      #expect(closes(sent.value) == ["pane \(other.id.externalID) \(token)"])
      #expect(store.state.alert == nil)
    }
  }

  @Test(.dependencies) func aPaneCloseWaitsForTheConfirmationThenClosesInItsOwnTask() async {
    let (store, sent) = makeStore(confirming())
    let action = Deeplink.WorktreeAction.paneDestroy(token: other.pane.rawValue)
    await store.send(.deeplink(.worktree(id: worktree.id, action: action, background: true)))
    #expect(store.state.deeplinkInputConfirmation != nil)
    #expect(sent.value.isEmpty)
    await confirm(action, in: store)
    #expect(closes(sent.value) == ["pane \(other.id.externalID) \(other.pane.rawValue)"])
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

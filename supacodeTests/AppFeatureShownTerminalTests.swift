import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import Testing

@testable import SupacodeSettingsFeature
@testable import SupacodeSettingsShared
@testable import supacode

/// Menu terminal commands with no id of their own act on the terminal on
/// screen: the shown task, orphan or not, never the task the directory
/// recorded while the user already looks at another.
@MainActor
struct AppFeatureShownTerminalTests {
  private let worktree = Worktree(
    id: WorktreeID("/tmp/repo/wt-1"),
    name: "wt-1",
    detail: "detail",
    workingDirectory: URL(fileURLWithPath: "/tmp/repo/wt-1"),
    repositoryRootURL: URL(fileURLWithPath: "/tmp/repo")
  )
  private let orphanDirectory = WorktreeID("/tmp/gone/wt-9")
  private let taskA = LayoutID(task: UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!)
  private let taskB = LayoutID(task: UUID(uuidString: "00000000-0000-0000-0000-0000000000B2")!)
  private let orphan = LayoutID(task: UUID(uuidString: "00000000-0000-0000-0000-0000000000C3")!)
  private let focusedTab = TabID(rawValue: UUID())

  private func layout(_ id: LayoutID, tabs: Int = 1) -> LayoutFeature.State {
    let pane = PaneID()
    let items = (0..<tabs).map { _ in
      TabItem(
        id: TabID(rawValue: UUID()), title: "Tab",
        content: ContentSnapshot(
          id: ContentID(rawValue: UUID()), state: .terminal(TerminalContentState(workingDirectory: nil))))
    }
    return LayoutFeature.State(
      id: id,
      layout: PaneLayout(
        tree: SplitTree(view: pane),
        panes: [Pane(id: pane, tabs: IdentifiedArray(uniqueElements: items), selectedTabID: items.first?.id)]))
  }

  private func rosterState(selected: Bool = true, missing: Bool = false) -> AppFeature.State {
    let listed =
      missing
      ? Worktree(
        id: worktree.id, name: worktree.name, detail: worktree.detail, workingDirectory: worktree.workingDirectory,
        repositoryRootURL: worktree.repositoryRootURL, isMissing: true)
      : worktree
    var repositories = RepositoriesFeature.State()
    repositories.repositories = [
      Repository(id: "/tmp/repo", rootURL: URL(fileURLWithPath: "/tmp/repo"), name: "repo", worktrees: [listed])
    ]
    if selected { repositories.selection = .worktree(worktree.id) }
    repositories.isInitialLoadComplete = true
    repositories.reconcileSidebarForTesting()
    return AppFeature.State(repositories: repositories, settings: SettingsFeature.State())
  }

  /// Two tasks on the directory; the terminal recorded A, the user picked B.
  private func echoWindowState() -> AppFeature.State {
    var state = rosterState()
    state.terminals.layouts = [layout(taskA), layout(taskB)]
    state.terminals.directories[taskA] = TaskRecord.Directory(worktreeID: worktree.id)
    state.terminals.directories[taskB] = TaskRecord.Directory(worktreeID: worktree.id)
    state.terminals.activeTasks[worktree.id] = taskA
    state.repositories.selectedTask = SelectedTask(id: taskB, directoryID: worktree.id)
    return state
  }

  /// An orphan task shown: its directory is in no roster, nothing else selected.
  private func orphanState(hosted: Bool = true) -> AppFeature.State {
    var state = rosterState(selected: false)
    if hosted {
      state.terminals.layouts = [layout(orphan)]
      state.terminals.directories[orphan] = TaskRecord.Directory(worktreeID: orphanDirectory)
    }
    state.repositories.selectedTask = SelectedTask(id: orphan, directoryID: orphanDirectory)
    return state
  }

  private func makeStore(_ initial: AppFeature.State) -> (
    TestStoreOf<AppFeature>, LockIsolated<[TerminalClient.Command]>
  ) {
    let sent = LockIsolated<[TerminalClient.Command]>([])
    let store = TestStore(initialState: initial) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.send = { command in sent.withValue { $0.append(command) } }
      $0.terminalClient.selectedTabID = { [focusedTab] _ in focusedTab }
      $0.analyticsClient.capture = { _, _ in }
    }
    store.exhaustivity = .off
    return (store, sent)
  }

  @Test(.dependencies) func anOrphanTaskTakesTheMenuTerminalCommands() async {
    let (store, sent) = makeStore(orphanState())
    let context = DirectoryContext(orphan: TaskRecord.Directory(worktreeID: orphanDirectory))

    await store.send(.selectNextTerminalTab)
    await store.send(.closeTab)
    await store.send(.splitTerminal(.right))
    await store.send(.startSearch)
    await store.send(.renameSelectedTerminalTab)
    await store.send(.newTerminal)
    await store.finish()

    #expect(
      sent.value == [
        .selectRelativeTab(orphan, forward: true),
        .closeFocusedTab(orphan, context),
        .splitFocusedPane(orphan, direction: .right),
        .startSearch(orphan, context),
        .beginTabRename(orphan, context, tabID: focusedTab),
        .createTab(orphan, context, runSetupScriptIfNew: false),
      ])
  }

  @Test(.dependencies) func aTaskSelectedButNotYetEchoedIsTheTarget() async {
    let (store, sent) = makeStore(echoWindowState())
    await store.send(.selectNextTerminalTab)
    await store.send(.closeTab)
    await store.send(.closeSurface)
    await store.finish()

    let context = DirectoryContext(worktree: worktree)
    #expect(
      sent.value == [
        .selectRelativeTab(taskB, forward: true),
        .closeFocusedTab(taskB, context),
        .closeFocusedSurface(taskB, context),
      ])
    #expect(!sent.value.contains { $0 == .closeFocusedTab(taskA, context) })
  }

  @Test(.dependencies) func shownTerminalTable() {
    let orphanShown = orphanState().shownTerminal
    #expect(orphanShown?.layoutID == orphan)
    #expect(orphanShown?.directory == DirectoryContext(orphan: TaskRecord.Directory(worktreeID: orphanDirectory)))

    let withTask = echoWindowState().shownTerminal
    #expect(withTask?.layoutID == taskB)
    #expect(withTask?.directory == DirectoryContext(worktree: worktree))

    let empty = rosterState().shownTerminal
    #expect(empty != nil)
    #expect(empty?.layoutID == nil)

    #expect(rosterState(missing: true).shownTerminal == nil)

    #expect(rosterState(selected: false).shownTerminal == nil)
    #expect(orphanState(hosted: false).shownTerminal == nil)
  }

  @Test(.dependencies) func aDirectoryWithNoTaskSendsNothingButNewTerminal() async {
    let (store, sent) = makeStore(rosterState())
    await store.send(.renameSelectedTerminalTab)
    await store.send(.selectTerminalTabAtIndex(1))
    await store.send(.selectNextTerminalTab)
    await store.send(.selectPreviousTerminalTab)
    await store.send(.splitTerminal(.down))
    await store.send(.focusSplit(.left))
    await store.send(.focusRelativePane(forward: true))
    await store.send(.toggleSplitZoom)
    await store.send(.equalizeSplits)
    await store.send(.toggleWindowModeForFocusedPane)
    await store.send(.closeTab)
    await store.send(.closeSurface)
    await store.send(.startSearch)
    await store.send(.searchSelection)
    await store.send(.navigateSearchNext)
    await store.send(.navigateSearchPrevious)
    await store.send(.commandPalette(.delegate(.ghosttyCommand("copy_to_clipboard"))))
    await store.finish()
    #expect(sent.value.isEmpty)
  }

  @Test(.dependencies) func directoryFeaturesStayOffAnOrphan() async {
    let (store, sent) = makeStore(orphanState())
    await store.send(.runScript)
    await store.send(.stopRunScripts)
    await store.finish()
    #expect(sent.value.isEmpty)
  }
}

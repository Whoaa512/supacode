import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import Testing

@testable import SupacodeSettingsFeature
@testable import SupacodeSettingsShared
@testable import supacode

/// A directory with no task: nothing is derived from its path. The first tab
/// mints a task (D2), remembered until that tab exists so a second command in
/// that window joins it, and the mint follows the still-selected directory
/// without ever becoming a task pick.
@MainActor
struct AppFeatureFirstTabTests {
  private let worktree = Worktree(
    id: WorktreeID("/tmp/repo/wt-1"),
    name: "wt-1",
    detail: "detail",
    workingDirectory: URL(fileURLWithPath: "/tmp/repo/wt-1"),
    repositoryRootURL: URL(fileURLWithPath: "/tmp/repo")
  )
  private let sibling = Worktree(
    id: WorktreeID("/tmp/repo/wt-2"),
    name: "wt-2",
    detail: "detail",
    workingDirectory: URL(fileURLWithPath: "/tmp/repo/wt-2"),
    repositoryRootURL: URL(fileURLWithPath: "/tmp/repo")
  )
  private let minted = LayoutID(task: UUID(0))
  private let stored = LayoutID(task: UUID(uuidString: "00000000-0000-0000-0000-0000000000D1")!)

  private func state(selected: Worktree? = nil, pending: Bool = false) -> AppFeature.State {
    var repositories = RepositoriesFeature.State()
    repositories.repositories = [
      Repository(
        id: "/tmp/repo", rootURL: URL(fileURLWithPath: "/tmp/repo"), name: "repo", worktrees: [worktree, sibling])
    ]
    if let selected { repositories.selection = .worktree(selected.id) }
    repositories.isInitialLoadComplete = true
    repositories.reconcileSidebarForTesting()
    if pending { repositories.sidebarItems[id: worktree.id]?.lifecycle = .pending }
    return AppFeature.State(repositories: repositories, settings: SettingsFeature.State())
  }

  private func makeStore(_ initial: AppFeature.State) -> (
    TestStoreOf<AppFeature>, LockIsolated<[TerminalClient.Command]>
  ) {
    let sent = LockIsolated<[TerminalClient.Command]>([])
    let store = TestStore(initialState: initial) {
      AppFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.terminalClient.send = { command in sent.withValue { $0.append(command) } }
      $0.analyticsClient.capture = { _, _ in }
      $0.worktreeInfoWatcher.send = { _ in }
    }
    store.exhaustivity = .off
    return (store, sent)
  }

  private var pendingMint: PendingTaskLaunch {
    PendingTaskLaunch(layoutID: minted, directoryID: worktree.id, primary: nil, followsDirectory: true)
  }

  private func tabbed(_ id: LayoutID) -> PaneLayout {
    let paneID = PaneID()
    let tab = TabItem(
      id: TabID(), title: "shell",
      content: ContentSnapshot(id: ContentID(), state: .terminal(TerminalContentState(workingDirectory: nil))))
    return PaneLayout(
      tree: SplitTree(view: paneID), panes: [Pane(id: paneID, tabs: [tab], selectedTabID: tab.id)],
      focusedPaneID: paneID)
  }

  /// Hosts the minted layout with one tab, as the manager does when the first tab lands.
  private func host(_ id: LayoutID, on directoryID: Worktree.ID, in store: TestStoreOf<AppFeature>) async {
    await store.send(
      .terminals(
        .attachLayout(worktreeID: id, directory: TaskRecord.Directory(worktreeID: directoryID), titlePrefix: "")))
    await store.send(.terminals(.replaceRestoredLayout(worktreeID: id, layout: tabbed(id))))
    await store.finish()
  }

  @Test(.dependencies) func cmdTOnAnEmptyDirectoryMintsATaskCarryingTheRowsIdentity() async {
    let (store, sent) = makeStore(state(selected: worktree))
    await store.send(.newTerminal)
    await store.finish()
    #expect(
      sent.value == [
        .createTaskTab(minted, source: .roster(worktree.id), input: nil, runSetupScriptIfNew: false, focusing: true)
      ])
    #expect(store.state.pendingTaskLaunches == [pendingMint])
    #expect(
      !sent.value.contains {
        $0 == .createTab(worktree.layoutID, DirectoryContext(worktree: worktree), runSetupScriptIfNew: false)
      })
  }

  @Test(.dependencies) func aSecondCmdTBeforeTheFirstTabExistsJoinsTheMint() async {
    let (store, sent) = makeStore(state(selected: worktree))
    await store.send(.newTerminal)
    await store.send(.newTerminal)
    await store.finish()
    let targets: [LayoutID] = sent.value.compactMap {
      if case .createTaskTab(let id, _, _, _, _) = $0 { return id }
      return nil
    }
    #expect(targets == [minted, minted])
    #expect(store.state.pendingTaskLaunches == [pendingMint])
  }

  @Test(.dependencies) func theMintFollowsTheStillSelectedDirectoryAndSelectsNoTask() async {
    let (store, sent) = makeStore(state(selected: worktree))
    await store.send(.newTerminal)
    await host(minted, on: worktree.id, in: store)
    #expect(sent.value.contains(.followFirstTab(minted, forDirectory: worktree.id)))
    #expect(store.state.pendingTaskLaunches.isEmpty)
    #expect(store.state.repositories.selectedTask == nil)
    #expect(store.state.layoutID(forDirectory: worktree.id) == minted)
  }

  @Test(.dependencies) func theMintNeverYanksAUserWhoMovedOn() async {
    let (store, sent) = makeStore(state(selected: worktree))
    await store.send(.newTerminal)
    await store.send(.repositories(.selectWorktree(sibling.id)))
    await store.finish()
    await host(minted, on: worktree.id, in: store)
    #expect(!sent.value.contains(.followFirstTab(minted, forDirectory: worktree.id)))
    #expect(store.state.pendingTaskLaunches.isEmpty)
    #expect(store.state.repositories.selectedWorktreeID == sibling.id)
  }

  @Test(.dependencies) func theMintNeverOverridesATaskPick() async {
    var initial = state(selected: worktree)
    let picked = LayoutID(task: UUID(uuidString: "00000000-0000-0000-0000-0000000000E1")!)
    initial.seedTask(picked, on: sibling.id)
    let (store, sent) = makeStore(initial)
    await store.send(.newTerminal)
    await store.send(.repositories(.selectTask(picked, directory: sibling.id)))
    await store.finish()
    await host(minted, on: worktree.id, in: store)
    #expect(!sent.value.contains(.followFirstTab(minted, forDirectory: worktree.id)))
    #expect(store.state.pendingTaskLaunches.isEmpty)
    #expect(store.state.repositories.selectedTaskID == picked)
  }

  @Test(.dependencies) func aNewWorktreeMintsItsFirstTaskAndAFailedFirstTabFailsTheAck() async {
    var initial = state(selected: nil, pending: true)
    let writeFD = Int32(999)
    initial.pendingCommandAcks[id: writeFD] = AppFeature.PendingCommandAck(
      responseFD: writeFD, token: 1,
      match: .worktreeNew(pendingID: WorktreeID("pending:cli-1"), worktreeID: worktree.id))
    let (store, sent) = makeStore(initial)
    await store.send(.repositories(.delegate(.worktreeCreated(worktree))))
    await store.finish()
    #expect(
      sent.value == [
        .ensureInitialTab(minted, DirectoryContext(worktree: worktree), runSetupScriptIfNew: true, focusing: false)
      ])
    #expect(store.state.pendingTaskLaunches == [pendingMint])
    #expect(store.state.worktreeNewAckDirectory(forLayout: minted) == worktree.id)

    // The failure names the mint; the ack bound to the directory fails through it.
    await store.send(.terminalEvent(.initialTabCreationFailed(layoutID: minted, message: "boom")))
    await store.finish()
    #expect(store.state.pendingCommandAcks.isEmpty)
    #expect(store.state.pendingTaskLaunches == [pendingMint], "the next Cmd-T reuses the same id")
  }

  @Test(.dependencies) func anEmptiedSessionBearingTaskTakesTheTabInsteadOfAMint() async {
    var initial = state(selected: worktree)
    initial.terminals.layouts = [LayoutFeature.State(id: stored, layout: PaneLayout())]
    initial.terminals.directories[stored] = TaskRecord.Directory(worktreeID: worktree.id)
    initial.terminals.members[stored] = [.session(SessionKey(harness: .pi, sessionID: "s1"))]
    initial.terminals.activeTasks[worktree.id] = stored
    initial.repositories.selectedTask = SelectedTask(id: stored, directoryID: worktree.id)
    let (store, sent) = makeStore(initial)
    await store.send(.newTerminal)
    await store.finish()
    #expect(sent.value == [.createTab(stored, DirectoryContext(worktree: worktree), runSetupScriptIfNew: false)])
    #expect(store.state.pendingTaskLaunches.isEmpty)
  }

  @Test(.dependencies) func aRecordNamingAnotherDirectorysTaskIsNoAnswerAndCmdTMints() async {
    var initial = state(selected: worktree)
    let elsewhere = LayoutID(task: UUID(uuidString: "00000000-0000-0000-0000-0000000000E2")!)
    initial.seedTask(elsewhere, on: sibling.id)
    initial.terminals.activeTasks[worktree.id] = elsewhere
    #expect(initial.detailLayoutID(forDirectory: worktree.id) == nil)
    let (store, sent) = makeStore(initial)
    await store.send(.newTerminal)
    await store.finish()
    #expect(
      sent.value == [
        .createTaskTab(minted, source: .roster(worktree.id), input: nil, runSetupScriptIfNew: false, focusing: true)
      ])
  }

  /// Stored tasks not hydrated yet never make a first tab land in them: the
  /// tab mints a fresh id, and hydration adds the stored tasks beside it unchanged.
  @Test(.dependencies) func aFirstTabBeforeHydrationMintsAndHydrationAddsTheStoredTasksUnchanged() async {
    var initial = state(selected: worktree)
    let session = SessionKey(harness: .pi, sessionID: "kept")
    let record = TaskRecord(
      id: stored, directory: TaskRecord.Directory(worktreeID: worktree.id), layout: tabbed(stored),
      sessions: [session], createdAt: Date(timeIntervalSince1970: 1))
    let file = TaskLayoutsFile(tasks: [stored.persistenceKey: record])
    initial.repositories.$persistedLayouts = SharedReader(value: file)
    let (store, sent) = makeStore(initial)
    await store.send(.newTerminal)
    await store.finish()
    let targets: [LayoutID] = sent.value.compactMap {
      if case .createTaskTab(let id, _, _, _, _) = $0 { return id }
      return nil
    }
    #expect(targets == [minted])
    #expect(minted != stored)

    await store.send(.terminals(.layoutsHydrated(file)))
    await store.finish()
    #expect(store.state.terminals.layouts[id: stored]?.layout == record.layout)
    #expect(store.state.terminals.directories[stored] == record.directory)
    #expect(store.state.terminals.members[stored] == [.session(session)])
  }
}

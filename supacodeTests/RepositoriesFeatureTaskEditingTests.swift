import ComposableArchitecture
import Dependencies
import DependenciesTestSupport
import Foundation
import IdentifiedCollections
import Sharing
import Testing

@testable import SupacodeSettingsShared
@testable import supacode

/// The three row-level edits the inbox needs before it can be lived in: rename,
/// open-a-terminal-for-a-task-that-has-none, and delete.
@MainActor
struct RepositoriesFeatureTaskEditingTests {
  private typealias Sandbox = TaskInboxSandbox
  private static let now = TaskInboxFixture.now

  private func makeSandbox() throws -> Sandbox {
    try Sandbox(name: "RepositoriesFeatureTaskEditingTests")
  }

  private func makeStore(
    _ state: RepositoriesFeature.State,
    sandbox: Sandbox
  ) -> TestStoreOf<RepositoriesFeature> {
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    } withDependencies: {
      $0.settingsFileStorage = sandbox.storage
      $0.date.now = Self.now
      $0.continuousClock = TestClock()
    }
    store.exhaustivity = .off
    return store
  }

  // MARK: - Open Terminal Here

  /// The claim target is the task the user right-clicked, not the directory's
  /// newest active task. Two tasks share a directory as a supported shape
  /// (Resolved #11), so resolving by directory would hand the older one's
  /// terminal to the newer one.
  @Test func openTerminalRequestsATabForTheTaskItWasAskedAbout() async throws {
    let sandbox = try makeSandbox()
    let directory = try sandbox.makeDirectory("fresh", activityAt: TaskInboxFixture.freshDate)
    var state = TaskInboxFixture.makeState(sandbox: sandbox, directories: [directory], hasLoadedTasks: true)
    // Surface-less: its tab was closed, so selecting it leads nowhere.
    let stranded = TaskInboxFixture.makeRecord(
      directory: directory,
      createdAt: TaskInboxFixture.freshDate.addingTimeInterval(-600)
    )
    let newer = TaskInboxFixture.makeRecord(
      directory: directory,
      surfaceIDs: [UUID()],
      createdAt: TaskInboxFixture.freshDate
    )
    state.taskRecords = [stranded, newer]
    state.applyPostReduceCacheRecomputes(.all)
    let store = makeStore(state, sandbox: sandbox)
    let rowID = WorktreeID(directory.path(percentEncoded: false))

    await store.send(.tasks(.openTerminal(stranded.id)))
    await store.receive(\.delegate.openTaskTerminal)
    // The selection hop rides along; drained rather than ordered because the
    // merge order between the two is not part of the contract.
    await store.skipReceivedActions(strict: false)
    await store.finish()

    // The request names the older, surface-less task — `AppFeatureTaskTerminalTests`
    // carries the other half, that the claim the parent parks names it too.
    #expect(store.state.selection?.taskID == stranded.id)
    #expect(
      store.state.taskTerminalRequestDelegate(for: stranded)
        == .openTaskTerminal(worktreeID: rowID, taskID: stranded.id)
    )
  }

  /// The settled variant is one action, not "unsettle, then find the row again":
  /// a settled task is deliberately un-focusable, so the terminal request has to
  /// leave in the same reduce that brought it back to Active.
  @Test func openTerminalUnsettlesASettledTaskFirst() async throws {
    let sandbox = try makeSandbox()
    let directory = try sandbox.makeDirectory("fresh", activityAt: TaskInboxFixture.freshDate)
    var state = TaskInboxFixture.makeState(sandbox: sandbox, directories: [directory], hasLoadedTasks: true)
    let record = TaskInboxFixture.makeRecord(directory: directory, settledAt: Self.now)
    state.taskRecords = [record]
    state.applyPostReduceCacheRecomputes(.all)
    let store = makeStore(state, sandbox: sandbox)

    await store.send(.tasks(.openTerminal(record.id)))
    await store.receive(\.delegate.openTaskTerminal)
    await store.finish()

    #expect(store.state.taskRecords[id: record.id]?.settledAt == nil)
    #expect(store.state.tasksSidebarStructure.activeTaskIDs == [record.id])
    #expect(store.state.tasksSidebarStructure.settledTotalCount == 0)
    // The unsettle rides the selection's persist, so it survives a relaunch.
    let persisted = try #require(sandbox.loadFile())
    #expect(persisted.tasks.first?.settledAt == nil)
  }

  /// A10b: the inbox outlives worktrees. A task whose directory is gone has
  /// nowhere to open a terminal, and the leaf says so, which is what greys the
  /// menu item out instead of offering an action the reducer refuses.
  @Test func openTerminalIsRefusedWhenTheDirectoryHasNoRow() async throws {
    let sandbox = try makeSandbox()
    let live = try sandbox.makeDirectory("live", activityAt: TaskInboxFixture.freshDate)
    let deleted = sandbox.rootURL.appending(path: "deleted", directoryHint: .isDirectory)
    var state = TaskInboxFixture.makeState(sandbox: sandbox, directories: [live], hasLoadedTasks: true)
    let orphan = TaskInboxFixture.makeRecord(directory: deleted)
    state.taskRecords = [orphan]
    state.applyPostReduceCacheRecomputes(.all)
    let store = makeStore(state, sandbox: sandbox)

    #expect(store.state.taskLeaves[id: orphan.id]?.hasDirectoryRow == false)

    await store.send(.tasks(.openTerminal(orphan.id)))
    await store.finish()

    #expect(store.state.selection?.taskID == nil)
  }

  // MARK: - Delete

  /// A26, applied to delete: the open row leaving takes the selection forward to
  /// the next visible task rather than dropping the user on nothing.
  @Test func deletingTheOpenTaskForwardsTheSelectionAndPersists() async throws {
    let sandbox = try makeSandbox()
    let directory = try sandbox.makeDirectory("fresh", activityAt: TaskInboxFixture.freshDate)
    var state = TaskInboxFixture.makeState(sandbox: sandbox, directories: [directory], hasLoadedTasks: true)
    let doomed = TaskInboxFixture.makeRecord(directory: directory, createdAt: TaskInboxFixture.freshDate)
    let survivor = TaskInboxFixture.makeRecord(
      directory: directory,
      createdAt: TaskInboxFixture.freshDate.addingTimeInterval(-600)
    )
    state.taskRecords = [doomed, survivor]
    state.selection = .task(doomed.id)
    state.applyPostReduceCacheRecomputes(.all)
    let store = makeStore(state, sandbox: sandbox)

    await store.send(.tasks(.requestDelete(doomed.id)))
    #expect(store.state.alert != nil)

    await store.send(.alert(.presented(.confirmDeleteTask(doomed.id))))
    await store.receive(\.tasks.select)
    await store.receive(\.selectionChanged)
    await store.finish()

    #expect(store.state.alert == nil)
    #expect(store.state.taskRecords.map(\.id) == [survivor.id])
    #expect(store.state.selection?.taskID == survivor.id)
    // The leaf goes with the record; a leaf for a task that is gone is a leak
    // nothing else prunes.
    #expect(store.state.taskLeaves[id: doomed.id] == nil)
    let persisted = try #require(sandbox.loadFile())
    #expect(persisted.tasks.map(\.id) == [survivor.id])
  }

  /// The last row leaving clears the selection rather than leaving it pointing
  /// at a record that no longer exists.
  @Test func deletingTheLastTaskClearsTheSelection() async throws {
    let sandbox = try makeSandbox()
    let directory = try sandbox.makeDirectory("fresh", activityAt: TaskInboxFixture.freshDate)
    var state = TaskInboxFixture.makeState(sandbox: sandbox, directories: [directory], hasLoadedTasks: true)
    let record = TaskInboxFixture.makeRecord(directory: directory)
    state.taskRecords = [record]
    state.selection = .task(record.id)
    state.applyPostReduceCacheRecomputes(.all)
    let store = makeStore(state, sandbox: sandbox)

    await store.send(.alert(.presented(.confirmDeleteTask(record.id))))
    await store.finish()

    #expect(store.state.taskRecords.isEmpty)
    #expect(store.state.selection == nil)
  }

  /// Resolved #9: the auto-managed delete is only ever authorized by a settle,
  /// with its preconditions re-checked. Forgetting the record orphans that
  /// worktree by design, so the confirmation has to say so up front.
  @Test func deleteConfirmationNamesAnOrphanedAutoManagedWorktree() throws {
    let sandbox = try makeSandbox()
    let directory = try sandbox.makeDirectory("fresh", activityAt: TaskInboxFixture.freshDate)
    var record = TaskInboxFixture.makeRecord(directory: directory)
    let plain = RepositoriesFeature.taskDeletionAlert(for: record)
    record.autoManagedWorktree = TaskRecord.AutoManagedWorktree(
      path: TaskDirectoryPath.canonical(directory),
      branch: "task/fresh",
      createdAt: Self.now
    )
    let orphaning = RepositoriesFeature.taskDeletionAlert(for: record)

    #expect(!String(state: plain.message ?? TextState("")).contains("auto-created worktree"))
    #expect(String(state: orphaning.message ?? TextState("")).contains("auto-created worktree"))
  }

  // MARK: - Rename

  @Test func renamingATaskPersistsAndReachesTheRenderPlan() async throws {
    let sandbox = try makeSandbox()
    let directory = try sandbox.makeDirectory("fresh", activityAt: TaskInboxFixture.freshDate)
    var state = TaskInboxFixture.makeState(sandbox: sandbox, directories: [directory], hasLoadedTasks: true)
    let record = TaskInboxFixture.makeRecord(directory: directory)
    state.taskRecords = [record]
    state.applyPostReduceCacheRecomputes(.all)
    let store = makeStore(state, sandbox: sandbox)

    await store.send(.tasks(.presentRenamePrompt(record.id)))
    #expect(store.state.taskRenamePrompt?.startingTitle == record.title)
    // A sheet is up, so the lifecycle chords stay inert underneath it (§4.6).
    #expect(store.state.hasBlockingSheet)

    await store.send(.tasks(.renameTask(record.id, title: "  Ship the inbox  ")))
    await store.finish()

    #expect(store.state.taskRenamePrompt == nil)
    #expect(store.state.taskRecords[id: record.id]?.title == "Ship the inbox")
    // The filter reads titles, so a rename that never reached the render plan
    // would leave the row un-findable under its new name (A37).
    await store.send(.tasks(.setSearchQuery("ship the")))
    #expect(store.state.tasksSidebarStructure.hasSearchMatches)
    #expect(store.state.tasksSidebarStructure.visibleTaskIDs == [record.id])

    let persisted = try #require(sandbox.loadFile())
    #expect(persisted.tasks.first?.title == "Ship the inbox")
  }

  /// A title is the only handle the panel gives a row, so an empty one is
  /// refused rather than applied — and the record keeps what it had.
  @Test func renamingToAnEmptyTitleIsRefused() async throws {
    let sandbox = try makeSandbox()
    let directory = try sandbox.makeDirectory("fresh", activityAt: TaskInboxFixture.freshDate)
    var state = TaskInboxFixture.makeState(sandbox: sandbox, directories: [directory], hasLoadedTasks: true)
    let record = TaskInboxFixture.makeRecord(directory: directory)
    state.taskRecords = [record]
    state.applyPostReduceCacheRecomputes(.all)
    let store = makeStore(state, sandbox: sandbox)

    await store.send(.tasks(.presentRenamePrompt(record.id)))
    await store.send(.tasks(.renameTask(record.id, title: "   ")))
    await store.finish()

    #expect(store.state.taskRecords[id: record.id]?.title == record.title)
    // The question stays open on what the user typed rather than dismissing as
    // though the rename had worked.
    #expect(store.state.taskRenamePrompt?.taskID == record.id)
  }

  @Test func renamingATaskThatIsGoneOpensNothing() async throws {
    let sandbox = try makeSandbox()
    let directory = try sandbox.makeDirectory("fresh", activityAt: TaskInboxFixture.freshDate)
    let state = TaskInboxFixture.makeState(sandbox: sandbox, directories: [directory], hasLoadedTasks: true)
    let store = makeStore(state, sandbox: sandbox)

    await store.send(.tasks(.presentRenamePrompt(TaskID())))
    await store.finish()

    #expect(store.state.taskRenamePrompt == nil)
  }
}

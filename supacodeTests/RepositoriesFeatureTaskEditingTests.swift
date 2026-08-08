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

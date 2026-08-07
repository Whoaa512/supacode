import ComposableArchitecture
import Dependencies
import DependenciesTestSupport
import Foundation
import IdentifiedCollections
import Sharing
import Testing

@testable import SupacodeSettingsShared
@testable import supacode

/// Phase-3b parent contract for prompt-first task creation: assertion A19 of
/// `plans/task-inbox-sidebar-plan.md` (⌘N → optional prompt → fuzzy directory
/// pick → a task exists with a terminal opening, never a worktree decision),
/// plus the A20b half that a cancelled creation leaves nothing behind.
///
/// Scope note: the full Resolved #11 conflict cascade (per-repo isolation
/// policy, warm auto-managed worktrees) is Phase 3c. 3b ships creation into a
/// free directory and a *documented seam* for the busy case — the parent
/// consults `TaskDirectoryConflictPolicy`, which 3b hardcodes to `.share`, so
/// a busy directory produces a second task with zero surfaces rather than a
/// worktree decision in the user's face.
@MainActor
struct RepositoriesFeatureTaskCreationTests {
  private typealias Sandbox = TaskInboxSandbox
  private static let now = TaskInboxFixture.now
  private static let freshDate = TaskInboxFixture.freshDate

  // MARK: - Fixture

  private func makeSandbox() throws -> Sandbox {
    try Sandbox(name: "RepositoriesFeatureTaskCreationTests")
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
    }
    store.exhaustivity = .off
    return store
  }

  private func makeEmptyState() -> RepositoriesFeature.State {
    var state = RepositoriesFeature.State()
    state.isInitialLoadComplete = true
    state.hasLoadedTasks = true
    return state
  }

  // MARK: - A19: ⌘N routing is tab-aware

  /// ⌘N is one shortcut with two meanings. On the Tasks tab it captures work,
  /// so it must reach the task prompt and never the worktree prompt — a
  /// worktree decision is exactly what A19 forbids at capture time.
  @Test(.sidebarTab(.tasks))
  func newShortcutOnTasksTabOpensTheTaskPrompt() async throws {
    let sandbox = try makeSandbox()
    let fresh = try sandbox.makeDirectory("fresh", activityAt: Self.freshDate)
    let other = try sandbox.makeDirectory("other", activityAt: Self.freshDate)
    let state = TaskInboxFixture.makeState(
      sandbox: sandbox,
      directories: [fresh, other],
      hasLoadedTasks: true
    )
    let store = makeStore(state, sandbox: sandbox)

    await store.send(.createRandomWorktree)
    await store.receive(\.tasks.presentCreationPrompt)

    let prompt = try #require(store.state.taskCreationPrompt)
    #expect(store.state.worktreeCreationPrompt == nil)
    #expect(store.state.alert == nil)
    #expect(
      Set(prompt.candidates.map(\.id))
        == Set([fresh, other].map { TaskDirectoryPath.canonical($0) })
    )
    // The reducer is handed live rows, so it can request a terminal without
    // re-deriving the worktree from the path.
    #expect(prompt.candidates.allSatisfy { $0.worktreeID != nil })
    // No active task owns either directory yet, so nothing is busy (A20 free
    // branch; the busy branch is the 3c cascade's input).
    #expect(prompt.candidates.allSatisfy { !$0.isBusy })
  }

  /// A9: the existing tabs are unchanged. On Worktrees, ⌘N still means "new
  /// worktree" — here with no registered repository, so it takes the worktree
  /// path's own "open a repository first" alert rather than the task prompt.
  @Test(.sidebarTab(.worktrees))
  func newShortcutOnWorktreesTabKeepsWorktreeRouting() async throws {
    let sandbox = try makeSandbox()
    let store = makeStore(makeEmptyState(), sandbox: sandbox)

    await store.send(.createRandomWorktree)

    #expect(store.state.taskCreationPrompt == nil)
    #expect(store.state.alert != nil)
  }

  /// A prompt with nothing to pick still opens: registration UX is P7, and an
  /// alert here would make ⌘N feel broken on a fresh install.
  @Test(.sidebarTab(.tasks))
  func taskPromptOpensEvenWithNoRegisteredRepositories() async throws {
    let sandbox = try makeSandbox()
    let store = makeStore(makeEmptyState(), sandbox: sandbox)

    await store.send(.createRandomWorktree)
    await store.receive(\.tasks.presentCreationPrompt)

    let prompt = try #require(store.state.taskCreationPrompt)
    #expect(prompt.candidates.isEmpty)
    #expect(store.state.alert == nil)
  }

  // MARK: - A19: submit creates the task and asks for a terminal

  @Test(.sidebarTab(.tasks))
  func submitCreatesTheTaskInAFreeDirectoryAndRequestsATerminal() async throws {
    let sandbox = try makeSandbox()
    let fresh = try sandbox.makeDirectory("fresh", activityAt: Self.freshDate)
    let state = TaskInboxFixture.makeState(
      sandbox: sandbox,
      directories: [fresh],
      hasLoadedTasks: true
    )
    let store = makeStore(state, sandbox: sandbox)

    await store.send(.createRandomWorktree)
    await store.receive(\.tasks.presentCreationPrompt)
    await store.send(
      .taskCreationPrompt(
        .presented(.delegate(.createTask(title: "Ship the inbox", directoryURL: fresh)))
      )
    )
    await store.receive(\.tasks.createTask)
    await store.receive(\.delegate.openTaskTerminal)
    await store.finish()

    // The prompt closes itself on submit: A19 counts interactions, and a
    // sheet the user has to dismiss is a third one.
    #expect(store.state.taskCreationPrompt == nil)
    let record = try #require(store.state.taskRecords.first)
    #expect(store.state.taskRecords.count == 1)
    #expect(record.title == "Ship the inbox")
    #expect(record.directoryPath == TaskDirectoryPath.canonical(fresh))
    #expect(record.createdAt == Self.now)
    #expect(record.settledAt == nil)
    // A3: a fresh task steals nothing. Its terminal arrives via the delegate.
    #expect(record.surfaceIDs.isEmpty)
    // A2: created, not inferred — the row must never render seeded confidence.
    #expect(record.seedEvidence == TaskRecord.SeedEvidence(source: .manual, confidence: .high))
    #expect(record.repositoryID == RepositoryID(sandbox.rootURL.path(percentEncoded: false)))
    // A4: the newest task heads the active list, and the row is selected so
    // the user lands on what they just created.
    #expect(store.state.tasksSidebarStructure.activeTaskIDs.first == record.id)
    #expect(store.state.selection == .task(record.id))
    // A11: the record survives the round-trip to `tasks.json`.
    #expect(sandbox.loadFile()?.tasks.map(\.id) == [record.id])
    #expect(sandbox.didWriteTasksFile)
  }

  /// A blank title is the fast path: the seeder's naming cascade
  /// (customization → worktree name → detail → branch → leaf) names it, so an
  /// untitled task never renders as an empty row.
  @Test func blankTitleFallsBackToTheSeederNamingCascade() async throws {
    let sandbox = try makeSandbox()
    let fresh = try sandbox.makeDirectory("fresh", activityAt: Self.freshDate)
    let state = TaskInboxFixture.makeState(
      sandbox: sandbox,
      directories: [fresh],
      hasLoadedTasks: true
    )
    let store = makeStore(state, sandbox: sandbox)

    await store.send(.tasks(.createTask(title: nil, directoryURL: fresh)))
    await store.finish()

    #expect(store.state.taskRecords.first?.title == "fresh")
  }

  /// A directory with no live worktree row still gets a task — the inbox
  /// outlives worktrees (A10b) — but there is no worktree to open a terminal
  /// in, so the request is skipped rather than aimed at a guess. 3c decides
  /// what a row-less directory deserves.
  @Test func directoryWithNoLiveRowCreatesTheTaskAndSkipsTheTerminalRequest() async throws {
    let sandbox = try makeSandbox()
    let registered = try sandbox.makeDirectory("registered", activityAt: Self.freshDate)
    let orphan = try sandbox.makeDirectory("orphan", activityAt: Self.freshDate)
    let state = TaskInboxFixture.makeState(
      sandbox: sandbox,
      directories: [registered],
      hasLoadedTasks: true
    )
    let store = makeStore(state, sandbox: sandbox)

    await store.send(.tasks(.createTask(title: "Orphan work", directoryURL: orphan)))
    await store.finish()

    let record = try #require(store.state.taskRecords.first)
    #expect(record.directoryPath == TaskDirectoryPath.canonical(orphan))
    #expect(record.repositoryID == nil)
    #expect(store.state.taskTerminalRequestDelegate(for: record) == nil)
  }

  /// Payload-level lock, mirroring `taskHibernationDelegate`: the terminal
  /// request names the row that owns the task's directory and the task it is
  /// for, so the parent never has to re-resolve either.
  @Test func terminalRequestNamesTheDirectorysWorktreeRowAndTask() throws {
    let sandbox = try makeSandbox()
    let fresh = try sandbox.makeDirectory("fresh", activityAt: Self.freshDate)
    var state = TaskInboxFixture.makeState(
      sandbox: sandbox,
      directories: [fresh],
      hasLoadedTasks: true
    )
    let record = TaskInboxFixture.makeRecord(directory: fresh)
    state.taskRecords = [record]

    let delegate = try #require(state.taskTerminalRequestDelegate(for: record))
    guard case .openTaskTerminal(let worktreeID, let taskID) = delegate else {
      Issue.record("Expected a terminal request delegate, got \(delegate).")
      return
    }
    #expect(worktreeID == WorktreeID(fresh.path(percentEncoded: false)))
    #expect(taskID == record.id)
  }

  // MARK: - A20 (3b slice): a busy directory shares, it never asks

  /// Phase 3b hardcodes the conflict policy to `.share`. The seam exists so 3c
  /// can swap in the per-repo isolation policy without touching the arm.
  @Test func conflictPolicyIsShareInPhase3b() {
    #expect(TaskDirectoryConflictPolicy.resolve(directoryPath: "/repos/acme/alpha") == .share)
  }

  /// A directory another *active* task owns still creates: A3 allows two tasks
  /// over one directory as long as they share zero surfaces, and A19 forbids
  /// putting a worktree decision in front of the user at capture time.
  @Test func busyDirectoryCreatesASharedTaskWithZeroSurfaces() async throws {
    let sandbox = try makeSandbox()
    let shared = try sandbox.makeDirectory("shared", activityAt: Self.freshDate)
    let surfaceID = UUID()
    var state = TaskInboxFixture.makeState(
      sandbox: sandbox,
      directories: [shared],
      surfacesPerRow: [shared: [surfaceID]],
      hasLoadedTasks: true
    )
    let incumbent = TaskInboxFixture.makeRecord(directory: shared, surfaceIDs: [surfaceID])
    state.taskRecords = [incumbent]
    state.applyPostReduceCacheRecomputes(.all)
    let store = makeStore(state, sandbox: sandbox)

    await store.send(.tasks(.createTask(title: "Second pass", directoryURL: shared)))
    await store.finish()

    #expect(store.state.taskRecords.count == 2)
    // The incumbent is untouched: no surface is transferred, no lifecycle stamp
    // moves, and it keeps its place in the active list.
    #expect(store.state.taskRecords[id: incumbent.id] == incumbent)
    let created = try #require(store.state.taskRecords.first { $0.id != incumbent.id })
    #expect(created.directoryPath == incumbent.directoryPath)
    #expect(created.surfaceIDs.isEmpty)
    // No worktree decision reached the user, and no auto-managed worktree was
    // minted (that is 3c's cascade, not 3b's).
    #expect(store.state.alert == nil)
    #expect(created.autoManagedWorktree == nil)
    #expect(store.state.tasksSidebarStructure.activeTaskIDs.first == created.id)
  }

  /// The prompt surfaces the busy directory as busy so 3c has somewhere to hang
  /// the cascade UI, but 3b renders it as a hint, not a fork in the flow.
  @Test(.sidebarTab(.tasks))
  func candidatesFlagADirectoryOwnedByAnActiveTask() async throws {
    let sandbox = try makeSandbox()
    let busy = try sandbox.makeDirectory("busy", activityAt: Self.freshDate)
    let free = try sandbox.makeDirectory("free", activityAt: Self.freshDate)
    var state = TaskInboxFixture.makeState(
      sandbox: sandbox,
      directories: [busy, free],
      hasLoadedTasks: true
    )
    state.taskRecords = [TaskInboxFixture.makeRecord(directory: busy)]
    state.applyPostReduceCacheRecomputes(.all)
    let store = makeStore(state, sandbox: sandbox)

    await store.send(.createRandomWorktree)
    await store.receive(\.tasks.presentCreationPrompt)

    let prompt = try #require(store.state.taskCreationPrompt)
    let busyCandidate = try #require(
      prompt.candidates.first { $0.id == TaskDirectoryPath.canonical(busy) }
    )
    let freeCandidate = try #require(
      prompt.candidates.first { $0.id == TaskDirectoryPath.canonical(free) }
    )
    #expect(busyCandidate.isBusy)
    #expect(!freeCandidate.isBusy)
  }

  // MARK: - A20b: cancel leaves nothing behind

  @Test(.sidebarTab(.tasks))
  func cancellingTheCreationPromptLeavesNoRecordAndNoWrite() async throws {
    let sandbox = try makeSandbox()
    let fresh = try sandbox.makeDirectory("fresh", activityAt: Self.freshDate)
    let state = TaskInboxFixture.makeState(
      sandbox: sandbox,
      directories: [fresh],
      hasLoadedTasks: true
    )
    let store = makeStore(state, sandbox: sandbox)

    await store.send(.createRandomWorktree)
    await store.receive(\.tasks.presentCreationPrompt)
    await store.send(.taskCreationPrompt(.presented(.delegate(.cancel))))
    await store.finish()

    #expect(store.state.taskCreationPrompt == nil)
    #expect(store.state.taskRecords.isEmpty)
    #expect(store.state.selection == nil)
    // The save spy: `tasks.json` was never written at all (a load-based check
    // would see the default empty file and pass either way).
    #expect(!sandbox.didWriteTasksFile)
  }

  /// Escape / click-away takes the same path as the Cancel button.
  @Test(.sidebarTab(.tasks))
  func dismissingTheCreationPromptLeavesNoRecordAndNoWrite() async throws {
    let sandbox = try makeSandbox()
    let fresh = try sandbox.makeDirectory("fresh", activityAt: Self.freshDate)
    let state = TaskInboxFixture.makeState(
      sandbox: sandbox,
      directories: [fresh],
      hasLoadedTasks: true
    )
    let store = makeStore(state, sandbox: sandbox)

    await store.send(.createRandomWorktree)
    await store.receive(\.tasks.presentCreationPrompt)
    await store.send(.taskCreationPrompt(.dismiss))
    await store.finish()

    #expect(store.state.taskCreationPrompt == nil)
    #expect(store.state.taskRecords.isEmpty)
    #expect(!sandbox.didWriteTasksFile)
  }

  /// An unreadable `tasks.json` disables the inbox for the launch (a write on
  /// top of records we failed to read would erase them), so creation refuses
  /// rather than writing over them — same rule the promote-tab arm follows.
  @Test func creationIsRefusedWhenTaskPersistenceIsDisabled() async throws {
    let sandbox = try makeSandbox()
    let fresh = try sandbox.makeDirectory("fresh", activityAt: Self.freshDate)
    var state = TaskInboxFixture.makeState(
      sandbox: sandbox,
      directories: [fresh],
      hasLoadedTasks: true
    )
    state.isTaskPersistenceDisabled = true
    let store = makeStore(state, sandbox: sandbox)

    await store.send(.tasks(.createTask(title: "Nope", directoryURL: fresh)))
    await store.finish()

    #expect(store.state.taskRecords.isEmpty)
    #expect(!sandbox.didWriteTasksFile)
  }
}

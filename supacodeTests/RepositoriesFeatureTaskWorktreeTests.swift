import ComposableArchitecture
import Dependencies
import DependenciesTestSupport
import Foundation
import IdentifiedCollections
import Sharing
import Testing

@testable import SupacodeSettingsShared
@testable import supacode

/// Phase 3c step 3 of the Resolved #11 cascade, end to end: the auto-managed
/// worktree an `.isolate` answer mints, the rollback when minting fails (A20b),
/// and the single place Supacode is ever allowed to delete one (A20 + Resolved
/// #9).
///
/// Two rules the whole file exists to hold:
/// 1. Creation never blocks. A cold worktree beats no worktree, and a failed
///    worktree beats a half-created task — so a warm-copy failure degrades, and
///    a creation failure leaves *nothing* behind.
/// 2. Deletion is refused by default. `TaskRecord.autoManagedWorktree` is the
///    only delete authority there is, and every precondition it names is
///    re-checked immediately before the delete. Any mismatch leaks a directory
///    rather than destroying work.
@MainActor
struct RepositoriesFeatureTaskWorktreeTests {
  private typealias Sandbox = TaskInboxSandbox
  private static let now = TaskInboxFixture.now
  private static let freshDate = TaskInboxFixture.freshDate

  // MARK: - Fixture

  /// One creation attempt as the reducer made it, so the assertions can talk
  /// about warmth and naming rather than about argument positions.
  private struct CreateAttempt: Equatable, Sendable {
    var name: String
    var repoRoot: URL
    var baseDirectory: URL
    var copyIgnored: Bool
    var copyUntracked: Bool
    var baseRef: String
  }

  private func makeSandbox() throws -> Sandbox {
    try Sandbox(name: "RepositoriesFeatureTaskWorktreeTests")
  }

  /// A repository whose `busy` directory is already owned by a live task, with
  /// `.isolate` remembered — the exact state that sends the next capture down
  /// step 3 with no sheet in the way.
  private func makeIsolatingState(
    sandbox: Sandbox,
    busy: URL,
    incumbentSurfaceID: UUID = UUID()
  ) -> RepositoriesFeature.State {
    var state = TaskInboxFixture.makeState(
      sandbox: sandbox,
      directories: [busy],
      surfacesPerRow: [busy: [incumbentSurfaceID]],
      hasLoadedTasks: true
    )
    state.taskRecords = [TaskInboxFixture.makeRecord(directory: busy, surfaceIDs: [incumbentSurfaceID])]
    state.applyPostReduceCacheRecomputes(.all)
    withDependencies {
      $0.settingsFileStorage = sandbox.storage
    } operation: {
      @Shared(.repositorySettings(sandbox.rootURL)) var settings
      $settings.withLock { $0.taskDirectoryIsolation = .isolate }
    }
    return state
  }

  /// `tabCount` defaults to the only state a delete is allowed in: no tabs left
  /// standing in the directory. Tests that exercise the refusal raise it.
  private func makeStore(
    _ state: RepositoriesFeature.State,
    sandbox: Sandbox,
    tabCount: Int = 0,
    configureGit: (inout GitClientDependency) -> Void = { _ in }
  ) -> TestStoreOf<RepositoriesFeature> {
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    } withDependencies: {
      $0.settingsFileStorage = sandbox.storage
      $0.date.now = Self.now
      $0.terminalClient.tabCount = { _ in tabCount }
      $0.gitClient.automaticWorktreeBaseRef = { _ in "origin/main" }
      $0.gitClient.remoteNames = { _ in ["origin"] }
      $0.gitClient.ignoredFileCount = { _ in 0 }
      $0.gitClient.untrackedFileCount = { _ in 0 }
      configureGit(&$0.gitClient)
    }
    store.exhaustivity = .off
    return store
  }

  /// Records every attempt and answers with `worktree` on the attempts named in
  /// `succeedsOnAttempt` (1-based), throwing on the rest — the shape both the
  /// degrade path and the rollback path need.
  private static func createWorktreeStreamSpy(
    attempts: LockIsolated<[CreateAttempt]>,
    worktree: Worktree?,
    succeedsFromAttempt: Int = 1
  ) -> @Sendable (String, URL, URL, Bool, Bool, String, URL?) -> AsyncThrowingStream<
    GitWorktreeCreateEvent, Error
  > {
    { name, repoRoot, baseDirectory, copyIgnored, copyUntracked, baseRef, _ in
      let index = attempts.withValue { value -> Int in
        value.append(
          CreateAttempt(
            name: name,
            repoRoot: repoRoot,
            baseDirectory: baseDirectory,
            copyIgnored: copyIgnored,
            copyUntracked: copyUntracked,
            baseRef: baseRef
          )
        )
        return value.count
      }
      return AsyncThrowingStream { continuation in
        guard let worktree, index >= succeedsFromAttempt else {
          continuation.finish(
            throwing: GitClientError.commandFailed(command: "wt sw", message: "boom")
          )
          return
        }
        continuation.yield(.finished(worktree))
        continuation.finish()
      }
    }
  }

  // MARK: - A20 step 3: the isolating capture mints a warm worktree

  @Test func isolatingCaptureCreatesAWarmAutoManagedWorktreeAndOpensATerminalThere() async throws {
    let sandbox = try makeSandbox()
    let busy = try sandbox.makeDirectory("busy", activityAt: Self.freshDate)
    let created = try sandbox.makeDirectory("created", activityAt: Self.freshDate)
    let createdWorktree = TaskInboxFixture.makeWorktree(created, rootURL: sandbox.rootURL)
    let attempts = LockIsolated<[CreateAttempt]>([])
    let state = makeIsolatingState(sandbox: sandbox, busy: busy)
    let store = makeStore(state, sandbox: sandbox) {
      $0.createWorktreeStream = Self.createWorktreeStreamSpy(
        attempts: attempts,
        worktree: createdWorktree
      )
      $0.worktrees = { _ in [] }
    }

    await store.send(.tasks(.createTask(title: "Ship the inbox", directoryURL: busy)))
    await store.receive(\.tasks.autoManagedWorktreeCreated)
    await store.receive(\.delegate.openTaskTerminal)
    await store.finish()

    let record = try #require(store.state.taskRecords.first { $0.title == "Ship the inbox" })
    // The task lives in the new worktree, not in the directory the user picked:
    // that directory is exactly what the isolation policy refused to share.
    #expect(record.directoryPath == TaskDirectoryPath.canonical(created))
    #expect(record.repositoryID == RepositoryID(sandbox.rootURL.path(percentEncoded: false)))
    // Resolved #9's marker, stamped at creation and never at any other time —
    // it is the only thing that will ever authorize deleting this directory.
    let marker = try #require(record.autoManagedWorktree)
    #expect(marker.path == TaskDirectoryPath.canonical(created))
    #expect(marker.branch == TaskAutoWorktreeNaming.branchName(title: "Ship the inbox", taskID: record.id))
    #expect(marker.createdAt == Self.now)
    // A3 still holds: the new task steals nothing from the incumbent.
    #expect(record.surfaceIDs.isEmpty)
    #expect(store.state.taskRecords.count == 2)
    #expect(store.state.taskRecords.first { $0.id != record.id }?.autoManagedWorktree == nil)

    let attempt = try #require(attempts.value.first)
    #expect(attempts.value.count == 1)
    #expect(attempt.name == marker.branch)
    #expect(attempt.repoRoot == sandbox.rootURL)
    // Warm (A20): the ignored cache directories are CoW-cloned from the source
    // so the worktree is usable the second it exists.
    #expect(attempt.copyIgnored)

    // The row has to reach the roster, or the terminal request has nothing to
    // open in — this is the whole point of isolating rather than sharing.
    #expect(store.state.sidebarItems[id: createdWorktree.id] != nil)
    #expect(store.state.selection == .task(record.id))
    #expect(sandbox.loadFile()?.tasks.contains { $0.id == record.id } == true)
    #expect(store.state.alert == nil)
  }

  /// The terminal request names the *new* worktree, never the busy one the
  /// user picked. Getting this wrong would put the second agent straight back
  /// into the directory the policy just protected.
  @Test func theTerminalRequestNamesTheNewWorktree() async throws {
    let sandbox = try makeSandbox()
    let busy = try sandbox.makeDirectory("busy", activityAt: Self.freshDate)
    let created = try sandbox.makeDirectory("created", activityAt: Self.freshDate)
    let createdWorktree = TaskInboxFixture.makeWorktree(created, rootURL: sandbox.rootURL)
    let attempts = LockIsolated<[CreateAttempt]>([])
    let store = makeStore(makeIsolatingState(sandbox: sandbox, busy: busy), sandbox: sandbox) {
      $0.createWorktreeStream = Self.createWorktreeStreamSpy(attempts: attempts, worktree: createdWorktree)
      $0.worktrees = { _ in [] }
    }

    await store.send(.tasks(.createTask(title: "Ship the inbox", directoryURL: busy)))
    await store.receive(\.tasks.autoManagedWorktreeCreated)
    await store.receive(\.delegate.openTaskTerminal)
    await store.finish()

    let record = try #require(store.state.taskRecords.first { $0.title == "Ship the inbox" })
    let delegate = store.state.taskTerminalRequestDelegate(for: record)
    #expect(delegate == .openTaskTerminal(worktreeID: createdWorktree.id, taskID: record.id))
    #expect(delegate != .openTaskTerminal(worktreeID: WorktreeID(busy.path(percentEncoded: false)), taskID: record.id))
  }

  /// A20: "clone failure degrades to a cold worktree, never blocks creation".
  /// The warm attempt is retried cold rather than surfaced — a worktree without
  /// its `node_modules` is a slow start, not a failed capture.
  @Test func warmCloneFailureDegradesToAColdWorktree() async throws {
    let sandbox = try makeSandbox()
    let busy = try sandbox.makeDirectory("busy", activityAt: Self.freshDate)
    let created = try sandbox.makeDirectory("created", activityAt: Self.freshDate)
    let createdWorktree = TaskInboxFixture.makeWorktree(created, rootURL: sandbox.rootURL)
    let attempts = LockIsolated<[CreateAttempt]>([])
    let store = makeStore(makeIsolatingState(sandbox: sandbox, busy: busy), sandbox: sandbox) {
      $0.createWorktreeStream = Self.createWorktreeStreamSpy(
        attempts: attempts,
        worktree: createdWorktree,
        succeedsFromAttempt: 2
      )
      $0.worktrees = { _ in [] }
    }

    await store.send(.tasks(.createTask(title: "Ship the inbox", directoryURL: busy)))
    await store.receive(\.tasks.autoManagedWorktreeCreated)
    await store.finish()

    #expect(attempts.value.count == 2)
    #expect(attempts.value.map(\.copyIgnored) == [true, false])
    // Same branch both times: a retry must not mint a second name, or the
    // marker would authorize deleting a directory that was never created.
    #expect(Set(attempts.value.map(\.name)).count == 1)
    let record = try #require(store.state.taskRecords.first { $0.title == "Ship the inbox" })
    #expect(record.autoManagedWorktree?.path == TaskDirectoryPath.canonical(created))
    // The degrade is invisible: nothing failed from the user's point of view.
    #expect(store.state.alert == nil)
  }

  /// A worktree minted for a task is a worktree like any other: it owes the
  /// roster the same two delegates the manual path fires, and its row starts
  /// `.pending` so `openTaskTerminal` runs the repository's setup script in it.
  /// Without the lifecycle the agent lands in a worktree with no `.env` and no
  /// installed dependencies; without the delegates the parent never learns the
  /// worktree exists, and the terminal request it *does* get resolves to nothing.
  @Test func anAutoManagedWorktreeIsAnnouncedAndStartsPendingSoItsSetupScriptRuns() async throws {
    let sandbox = try makeSandbox()
    let busy = try sandbox.makeDirectory("busy", activityAt: Self.freshDate)
    let created = try sandbox.makeDirectory("created", activityAt: Self.freshDate)
    let createdWorktree = TaskInboxFixture.makeWorktree(created, rootURL: sandbox.rootURL)
    let attempts = LockIsolated<[CreateAttempt]>([])
    let store = makeStore(makeIsolatingState(sandbox: sandbox, busy: busy), sandbox: sandbox) {
      $0.createWorktreeStream = Self.createWorktreeStreamSpy(attempts: attempts, worktree: createdWorktree)
      $0.worktrees = { _ in [] }
    }

    await store.send(.tasks(.createTask(title: "Ship the inbox", directoryURL: busy)))
    await store.receive(\.tasks.autoManagedWorktreeCreated)
    // Order is the assertion: a non-exhaustive `receive` discards what it skips,
    // so the roster update landing after the terminal request would leave the
    // last `receive` with nothing to take. The parent resolves the request
    // against its own copy of the roster, which only this delegate updates.
    await store.receive(\.delegate.repositoriesChanged)
    await store.receive(\.delegate.worktreeCreated)
    await store.receive(\.delegate.openTaskTerminal)
    await store.finish()

    #expect(store.state.sidebarItems[id: createdWorktree.id]?.lifecycle == .pending)
  }

  // MARK: - A20b: a failed creation rolls back completely

  @Test func failedWorktreeCreationLeavesNoRecordNoWriteAndNoTerminal() async throws {
    let sandbox = try makeSandbox()
    let busy = try sandbox.makeDirectory("busy", activityAt: Self.freshDate)
    let attempts = LockIsolated<[CreateAttempt]>([])
    let state = makeIsolatingState(sandbox: sandbox, busy: busy)
    let incumbent = try #require(state.taskRecords.first)
    let store = makeStore(state, sandbox: sandbox) {
      $0.createWorktreeStream = Self.createWorktreeStreamSpy(attempts: attempts, worktree: nil)
      // Stubbed even though this test asserts nothing about it: the rollback is
      // real, and the unstubbed client shells out to git in a temp directory.
      $0.removeWorktree = { worktree, _ in worktree.workingDirectory }
      $0.worktrees = { _ in [] }
    }

    await store.send(.tasks(.createTask(title: "Ship the inbox", directoryURL: busy)))
    await store.receive(\.tasks.autoManagedWorktreeCreationFailed)
    await store.finish()

    // Cold was tried too, and only then did the capture fail.
    #expect(attempts.value.map(\.copyIgnored) == [true, false])
    // Nothing landed: no record, no orphan marker, no selection move, no write.
    // No terminal either, though only by construction rather than by assertion —
    // the request rides on the record, and no record was created.
    #expect(store.state.taskRecords.map(\.id) == [incumbent.id])
    #expect(store.state.taskRecords.allSatisfy { $0.autoManagedWorktree == nil })
    #expect(store.state.selection == nil)
    #expect(!sandbox.didWriteTasksFile)
    // …and the failure is visible, on the same surface every other worktree
    // creation failure uses.
    #expect(store.state.alert != nil)
  }

  /// The retry runs under the same name, so the half-created directory a warm
  /// failure leaves behind has to go first — otherwise the cold attempt fails on
  /// "directory already exists" and the degrade path that exists to save the
  /// capture never runs. Ordering is the whole assertion.
  @Test func aWarmFailureRemovesItsLeftoversBeforeRetryingCold() async throws {
    let sandbox = try makeSandbox()
    let busy = try sandbox.makeDirectory("busy", activityAt: Self.freshDate)
    let created = try sandbox.makeDirectory("created", activityAt: Self.freshDate)
    let createdWorktree = TaskInboxFixture.makeWorktree(created, rootURL: sandbox.rootURL)
    let attempts = LockIsolated<[CreateAttempt]>([])
    let calls = LockIsolated<[String]>([])
    let removedBranches = LockIsolated<[Bool]>([])
    let spy = Self.createWorktreeStreamSpy(attempts: attempts, worktree: createdWorktree, succeedsFromAttempt: 2)
    let store = makeStore(makeIsolatingState(sandbox: sandbox, busy: busy), sandbox: sandbox) {
      $0.createWorktreeStream = { name, repoRoot, base, ignored, untracked, ref, override in
        calls.withValue { $0.append("create") }
        return spy(name, repoRoot, base, ignored, untracked, ref, override)
      }
      $0.removeWorktree = { worktree, deleteBranch in
        calls.withValue { $0.append("remove") }
        removedBranches.withValue { $0.append(deleteBranch) }
        return worktree.workingDirectory
      }
      $0.worktrees = { _ in [] }
    }

    await store.send(.tasks(.createTask(title: "Ship the inbox", directoryURL: busy)))
    await store.receive(\.tasks.autoManagedWorktreeCreated)
    await store.finish()

    #expect(calls.value == ["create", "remove", "create"])
    // The branch goes with it: it was minted seconds ago by the attempt that
    // just failed, so it cannot carry work — and leaving it would make the
    // retry collide on the branch instead of on the directory.
    #expect(removedBranches.value == [true])
    let record = try #require(store.state.taskRecords.first { $0.title == "Ship the inbox" })
    #expect(record.autoManagedWorktree?.path == TaskDirectoryPath.canonical(created))
    #expect(store.state.alert == nil)
  }

  /// A20b is about what is left *behind*, not only about what was written. Both
  /// attempts failing means the directory and branch the last one may have
  /// created are orphans nothing else will ever clean up.
  @Test func aFailedCaptureRemovesTheOrphanItsLastAttemptLeftBehind() async throws {
    let sandbox = try makeSandbox()
    let busy = try sandbox.makeDirectory("busy", activityAt: Self.freshDate)
    let attempts = LockIsolated<[CreateAttempt]>([])
    let removed = LockIsolated<[(path: String, deleteBranch: Bool)]>([])
    let store = makeStore(makeIsolatingState(sandbox: sandbox, busy: busy), sandbox: sandbox) {
      $0.createWorktreeStream = Self.createWorktreeStreamSpy(attempts: attempts, worktree: nil)
      $0.removeWorktree = { worktree, deleteBranch in
        removed.withValue {
          $0.append((worktree.workingDirectory.path(percentEncoded: false), deleteBranch))
        }
        return worktree.workingDirectory
      }
      $0.worktrees = { _ in [] }
    }

    await store.send(.tasks(.createTask(title: "Ship the inbox", directoryURL: busy)))
    await store.receive(\.tasks.autoManagedWorktreeCreationFailed)
    await store.finish()

    // Once between the attempts, once for the attempt that had no retry left.
    #expect(removed.value.count == 2)
    let branch = try #require(attempts.value.first?.name)
    let baseDirectory = try #require(attempts.value.first?.baseDirectory)
    let expected = baseDirectory.appending(path: branch, directoryHint: .isDirectory)
      .standardizedFileURL.path(percentEncoded: false)
    #expect(removed.value.map(\.path) == [expected, expected])
    #expect(removed.value.map(\.deleteBranch) == [true, true])
    // Still nothing persisted, and the failure is still reported.
    #expect(!sandbox.didWriteTasksFile)
    #expect(store.state.alert != nil)
  }

  /// The inbox must not gain a phantom row for a worktree that does not exist:
  /// rollback is roster-level too.
  @Test func failedWorktreeCreationRegistersNoWorktreeRow() async throws {
    let sandbox = try makeSandbox()
    let busy = try sandbox.makeDirectory("busy", activityAt: Self.freshDate)
    let attempts = LockIsolated<[CreateAttempt]>([])
    let store = makeStore(makeIsolatingState(sandbox: sandbox, busy: busy), sandbox: sandbox) {
      $0.createWorktreeStream = Self.createWorktreeStreamSpy(attempts: attempts, worktree: nil)
      $0.removeWorktree = { worktree, _ in worktree.workingDirectory }
      $0.worktrees = { _ in [] }
    }
    let rowsBefore = Set(store.state.sidebarItems.ids)

    await store.send(.tasks(.createTask(title: "Ship the inbox", directoryURL: busy)))
    await store.receive(\.tasks.autoManagedWorktreeCreationFailed)
    await store.finish()

    #expect(Set(store.state.sidebarItems.ids) == rowsBefore)
    #expect(store.state.pendingWorktrees.isEmpty)
  }

  // MARK: - Settle cleanup (A20 + Resolved #9)

  /// State with one auto-managed task, sole owner of its directory and holding
  /// a live surface — the only shape a settle is allowed to clean up.
  private func makeSettleableState(
    sandbox: Sandbox,
    worktreeDirectory: URL,
    markerPath: String? = nil,
    markerBranch: String = "task/ship-the-inbox-abcdef01"
  ) -> (state: RepositoriesFeature.State, record: TaskRecord) {
    let surfaceID = UUID()
    var state = TaskInboxFixture.makeState(
      sandbox: sandbox,
      directories: [worktreeDirectory],
      surfacesPerRow: [worktreeDirectory: [surfaceID]],
      hasLoadedTasks: true
    )
    var record = TaskInboxFixture.makeRecord(directory: worktreeDirectory, surfaceIDs: [surfaceID])
    record.autoManagedWorktree = TaskRecord.AutoManagedWorktree(
      path: markerPath ?? TaskDirectoryPath.canonical(worktreeDirectory),
      branch: markerBranch,
      createdAt: Self.freshDate
    )
    state.taskRecords = [record]
    state.applyPostReduceCacheRecomputes(.all)
    return (state, record)
  }

  @Test func settlingAnAutoManagedTaskDeletesTheWorktreeAfterHibernation() async throws {
    let sandbox = try makeSandbox()
    let auto = try sandbox.makeDirectory("auto", activityAt: Self.freshDate)
    let (state, record) = makeSettleableState(sandbox: sandbox, worktreeDirectory: auto)
    let removed = LockIsolated<[(worktree: Worktree, deleteBranch: Bool)]>([])
    let store = makeStore(state, sandbox: sandbox) {
      $0.rootDirectoryExists = { _ in true }
      $0.branchName = { _ in "task/ship-the-inbox-abcdef01" }
      $0.lineChanges = { _ in (added: 0, removed: 0) }
      $0.removeWorktree = { worktree, deleteBranch in
        removed.withValue { $0.append((worktree, deleteBranch)) }
        return worktree.workingDirectory
      }
      $0.worktrees = { _ in [] }
    }

    await store.send(.tasks(.settle(record.id)))
    // Hibernation first, always: deleting a directory with live sessions in it
    // is how a settle turns into data loss. This pair is the ordering proof —
    // a non-exhaustive `receive` *discards* everything it skips, so a cleanup
    // dispatched ahead of the hibernation request would be swallowed here and
    // the next `receive` would find nothing left to take.
    await store.receive(\.delegate.hibernateTaskSurfaces)
    await store.receive(\.tasks.cleanupAutoManagedWorktree)
    await store.receive(\.tasks.autoManagedWorktreeCleanupFinished)
    await store.finish()

    let deletion = try #require(removed.value.first)
    #expect(removed.value.count == 1)
    #expect(deletion.worktree.id == WorktreeID(auto.path(percentEncoded: false)))
    // The branch is kept: it may carry commits, and Resolved #9's rule is to
    // leak rather than destroy.
    #expect(deletion.deleteBranch == false)
    // The marker is cleared once the directory is gone, so a later settle /
    // unsettle round cannot re-authorize a delete against a stale path.
    #expect(store.state.taskRecords[id: record.id]?.autoManagedWorktree == nil)
    #expect(store.state.taskRecords[id: record.id]?.settledAt == Self.now)
    #expect(sandbox.loadFile()?.tasks.first?.autoManagedWorktree == nil)
  }

  /// A deleted directory must not keep its row. The sidebar would go on
  /// rendering it, and the terminal would go on treating it as a worktree it is
  /// allowed to hold sessions for, until something unrelated forced a reload.
  @Test func aSuccessfulCleanupPrunesTheRowAndAnnouncesTheRoster() async throws {
    let sandbox = try makeSandbox()
    let auto = try sandbox.makeDirectory("auto", activityAt: Self.freshDate)
    let (state, record) = makeSettleableState(sandbox: sandbox, worktreeDirectory: auto)
    let worktreeID = WorktreeID(auto.path(percentEncoded: false))
    let store = makeStore(state, sandbox: sandbox) {
      $0.rootDirectoryExists = { _ in true }
      $0.branchName = { _ in "task/ship-the-inbox-abcdef01" }
      $0.lineChanges = { _ in (added: 0, removed: 0) }
      $0.removeWorktree = { worktree, _ in worktree.workingDirectory }
      $0.worktrees = { _ in [] }
    }
    #expect(store.state.sidebarItems[id: worktreeID] != nil)

    await store.send(.tasks(.settle(record.id)))
    await store.receive(\.tasks.autoManagedWorktreeCleanupFinished)
    await store.receive(\.delegate.repositoriesChanged)
    await store.finish()

    #expect(store.state.sidebarItems[id: worktreeID] == nil)
    #expect(store.state.repositories.flatMap(\.worktrees).isEmpty)
    // The task outlives its worktree (A10b) — only the marker is spent.
    #expect(store.state.taskRecords[id: record.id] != nil)
  }

  /// A settle usually runs from the Tasks tab, but the worktree row can be the
  /// selection when it happens, and a selection pointing at a directory that no
  /// longer exists renders a detail pane for nothing.
  @Test func aSuccessfulCleanupMovesASelectionOffTheDeletedRow() async throws {
    let sandbox = try makeSandbox()
    let auto = try sandbox.makeDirectory("auto", activityAt: Self.freshDate)
    var (state, record) = makeSettleableState(sandbox: sandbox, worktreeDirectory: auto)
    let worktreeID = WorktreeID(auto.path(percentEncoded: false))
    state.selection = .worktree(worktreeID)
    state.applyPostReduceCacheRecomputes(.all)
    let store = makeStore(state, sandbox: sandbox) {
      $0.rootDirectoryExists = { _ in true }
      $0.branchName = { _ in "task/ship-the-inbox-abcdef01" }
      $0.lineChanges = { _ in (added: 0, removed: 0) }
      $0.removeWorktree = { worktree, _ in worktree.workingDirectory }
      $0.worktrees = { _ in [] }
    }

    await store.send(.tasks(.settle(record.id)))
    await store.receive(\.tasks.autoManagedWorktreeCleanupFinished)
    await store.finish()

    #expect(store.state.selection != .worktree(worktreeID))
  }

  /// Resolved #9's precondition, verbatim: "path still resolves to that
  /// branch". A worktree the user checked out onto something else is a
  /// worktree the user is using.
  @Test func aBranchMismatchRefusesToDeleteAndKeepsTheMarker() async throws {
    let sandbox = try makeSandbox()
    let auto = try sandbox.makeDirectory("auto", activityAt: Self.freshDate)
    let (state, record) = makeSettleableState(sandbox: sandbox, worktreeDirectory: auto)
    let removed = LockIsolated(false)
    let store = makeStore(state, sandbox: sandbox) {
      $0.rootDirectoryExists = { _ in true }
      $0.branchName = { _ in "main" }
      $0.lineChanges = { _ in (added: 0, removed: 0) }
      $0.removeWorktree = { worktree, _ in
        removed.withValue { $0 = true }
        return worktree.workingDirectory
      }
      $0.worktrees = { _ in [] }
    }

    await store.send(.tasks(.settle(record.id)))
    await store.receive(\.tasks.cleanupAutoManagedWorktree)
    await store.receive(\.tasks.autoManagedWorktreeCleanupFinished)
    await store.finish()

    #expect(removed.value == false)
    // The marker survives the refusal: the directory is still ours, we just
    // refuse to act on it right now.
    #expect(store.state.taskRecords[id: record.id]?.autoManagedWorktree != nil)
    // Settling still worked — cleanup is a side effect of settling, never a
    // precondition for it.
    #expect(store.state.taskRecords[id: record.id]?.settledAt == Self.now)
  }

  /// A branch that cannot be proven at all (detached HEAD, unreadable repo)
  /// reads as a mismatch. "Unknown" is never good enough to delete on.
  @Test func anUnprovableBranchRefusesToDelete() async throws {
    let sandbox = try makeSandbox()
    let auto = try sandbox.makeDirectory("auto", activityAt: Self.freshDate)
    let (state, record) = makeSettleableState(sandbox: sandbox, worktreeDirectory: auto)
    let removed = LockIsolated(false)
    let store = makeStore(state, sandbox: sandbox) {
      $0.rootDirectoryExists = { _ in true }
      $0.branchName = { _ in nil }
      $0.lineChanges = { _ in (added: 0, removed: 0) }
      $0.removeWorktree = { worktree, _ in
        removed.withValue { $0 = true }
        return worktree.workingDirectory
      }
      $0.worktrees = { _ in [] }
    }

    await store.send(.tasks(.settle(record.id)))
    await store.receive(\.tasks.autoManagedWorktreeCleanupFinished)
    await store.finish()

    #expect(removed.value == false)
    #expect(store.state.taskRecords[id: record.id]?.autoManagedWorktree != nil)
  }

  @Test func aMissingPathRefusesToDelete() async throws {
    let sandbox = try makeSandbox()
    let auto = try sandbox.makeDirectory("auto", activityAt: Self.freshDate)
    let (state, record) = makeSettleableState(sandbox: sandbox, worktreeDirectory: auto)
    let removed = LockIsolated(false)
    let branchWasRead = LockIsolated(false)
    let store = makeStore(state, sandbox: sandbox) {
      $0.rootDirectoryExists = { _ in false }
      $0.branchName = { _ in
        branchWasRead.withValue { $0 = true }
        return "task/ship-the-inbox-abcdef01"
      }
      $0.lineChanges = { _ in (added: 0, removed: 0) }
      $0.removeWorktree = { worktree, _ in
        removed.withValue { $0 = true }
        return worktree.workingDirectory
      }
      $0.worktrees = { _ in [] }
    }

    await store.send(.tasks(.settle(record.id)))
    await store.receive(\.tasks.autoManagedWorktreeCleanupFinished)
    await store.finish()

    #expect(removed.value == false)
    #expect(branchWasRead.value == false)
    #expect(store.state.taskRecords[id: record.id]?.autoManagedWorktree != nil)
  }

  /// Uncommitted work outranks tidiness, every time.
  @Test func aDirtyWorktreeRefusesToDelete() async throws {
    let sandbox = try makeSandbox()
    let auto = try sandbox.makeDirectory("auto", activityAt: Self.freshDate)
    let (state, record) = makeSettleableState(sandbox: sandbox, worktreeDirectory: auto)
    let removed = LockIsolated(false)
    let store = makeStore(state, sandbox: sandbox) {
      $0.rootDirectoryExists = { _ in true }
      $0.branchName = { _ in "task/ship-the-inbox-abcdef01" }
      $0.lineChanges = { _ in (added: 12, removed: 3) }
      $0.removeWorktree = { worktree, _ in
        removed.withValue { $0 = true }
        return worktree.workingDirectory
      }
      $0.worktrees = { _ in [] }
    }

    await store.send(.tasks(.settle(record.id)))
    await store.receive(\.tasks.autoManagedWorktreeCleanupFinished)
    await store.finish()

    #expect(removed.value == false)
    #expect(store.state.taskRecords[id: record.id]?.autoManagedWorktree != nil)
  }

  /// A marker pointing at a registered repository root is a marker that is
  /// wrong, whatever it says. Main checkouts are never deletable (A20).
  @Test func aMarkerPointingAtARegisteredRepositoryRootRefusesToDelete() async throws {
    let sandbox = try makeSandbox()
    let (state, record) = makeSettleableState(
      sandbox: sandbox,
      worktreeDirectory: sandbox.rootURL,
      markerPath: TaskDirectoryPath.canonical(sandbox.rootURL)
    )
    let removed = LockIsolated(false)
    let store = makeStore(state, sandbox: sandbox) {
      $0.rootDirectoryExists = { _ in true }
      $0.branchName = { _ in "task/ship-the-inbox-abcdef01" }
      $0.lineChanges = { _ in (added: 0, removed: 0) }
      $0.removeWorktree = { worktree, _ in
        removed.withValue { $0 = true }
        return worktree.workingDirectory
      }
      $0.worktrees = { _ in [] }
    }

    await store.send(.tasks(.settle(record.id)))
    await store.finish()

    #expect(removed.value == false)
    #expect(store.state.taskRecords[id: record.id]?.autoManagedWorktree != nil)
  }

  /// The common case, and the one a bug here would destroy: an ordinary task in
  /// an ordinary worktree. No marker, no cleanup action, no delete — the settle
  /// path must not even reach the git client.
  @Test func settlingATaskWithoutAMarkerNeverDeletesAnything() async throws {
    let sandbox = try makeSandbox()
    let plain = try sandbox.makeDirectory("plain", activityAt: Self.freshDate)
    let surfaceID = UUID()
    var state = TaskInboxFixture.makeState(
      sandbox: sandbox,
      directories: [plain],
      surfacesPerRow: [plain: [surfaceID]],
      hasLoadedTasks: true
    )
    let record = TaskInboxFixture.makeRecord(directory: plain, surfaceIDs: [surfaceID])
    state.taskRecords = [record]
    state.applyPostReduceCacheRecomputes(.all)
    let reads = LockIsolated<[String]>([])
    let store = makeStore(state, sandbox: sandbox) {
      $0.rootDirectoryExists = { _ in
        reads.withValue { $0.append("exists") }
        return true
      }
      $0.branchName = { _ in
        reads.withValue { $0.append("branch") }
        return "main"
      }
      $0.lineChanges = { _ in
        reads.withValue { $0.append("lineChanges") }
        return (added: 0, removed: 0)
      }
      $0.removeWorktree = { worktree, _ in
        reads.withValue { $0.append("remove") }
        return worktree.workingDirectory
      }
      $0.worktrees = { _ in [] }
    }

    await store.send(.tasks(.settle(record.id)))
    await store.receive(\.delegate.hibernateTaskSurfaces)
    await store.finish()

    // Not "nothing was deleted" — nothing was even *asked*. A settle with no
    // marker has no delete authority to re-check, so it must not reach git at
    // all, and a spy on the delete alone would not notice if it did.
    #expect(reads.value.isEmpty)
    #expect(store.state.taskRecords[id: record.id]?.settledAt == Self.now)
  }

  /// A6: a directory shared with another live task defers hibernation
  /// entirely — its sessions are somebody else's. A directory nobody hibernated
  /// is a directory nobody may delete, marker or not.
  @Test func aSharedDirectoryDefersHibernationAndNeverDeletes() async throws {
    let sandbox = try makeSandbox()
    let auto = try sandbox.makeDirectory("auto", activityAt: Self.freshDate)
    var (state, record) = makeSettleableState(sandbox: sandbox, worktreeDirectory: auto)
    // A second live task moved into the auto-managed directory (a promote-tab,
    // or a share answered later): the delete authority is now contested.
    state.taskRecords.append(TaskInboxFixture.makeRecord(directory: auto))
    state.applyPostReduceCacheRecomputes(.all)
    let removed = LockIsolated(false)
    let store = makeStore(state, sandbox: sandbox) {
      $0.rootDirectoryExists = { _ in true }
      $0.branchName = { _ in "task/ship-the-inbox-abcdef01" }
      $0.lineChanges = { _ in (added: 0, removed: 0) }
      $0.removeWorktree = { worktree, _ in
        removed.withValue { $0 = true }
        return worktree.workingDirectory
      }
      $0.worktrees = { _ in [] }
    }

    await store.send(.tasks(.settle(record.id)))
    await store.finish()

    #expect(removed.value == false)
    #expect(store.state.taskRecords[id: record.id]?.autoManagedWorktree != nil)
  }

  /// The precondition no git read can answer: a tab still standing in the
  /// worktree means a session is still standing in the directory. Hibernation is
  /// dispatched before the cleanup but finishes long after it, so the delete has
  /// to check for itself — and it refuses without reading a single byte of git
  /// state, because none of it could make an open session safe to delete under.
  @Test func anOpenTabRefusesToDeleteBeforeAnyGitStateIsRead() async throws {
    let sandbox = try makeSandbox()
    let auto = try sandbox.makeDirectory("auto", activityAt: Self.freshDate)
    let (state, record) = makeSettleableState(sandbox: sandbox, worktreeDirectory: auto)
    let reads = LockIsolated<[String]>([])
    let store = makeStore(state, sandbox: sandbox, tabCount: 1) {
      $0.rootDirectoryExists = { _ in
        reads.withValue { $0.append("exists") }
        return true
      }
      $0.branchName = { _ in "task/ship-the-inbox-abcdef01" }
      $0.lineChanges = { _ in (added: 0, removed: 0) }
      $0.removeWorktree = { worktree, _ in
        reads.withValue { $0.append("remove") }
        return worktree.workingDirectory
      }
      $0.worktrees = { _ in [] }
    }

    await store.send(.tasks(.settle(record.id)))
    await store.receive(\.delegate.hibernateTaskSurfaces)
    await store.receive(\.tasks.cleanupAutoManagedWorktree)
    await store.finish()

    #expect(reads.value.isEmpty)
    // The marker survives: the directory is still ours, we just refuse to act
    // on it while somebody may be standing in it.
    #expect(store.state.taskRecords[id: record.id]?.autoManagedWorktree != nil)
    #expect(store.state.taskRecords[id: record.id]?.settledAt == Self.now)
  }

  /// The case `lineChanges` alone cannot see: a worktree holding nothing but a
  /// file git has never been told about. `git diff` reports `(0, 0)` for it, so
  /// without its own check the delete would take an uncommitted first draft — a
  /// scratch script, a `.env` — with it, and git could not give it back.
  @Test func anUntrackedFileRefusesToDeleteEvenWithACleanDiff() async throws {
    let sandbox = try makeSandbox()
    let auto = try sandbox.makeDirectory("auto", activityAt: Self.freshDate)
    let (state, record) = makeSettleableState(sandbox: sandbox, worktreeDirectory: auto)
    let removed = LockIsolated(false)
    let store = makeStore(state, sandbox: sandbox) {
      $0.rootDirectoryExists = { _ in true }
      $0.branchName = { _ in "task/ship-the-inbox-abcdef01" }
      $0.untrackedFileCount = { _ in 1 }
      $0.lineChanges = { _ in (added: 0, removed: 0) }
      $0.removeWorktree = { worktree, _ in
        removed.withValue { $0 = true }
        return worktree.workingDirectory
      }
      $0.worktrees = { _ in [] }
    }

    await store.send(.tasks(.settle(record.id)))
    await store.receive(\.tasks.autoManagedWorktreeCleanupFinished)
    await store.finish()

    #expect(removed.value == false)
    #expect(store.state.taskRecords[id: record.id]?.autoManagedWorktree != nil)
  }

  /// A count that cannot be read is not a count of zero. Same rule as the
  /// unprovable branch: "unknown" is never good enough to delete on.
  @Test func anUnreadableUntrackedCountRefusesToDelete() async throws {
    let sandbox = try makeSandbox()
    let auto = try sandbox.makeDirectory("auto", activityAt: Self.freshDate)
    let (state, record) = makeSettleableState(sandbox: sandbox, worktreeDirectory: auto)
    let removed = LockIsolated(false)
    let store = makeStore(state, sandbox: sandbox) {
      $0.rootDirectoryExists = { _ in true }
      $0.branchName = { _ in "task/ship-the-inbox-abcdef01" }
      $0.untrackedFileCount = { _ in
        throw GitClientError.commandFailed(command: "git status", message: "boom")
      }
      $0.lineChanges = { _ in (added: 0, removed: 0) }
      $0.removeWorktree = { worktree, _ in
        removed.withValue { $0 = true }
        return worktree.workingDirectory
      }
      $0.worktrees = { _ in [] }
    }

    await store.send(.tasks(.settle(record.id)))
    await store.receive(\.tasks.autoManagedWorktreeCleanupFinished)
    await store.finish()

    #expect(removed.value == false)
    #expect(store.state.taskRecords[id: record.id]?.autoManagedWorktree != nil)
  }

  /// `lineChanges` is optional, and its `nil` means "could not diff", not
  /// "clean". Deleting on it would be deleting on a failed read.
  @Test func anUnprovableDiffRefusesToDelete() async throws {
    let sandbox = try makeSandbox()
    let auto = try sandbox.makeDirectory("auto", activityAt: Self.freshDate)
    let (state, record) = makeSettleableState(sandbox: sandbox, worktreeDirectory: auto)
    let removed = LockIsolated(false)
    let store = makeStore(state, sandbox: sandbox) {
      $0.rootDirectoryExists = { _ in true }
      $0.branchName = { _ in "task/ship-the-inbox-abcdef01" }
      $0.lineChanges = { _ in nil }
      $0.removeWorktree = { worktree, _ in
        removed.withValue { $0 = true }
        return worktree.workingDirectory
      }
      $0.worktrees = { _ in [] }
    }

    await store.send(.tasks(.settle(record.id)))
    await store.receive(\.tasks.autoManagedWorktreeCleanupFinished)
    await store.finish()

    #expect(removed.value == false)
    #expect(store.state.taskRecords[id: record.id]?.autoManagedWorktree != nil)
  }

  /// The preconditions are a *chain*, not a set: each one is only meaningful
  /// once the cheaper one before it held. Reading the diff of a directory that
  /// no longer exists, or of one checked out onto a branch we never created, is
  /// how a refusal turns into a stale answer that passes. Pinned by call order
  /// so a reordering refactor fails here rather than in production.
  @Test func preconditionsAreReadInTheirLockedOrder() async throws {
    let sandbox = try makeSandbox()
    let auto = try sandbox.makeDirectory("auto", activityAt: Self.freshDate)
    let (state, record) = makeSettleableState(sandbox: sandbox, worktreeDirectory: auto)
    let reads = LockIsolated<[String]>([])
    let store = makeStore(state, sandbox: sandbox) {
      $0.rootDirectoryExists = { _ in
        reads.withValue { $0.append("exists") }
        return true
      }
      $0.branchName = { _ in
        reads.withValue { $0.append("branch") }
        return "task/ship-the-inbox-abcdef01"
      }
      $0.untrackedFileCount = { _ in
        reads.withValue { $0.append("untracked") }
        return 0
      }
      $0.lineChanges = { _ in
        reads.withValue { $0.append("lineChanges") }
        return (added: 0, removed: 0)
      }
      $0.removeWorktree = { worktree, _ in
        reads.withValue { $0.append("remove") }
        return worktree.workingDirectory
      }
      $0.worktrees = { _ in [] }
    }

    await store.send(.tasks(.settle(record.id)))
    await store.receive(\.tasks.autoManagedWorktreeCleanupFinished)
    await store.finish()

    #expect(reads.value == ["exists", "branch", "untracked", "lineChanges", "remove"])
  }

  /// Settle is idempotent (a second one is a no-op), so the cleanup that rides
  /// on it must be too — otherwise a double-click re-runs a delete against a
  /// path something else may have taken over.
  @Test func aSecondSettleRunsNoSecondCleanup() async throws {
    let sandbox = try makeSandbox()
    let auto = try sandbox.makeDirectory("auto", activityAt: Self.freshDate)
    let (state, record) = makeSettleableState(sandbox: sandbox, worktreeDirectory: auto)
    let removeCount = LockIsolated(0)
    let store = makeStore(state, sandbox: sandbox) {
      $0.rootDirectoryExists = { _ in true }
      $0.branchName = { _ in "task/ship-the-inbox-abcdef01" }
      $0.lineChanges = { _ in (added: 0, removed: 0) }
      $0.removeWorktree = { worktree, _ in
        removeCount.withValue { $0 += 1 }
        return worktree.workingDirectory
      }
      $0.worktrees = { _ in [] }
    }

    await store.send(.tasks(.settle(record.id)))
    await store.receive(\.tasks.autoManagedWorktreeCleanupFinished)
    await store.send(.tasks(.settle(record.id)))
    await store.finish()

    #expect(removeCount.value == 1)
  }
}

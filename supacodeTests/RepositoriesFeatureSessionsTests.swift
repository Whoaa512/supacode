import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import Observation
import Sharing
import Testing

@testable import SupacodeSettingsShared
@testable import supacode

@MainActor
struct RepositoriesFeatureSessionsTests {
  private func summary(_ id: String, created: TimeInterval = 10, title: String = "Title")
    -> SessionSummary
  {
    SessionSummary(
      harness: .pi, sessionID: id, createdAt: Date(timeIntervalSince1970: created),
      cwd: "/workspace", title: title, messageCount: 5,
      lastActivity: Date(timeIntervalSince1970: created))
  }

  private func snapshot(_ surface: UUID, ref: String? = nil) -> SessionLiveSnapshot {
    SessionLiveSnapshot(
      harness: .pi, sessionRef: ref, cwd: "/workspace",
      location: SessionLocation(
        layoutID: "/workspace", directoryID: "/workspace", tabID: TabID(rawValue: surface), surfaceID: surface))
  }

  private func state() -> RepositoriesFeature.State {
    var state = RepositoriesFeature.State()
    state.$sessions = Shared(value: [:])
    state.$sidebar = Shared(value: SidebarState())
    state.$persistedLayouts = SharedReader(value: TaskLayoutsFile())
    return state
  }

  private func store(clock: TestClock<Duration> = TestClock()) -> TestStoreOf<RepositoriesFeature> {
    var initial = state()
    initial.sessionsStarted = true
    let store = TestStore(initialState: initial) {
      RepositoriesFeature()
    } withDependencies: {
      $0.date.now = .distantPast
      $0.continuousClock = clock
      $0.defaultAppStorage = .inMemory
    }
    store.exhaustivity = .off
    return store
  }

  @Test(.dependencies) func newStorageKeyDefaultsToSessionsAndPersistsChoices() {
    let defaults = UserDefaults.inMemory
    defaults.set("agents", forKey: "sidebarTab")
    withDependencies {
      $0.defaultAppStorage = defaults
    } operation: {
      @Shared(.sidebarTab) var tab
      #expect(tab == "sessions")
      $tab.withLock { $0 = "worktrees" }
      #expect(defaults.string(forKey: "sessionsSidebarTab") == "worktrees")
    }
  }

  @Test(.dependencies) func creationOrderSectionsAndTitleUpdatesKeepStructureStable() async {
    let store = store()
    let settled = summary("new", created: 30)
    store.state.$sessions.withLock { $0[settled.id] = SessionSidecarEntry(settledAt: .distantPast) }
    await store.send(
      .sessionsCacheLoaded([summary("old"), settled, summary("middle", created: 20)]))
    #expect(
      store.state.sessionsSidebarStructure.allIDs == [
        .session(summary("middle").id), .session(summary("old").id), .session(settled.id),
      ])
    #expect(store.state.sessionsSidebarStructure.sections.map(\.id) == [.active, .settled])
    let structure = store.state.sessionsSidebarStructure
    let worktrees = store.state.sidebarStructure
    var renamed = summary("middle", created: 20, title: "Renamed")
    renamed.lastActivity = .distantFuture
    await store.send(.sessionsRefreshCompleted([summary("old"), settled, renamed]))
    #expect(store.state.sessionItems[id: .session(renamed.id)]?.title == "Renamed")
    #expect(store.state.sessionsSidebarStructure == structure)
    #expect(store.state.sidebarStructure == worktrees)
    #expect(
      !AppFeature.Action.repositories(.sessionsRefreshCompleted([])).affectsWorktreeMenuSnapshot)
    #expect(
      RepositoriesFeature.Action.sessionsRefreshCompleted([]).cacheInvalidations
        == .sessionsStructure)
    #expect(
      RepositoriesFeature.Action.sessionItems(.element(id: .session(renamed.id), action: .activate))
        .cacheInvalidations.isEmpty)
    await store.finish()
  }

  @Test(.dependencies) func provisionalCreationIsStableAndMergesSelectionIntoIndexedRow() async {
    let clock = TestClock()
    let store = store(clock: clock)
    let surface = UUID()
    let provisional = snapshot(surface)
    await store.send(.sessionSnapshotsChanged([provisional]))
    await store.receive(\.sessionsRefreshRequested)
    let created = store.state.sessionItems.first?.createdAt
    await store.send(.sessionSelectionChanged(provisional.id))
    await store.send(.sessionSnapshotsChanged([provisional]))
    #expect(store.state.sessionItems.first?.createdAt == created)
    let indexed = summary("real")
    await store.send(.sessionsCacheLoaded([indexed]))
    #expect(store.state.sessionItems.count == 2)
    await store.send(.sessionSnapshotsChanged([snapshot(surface, ref: "real")]))
    await store.receive(\.sessionsRefreshRequested)
    #expect(store.state.sessionItems.count == 1)
    #expect(store.state.sessionSelection == .session(indexed.id))
    #expect(store.state.sessionItems.first?.createdAt == indexed.createdAt)
    #expect(store.state.sessionItems.first?.title == indexed.title)
    #expect(store.state.sessionItems.first?.location?.surfaceID == surface)
    await clock.advance(by: .milliseconds(500))
    await store.receive(\.sessionsRefreshDebounced)
    await store.receive(\.sessionsRefreshCompleted)
    await store.finish()
  }

  @Test(.dependencies) func syntheticRealRowHydratesThenBecomesDormant() async {
    let clock = TestClock()
    let store = store(clock: clock)
    let surface = UUID()
    await store.send(.sessionSnapshotsChanged([snapshot(surface)]))
    await store.receive(\.sessionsRefreshRequested)
    let created = store.state.sessionItems.first?.createdAt
    await store.send(.sessionSnapshotsChanged([snapshot(surface, ref: "real")]))
    await store.receive(\.sessionsRefreshRequested)
    #expect(store.state.sessionItems.count == 1)
    #expect(store.state.sessionItems.first?.createdAt == created)
    await store.send(.sessionsCacheLoaded([summary("real", created: 1)]))
    #expect(store.state.sessionItems.first?.createdAt == Date(timeIntervalSince1970: 1))
    await store.send(.sessionSnapshotsChanged([]))
    await store.receive(\.sessionsRefreshRequested)
    #expect(store.state.sessionItems.first?.isLive == false)
    #expect(store.state.sessionsSidebarStructure.liveIDs.isEmpty)
    await clock.advance(by: .milliseconds(500))
    await store.receive(\.sessionsRefreshDebounced)
    await store.receive(\.sessionsRefreshCompleted)
    await store.finish()
  }

  @Test(.dependencies) func duplicateIdentityKeepsOneRowAndExistingLinkUntilLastSurfaceLeaves()
    async
  {
    let clock = TestClock()
    let store = store(clock: clock)
    let low = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    let high = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    let first = snapshot(high, ref: "same")
    let second = snapshot(low, ref: "same")
    await store.send(.sessionSnapshotsChanged([first]))
    await store.receive(\.sessionsRefreshRequested)
    await store.send(.sessionSnapshotsChanged([second, first]))
    await store.receive(\.sessionsRefreshRequested)
    #expect(store.state.sessionItems.count == 1)
    #expect(store.state.sessionItems.first?.location == first.location)
    await store.send(.sessionSnapshotsChanged([second]))
    await store.receive(\.sessionsRefreshRequested)
    #expect(store.state.sessionItems.first?.location == second.location)
    await store.send(.sessionSnapshotsChanged([]))
    await store.receive(\.sessionsRefreshRequested)
    #expect(store.state.sessionItems.count == 1)
    #expect(store.state.sessionItems.first?.isLive == false)
    await store.send(.activateSession(first.id))
    await clock.advance(by: .milliseconds(500))
    await store.receive(\.sessionsRefreshDebounced)
    await store.receive(\.sessionsRefreshCompleted)
    await store.finish()
  }

  @Test(.dependencies) func cachePublishesBeforeRefreshAndErrorsPreserveRows() async {
    enum Failure: Error { case unavailable }
    let cached = summary("cached")
    @Shared(.sidebarTab) var tab
    $tab.withLock { $0 = SidebarTab.worktrees.rawValue }
    let cacheCalls = LockIsolated(0)
    let gate = AsyncStream<Void>.makeStream()
    let store = TestStore(initialState: state()) {
      RepositoriesFeature()
    } withDependencies: {
      $0.date.now = .distantPast
      $0.continuousClock = TestClock()
      $0.sessionIndex.cached = {
        cacheCalls.withValue { $0 += 1 }
        return [cached]
      }
      $0.sessionIndex.refresh = {
        for await _ in gate.stream { break }
        throw Failure.unavailable
      }
    }
    store.exhaustivity = .off
    await store.send(.sessionsSidebarShown)
    await store.receive(\.sessionsStarted)
    await store.receive(\.sessionsCacheLoaded)
    await store.send(.sessionsStarted)
    #expect(cacheCalls.value == 1)
    #expect(tab == SidebarTab.worktrees.rawValue)
    #expect(store.state.sessionItems.first?.id == .session(cached.id))
    #expect(store.state.sessionsRefreshInFlight)
    gate.continuation.yield(())
    gate.continuation.finish()
    await store.receive(\.sessionsRefreshFailed)
    #expect(store.state.sessionItems.first?.id == .session(cached.id))
    #expect(!store.state.sessionsRefreshInFlight)
    await store.send(.sessionsStopped)
    await store.finish()
  }

  @Test(.dependencies) func sessionKilledBeforeAnyTurnLosesItsRowAfterTheNextScan() async {
    let clock = TestClock()
    let store = store(clock: clock)
    await store.send(.sessionSnapshotsChanged([snapshot(UUID(), ref: "never-saved")]))
    await store.receive(\.sessionsRefreshRequested)
    await store.send(.sessionSnapshotsChanged([]))
    await store.receive(\.sessionsRefreshRequested)
    #expect(store.state.sessionItems.count == 1, "kept until the scan confirms nothing was saved")
    await clock.advance(by: .milliseconds(500))
    await store.receive(\.sessionsRefreshCompleted)
    #expect(store.state.sessionItems.isEmpty)
    #expect(store.state.sessionsSidebarStructure.sections.isEmpty)
    await store.finish()
  }

  @Test(.dependencies) func statusFlipUpdatesRowWithoutRescanningTheIndex() async {
    let clock = TestClock()
    let calls = LockIsolated(0)
    var initial = state()
    initial.sessionsStarted = true
    let store = TestStore(initialState: initial) {
      RepositoriesFeature()
    } withDependencies: {
      $0.date.now = .distantPast
      $0.continuousClock = clock
      $0.sessionIndex.refresh = {
        calls.withValue { $0 += 1 }
        return []
      }
    }
    store.exhaustivity = .off
    var live = snapshot(UUID(), ref: "real")
    await store.send(.sessionSnapshotsChanged([live]))
    await store.receive(\.sessionsRefreshRequested)
    await clock.advance(by: .milliseconds(500))
    await store.receive(\.sessionsRefreshCompleted)
    #expect(calls.value == 1)
    live.status = .working
    await store.send(.sessionSnapshotsChanged([live]))
    #expect(store.state.sessionItems.first?.status == .working)
    await clock.advance(by: .milliseconds(500))
    await store.finish()
    #expect(calls.value == 1)
  }

  @Test(.dependencies) func debouncesEventsAndQueuesOneRefreshWithoutOverlap() async {
    let clock = TestClock()
    let calls = LockIsolated(0)
    let gate = AsyncStream<Void>.makeStream()
    var initial = state()
    initial.sessionsStarted = true
    let store = TestStore(initialState: initial) {
      RepositoriesFeature()
    } withDependencies: {
      $0.date.now = .distantPast
      $0.continuousClock = clock
      $0.sessionIndex.refresh = {
        let count = calls.withValue {
          $0 += 1
          return $0
        }
        if count == 1 { for await _ in gate.stream { break } }
        return []
      }
    }
    store.exhaustivity = .off
    await store.send(.sessionsRefreshRequested)
    await clock.advance(by: .milliseconds(400))
    await store.send(.sessionsRefreshRequested)
    await clock.advance(by: .milliseconds(400))
    #expect(calls.value == 0)
    await clock.advance(by: .milliseconds(100))
    await store.receive(\.sessionsRefreshDebounced)
    await store.send(.sessionsRefreshRequested)
    await clock.advance(by: .milliseconds(500))
    await store.receive(\.sessionsRefreshDebounced)
    #expect(calls.value == 1)
    #expect(store.state.sessionsRefreshPending)
    gate.continuation.yield(())
    gate.continuation.finish()
    await store.receive(\.sessionsRefreshCompleted)
    await store.receive(\.sessionsRefreshDebounced)
    await store.receive(\.sessionsRefreshCompleted)
    #expect(calls.value == 2)
    #expect(!store.state.sessionsRefreshInFlight)
    await store.finish()
  }

  @Test(.dependencies) func unchangedStructureAndSiblingAreNotObservedOnRename() {
    var model = state()
    model.sessionSummaries = [summary("a"), summary("b")]
    let synthetic = snapshot(UUID(), ref: "synthetic")
    model.sessionSnapshots = [synthetic]
    model.reconcileSessionItems(now: .distantPast)
    model.applyCacheRecomputes(.sessionsStructure)
    let structureChanged = LockIsolated(false)
    let siblingChanged = LockIsolated(false)
    let ownChanged = LockIsolated(false)
    let syntheticChanged = LockIsolated(false)
    withObservationTracking {
      _ = model.sessionItems[id: synthetic.id]?.location
    } onChange: {
      syntheticChanged.setValue(true)
    }
    withObservationTracking {
      _ = model.sessionsSidebarStructure
    } onChange: {
      structureChanged.setValue(true)
    }
    withObservationTracking {
      _ = model.sessionItems[id: .session(summary("b").id)]?.title
    } onChange: {
      siblingChanged.setValue(true)
    }
    withObservationTracking {
      _ = model.sessionItems[id: .session(summary("a").id)]?.title
    } onChange: {
      ownChanged.setValue(true)
    }
    model.sessionSummaries = [summary("a", title: "Changed"), summary("b")]
    model.reconcileSessionItems(now: .distantPast)
    model.applyCacheRecomputes(.sessionsStructure)
    #expect(!structureChanged.value)
    #expect(!siblingChanged.value)
    #expect(!syntheticChanged.value)
    #expect(ownChanged.value)
  }

  // MARK: - mergeSessionFolderRepositories overrides git-classified roots

  @Test func mergeSessionFolderOverridesGitRootWithSameID() {
    let path = "/tmp/supacode-merge-test-\(UUID())"
    let url = URL(fileURLWithPath: path).standardizedFileURL
    let repoID = RepositoryID(url.path(percentEncoded: false))
    let gitWorktree = Worktree(
      id: WorktreeID(url.path(percentEncoded: false)), name: "git", detail: "",
      workingDirectory: url, repositoryRootURL: url)
    let gitRepo = Repository(
      id: repoID, rootURL: url, name: "git",
      worktrees: [gitWorktree], isGitRepository: true)
    let result = RepositoriesFeature.mergeSessionFolderRepositories(
      [path], into: [gitRepo])
    #expect(result.count == 1)
    #expect(result[0].isGitRepository == false)
    #expect(result[0].id == repoID)
  }

  @Test func mergeSessionFolderDoesNotDuplicateWhenAlreadyFolderRepo() {
    let path = "/tmp/supacode-merge-dedup-\(UUID())"
    let url = URL(fileURLWithPath: path).standardizedFileURL
    let repoID = RepositoryID(url.path(percentEncoded: false))
    let folderRepo = RepositoriesFeature.makeFolderRepository(for: url)
    let result = RepositoriesFeature.mergeSessionFolderRepositories(
      [path], into: [folderRepo])
    #expect(result.count == 1)
    #expect(result[0].id == repoID)
  }

  @Test func mergeSessionFolderAppendsNewRoots() {
    let path = "/tmp/supacode-merge-new-\(UUID())"
    let result = RepositoriesFeature.mergeSessionFolderRepositories(
      [path], into: [])
    #expect(result.count == 1)
    #expect(result[0].isGitRepository == false)
  }

  @Test(.dependencies) func sessionRowIDByOffsetOnlyIncludesLiveRows() {
    var state = state()
    let active = summary("active", created: 30)
    let dormant = summary("dormant", created: 20)
    state.sessionSummaries = [active, dormant]
    state.sessionSnapshots = [snapshot(UUID(), ref: "active")]
    state.reconcileSessionItems(now: .distantPast)
    state.applyCacheRecomputes(.sessionsStructure)
    state.sessionSelection = .session(active.id)
    #expect(state.sessionRowID(byOffset: 1, focusedRowID: nil) == .session(active.id))
    #expect(state.sessionRowID(byOffset: -1, focusedRowID: nil) == .session(active.id))
  }

  @Test func mergeSessionFolderDoesNotReplaceParentGitRepoOnWorktreeCwdMatch() {
    let gitRoot = "/tmp/supacode-parent-git-\(UUID())"
    let worktreePath = gitRoot + "/wt-feature"
    let gitRootURL = URL(fileURLWithPath: gitRoot).standardizedFileURL
    let wtURL = URL(fileURLWithPath: worktreePath).standardizedFileURL
    let wtWorktree = Worktree(
      id: WorktreeID(wtURL.path(percentEncoded: false)), name: "wt-feature", detail: "",
      workingDirectory: wtURL, repositoryRootURL: gitRootURL)
    let gitRepo = Repository(
      id: RepositoryID(gitRootURL.path(percentEncoded: false)), rootURL: gitRootURL, name: "git",
      worktrees: [wtWorktree], isGitRepository: true)
    // sessionFolderRoot path is the worktree cwd, not the git repo root
    let result = RepositoriesFeature.mergeSessionFolderRepositories(
      [worktreePath], into: [gitRepo])
    // git repo must be preserved; folder repo is appended as a separate entry
    #expect(result.count == 2)
    #expect(result.contains { $0.id == gitRepo.id && $0.isGitRepository })
    #expect(result.contains { $0.id == RepositoryID(wtURL.path(percentEncoded: false)) && !$0.isGitRepository })
  }

  // MARK: - loadRepositoriesData forced folder paths skip git classification

  @Test(.dependencies) func registeredSessionFolderSurvivesRefreshAndPersistedLoad() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let path = folder.standardizedFileURL.path(percentEncoded: false)
    let persisted = LockIsolated(["/existing-root"])
    var initial = state()
    initial.$sessionFolderRoots = Shared(value: [])
    let store = TestStore(initialState: initial) {
      RepositoriesFeature()
    } withDependencies: {
      $0.repositoryPersistence.loadRoots = { persisted.value }
      $0.repositoryPersistence.saveRoots = { persisted.setValue($0) }
      $0.gitClient.rootDirectoryExists = { _ in true }
      $0.gitClient.isGitRepository = { _ in
        Issue.record("Forced folder must bypass git classification")
        return false
      }
    }
    store.exhaustivity = .off
    await store.send(.registerSessionFolder(folder))
    await store.receive(\.delegate.repositoriesChanged)
    #expect(persisted.value == ["/existing-root", path])
    #expect(store.state.repositoryRoots == [folder.standardizedFileURL])
    #expect(store.state.sessionFolderRoots == [path])
    await store.send(.refreshWorktrees)
    await store.receive(\.reloadRepositories)
    await store.receive(\.repositoriesLoaded)
    #expect(store.state.repositories.first?.worktrees.first?.workingDirectory == folder.standardizedFileURL)
    await store.finish()

    persisted.setValue([path])
    var fresh = state()
    fresh.$sessionFolderRoots = Shared(value: [path])
    let relaunched = TestStore(initialState: fresh) {
      RepositoriesFeature()
    } withDependencies: {
      $0.repositoryPersistence.loadRoots = { persisted.value }
      $0.gitClient.rootDirectoryExists = { _ in true }
      $0.gitClient.isGitRepository = { _ in
        Issue.record("Persisted forced folder must bypass git classification")
        return false
      }
    }
    relaunched.exhaustivity = .off
    await relaunched.send(.loadPersistedRepositories)
    await relaunched.receive(\.gitEnvironmentChanged)
    await relaunched.receive(\.repositoriesLoaded)
    #expect(relaunched.state.repositoryRoots == [folder.standardizedFileURL])
    #expect(relaunched.state.repositories.first?.worktrees.first?.workingDirectory == folder.standardizedFileURL)
    #expect(relaunched.state.repositories.first?.isGitRepository == false)
    await relaunched.finish()
  }

  @Test(.dependencies) func settledLiveNavigationAndAllVisibleSelection() async {
    var initial = state()
    let live = summary("live", created: 30)
    let dormant = summary("dormant", created: 20)
    let settled = summary("settled", created: 10)
    initial.sessionSummaries = [live, dormant, settled]
    initial.sessionSnapshots = [snapshot(UUID(), ref: "settled")]
    initial.$sessions.withLock { $0[settled.id] = SessionSidecarEntry(settledAt: .distantPast) }
    initial.reconcileSessionItems(now: .distantPast)
    initial.applyCacheRecomputes(.sessionsStructure)
    let structure = initial.sessionsSidebarStructure
    #expect(structure.liveIDs == [.session(settled.id)])
    #expect(structure.selection(byOffset: 1, from: .session(live.id)) == .session(dormant.id))
    #expect(structure.selection(byOffset: 1, from: .session(dormant.id)) == .session(settled.id))
    #expect(structure.selection(byOffset: 1, from: .session(settled.id)) == .session(live.id))
    #expect(structure.selection(byOffset: -1, from: nil) == .session(settled.id))
    let store = TestStore(initialState: initial) { RepositoriesFeature() }
    await store.send(.sessionSelectionChanged(.session(dormant.id))) {
      $0.sessionSelection = .session(dormant.id)
    }
    await store.send(.activateSession(.session(dormant.id)))
    await store.receive(\.delegate.resumeSession)
    await store.finish()
  }

  @Test(.dependencies) func sessionRowIDAtSlotReturnsNthLive() {
    var state = state()
    state.sessionSummaries = [
      summary("live1", created: 30), summary("live2", created: 20), summary("dormant", created: 10),
    ]
    state.sessionSnapshots = [
      snapshot(UUID(), ref: "live1"), snapshot(UUID(), ref: "live2"),
    ]
    state.reconcileSessionItems(now: .distantPast)
    state.applyCacheRecomputes(.sessionsStructure)
    #expect(state.sessionRowID(atSlot: 0) == .session(summary("live1").id))
    #expect(state.sessionRowID(atSlot: 1) == .session(summary("live2").id))
    #expect(state.sessionRowID(atSlot: 2) == nil)
  }

  @Test(.dependencies) func sessionRowIDByOffsetWrapsOverLiveIDs() {
    var state = state()
    let first = summary("live1", created: 30)
    let second = summary("live2", created: 20)
    let third = summary("live3", created: 10)
    state.sessionSummaries = [first, second, third]
    state.sessionSnapshots = [
      snapshot(UUID(), ref: "live1"), snapshot(UUID(), ref: "live2"),
      snapshot(UUID(), ref: "live3"),
    ]
    state.reconcileSessionItems(now: .distantPast)
    state.applyCacheRecomputes(.sessionsStructure)
    state.sessionSelection = .session(second.id)
    #expect(state.sessionRowID(byOffset: 1, focusedRowID: nil) == .session(third.id))
    #expect(state.sessionRowID(byOffset: -1, focusedRowID: nil) == .session(first.id))
    state.sessionSelection = .session(third.id)
    #expect(state.sessionRowID(byOffset: 1, focusedRowID: nil) == .session(first.id))
    state.sessionSelection = .session(first.id)
    #expect(state.sessionRowID(byOffset: -1, focusedRowID: nil) == .session(third.id))
  }

  @Test(.dependencies) func sessionRowIDByOffsetWithNoSelectionEntersFromTravelDirection() {
    var state = state()
    state.sessionSummaries = [summary("live1", created: 30), summary("live2", created: 20)]
    state.sessionSnapshots = [
      snapshot(UUID(), ref: "live1"), snapshot(UUID(), ref: "live2"),
    ]
    state.reconcileSessionItems(now: .distantPast)
    state.applyCacheRecomputes(.sessionsStructure)
    state.sessionSelection = nil
    #expect(state.sessionRowID(byOffset: 1, focusedRowID: nil) == .session(summary("live1").id))
    #expect(state.sessionRowID(byOffset: -1, focusedRowID: nil) == .session(summary("live2").id))
  }

  @Test(.dependencies) func sessionRowIDByOffsetWithFocusedRowIDUsesThat() {
    var state = state()
    let first = summary("live1", created: 30)
    let second = summary("live2", created: 20)
    state.sessionSummaries = [first, second]
    state.sessionSnapshots = [
      snapshot(UUID(), ref: "live1"), snapshot(UUID(), ref: "live2"),
    ]
    state.reconcileSessionItems(now: .distantPast)
    state.applyCacheRecomputes(.sessionsStructure)
    state.sessionSelection = .session(first.id)
    let focused = SessionRowID.session(second.id)
    #expect(state.sessionRowID(byOffset: 1, focusedRowID: focused) == .session(first.id))
    #expect(state.sessionRowID(byOffset: -1, focusedRowID: focused) == .session(first.id))
  }

  @Test(.dependencies) func sessionRowIDByOffsetReturnsNilWhenEmpty() {
    var state = state()
    #expect(state.sessionRowID(byOffset: 1, focusedRowID: nil) == nil)
    #expect(state.sessionRowID(byOffset: -1, focusedRowID: nil) == nil)
  }

  @Test(.dependencies) func selectNextWorktreeWithFocusOnlyLiveRows() async {
    var initial = state()
    let live1 = summary("live1", created: 30)
    let live2 = summary("live2", created: 20)
    let dormant = summary("dormant", created: 10)
    initial.sessionSummaries = [live1, live2, dormant]
    initial.sessionSnapshots = [
      snapshot(UUID(), ref: "live1"),
      snapshot(UUID(), ref: "live2"),
    ]
    initial.reconcileSessionItems(now: .distantPast)
    initial.applyCacheRecomputes(.sessionsStructure)
    initial.sessionSelection = .session(live1.id)
    @Shared(.sidebarTab) var tab
    $tab.withLock { $0 = SidebarTab.sessions.rawValue }
    let store = TestStore(initialState: initial) { RepositoriesFeature() }
    store.exhaustivity = .off
    await store.send(.selectNextWorktree) {
      $0.sessionSelection = .session(live2.id)
    }
    await store.receive(\.delegate.focusSession)
    await store.finish()
    #expect(initial.sessionsSidebarStructure.allIDs.count == 3)
    #expect(initial.sessionsSidebarStructure.liveIDs.count == 2)
  }

  @Test(.dependencies) func selectPreviousWorktreeWithDormantRowsPreservesBounds() async {
    var initial = state()
    let dormant = summary("dormant", created: 10)
    initial.sessionSummaries = [dormant]
    initial.reconcileSessionItems(now: .distantPast)
    initial.applyCacheRecomputes(.sessionsStructure)
    @Shared(.sidebarTab) var tab
    $tab.withLock { $0 = SidebarTab.sessions.rawValue }
    let store = TestStore(initialState: initial) { RepositoriesFeature() }
    store.exhaustivity = .off
    await store.send(.selectPreviousWorktree)
    await store.finish()
    #expect(initial.sessionSelection == nil)
    #expect(initial.sessionsSidebarStructure.allIDs.count == 1)
    #expect(initial.sessionsSidebarStructure.liveIDs.isEmpty)
  }

  @Test(.dependencies) func selectWorktreeAtHotkeySlotWithLiveAndDormant() async {
    var initial = state()
    let live = summary("live", created: 30)
    let dormant = summary("dormant", created: 10)
    initial.sessionSummaries = [live, dormant]
    initial.sessionSnapshots = [snapshot(UUID(), ref: "live")]
    initial.reconcileSessionItems(now: .distantPast)
    initial.applyCacheRecomputes(.sessionsStructure)
    @Shared(.sidebarTab) var tab
    $tab.withLock { $0 = SidebarTab.sessions.rawValue }
    let store = TestStore(initialState: initial) { RepositoriesFeature() }
    store.exhaustivity = .off
    await store.send(.selectWorktreeAtHotkeySlot(0)) {
      $0.sessionSelection = .session(live.id)
    }
    await store.receive(\.delegate.focusSession)
    await store.finish()
    #expect(initial.sessionsSidebarStructure.allIDs == [.session(live.id), .session(dormant.id)])
    #expect(initial.sessionsSidebarStructure.liveIDs == [.session(live.id)])
  }

  // MARK: - Manual settle / unsettle

  @Test(.dependencies) func settleSessionWritesSettledAtAndMovesRowToSettledSection() async {
    let store = store()
    let key = SessionKey(harness: .pi, sessionID: "s1")
    await store.send(.sessionsRefreshCompleted([summary("s1", created: 10)])) { state in
      #expect(state.sessionItems[id: .session(key)]?.lifecycle == .active)
    }
    await store.send(.settleSession(key)) { state in
      let entry = state.sessions[key]
      #expect(entry?.settledAt != nil)
      #expect(entry?.manualUnsettledAtActivity == nil)
      #expect(state.sessionItems[id: .session(key)]?.lifecycle == .settled)
      #expect(state.sessionsSidebarStructure.sections.first?.id == .settled)
    }
  }

  @Test(.dependencies) func unsettleSessionClearsSettledAtAndSetsWatermark() async {
    let store = store()
    let key = SessionKey(harness: .pi, sessionID: "s1")
    let lastActivity = Date(timeIntervalSince1970: 10)
    await store.send(.sessionsRefreshCompleted([summary("s1", created: 10)])) { _ in }
    await store.send(.settleSession(key)) { _ in }
    await store.send(.unsettleSession(key)) { state in
      let entry = state.sessions[key]
      #expect(entry?.settledAt == nil)
      #expect(entry?.manualUnsettledAtActivity == lastActivity)
      #expect(state.sessionItems[id: .session(key)]?.lifecycle == .active)
    }
  }

  @Test(.dependencies) func settlingDoesNotAffectOtherRows() async {
    let store = store()
    let key1 = SessionKey(harness: .pi, sessionID: "s1")
    let key2 = SessionKey(harness: .pi, sessionID: "s2")
    await store.send(.sessionsRefreshCompleted([summary("s1", created: 20), summary("s2", created: 10)]))
    await store.send(.settleSession(key1)) { state in
      #expect(state.sessionItems[id: .session(key1)]?.lifecycle == .settled)
      #expect(state.sessionItems[id: .session(key2)]?.lifecycle == .active)
    }
  }

  @Test(.dependencies) func settledLiveRowActivationUnsettles() async {
    let surface = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!
    let ref = "live-settled"
    let key = SessionKey(harness: .pi, sessionID: ref)
    let store = store()
    await store.send(.sessionsRefreshCompleted([summary(ref, created: 10)]))
    await store.send(.settleSession(key)) { state in
      #expect(state.sessionItems[id: .session(key)]?.lifecycle == .settled)
    }
    let snap = snapshot(surface, ref: ref)
    await store.send(.sessionSnapshotsChanged([snap])) { state in
      #expect(state.sessionItems[id: .session(key)]?.isLive == true)
    }
    await store.send(.activateSession(.session(key))) { state in
      #expect(state.sessionItems[id: .session(key)]?.lifecycle == .active)
    }
  }

  @Test(.dependencies) func refreshDoesNotAutoUnsettleManuallySettledRow() async {
    let store = store()
    let key = SessionKey(harness: .pi, sessionID: "s1")
    await store.send(.sessionsRefreshCompleted([summary("s1", created: 10)]))
    await store.send(.settleSession(key))
    await store.send(.sessionsRefreshCompleted([summary("s1", created: 10)])) { state in
      #expect(state.sessionItems[id: .session(key)]?.lifecycle == .settled)
    }
  }

  @Test(.dependencies) func sectionsOrderIsActiveThenSettledCreationDescending() async {
    let store = store()
    let key1 = SessionKey(harness: .pi, sessionID: "s1")
    let key2 = SessionKey(harness: .pi, sessionID: "s2")
    let key3 = SessionKey(harness: .pi, sessionID: "s3")
    await store.send(
      .sessionsRefreshCompleted([
        summary("s1", created: 30), summary("s2", created: 20), summary("s3", created: 10),
      ]))
    await store.send(.settleSession(key2)) { state in
      let sections = state.sessionsSidebarStructure.sections
      #expect(sections.map(\.id) == [.active, .settled])
      let activeIDs = sections.first?.rowIDs ?? []
      #expect(activeIDs == [.session(key1), .session(key3)])
      let settledIDs = sections.last?.rowIDs ?? []
      #expect(settledIDs == [.session(key2)])
    }
  }

  @Test func forcedFolderPathSkipsGitClassification() async {
    let folderPath = "/tmp/supacode-forced-folder-\(UUID())"
    let folderURL = URL(fileURLWithPath: folderPath).standardizedFileURL
    let gitCallCount = LockIsolated(0)

    var initial = state()
    initial.$sessionFolderRoots = Shared(value: [folderURL.path(percentEncoded: false)])

    let store = TestStore(initialState: initial) {
      RepositoriesFeature()
    } withDependencies: {
      $0.repositoryPersistence.loadRoots = { [folderURL.path(percentEncoded: false)] }
      $0.gitClient.rootDirectoryExists = { _ in true }
      $0.gitClient.isGitRepository = { _ in
        gitCallCount.withValue { $0 += 1 }
        return false
      }
      $0.gitClient.worktrees = { _ in
        Issue.record("worktrees() must not be called for forced folder root")
        return []
      }
    }
    store.exhaustivity = .off

    await store.send(.loadPersistedRepositories)
    await store.receive(\.gitEnvironmentChanged)
    await store.receive(\.repositoriesLoaded) { state in
      #expect(state.repositories.count == 1)
      #expect(state.repositories.first?.isGitRepository == false)
      #expect(state.repositories.first?.id == RepositoryID(folderURL.path(percentEncoded: false)))
    }
    #expect(gitCallCount.value == 0, "isGitRepository must not be called for forced folder path")
    await store.finish()
  }

  // MARK: - A3: sessionsRefreshInFlight tracks loading so the view can show a spinner

  @Test(.dependencies) func refreshInFlightTrueWhileLoadingFalseAfterCompletion() async {
    let clock = TestClock()
    var initial = state()
    initial.sessionsStarted = false
    let refreshCalled = LockIsolated(false)
    let store = TestStore(initialState: initial) {
      RepositoriesFeature()
    } withDependencies: {
      $0.date.now = .distantPast
      $0.continuousClock = clock
      $0.sessionIndex.cached = { [] }
      $0.sessionIndex.refresh = {
        refreshCalled.withValue { $0 = true }
        return []
      }
      $0.defaultAppStorage = .inMemory
    }
    store.exhaustivity = .off
    #expect(!store.state.sessionsRefreshInFlight, "should be false before start")

    await store.send(.sessionsStarted) { rep in
      #expect(rep.sessionsStarted)
      #expect(rep.sessionsRefreshInFlight, "should be true immediately after start")
    }
    await store.receive(\.sessionsCacheLoaded)
    await store.receive(\.sessionsRefreshCompleted) { rep in
      #expect(!rep.sessionsRefreshInFlight, "should clear after refresh completes")
    }
    #expect(refreshCalled.value)
    await store.send(.sessionsStopped)
    await store.finish()
  }

  @Test(.dependencies) func refreshInFlightRemainsAfterCacheLoadBeforeRefreshCompletes() async {
    let clock = TestClock()
    var initial = state()
    initial.sessionsStarted = false
    let refreshGate = AsyncStream<[SessionSummary]>.makeStream()
    let store = TestStore(initialState: initial) {
      RepositoriesFeature()
    } withDependencies: {
      $0.date.now = .distantPast
      $0.continuousClock = clock
      $0.sessionIndex.cached = { [] }
      $0.sessionIndex.refresh = {
        for await item in refreshGate.stream { return item }
        return []
      }
      $0.defaultAppStorage = .inMemory
    }
    store.exhaustivity = .off
    await store.send(.sessionsStarted)
    await store.receive(\.sessionsCacheLoaded) { rep in
      #expect(rep.sessionsRefreshInFlight, "still in flight while disk refresh runs")
    }
    refreshGate.continuation.yield([])
    refreshGate.continuation.finish()
    await store.receive(\.sessionsRefreshCompleted) { rep in
      #expect(!rep.sessionsRefreshInFlight)
    }
    await store.send(.sessionsStopped)
    await store.finish()
  }

  // MARK: - sessionsIndexingInProgress computed property

  @Test func sessionsIndexingInProgressTrueWhenNoRefreshCompletedYet() {
    var repo = RepositoriesFeature.State()
    repo.sessionsRefreshInFlight = false
    repo.sessionsHasCompletedRefresh = false
    #expect(repo.sessionsIndexingInProgress == true)
  }

  @Test func sessionsIndexingInProgressTrueWhileRefreshInFlight() {
    var repo = RepositoriesFeature.State()
    repo.sessionsRefreshInFlight = true
    repo.sessionsHasCompletedRefresh = true
    #expect(repo.sessionsIndexingInProgress == true)
  }

  @Test func sessionsIndexingInProgressFalseAfterRefreshCompletedAndNotInFlight() {
    var repo = RepositoriesFeature.State()
    repo.sessionsRefreshInFlight = false
    repo.sessionsHasCompletedRefresh = true
    #expect(repo.sessionsIndexingInProgress == false)
  }

  @Test func sessionsIndexingInProgressFalseAfterSuccessThenSubsequentFailure() {
    var repo = RepositoriesFeature.State()
    repo.sessionsHasCompletedRefresh = true
    repo.sessionsRefreshSucceeded = false
    repo.sessionsRefreshInFlight = false
    #expect(
      repo.sessionsIndexingInProgress == false,
      "once completed, indexing stays false even if a later refresh fails")
  }
}

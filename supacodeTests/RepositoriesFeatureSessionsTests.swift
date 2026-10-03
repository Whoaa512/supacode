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
        worktreeID: "/workspace", tabID: TabID(rawValue: surface), surfaceID: surface))
  }

  private func state() -> RepositoriesFeature.State {
    var state = RepositoriesFeature.State()
    state.$sessions = Shared(value: [:])
    state.$sidebar = Shared(value: SidebarState())
    state.$persistedLayouts = SharedReader(value: LayoutsFile(worktrees: [:]))
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
    await store.finish()
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
}

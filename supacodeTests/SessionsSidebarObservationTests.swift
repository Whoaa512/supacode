import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import IdentifiedCollections
import Observation
import Testing

@testable import SupacodeSettingsShared
@testable import supacode

@MainActor
struct SessionsSidebarObservationTests {
  private func snapshot(_ id: String, surface: UUID, status: SessionClassification.Status)
    -> SessionLiveSnapshot
  {
    SessionLiveSnapshot(
      harness: .pi, sessionRef: id, cwd: "/workspace",
      location: SessionLocation(
        worktreeID: "/workspace", tabID: TabID(rawValue: surface), surfaceID: surface),
      status: status)
  }

  @Test func statusOnlyMutationInvalidatesOwnLeafButNotStructureOrSibling() {
    var state = RepositoriesFeature.State()
    let first = SessionKey(harness: .pi, sessionID: "first")
    let second = SessionKey(harness: .pi, sessionID: "second")
    state.sessionItems = [
      SessionSidebarItemFeature.State(
        id: .session(first), title: "First", cwd: "/first",
        createdAt: Date(timeIntervalSince1970: 2), status: .idle),
      SessionSidebarItemFeature.State(
        id: .session(second), title: "Second", cwd: "/second",
        createdAt: Date(timeIntervalSince1970: 1), status: .idle),
    ]
    state.recomputeSessionsSidebarStructureIfChanged()

    var firstInvalidated = false
    var secondInvalidated = false
    var structureInvalidated = false

    withObservationTracking {
      _ = state.sessionItems[id: .session(first)]?.status
    } onChange: {
      firstInvalidated = true
    }
    withObservationTracking {
      _ = state.sessionItems[id: .session(second)]?.status
    } onChange: {
      secondInvalidated = true
    }
    withObservationTracking {
      _ = state.sessionsSidebarStructure
    } onChange: {
      structureInvalidated = true
    }

    state.sessionItems[id: .session(first)]?.status = .needsYou

    #expect(firstInvalidated)
    #expect(!secondInvalidated)
    #expect(!structureInvalidated)
  }

  @Test(.dependencies) func snapshotsStatusChangeInvalidatesOwnLeafButNotStructureOrSibling() async {
    let firstSurface = UUID(uuidString: "00000000-0000-0000-0000-0000000000C1")!
    let secondSurface = UUID(uuidString: "00000000-0000-0000-0000-0000000000C2")!
    let clock = TestClock()
    let store = TestStore(initialState: RepositoriesFeature.State()) {
      RepositoriesFeature()
    } withDependencies: {
      $0.continuousClock = clock
      $0.date.now = Date(timeIntervalSince1970: 1)
      $0.defaultAppStorage = .inMemory
    }
    store.exhaustivity = .off

    await store.send(
      .sessionSnapshotsChanged([
        snapshot("first", surface: firstSurface, status: .idle),
        snapshot("second", surface: secondSurface, status: .idle),
      ]))
    await store.receive(\.sessionsRefreshRequested)

    var firstInvalidated = false
    var secondInvalidated = false
    var structureInvalidated = false
    withObservationTracking {
      _ = store.state.sessionItems[id: .session(SessionKey(harness: .pi, sessionID: "first"))]?.status
    } onChange: {
      firstInvalidated = true
    }
    withObservationTracking {
      _ = store.state.sessionItems[id: .session(SessionKey(harness: .pi, sessionID: "second"))]?.status
    } onChange: {
      secondInvalidated = true
    }
    withObservationTracking {
      _ = store.state.sessionsSidebarStructure
    } onChange: {
      structureInvalidated = true
    }

    await store.send(
      .sessionSnapshotsChanged([
        snapshot("first", surface: firstSurface, status: .needsYou),
        snapshot("second", surface: secondSurface, status: .idle),
      ]))

    #expect(firstInvalidated)
    #expect(!secondInvalidated)
    #expect(!structureInvalidated)
  }

  @Test func structuralTransitionInvalidatesStructure() {
    var state = RepositoriesFeature.State()
    let key = SessionKey(harness: .pi, sessionID: "first")
    state.sessionItems = [
      SessionSidebarItemFeature.State(
        id: .session(key), title: "First", cwd: "/first",
        createdAt: Date(timeIntervalSince1970: 1), lifecycle: .active, status: .idle)
    ]
    state.recomputeSessionsSidebarStructureIfChanged()

    var structureInvalidated = false
    withObservationTracking {
      _ = state.sessionsSidebarStructure
    } onChange: {
      structureInvalidated = true
    }

    state.sessionItems[id: .session(key)]?.lifecycle = .settled
    state.recomputeSessionsSidebarStructureIfChanged()

    #expect(structureInvalidated)
  }
}

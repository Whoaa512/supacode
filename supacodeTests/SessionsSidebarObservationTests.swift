import Foundation
import IdentifiedCollections
import Observation
import Testing

@testable import SupacodeSettingsShared
@testable import supacode

@MainActor
struct SessionsSidebarObservationTests {
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

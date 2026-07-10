import ComposableArchitecture
import Foundation
import SupacodeSettingsShared
import Testing

@testable import supacode

@MainActor
struct DecisionInboxFeatureTests {
  private let surfaceA = UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!
  private let fixedNow = Date(timeIntervalSince1970: 1000)

  private func at(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: seconds) }

  private func inputRequested(
    surface: UUID, id: String, question: String, recommendation: String? = nil, at seconds: TimeInterval
  ) -> AgentHookEvent {
    var fields: [String: JSONValue] = [
      "id": .string(id),
      "question": .string(question),
      "options": .array([]),
      "context_refs": .array([]),
    ]
    if let recommendation { fields["recommendation"] = .string(recommendation) }
    return AgentHookEvent(
      agent: "claude", event: "input_requested", surfaceID: surface,
      timestamp: at(seconds), data: .object(fields))
  }

  /// Captures persisted resolutions so tests can assert what hit the log.
  private func makeStore(
    persisted: LockIsolated<[InboxResolution]> = LockIsolated([]),
    copied: LockIsolated<[String]> = LockIsolated([])
  ) -> TestStoreOf<DecisionInboxFeature> {
    TestStore(initialState: DecisionInboxFeature.State()) {
      DecisionInboxFeature()
    } withDependencies: {
      $0.date = .constant(fixedNow)
      $0.decisionInboxClient = DecisionInboxClient(
        persistResolution: { resolution in persisted.withValue { $0.append(resolution) } },
        copyToPasteboard: { text in copied.withValue { $0.append(text) } })
    }
  }

  @Test func hookEventProducesCandidate() async {
    let store = makeStore()
    let event = inputRequested(surface: surfaceA, id: "q1", question: "Rebase or merge?", at: 10)
    await store.send(.hookEventReceived(event)) {
      $0.detector = $0.detector.reducing(event)
      $0.candidates = [$0.detector.candidates[0]]
    }
    #expect(store.state.unresolvedCount == 1)
  }

  @Test func dismissRemovesAndPersists() async {
    let persisted = LockIsolated<[InboxResolution]>([])
    let store = makeStore(persisted: persisted)
    let event = inputRequested(surface: surfaceA, id: "q1", question: "Ship it?", at: 10)
    await store.send(.hookEventReceived(event)) {
      $0.detector = $0.detector.reducing(event)
      $0.candidates = [$0.detector.candidates[0]]
    }
    let id = store.state.candidates[0].id

    let dismissed = store.state.candidates[0]
    await store.send(.dismissTapped(id: id)) {
      $0.resolved = [id: dismissed]
      $0.candidates = []
    }
    await store.finish()

    #expect(persisted.value.count == 1)
    let resolution = persisted.value[0]
    #expect(resolution.candidateID == id)
    #expect(resolution.chosenAction == .dismissed)
    #expect(resolution.recommendationAccepted == false)
    #expect(resolution.resolvedAt == fixedNow)
  }

  @Test func focusRoutesToSurfaceAndPersists() async {
    let persisted = LockIsolated<[InboxResolution]>([])
    let store = makeStore(persisted: persisted)
    let event = inputRequested(surface: surfaceA, id: "q1", question: "Deploy?", at: 10)
    await store.send(.hookEventReceived(event)) {
      $0.detector = $0.detector.reducing(event)
      $0.candidates = [$0.detector.candidates[0]]
    }
    let id = store.state.candidates[0].id

    let focused = store.state.candidates[0]
    await store.send(.focusTapped(id: id)) {
      $0.resolved = [id: focused]
      $0.candidates = []
    }
    await store.receive(\.delegate.focusSurface)
    await store.finish()

    #expect(persisted.value.map(\.chosenAction) == [.focused])
    #expect(persisted.value[0].recommendationAccepted == nil)
  }

  @Test func copyPutsSuggestedResponseOnPasteboard() async {
    let persisted = LockIsolated<[InboxResolution]>([])
    let copied = LockIsolated<[String]>([])
    let store = makeStore(persisted: persisted, copied: copied)
    let event = inputRequested(
      surface: surfaceA, id: "q1", question: "Rebase or merge?", recommendation: "rebase", at: 10)
    await store.send(.hookEventReceived(event)) {
      $0.detector = $0.detector.reducing(event)
      $0.candidates = [$0.detector.candidates[0]]
    }
    let id = store.state.candidates[0].id

    let copiedCandidate = store.state.candidates[0]
    await store.send(.copyTapped(id: id)) {
      $0.resolved = [id: copiedCandidate]
      $0.candidates = []
    }
    await store.finish()

    #expect(copied.value == ["rebase"])
    #expect(persisted.value.map(\.chosenAction) == [.copied])
    #expect(persisted.value[0].recommendationAccepted == true)
  }

  @Test func dismissedInputRequestResurfacesOnChangedReAsk() async {
    let store = makeStore()
    let first = inputRequested(
      surface: surfaceA, id: "q1", question: "Rebase or merge?", recommendation: "rebase", at: 10)
    await store.send(.hookEventReceived(first)) {
      $0.detector = $0.detector.reducing(first)
      $0.candidates = [$0.detector.candidates[0]]
    }
    let id = store.state.candidates[0].id
    let dismissed = store.state.candidates[0]

    await store.send(.dismissTapped(id: id)) {
      $0.resolved = [id: dismissed]
      $0.candidates = []
    }

    // Same protocol id, updated in place with a changed recommendation: the
    // snapshot no longer matches, so the candidate must resurface.
    let reAsk = inputRequested(
      surface: surfaceA, id: "q1", question: "Rebase or merge?", recommendation: "merge", at: 20)
    await store.send(.hookEventReceived(reAsk)) {
      $0.detector = $0.detector.reducing(reAsk)
      $0.resolved = [:]
      $0.candidates = [$0.detector.candidates[0]]
    }
    #expect(store.state.unresolvedCount == 1)
    #expect(store.state.candidates[0].recommendation == "merge")
  }

  @Test func resolvedMarkerPrunedWhenDetectorClearsCandidate() async {
    let store = makeStore()
    let request = inputRequested(surface: surfaceA, id: "q1", question: "Ship it?", at: 10)
    await store.send(.hookEventReceived(request)) {
      $0.detector = $0.detector.reducing(request)
      $0.candidates = [$0.detector.candidates[0]]
    }
    let id = store.state.candidates[0].id
    let dismissed = store.state.candidates[0]

    await store.send(.dismissTapped(id: id)) {
      $0.resolved = [id: dismissed]
      $0.candidates = []
    }

    // A real clearing event (input_resolved) drops the underlying candidate, so
    // the resolved marker is pruned by the intersection in reproject.
    let resolved = AgentHookEvent(
      agent: "claude", event: "input_resolved", surfaceID: surfaceA,
      timestamp: at(20), data: .object(["id": .string("q1"), "choice": .string("yes")]))
    await store.send(.hookEventReceived(resolved)) {
      $0.detector = $0.detector.reducing(resolved)
      $0.resolved = [:]
    }
    #expect(store.state.unresolvedCount == 0)
    #expect(store.state.resolved.isEmpty)
  }
}

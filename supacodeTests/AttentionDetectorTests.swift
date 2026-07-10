import Foundation
import SupacodeSettingsShared
import Testing

@testable import supacode

struct AttentionDetectorTests {
  private let surfaceA = UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!
  private let surfaceB = UUID(uuidString: "00000000-0000-0000-0000-0000000000BB")!

  private func at(_ seconds: TimeInterval) -> Date {
    Date(timeIntervalSince1970: seconds)
  }

  private func event(
    _ name: String,
    surface: UUID,
    at seconds: TimeInterval,
    data: JSONValue? = nil,
    agent: String = "claude"
  ) -> AgentHookEvent {
    AgentHookEvent(
      agent: agent, event: name, surfaceID: surface, timestamp: at(seconds), data: data)
  }

  private func inputRequestedData(
    id: String,
    question: String,
    options: [String] = [],
    recommendation: String? = nil,
    contextRefs: [String] = []
  ) -> JSONValue {
    var fields: [String: JSONValue] = [
      "id": .string(id),
      "question": .string(question),
      "options": .array(options.map(JSONValue.string)),
      "context_refs": .array(contextRefs.map(JSONValue.string)),
    ]
    if let recommendation { fields["recommendation"] = .string(recommendation) }
    return .object(fields)
  }

  // MARK: - input_requested → input_resolved lifecycle.

  @Test func inputRequestedProducesFullDetailCandidate() throws {
    let detector = AttentionDetector().reducing(
      event(
        "input_requested", surface: surfaceA, at: 10,
        data: inputRequestedData(
          id: "q1", question: "Rebase or merge?", options: ["rebase", "merge"],
          recommendation: "rebase", contextRefs: ["diff:123"])))

    let candidate = try #require(detector.candidates.first)
    #expect(detector.candidates.count == 1)
    #expect(candidate.id == "q1")
    #expect(candidate.sessionID == surfaceA)
    #expect(candidate.kind == .inputRequested)
    #expect(candidate.question == "Rebase or merge?")
    #expect(candidate.options == ["rebase", "merge"])
    #expect(candidate.recommendation == "rebase")
    #expect(candidate.contextRefs == ["diff:123"])
    #expect(candidate.occurredAt == at(10))
  }

  @Test func inputResolvedRemovesMatchingCandidate() {
    let detector = AttentionDetector()
      .reducing(
        event(
          "input_requested", surface: surfaceA, at: 10,
          data: inputRequestedData(id: "q1", question: "Go?")))
      .reducing(
        event(
          "input_resolved", surface: surfaceA, at: 11,
          data: .object(["id": "q1", "choice": "yes"])))

    #expect(detector.candidates.isEmpty)
  }

  @Test func inputResolvedForOtherIDLeavesCandidate() {
    let detector = AttentionDetector()
      .reducing(
        event(
          "input_requested", surface: surfaceA, at: 10,
          data: inputRequestedData(id: "q1", question: "Go?")))
      .reducing(
        event(
          "input_resolved", surface: surfaceA, at: 11,
          data: .object(["id": "other", "choice": "yes"])))

    #expect(detector.candidates.map(\.id) == ["q1"])
  }

  @Test func reRequestUpdatesInPlace() {
    let detector = AttentionDetector()
      .reducing(
        event(
          "input_requested", surface: surfaceA, at: 10,
          data: inputRequestedData(id: "q1", question: "First?")))
      .reducing(
        event(
          "input_requested", surface: surfaceA, at: 20,
          data: inputRequestedData(id: "q1", question: "Updated?")))

    #expect(detector.candidates.count == 1)
    #expect(detector.candidates.first?.question == "Updated?")
    #expect(detector.candidates.first?.occurredAt == at(20))
  }

  @Test func inputRequestedWithoutDecodablePayloadIsIgnored() {
    let detector = AttentionDetector()
      .reducing(event("input_requested", surface: surfaceA, at: 10, data: nil))
      .reducing(event("input_requested", surface: surfaceA, at: 11, data: .string("garbage")))

    #expect(detector.candidates.isEmpty)
  }

  // MARK: - awaiting_input cleared by activity.

  @Test func awaitingInputProducesLowDetailCandidate() throws {
    let detector = AttentionDetector().reducing(
      event("awaiting_input", surface: surfaceA, at: 5))

    let candidate = try #require(detector.candidates.first)
    #expect(candidate.kind == .awaitingInput)
    #expect(candidate.sessionID == surfaceA)
    #expect(candidate.question == nil)
    #expect(candidate.options.isEmpty)
  }

  @Test func busyClearsAwaitingInput() {
    let detector = AttentionDetector()
      .reducing(event("awaiting_input", surface: surfaceA, at: 5))
      .reducing(event("busy", surface: surfaceA, at: 6))

    #expect(detector.candidates.isEmpty)
  }

  @Test func idleClearsAwaitingInput() {
    let detector = AttentionDetector()
      .reducing(event("awaiting_input", surface: surfaceA, at: 5))
      .reducing(event("idle", surface: surfaceA, at: 6))

    #expect(detector.candidates.isEmpty)
  }

  @Test func sessionEndClearsAwaitingInput() {
    let detector = AttentionDetector()
      .reducing(event("awaiting_input", surface: surfaceA, at: 5))
      .reducing(event("session_end", surface: surfaceA, at: 6))

    #expect(detector.candidates.isEmpty)
  }

  @Test func activityDoesNotClearProtocolRequest() {
    let detector = AttentionDetector()
      .reducing(
        event(
          "input_requested", surface: surfaceA, at: 5,
          data: inputRequestedData(id: "q1", question: "Go?")))
      .reducing(event("busy", surface: surfaceA, at: 6))
      .reducing(event("idle", surface: surfaceA, at: 7))

    #expect(detector.candidates.map(\.id) == ["q1"])
  }

  // MARK: - notification.

  @Test func notificationCarriesMessageThrough() throws {
    let detector = AttentionDetector().reducing(
      event(
        "notification", surface: surfaceA, at: 8,
        data: .object(["message": .string("Build finished")])))

    let candidate = try #require(detector.candidates.first)
    #expect(candidate.kind == .notification)
    #expect(candidate.question == "Build finished")
  }

  @Test func notificationFallsBackToBodyThenTitle() {
    let bodyOnly = AttentionDetector().reducing(
      event(
        "notification", surface: surfaceA, at: 8,
        data: .object(["body": .string("body text")])))
    #expect(bodyOnly.candidates.first?.question == "body text")

    let titleOnly = AttentionDetector().reducing(
      event(
        "notification", surface: surfaceB, at: 8,
        data: .object(["title": .string("title text")])))
    #expect(titleOnly.candidates.first?.question == "title text")
  }

  @Test func emptyNotificationProducesNoCandidate() {
    let detector = AttentionDetector()
      .reducing(event("notification", surface: surfaceA, at: 8, data: nil))
      .reducing(event("notification", surface: surfaceA, at: 9, data: .object([:])))

    #expect(detector.candidates.isEmpty)
  }

  @Test func sessionEndClearsNotification() {
    let detector = AttentionDetector()
      .reducing(
        event(
          "notification", surface: surfaceA, at: 8,
          data: .object(["message": .string("hi")])))
      .reducing(event("session_end", surface: surfaceA, at: 9))

    #expect(detector.candidates.isEmpty)
  }

  // MARK: - process_exited.

  @Test func processExitedNonZeroIsFailure() {
    let detector = AttentionDetector().reducing(
      event("process_exited", surface: surfaceA, at: 12, data: .object(["exit_code": .int(1)])))

    #expect(detector.candidates.first?.kind == .processExited(failure: true))
  }

  @Test func processExitedZeroIsCleanExit() {
    let detector = AttentionDetector().reducing(
      event("process_exited", surface: surfaceA, at: 12, data: .object(["exit_code": .int(0)])))

    #expect(detector.candidates.first?.kind == .processExited(failure: false))
  }

  @Test func processExitedWithoutCodeIsCleanExit() {
    let detector = AttentionDetector().reducing(
      event("process_exited", surface: surfaceA, at: 12, data: nil))

    #expect(detector.candidates.first?.kind == .processExited(failure: false))
  }

  // MARK: - unknown events ignored.

  @Test func unknownEventLeavesStateUnchanged() {
    let base = AttentionDetector().reducing(
      event(
        "input_requested", surface: surfaceA, at: 5,
        data: inputRequestedData(id: "q1", question: "Go?")))
    let after = base
      .reducing(event("run_started", surface: surfaceA, at: 6))
      .reducing(event("stage_completed", surface: surfaceA, at: 7))
      .reducing(event("totally_made_up", surface: surfaceA, at: 8))

    #expect(after.candidates == base.candidates)
  }

  @Test func sessionStartProducesNoCandidate() {
    let detector = AttentionDetector().reducing(
      event("session_start", surface: surfaceA, at: 1))

    #expect(detector.candidates.isEmpty)
  }

  // MARK: - cross-surface isolation.

  @Test func candidatesAreIsolatedPerSurface() {
    let detector = AttentionDetector()
      .reducing(event("awaiting_input", surface: surfaceA, at: 5))
      .reducing(event("awaiting_input", surface: surfaceB, at: 6))
      .reducing(event("busy", surface: surfaceA, at: 7))

    #expect(detector.candidates.count == 1)
    #expect(detector.candidates.first?.sessionID == surfaceB)
  }

  @Test func sessionEndOnlyClearsItsOwnSurface() {
    let detector = AttentionDetector()
      .reducing(
        event(
          "input_requested", surface: surfaceA, at: 5,
          data: inputRequestedData(id: "a1", question: "A?")))
      .reducing(
        event(
          "input_requested", surface: surfaceB, at: 6,
          data: inputRequestedData(id: "b1", question: "B?")))
      .reducing(event("session_end", surface: surfaceA, at: 7))

    #expect(detector.candidates.map(\.id) == ["b1"])
  }

  // MARK: - ordering + projecting.

  @Test func candidatesSortedByOccurredAtThenID() {
    let detector = AttentionDetector.projecting([
      event(
        "input_requested", surface: surfaceA, at: 30,
        data: inputRequestedData(id: "late", question: "late?")),
      event(
        "input_requested", surface: surfaceB, at: 10,
        data: inputRequestedData(id: "early", question: "early?")),
    ])

    #expect(detector.candidates.map(\.id) == ["early", "late"])
  }

  @Test func projectingMatchesSequentialReduce() {
    let events = [
      event("awaiting_input", surface: surfaceA, at: 1),
      event("busy", surface: surfaceA, at: 2),
      event(
        "input_requested", surface: surfaceB, at: 3,
        data: inputRequestedData(id: "q1", question: "Go?")),
    ]
    let projected = AttentionDetector.projecting(events)
    let sequential = events.reduce(AttentionDetector()) { $0.reducing($1) }

    #expect(projected.candidates == sequential.candidates)
  }
}

import Foundation
import SupacodeSettingsShared
import Testing

@testable import supacode

struct AgentEventLogTests {
  /// Fresh temp directory per test; cleaned up when the test returns.
  private func makeTempDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("agent-event-log-tests/\(UUID().uuidString)", isDirectory: true)
    return url
  }

  // MARK: - Append / replay round-trip.

  @Test func appendThenReplayRoundTripsInWriteOrder() async {
    let directory = makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)
    let log = AgentEventLog(directory: directory, now: { fixedNow })

    let session = UUID().uuidString
    await log.record(sessionKey: session, agent: "claude", event: "run_started")
    await log.record(
      sessionKey: session, agent: "claude", event: "input_requested",
      data: .object(["id": "q1"]))
    await log.record(sessionKey: session, agent: "claude", event: "process_exited")

    let replayed = await log.replay(sessionKey: session)
    #expect(replayed.count == 3)
    #expect(replayed.map(\.event) == ["run_started", "input_requested", "process_exited"])
    #expect(replayed.allSatisfy { $0.timestamp == fixedNow })
    #expect(replayed[1].data == .object(["id": "q1"]))
  }

  @Test func replayOfUnknownSessionIsEmpty() async {
    let directory = makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let log = AgentEventLog(directory: directory)
    #expect(await log.replay(sessionKey: "never-written").isEmpty)
  }

  @Test func separateSessionsDoNotBleed() async {
    let directory = makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let log = AgentEventLog(directory: directory)
    await log.record(sessionKey: "a", agent: "pi", event: "run_started")
    await log.record(sessionKey: "b", agent: "pi", event: "run_started")
    await log.record(sessionKey: "a", agent: "pi", event: "process_exited")

    #expect(await log.replay(sessionKey: "a").count == 2)
    #expect(await log.replay(sessionKey: "b").count == 1)
  }

  // MARK: - Unknown-event passthrough.

  @Test func unknownEventNameIsPersistedVerbatim() async {
    let directory = makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let log = AgentEventLog(directory: directory)
    let session = UUID().uuidString
    await log.record(
      sessionKey: session, agent: "future", event: "warp_drive_engaged",
      data: .object(["speed": .int(9)]))

    let replayed = await log.replay(sessionKey: session)
    #expect(replayed.count == 1)
    #expect(replayed[0].event == "warp_drive_engaged")
    #expect(replayed[0].data == .object(["speed": .int(9)]))
  }

  @Test func corruptLineIsSkippedNotFatal() async throws {
    let directory = makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let log = AgentEventLog(directory: directory)
    let session = "corrupt"
    await log.record(sessionKey: session, agent: "pi", event: "run_started")

    // Corrupt the file by injecting a non-JSON line between valid records.
    let fileURL = directory.appendingPathComponent("\(session).jsonl")
    let existing = try String(contentsOf: fileURL, encoding: .utf8)
    try (existing + "this is not json\n").write(to: fileURL, atomically: true, encoding: .utf8)
    await log.record(sessionKey: session, agent: "pi", event: "process_exited")

    let replayed = await log.replay(sessionKey: session)
    #expect(replayed.map(\.event) == ["run_started", "process_exited"])
  }
}

// MARK: - Protocol decode.

struct AgentInputProtocolTests {
  @Test func decodesInputRequestedWithSnakeCaseContextRefs() throws {
    let json = """
      {
        "id": "abc-123",
        "question": "Merge or rebase?",
        "options": ["merge", "rebase"],
        "recommendation": "rebase",
        "context_refs": ["diff:1", "log:2"]
      }
      """
    let decoded = try JSONDecoder().decode(InputRequested.self, from: Data(json.utf8))
    #expect(decoded.id == "abc-123")
    #expect(decoded.question == "Merge or rebase?")
    #expect(decoded.options == ["merge", "rebase"])
    #expect(decoded.recommendation == "rebase")
    #expect(decoded.contextRefs == ["diff:1", "log:2"])
  }

  @Test func inputRequestedToleratesMissingOptionalFields() throws {
    let json = #"{"id":"x","question":"proceed?","options":["y","n"]}"#
    let decoded = try JSONDecoder().decode(InputRequested.self, from: Data(json.utf8))
    #expect(decoded.recommendation == nil)
    #expect(decoded.contextRefs.isEmpty)
  }

  @Test func decodesInputResolved() throws {
    let json = #"{"id":"abc-123","choice":"rebase"}"#
    let decoded = try JSONDecoder().decode(InputResolved.self, from: Data(json.utf8))
    #expect(decoded == InputResolved(id: "abc-123", choice: "rebase"))
  }

  @Test func inputRequestedRoundTripsThroughEncoding() throws {
    let original = InputRequested(
      id: "r1", question: "q", options: ["a"], recommendation: "a", contextRefs: ["ref"])
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(InputRequested.self, from: data)
    #expect(decoded == original)
  }

  // MARK: - Hook-event ingestion of the typed payloads.

  @Test func hookEventDecodesInputRequestedPayload() throws {
    let json = """
      {
        "event": "input_requested",
        "v": 1,
        "agent": "claude",
        "surface_id": "\(UUID().uuidString)",
        "data": {
          "id": "q9",
          "question": "deploy?",
          "options": ["yes", "no"],
          "context_refs": ["build:42"]
        }
      }
      """
    let event = try JSONDecoder().decode(AgentHookEvent.self, from: Data(json.utf8))
    #expect(event.eventName == .inputRequested)
    let payload = try #require(event.decodeData(InputRequested.self))
    #expect(payload.id == "q9")
    #expect(payload.options == ["yes", "no"])
    #expect(payload.contextRefs == ["build:42"])
  }

  @Test func hookEventDecodesInputResolvedPayload() throws {
    let json = """
      {
        "event": "input_resolved",
        "v": 1,
        "agent": "claude",
        "surface_id": "\(UUID().uuidString)",
        "data": { "id": "q9", "choice": "yes" }
      }
      """
    let event = try JSONDecoder().decode(AgentHookEvent.self, from: Data(json.utf8))
    #expect(event.eventName == .inputResolved)
    #expect(event.decodeData(InputResolved.self) == InputResolved(id: "q9", choice: "yes"))
  }
}

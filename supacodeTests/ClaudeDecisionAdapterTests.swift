import Foundation
import Testing

@testable import SupacodeSettingsShared
@testable import supacode

@MainActor
struct ClaudeDecisionAdapterTests {
  private func markerEvent(event: String, data: JSONValue) -> AgentHookEvent {
    AgentHookEvent(agent: "claude", event: event, surfaceID: UUID(), data: data)
  }

  private func askUserQuestionHook(sessionID: String = "sess-1") -> JSONValue {
    [
      "session_id": .string(sessionID),
      "hook_event_name": "PreToolUse",
      "tool_name": "AskUserQuestion",
      "tool_input": [
        "questions": [
          [
            "question": "Which database should we use?",
            "header": "Database",
            "options": [
              ["label": "Postgres", "description": "Relational"],
              ["label": "SQLite", "description": "Embedded"],
            ],
          ]
        ]
      ],
    ]
  }

  @Test func nonMarkerEventPassesThrough() {
    let event = AgentHookEvent(agent: "claude", event: "idle", surfaceID: UUID())
    #expect(ClaudeDecisionAdapter.adapt(event) == nil)
  }

  @Test func askUserQuestionBecomesInputRequestedWithNestedQuestionAndOptions() throws {
    let event = markerEvent(
      event: ClaudeDecisionAdapter.requestedMarker, data: askUserQuestionHook())
    let adapted = try #require(ClaudeDecisionAdapter.adapt(event))

    #expect(adapted.event == "input_requested")
    let requested = try #require(adapted.decodeData(InputRequested.self))
    #expect(requested.question == "Which database should we use?")
    #expect(requested.options == ["Postgres", "SQLite"])
    #expect(!requested.id.isEmpty)
  }

  @Test func resolvedReusesTheSameStableIDAsTheRequest() throws {
    let requested = try #require(
      ClaudeDecisionAdapter.adapt(
        markerEvent(event: ClaudeDecisionAdapter.requestedMarker, data: askUserQuestionHook())))
    var resolvedHook = askUserQuestionHook().objectValue ?? [:]
    resolvedHook["hook_event_name"] = "PostToolUse"
    resolvedHook["tool_response"] = ["answers": [["answer": "Postgres"]]]
    let resolved = try #require(
      ClaudeDecisionAdapter.adapt(
        markerEvent(event: ClaudeDecisionAdapter.resolvedMarker, data: .object(resolvedHook))))

    #expect(resolved.event == "input_resolved")
    let requestedID = try #require(requested.decodeData(InputRequested.self)).id
    let resolvedPayload = try #require(resolved.decodeData(InputResolved.self))
    #expect(resolvedPayload.id == requestedID)
  }

  @Test func stableIDIsDeterministicAcrossCalls() throws {
    let first = try #require(
      ClaudeDecisionAdapter.adapt(
        markerEvent(event: ClaudeDecisionAdapter.requestedMarker, data: askUserQuestionHook())))
    let second = try #require(
      ClaudeDecisionAdapter.adapt(
        markerEvent(event: ClaudeDecisionAdapter.requestedMarker, data: askUserQuestionHook())))
    #expect(
      try #require(first.decodeData(InputRequested.self)).id
        == #require(second.decodeData(InputRequested.self)).id)
  }

  @Test func differentQuestionsGetDifferentIDs() throws {
    var otherHook = askUserQuestionHook().objectValue ?? [:]
    otherHook["tool_input"] = ["questions": [["question": "Different?", "options": [["label": "A"]]]]]
    let first = try #require(
      ClaudeDecisionAdapter.adapt(
        markerEvent(event: ClaudeDecisionAdapter.requestedMarker, data: askUserQuestionHook())))
    let second = try #require(
      ClaudeDecisionAdapter.adapt(
        markerEvent(event: ClaudeDecisionAdapter.requestedMarker, data: .object(otherHook))))
    #expect(
      try #require(first.decodeData(InputRequested.self)).id
        != #require(second.decodeData(InputRequested.self)).id)
  }

  @Test func exitPlanModeBecomesInputRequested() throws {
    let hook: JSONValue = [
      "session_id": "sess-2",
      "tool_name": "ExitPlanMode",
      "tool_input": ["plan": "1. Do the thing\n2. Ship it"],
    ]
    let adapted = try #require(
      ClaudeDecisionAdapter.adapt(
        markerEvent(event: ClaudeDecisionAdapter.requestedMarker, data: hook)))
    #expect(adapted.event == "input_requested")
    let requested = try #require(adapted.decodeData(InputRequested.self))
    #expect(!requested.question.isEmpty)
  }

  @Test func markerWithoutToolNamePassesThrough() {
    let hook: JSONValue = ["session_id": "sess-3"]
    let event = markerEvent(event: ClaudeDecisionAdapter.requestedMarker, data: hook)
    #expect(ClaudeDecisionAdapter.adapt(event) == nil)
  }

  @Test func adaptedEventPreservesSurfaceAndAgentAttribution() throws {
    let surfaceID = UUID()
    let event = AgentHookEvent(
      agent: "claude", event: ClaudeDecisionAdapter.requestedMarker, surfaceID: surfaceID,
      data: askUserQuestionHook())
    let adapted = try #require(ClaudeDecisionAdapter.adapt(event))
    #expect(adapted.surfaceID == surfaceID)
    #expect(adapted.agent == "claude")
  }
}

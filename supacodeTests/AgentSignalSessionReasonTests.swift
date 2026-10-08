import ComposableArchitecture
import Foundation
import Testing

@testable import SupacodeSettingsShared
@testable import supacode

struct AgentSignalSessionReasonTests {
  @Test(arguments: ["quit", "reload", "new", "resume", "fork"])
  func reasonSurvivesOSCAndJSON(reason: String) throws {
    let surface = UUID()
    let event = try AgentSignal.presenceEvent(
      id: "pi", metadata: "event=session_end;sid=session-1;reason=\(reason)",
      surfaceID: surface, surfaceExists: true
    ).get()
    #expect(event.sessionRef == "session-1")
    #expect(event.shutdownReason == reason)
    let json = """
      {"agent":"pi","event":"session_end","surface_id":"\(surface)",
       "session_ref":"session-1","reason":"\(reason)"}
      """
    let decoded = try JSONDecoder().decode(AgentHookEvent.self, from: Data(json.utf8))
    #expect(decoded == event)
  }

  @Test(arguments: ["", "QUIT", "quit;sid=other", "unknown", " quit", "quit\n"])
  func invalidReasonsAreNotUserEnds(reason: String) throws {
    #expect(AgentPresenceOSC.sanitizedShutdownReason(reason) == nil)
    #expect(
      AgentHookEvent(
        agent: "pi", event: "session_end", surfaceID: UUID(), shutdownReason: reason
      ).shutdownReason == nil)
    let bytes = try JSONSerialization.data(withJSONObject: [
      "agent": "pi", "event": "session_end", "surface_id": UUID().uuidString, "reason": reason,
    ])
    #expect(try JSONDecoder().decode(AgentHookEvent.self, from: bytes).shutdownReason == nil)
  }

  @Test func ambiguousEndIdentityIsRejected() {
    let surface = UUID()
    let record = AgentPresenceFeature.PresenceRecord(pids: [11, 22], sessionRef: "current")
    #expect(
      !record.matchesSessionEnd(
        AgentHookEvent(
          agent: "pi", event: "session_end", surfaceID: surface, pid: 11, sessionRef: "current")))
    #expect(
      !record.matchesSessionEnd(
        AgentHookEvent(
          agent: "pi", event: "session_end", surfaceID: surface, sessionRef: "current")))
    #expect(
      !record.matchesSessionEnd(
        AgentHookEvent(
          agent: "pi", event: "session_end", surfaceID: surface, pid: 33, sessionRef: "current")))
  }

  @Test @MainActor func barePiEndUsesPIDMatchingAndRemovesPresence() async {
    let surface = UUID()
    let key = AgentPresenceFeature.PresenceKey(agent: .pi, surfaceID: surface)
    let record = AgentPresenceFeature.PresenceRecord(pids: [22], sessionRef: "current", currentSessionPID: 22)
    let end = AgentHookEvent(agent: "pi", event: "session_end", surfaceID: surface, pid: 22)
    #expect(record.matchesSessionEnd(end))
    #expect(
      !record.matchesSessionEnd(
        AgentHookEvent(
          agent: "pi", event: "session_end", surfaceID: surface, pid: 11)))
    #expect(
      !record.matchesSessionEnd(
        AgentHookEvent(
          agent: "pi", event: "session_end", surfaceID: surface, pid: 22, sessionRef: "other")))
    var initial = AgentPresenceFeature.State()
    initial.records[key] = record
    let store = TestStore(initialState: initial) { AgentPresenceFeature() }
    await store.send(.hookEventReceived(end)) {
      $0.records.removeValue(forKey: key)
    }
    await store.receive(\.delegate)
    await store.finish()
    #expect(store.state.records[key] == nil)
  }

  @Test func missingOrUnknownOSCReasonStaysNil() throws {
    for suffix in ["", ";reason=unknown"] {
      let event = try AgentSignal.presenceEvent(
        id: "pi", metadata: "event=session_end;sid=real\(suffix)",
        surfaceID: UUID(), surfaceExists: true
      ).get()
      #expect(event.shutdownReason == nil)
    }
  }
}

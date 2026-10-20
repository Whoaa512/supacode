import Foundation
import SupacodeSettingsShared
import Testing

@testable import supacode

struct SessionSidebarRowHarnessTests {
  @Test func sessionKeyReadsHarnessBackFromRawValue() {
    #expect(SessionKey(harness: .pi, sessionID: "abc").harness == .pi)
    #expect(SessionKey(rawValue: "nope:abc").harness == nil)
    #expect(SessionKey(rawValue: "garbage").harness == nil)
  }

  @Test func implicitRowTakesHarnessFromItsKey() {
    let state = SessionSidebarItemFeature.State(
      id: .implicit(SessionKey(harness: .claude, sessionID: "s1")), title: "t", cwd: "/", createdAt: .distantPast)
    #expect(state.harness == .claude)
  }

  @Test func provisionalRowTakesHarnessFromItsID() {
    let state = SessionSidebarItemFeature.State(
      id: .provisional(.codex, UUID()), title: "t", cwd: "/", createdAt: .distantPast)
    #expect(state.harness == .codex)
  }

  @Test func taskRowTakesHarnessFromPrimaryAndShellOnlyHasNone() {
    var state = SessionSidebarItemFeature.State(
      id: .task(LayoutID(task: UUID())), title: "t", cwd: "/", createdAt: .distantPast)
    #expect(state.harness == nil)
    state.primary = SessionKey(harness: .pi, sessionID: "s1")
    #expect(state.harness == .pi)
  }

  @Test func subRowTakesHarnessFromMember() {
    let session = SessionsSidebarStructure.SubRow(id: .session(SessionKey(harness: .omp, sessionID: "s")), title: "t")
    let provisional = SessionsSidebarStructure.SubRow(id: .provisional(harness: .kiro, surfaceID: UUID()), title: "t")
    #expect(session.harness == .omp)
    #expect(provisional.harness == .kiro)
  }
}

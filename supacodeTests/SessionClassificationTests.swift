import Foundation
import SupacodeSettingsShared
import Testing

@testable import supacode

struct SessionClassificationTests {
  private func summary(_ id: String, created: TimeInterval, activity: TimeInterval = 0) -> SessionSummary {
    SessionSummary(
      harness: .pi, sessionID: id, createdAt: Date(timeIntervalSince1970: created),
      cwd: "/workspace", title: id, messageCount: 0, lastActivity: Date(timeIntervalSince1970: activity))
  }

  @Test func creationOrderIgnoresActivityAndUsesStableIdentityTies() {
    let rows = [summary("b", created: 2), summary("old", created: 1, activity: 999), summary("a", created: 2)]
    #expect(SessionClassification.ordered(rows).map(\.sessionID) == ["a", "b", "old"])
    #expect(SessionClassification.ordered(rows.reversed()).map(\.sessionID) == ["a", "b", "old"])
  }

  @Test func activeSectionPrecedesSettledWithoutActivityReordering() {
    let oldest = summary("old", created: 1)
    let newest = summary("new", created: 3)
    let middle = summary("middle", created: 2)
    let sidecar: SessionSidecar = [newest.id: SessionSidecarEntry(settledAt: Date())]
    #expect(
      SessionClassification.ordered([newest, oldest, middle], sidecar: sidecar).map(\.sessionID)
        == ["middle", "old", "new"])
    #expect(SessionClassification.ordered([newest, oldest, middle]).map(\.sessionID) == ["new", "middle", "old"])
  }

  @Test func lifecycleAndRuntimeAreIndependentAndAutoRulesAreDeferred() {
    for live in [true, false] {
      let active = SessionClassification.classify(isLive: live)
      #expect(active.lifecycle == .active)
      #expect(active.runtime == (live ? .live : .dormant))
      let settled = SessionClassification.classify(isLive: live, sidecar: SessionSidecarEntry(settledAt: Date()))
      #expect(settled.lifecycle == .settled)
      #expect(settled.runtime == active.runtime)
      #expect(
        SessionClassification.classify(
          isLive: live,
          sidecar: SessionSidecarEntry(manualUnsettledAtActivity: .distantPast)
        ).lifecycle == .active)
    }
  }

  @Test func sidecarRoundtripPreservesOnlyMarkersAndUniqueOrderedBranches() throws {
    let key = SessionKey(harness: .pi, sessionID: "abc")
    #expect(key.rawValue == "pi:abc")
    var entry = SessionSidecarEntry(
      settledAt: Date(timeIntervalSince1970: 1),
      manualUnsettledAtActivity: Date(timeIntervalSince1970: 2), branches: ["main", "feature", "main", ""])
    entry.recordBranch("next")
    entry.recordBranch("feature")
    #expect(entry.branches == ["main", "feature", "next"])
    let sidecar: SessionSidecar = [key: entry]
    #expect(try JSONDecoder().decode(SessionSidecar.self, from: JSONEncoder().encode(sidecar)) == sidecar)
    let data = try JSONEncoder().encode(entry)
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(Set(object.keys) == ["settledAt", "manualUnsettledAtActivity", "branches"])
  }
}

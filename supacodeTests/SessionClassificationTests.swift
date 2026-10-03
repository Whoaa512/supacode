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

  struct AutoCase: Sendable {
    var explicit = false
    var live = false
    var hold = false
    var count = 4
    var age = 10.0
    var days = 3
    var settled = false
  }

  @Test(arguments: [
    AutoCase(explicit: true, live: true, settled: true),
    AutoCase(live: true, count: 0),
    AutoCase(hold: true, count: 0),
    AutoCase(count: 3, age: 0, settled: true),
    AutoCase(age: 3, settled: true),
    AutoCase(age: 2.999),
    AutoCase(age: -1),
    AutoCase(count: 0, days: 0),
  ])
  func autoClassificationPrecedence(_ value: AutoCase) {
    let now = Date(timeIntervalSince1970: 1_000_000)
    var row = summary("table", created: 0)
    row.messageCount = value.count
    row.lastActivity = now.addingTimeInterval(-value.age * 86_400)
    let entry = SessionSidecarEntry(
      settledAt: value.explicit ? now : nil, manualUnsettledAtActivity: value.hold ? row.lastActivity : nil)
    #expect(SessionClassification.classify(
      summary: row, isLive: value.live, sidecar: entry, now: now, idleDays: value.days
    ).lifecycle == (value.settled ? .settled : .active))
  }

  @Test func newerActivityReleasesManualHold() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    var row = summary("hold", created: 0)
    row.messageCount = 3
    row.lastActivity = now
    let entry = SessionSidecarEntry(manualUnsettledAtActivity: now.addingTimeInterval(-1))
    #expect(SessionClassification.classify(
      summary: row, isLive: false, sidecar: entry, now: now
    ).lifecycle == .settled)
    #expect(SessionClassification.classify(
      summary: row, isLive: true, sidecar: entry, now: now
    ).lifecycle == .active)
  }

  @Test func idleSettingsDefaultsAndRoundtrip() throws {
    var settings = GlobalSettings.default
    #expect(settings.sessionIdleDays == 3)
    for days in [0, 7] {
      settings.sessionIdleDays = days
      #expect(try JSONDecoder().decode(
        GlobalSettings.self, from: JSONEncoder().encode(settings)).sessionIdleDays == days)
    }
    let data = try JSONEncoder().encode(settings)
    var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    object.removeValue(forKey: "sessionIdleDays")
    #expect(try JSONDecoder().decode(
      GlobalSettings.self, from: JSONSerialization.data(withJSONObject: object)).sessionIdleDays == 3)
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

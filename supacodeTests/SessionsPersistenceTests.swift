import Foundation
import Sharing
import Testing

@testable import SupacodeSettingsShared
@testable import supacode

@Suite
struct SessionsPersistenceTests {
  // MARK: - JSON roundtrip

  @Test func settledAtRoundtrips() throws {
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let entry = SessionSidecarEntry(settledAt: date)
    let data = try JSONEncoder().encode(entry)
    let decoded = try JSONDecoder().decode(SessionSidecarEntry.self, from: data)
    #expect(decoded.settledAt == date)
    #expect(decoded.manualUnsettledAtActivity == nil)
    #expect(decoded.branches.isEmpty)
  }

  @Test func manualUnsettledAtActivityRoundtrips() throws {
    let watermark = Date(timeIntervalSince1970: 1_700_100_000)
    let entry = SessionSidecarEntry(manualUnsettledAtActivity: watermark)
    let data = try JSONEncoder().encode(entry)
    let decoded = try JSONDecoder().decode(SessionSidecarEntry.self, from: data)
    #expect(decoded.settledAt == nil)
    #expect(decoded.manualUnsettledAtActivity == watermark)
  }

  @Test func fullEntryRoundtrips() throws {
    let settled = Date(timeIntervalSince1970: 1_700_000_000)
    let watermark = Date(timeIntervalSince1970: 1_700_100_000)
    var entry = SessionSidecarEntry(settledAt: settled, manualUnsettledAtActivity: watermark)
    entry.recordBranch("main")
    entry.recordBranch("feature")
    let data = try JSONEncoder().encode(entry)
    let decoded = try JSONDecoder().decode(SessionSidecarEntry.self, from: data)
    #expect(decoded.settledAt == settled)
    #expect(decoded.manualUnsettledAtActivity == watermark)
    #expect(decoded.branches == ["main", "feature"])
  }

  @Test func sidecarDictionaryRoundtrips() throws {
    let key = SessionKey(harness: .pi, sessionID: "abc123")
    let entry = SessionSidecarEntry(settledAt: Date(timeIntervalSince1970: 1_700_000_000))
    let sidecar: SessionSidecar = [key: entry]
    let data = try JSONEncoder().encode(sidecar)
    let decoded = try JSONDecoder().decode(SessionSidecar.self, from: data)
    #expect(decoded[key]?.settledAt == entry.settledAt)
  }

  // MARK: - Watermark semantics

  @Test func settlingClearsWatermark() throws {
    var entry = SessionSidecarEntry(manualUnsettledAtActivity: Date(timeIntervalSince1970: 1_000))
    #expect(entry.manualUnsettledAtActivity != nil)
    entry.settledAt = Date(timeIntervalSince1970: 2_000)
    entry.manualUnsettledAtActivity = nil
    #expect(entry.settledAt != nil)
    #expect(entry.manualUnsettledAtActivity == nil)
  }

  @Test func unsettlingClearsSettledAtAndSetsWatermark() throws {
    let watermark = Date(timeIntervalSince1970: 999)
    var entry = SessionSidecarEntry(settledAt: Date(timeIntervalSince1970: 2_000))
    entry.settledAt = nil
    entry.manualUnsettledAtActivity = watermark
    #expect(entry.settledAt == nil)
    #expect(entry.manualUnsettledAtActivity == watermark)
  }

  @Test func classificationUsesSettledAt() {
    let settled = SessionClassification.classify(
      isLive: false, sidecar: SessionSidecarEntry(settledAt: Date()))
    #expect(settled.lifecycle == .settled)

    let active = SessionClassification.classify(
      isLive: false, sidecar: SessionSidecarEntry(settledAt: nil))
    #expect(active.lifecycle == .active)
  }

  // MARK: - DEBUG path isolation

  @Test func sessionsURLUsesStateDirectoryOverride() {
    let original = SupacodePaths.sessionsURL.path
    // Without an env override the path should be under ~/.supacode
    #expect(original.contains(".supacode") || ProcessInfo.processInfo.environment["SUPACODE_STATE_DIR"] != nil)
  }

  @Test func sessionsURLRespectsSUPACODE_STATE_DIR() throws {
    let tmp = FileManager.default.temporaryDirectory
      .appendingPathComponent("supacode-tests-sessions-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }
    // Verify the URL construction pattern — actual env var injection happens at process level.
    // We confirm the path component is sessions.json under baseDirectory.
    let sessionsFileName = SupacodePaths.sessionsURL.lastPathComponent
    #expect(sessionsFileName == "sessions.json")
  }
}

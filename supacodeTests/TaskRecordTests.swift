import Foundation
import Testing

@testable import supacode

struct TaskRecordTests {
  private static let referenceDate = Date(timeIntervalSince1970: 1_700_000_000)

  private static func makeRecord(
    id: TaskID = TaskID("task-1"),
    surfaceIDs: Set<UUID> = []
  ) -> TaskRecord {
    TaskRecord(
      id: id,
      title: "Fix the sidebar",
      directoryPath: "/Users/test/code/supacode",
      branch: "task-inbox-sidebar",
      repositoryID: Repository.ID("/Users/test/code/supacode"),
      createdAt: referenceDate,
      settledAt: referenceDate.addingTimeInterval(60),
      settledOverride: .active,
      snoozedUntil: referenceDate.addingTimeInterval(120),
      snoozedAt: referenceDate.addingTimeInterval(90),
      pinnedAt: referenceDate.addingTimeInterval(30),
      lastVisitedAt: referenceDate.addingTimeInterval(150),
      surfaceIDs: surfaceIDs,
      seedEvidence: .init(source: .reflog, confidence: .medium),
      autoManagedWorktree: .init(
        path: "/Users/test/.supacode/repos/supacode/task-inbox",
        branch: "task-inbox",
        createdAt: referenceDate
      )
    )
  }

  private static func roundTrip(_ record: TaskRecord) throws -> TaskRecord {
    let data = try JSONEncoder().encode(record)
    return try JSONDecoder().decode(TaskRecord.self, from: data)
  }

  @Test func fullyPopulatedRecordRoundTrips() throws {
    let surfaces: Set<UUID> = [
      UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!,
      UUID(uuidString: "00000000-0000-0000-0000-0000000000BB")!,
    ]
    let record = Self.makeRecord(surfaceIDs: surfaces)
    #expect(try Self.roundTrip(record) == record)
  }

  @Test func minimalRecordRoundTrips() throws {
    let record = TaskRecord(
      id: TaskID("minimal"),
      title: "notes",
      directoryPath: "/Users/test/work/cj",
      createdAt: Self.referenceDate
    )
    let decoded = try Self.roundTrip(record)
    #expect(decoded == record)
    #expect(decoded.surfaceIDs.isEmpty)
    #expect(decoded.branch == nil)
    #expect(decoded.autoManagedWorktree == nil)
  }

  @Test func equalRecordsEncodeToIdenticalBytes() throws {
    // `surfaceIDs` is a Set, whose iteration order varies per process; the encode
    // sorts it so a no-op save can never produce a spurious diff.
    let surfaces: Set<UUID> = [
      UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!,
      UUID(uuidString: "00000000-0000-0000-0000-0000000000BB")!,
      UUID(uuidString: "00000000-0000-0000-0000-0000000000CC")!,
    ]
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    #expect(
      try encoder.encode(Self.makeRecord(surfaceIDs: surfaces))
        == encoder.encode(Self.makeRecord(surfaceIDs: surfaces))
    )
  }

  @Test func generatedIDsAreUniqueAndOpaque() {
    let first = TaskID()
    let second = TaskID()
    #expect(first != second)
    // Opaque: nothing about the task's location may leak into the id.
    #expect(!first.rawValue.contains("/"))
  }

  @Test(arguments: [
    TaskRecord.SettledOverride.settled,
    TaskRecord.SettledOverride.active,
  ])
  func settledOverrideRoundTrips(override: TaskRecord.SettledOverride) throws {
    var record = Self.makeRecord()
    record.settledOverride = override
    #expect(try Self.roundTrip(record).settledOverride == override)
  }

  @Test func absentSettledOverrideStaysNil() throws {
    var record = Self.makeRecord()
    record.settledOverride = nil
    #expect(try Self.roundTrip(record).settledOverride == nil)
  }

  @Test(arguments: TaskRecord.SeedEvidence.Source.allCases)
  func seedEvidenceSourceRoundTrips(source: TaskRecord.SeedEvidence.Source) throws {
    var record = Self.makeRecord()
    record.seedEvidence = .init(source: source, confidence: .low)
    #expect(try Self.roundTrip(record).seedEvidence?.source == source)
  }

  @Test func unknownKeysFromAFutureSchemaAreIgnored() throws {
    // A newer build adds fields; this build must still read the record whole.
    let json = """
      {
        "id": "future-1",
        "title": "Ship it",
        "directoryPath": "/tmp/repo",
        "createdAt": 1700000000,
        "priority": "urgent",
        "labels": ["one", "two"],
        "nested": { "a": 1 }
      }
      """
    let decoded = try JSONDecoder().decode(TaskRecord.self, from: Data(json.utf8))
    #expect(decoded.id == TaskID("future-1"))
    #expect(decoded.title == "Ship it")
    #expect(decoded.directoryPath == "/tmp/repo")
  }

  @Test(arguments: [
    #"{"id":"x","title":"t","directoryPath":"/tmp","createdAt":1700000000,"settledOverride":"parked"}"#,
    #"{"id":"x","title":"t","directoryPath":"/tmp","createdAt":1700000000,"#
      + #""seedEvidence":{"source":"telepathy","confidence":"high"}}"#,
    #"{"id":"x","title":"t","directoryPath":"/tmp","createdAt":1700000000,"surfaceIDs":"not-a-set"}"#,
    #"{"id":"x","title":"t","directoryPath":"/tmp","createdAt":1700000000,"autoManagedWorktree":42}"#,
  ])
  func unreadableOptionalFieldDropsOnlyThatField(json: String) throws {
    let decoded = try JSONDecoder().decode(TaskRecord.self, from: Data(json.utf8))
    #expect(decoded.id == TaskID("x"))
    #expect(decoded.title == "t")
    #expect(decoded.settledOverride == nil)
    #expect(decoded.seedEvidence == nil)
    #expect(decoded.surfaceIDs.isEmpty)
    #expect(decoded.autoManagedWorktree == nil)
  }

  @Test(arguments: [
    #"{"title":"t","directoryPath":"/tmp","createdAt":1700000000}"#,
    #"{"id":"x","directoryPath":"/tmp","createdAt":1700000000}"#,
    #"{"id":"x","title":"t","createdAt":1700000000}"#,
    #"{"id":"x","title":"t","directoryPath":"/tmp"}"#,
    #"{"id":"x","title":"t","directoryPath":"/tmp","createdAt":"yesterday"}"#,
  ])
  func missingLoadBearingFieldFailsDecode(json: String) {
    #expect(throws: (any Error).self) {
      try JSONDecoder().decode(TaskRecord.self, from: Data(json.utf8))
    }
  }
}

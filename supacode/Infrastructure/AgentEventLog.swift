import Foundation
import SupacodeSettingsShared

private nonisolated let eventLogLogger = SupaLogger("AgentEventLog")

/// The concrete, non-gameable vocabulary of orchestration events. Stored on the
/// record as a raw `String` so an unknown event from a newer emitter is
/// persisted verbatim (passthrough) rather than dropped; `AgentEventKind`
/// documents the names Supacode itself understands.
public nonisolated enum AgentEventKind: String, Sendable {
  case runStarted = "run_started"
  case stageStarted = "stage_started"
  case stageCompleted = "stage_completed"
  case stageFailed = "stage_failed"
  case inputRequested = "input_requested"
  case inputResolved = "input_resolved"
  case artifactProduced = "artifact_produced"
  case processExited = "process_exited"
}

/// One durable line in the append-only event log. The `event` name is preserved
/// as a raw `String` and the payload as opaque `JSONValue` so the log is a
/// faithful, replayable record of testimony — including events this build does
/// not yet recognize.
public nonisolated struct AgentEventRecord: Equatable, Sendable, Codable {
  public let timestamp: Date
  public let sessionKey: String
  public let agent: String
  public let event: String
  public let data: JSONValue?

  public init(
    timestamp: Date,
    sessionKey: String,
    agent: String,
    event: String,
    data: JSONValue? = nil
  ) {
    self.timestamp = timestamp
    self.sessionKey = sessionKey
    self.agent = agent
    self.event = event
    self.data = data
  }
}

/// Durable, append-only JSON-lines event log, one file per session key under
/// Application Support. Serializes all disk access on its own actor so hook
/// storms from the main actor never block the UI and never interleave writes.
///
/// This is orchestration memory that outlives any TCA state; TCA gets pure
/// projections later. The log is the truth spine — agent hook events are
/// testimony recorded against it, never the reverse.
public actor AgentEventLog {
  private let directory: URL
  private let now: @Sendable () -> Date
  private let encoder: JSONEncoder
  private let decoder: JSONDecoder

  /// `directory` is injected so tests write to a temp path; `now` is injected so
  /// timestamps are deterministic under test without a wall clock.
  public init(directory: URL, now: @escaping @Sendable () -> Date = { Date() }) {
    self.directory = directory
    self.now = now
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    self.encoder = encoder
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    self.decoder = decoder
  }

  /// Default location: `~/Library/Application Support/Supacode/agent-events`.
  /// Returns nil if Application Support can't be resolved, so the caller can
  /// degrade to no-logging rather than crash.
  public static func applicationSupportDirectory(
    fileManager: FileManager = .default
  ) -> URL? {
    guard
      let base = try? fileManager.url(
        for: .applicationSupportDirectory,
        in: .userDomainMask,
        appropriateFor: nil,
        create: false)
    else {
      eventLogLogger.warning("Could not resolve Application Support directory")
      return nil
    }
    return base.appendingPathComponent("Supacode/agent-events", isDirectory: true)
  }

  /// Stamps the current time and appends. The convenience the ingest path uses
  /// so timestamping stays inside the log (and stays deterministic under test).
  public func record(sessionKey: String, agent: String, event: String, data: JSONValue? = nil) {
    let entry = AgentEventRecord(
      timestamp: now(), sessionKey: sessionKey, agent: agent, event: event, data: data)
    append(entry)
  }

  /// Appends one record as a single JSON line. Logs and swallows I/O failures:
  /// a log write must never take down an agent session.
  public func append(_ record: AgentEventRecord) {
    do {
      let line = try encoder.encode(record) + Data("\n".utf8)
      let fileURL = url(for: record.sessionKey)
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true)
      guard let handle = try? FileHandle(forWritingTo: fileURL) else {
        try line.write(to: fileURL, options: .atomic)
        return
      }
      defer { try? handle.close() }
      try handle.seekToEnd()
      try handle.write(contentsOf: line)
    } catch {
      eventLogLogger.warning("Failed to append event for \(record.sessionKey): \(error)")
    }
  }

  /// Replays every record for a session in write order. An empty or missing log
  /// returns `[]`. A single corrupt line is skipped (logged), never fatal, so a
  /// partial trailing write can't poison the whole replay.
  public func replay(sessionKey: String) -> [AgentEventRecord] {
    let fileURL = url(for: sessionKey)
    guard let contents = try? String(contentsOf: fileURL, encoding: .utf8) else {
      return []
    }
    var records: [AgentEventRecord] = []
    for line in contents.split(separator: "\n", omittingEmptySubsequences: true) {
      guard let record = try? decoder.decode(AgentEventRecord.self, from: Data(line.utf8)) else {
        eventLogLogger.warning("Skipping corrupt log line for \(sessionKey)")
        continue
      }
      records.append(record)
    }
    return records
  }

  /// Session keys are UUID surface ids or short slugs; sanitize defensively so a
  /// stray path separator can't escape the log directory.
  private func url(for sessionKey: String) -> URL {
    let safe = sessionKey.replacing("/", with: "_").replacing("..", with: "_")
    return directory.appendingPathComponent("\(safe).jsonl", isDirectory: false)
  }
}

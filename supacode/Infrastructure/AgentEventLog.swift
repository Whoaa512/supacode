import CryptoKit
import Foundation
import SupacodeSettingsShared

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
  /// A decision-inbox card the user resolved (focused / copied / dismissed).
  /// `input_resolved`-adjacent: it records the human's disposition of a
  /// candidate, keyed by the originating surface, into the same durable log.
  case inboxResolution = "inbox_resolution"
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
/// The write-order guarantee is real: `ingest(_:)` funnels every record through
/// a FIFO `AsyncStream`, so events land on disk in submission order even under a
/// storm of concurrent callers. Timestamps are stamped by the caller at the
/// ingest boundary (not inside the actor) so a reordered dispatch can never
/// rewrite when an event actually happened.
///
/// This is orchestration memory that outlives any TCA state; TCA gets pure
/// projections later. The log is the truth spine — agent hook events are
/// testimony recorded against it, never the reverse.
public actor AgentEventLog {
  private nonisolated static let logger = SupaLogger("AgentEventLog")
  /// Session keys are constrained to this set verbatim; anything else is hashed
  /// so `a/b` and `a_b` can never collide and an empty key still has a file.
  private nonisolated static let safeKeyCharacters = CharacterSet(
    charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")

  private let directory: URL
  private let now: @Sendable () -> Date
  private let maxFileBytes: Int
  private let encoder: JSONEncoder
  private let decoder: JSONDecoder
  private let ingestContinuation: AsyncStream<Ingest>.Continuation

  /// A single unit of work funneled through the ordered ingest stream. `barrier`
  /// is a test/flush aid: it resumes once every record queued before it has been
  /// written, giving deterministic ordering assertions without `Task.sleep`.
  private enum Ingest: Sendable {
    case append(AgentEventRecord)
    case barrier(@Sendable () -> Void)
  }

  /// `directory` is injected so tests write to a temp path; `now` is injected so
  /// timestamps are deterministic under test without a wall clock. `maxFileBytes`
  /// caps a single session's live file before it rotates.
  public init(
    directory: URL,
    now: @escaping @Sendable () -> Date = { Date() },
    maxFileBytes: Int = 5 * 1024 * 1024
  ) {
    self.directory = directory
    self.now = now
    self.maxFileBytes = maxFileBytes
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    self.encoder = encoder
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    self.decoder = decoder
    let (stream, continuation) = AsyncStream<Ingest>.makeStream()
    self.ingestContinuation = continuation
    Task { await self.consume(stream) }
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
      logger.warning("Could not resolve Application Support directory")
      return nil
    }
    return base.appendingPathComponent("Supacode/agent-events", isDirectory: true)
  }

  /// Ordered, non-blocking ingest boundary. The caller stamps the timestamp and
  /// hands over a fully-formed record; submission order is preserved by the FIFO
  /// stream. Nonisolated + synchronous so the main actor never awaits the log.
  public nonisolated func ingest(_ record: AgentEventRecord) {
    ingestContinuation.yield(.append(record))
  }

  /// Awaits until every record ingested before this call has been written.
  /// Deterministic flush for tests; no polling, no sleeps.
  public func flush() async {
    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
      ingestContinuation.yield(.barrier { cont.resume() })
    }
  }

  private func consume(_ stream: AsyncStream<Ingest>) async {
    for await item in stream {
      switch item {
      case .append(let record): append(record)
      case .barrier(let done): done()
      }
    }
  }

  /// Stamps the current time and appends directly. Convenience for direct/test
  /// callers; the ingest path builds its own record so it can stamp at the
  /// boundary instead.
  public func record(sessionKey: String, agent: String, event: String, data: JSONValue? = nil) {
    let entry = AgentEventRecord(
      timestamp: now(), sessionKey: sessionKey, agent: agent, event: event, data: data)
    append(entry)
  }

  /// Appends one record as a single JSON line, rotating first if the file would
  /// exceed the size cap. Logs and swallows I/O failures: a log write must never
  /// take down an agent session.
  public func append(_ record: AgentEventRecord) {
    do {
      let line = try encoder.encode(record) + Data("\n".utf8)
      let fileURL = url(for: record.sessionKey)
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true)
      rotateIfNeeded(fileURL: fileURL, incoming: line.count, sessionKey: record.sessionKey)
      guard let handle = try? FileHandle(forWritingTo: fileURL) else {
        try line.write(to: fileURL, options: .atomic)
        return
      }
      defer { try? handle.close() }
      try handle.seekToEnd()
      try handle.write(contentsOf: line)
    } catch {
      Self.logger.warning("Failed to append event for \(record.sessionKey): \(error)")
    }
  }

  /// Replays every record for a session in write order, streaming the file(s)
  /// line-by-line so a large log never slurps into one giant String. Reads the
  /// rotated-out `.1` file first, then the live file, to preserve global order.
  /// A single corrupt line is skipped (logged), never fatal.
  public func replay(sessionKey: String) -> [AgentEventRecord] {
    var records: [AgentEventRecord] = []
    let decodeLine: (Data) -> Void = { line in
      guard let record = try? self.decoder.decode(AgentEventRecord.self, from: line) else {
        Self.logger.warning("Skipping corrupt log line for \(sessionKey)")
        return
      }
      records.append(record)
    }
    forEachLine(in: previousURL(for: sessionKey), decodeLine)
    forEachLine(in: url(for: sessionKey), decodeLine)
    return records
  }

  /// Streams `fileURL` in fixed chunks, invoking `body` once per newline-
  /// terminated line (and once for a trailing unterminated line). A missing file
  /// is a no-op.
  private func forEachLine(in fileURL: URL, _ body: (Data) -> Void) {
    guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return }
    defer { try? handle.close() }
    var buffer = Data()
    let newline = UInt8(ascii: "\n")
    while let chunk = try? handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
      buffer.append(chunk)
      while let idx = buffer.firstIndex(of: newline) {
        let line = buffer.subdata(in: buffer.startIndex..<idx)
        buffer.removeSubrange(buffer.startIndex...idx)
        if !line.isEmpty { body(line) }
      }
    }
    if !buffer.isEmpty { body(buffer) }
  }

  /// Rotates `<stem>.jsonl` to `<stem>.1.jsonl` (replacing any prior `.1`) when
  /// the incoming write would push it past the cap. Keeps current + one previous
  /// file per session; older history is intentionally dropped.
  private func rotateIfNeeded(fileURL: URL, incoming: Int, sessionKey: String) {
    let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
    let size = (attributes?[.size] as? Int) ?? 0
    guard size > 0, size + incoming > maxFileBytes else { return }
    let previous = previousURL(for: sessionKey)
    try? FileManager.default.removeItem(at: previous)
    do {
      try FileManager.default.moveItem(at: fileURL, to: previous)
    } catch {
      Self.logger.warning("Failed to rotate log for \(sessionKey): \(error)")
    }
  }

  private func url(for sessionKey: String) -> URL {
    directory.appendingPathComponent("\(stem(for: sessionKey)).jsonl", isDirectory: false)
  }

  private func previousURL(for sessionKey: String) -> URL {
    directory.appendingPathComponent("\(stem(for: sessionKey)).1.jsonl", isDirectory: false)
  }

  /// Maps a session key to a safe, collision-free filename stem. Keys already
  /// restricted to `[A-Za-z0-9_-]` (UUIDs, short slugs) pass through verbatim;
  /// anything else — path separators, empties, unicode — is SHA-256 hashed with
  /// an `h-` prefix so `a/b` and `a_b` land in distinct files and can't escape
  /// the log directory.
  private func stem(for sessionKey: String) -> String {
    let needsHash =
      sessionKey.isEmpty || sessionKey.contains("..")
      || sessionKey.unicodeScalars.contains { !Self.safeKeyCharacters.contains($0) }
    guard needsHash else { return sessionKey }
    let digest = SHA256.hash(data: Data(sessionKey.utf8))
    return "h-" + digest.map { String(format: "%02x", $0) }.joined()
  }
}

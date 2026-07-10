import Foundation
import SupacodeSettingsShared

/// A single thing an agent surface needs a human to look at, derived
/// deterministically from the hook-event stream. Never inferred from transcript
/// text or heuristics — every candidate traces to a concrete hook signal.
///
/// `id` is stable so the UI (and any later resolve transport) can address a
/// candidate across reduces: a protocol `input_requested` carries its own id;
/// everything else synthesizes one from the surface + kind so repeated signals
/// for the same surface coalesce instead of piling up.
nonisolated struct AttentionCandidate: Equatable, Identifiable, Sendable {
  /// Why this surface wants attention. `.processExited` carries whether the exit
  /// was a failure so the UI can rank a crash above a clean stop.
  enum Kind: Equatable, Sendable {
    case inputRequested
    case awaitingInput
    case notification
    case processExited(failure: Bool)
  }

  let id: String
  /// Raw protocol payload id for `.inputRequested` candidates, used to route a
  /// resolve back to the originating request. Nil for synthesized kinds. Note
  /// `id` is namespaced by surface to avoid cross-surface collisions, so this is
  /// the un-namespaced value the agent transport speaks.
  let requestID: String?
  let sessionID: UUID
  let kind: Kind
  let question: String?
  let options: [String]
  let recommendation: String?
  let contextRefs: [String]
  let occurredAt: Date

  init(
    id: String,
    requestID: String? = nil,
    sessionID: UUID,
    kind: Kind,
    question: String? = nil,
    options: [String] = [],
    recommendation: String? = nil,
    contextRefs: [String] = [],
    occurredAt: Date
  ) {
    self.id = id
    self.requestID = requestID
    self.sessionID = sessionID
    self.kind = kind
    self.question = question
    self.options = options
    self.recommendation = recommendation
    self.contextRefs = contextRefs
    self.occurredAt = occurredAt
  }
}

/// Pure, deterministic projection of the agent hook-event stream into the set of
/// `AttentionCandidate`s currently in play. Holds per-surface state and applies
/// one event at a time via `reducing(_:)` (a value-returning reduce, so it is
/// trivially testable and free of side effects). The event stream is testimony;
/// this type only annotates it — it never decides process liveness.
///
/// Deterministic rules (no AI, no transcript parsing):
/// - `input_requested` with a decodable `InputRequested` payload → a full-detail
///   candidate keyed by the payload id; a later `input_resolved` with the same
///   id removes it. An `input_requested` without a decodable payload is ignored
///   (we never fabricate a question).
/// - `awaiting_input` → a low-detail candidate for the surface; cleared by the
///   next `busy` / `idle` / `session_end` on that surface, and suppressed in the
///   projection whenever a live `input_requested` already covers the same block.
/// - `notification` with a decodable message → a candidate carrying the message;
///   coalesces per surface and clears on `session_end`.
/// - `process_exited` → surfaces a failure candidate only for a non-zero exit; a
///   clean exit (code 0) surfaces nothing. Either way the surface's live input
///   requests and awaiting flag are dropped (a dead process can't answer).
/// - `session_end` → drops every candidate for that surface (the surface is gone).
/// - any unrecognized event → state unchanged.
nonisolated struct AttentionDetector: Equatable, Sendable {
  /// Per-surface accumulator. Kept private so the only way to mutate is through
  /// the pure reduce; the public `candidates` view flattens across surfaces.
  private struct SurfaceState: Equatable, Sendable {
    /// Full-detail protocol requests, keyed by their stable payload id so a
    /// resolve can target one precisely and a re-request updates in place.
    var inputRequests: [String: AttentionCandidate] = [:]
    /// At most one low-detail awaiting-input candidate; overwritten by a newer
    /// `awaiting_input` and cleared by activity.
    var awaiting: AttentionCandidate?
    /// Latest notification candidate for the surface.
    var notification: AttentionCandidate?
    /// Latest process-exit candidate for the surface.
    var exited: AttentionCandidate?

    var isEmpty: Bool {
      inputRequests.isEmpty && awaiting == nil && notification == nil && exited == nil
    }

    var all: [AttentionCandidate] {
      var result = Array(inputRequests.values)
      // A live protocol request and a bare awaiting-input flag describe the same
      // blocked block; the detailed request wins so we never show two cards for
      // one prompt.
      if let awaiting, inputRequests.isEmpty { result.append(awaiting) }
      if let notification { result.append(notification) }
      if let exited { result.append(exited) }
      return result
    }
  }

  private var surfaces: [UUID: SurfaceState] = [:]

  init() {}

  /// Every open candidate across all surfaces, oldest first (ties broken by id
  /// for a stable order). Presentation layers project from this.
  var candidates: [AttentionCandidate] {
    surfaces.values
      .flatMap(\.all)
      .sorted { lhs, rhs in
        lhs.occurredAt == rhs.occurredAt ? lhs.id < rhs.id : lhs.occurredAt < rhs.occurredAt
      }
  }

  /// Returns a new detector with `event` applied. Pure: no field is read or
  /// written outside the returned copy, so `state.reducing(a).reducing(b)` is a
  /// faithful replay of the stream in order.
  func reducing(_ event: AgentHookEvent) -> AttentionDetector {
    var copy = self
    copy.apply(event)
    return copy
  }

  /// Replays a whole stream in order. Convenience over repeated `reducing`.
  static func projecting<S: Sequence>(_ events: S) -> AttentionDetector
  where S.Element == AgentHookEvent {
    events.reduce(into: AttentionDetector()) { $0.apply($1) }
  }

  private mutating func apply(_ event: AgentHookEvent) {
    let timestamp = event.timestamp ?? Date(timeIntervalSince1970: 0)
    switch event.eventName {
    case .inputRequested:
      applyInputRequested(event, timestamp: timestamp)
    case .inputResolved:
      applyInputResolved(event)
    case .awaitingInput:
      setAwaiting(event, timestamp: timestamp)
    case .busy, .idle:
      clearAwaiting(surfaceID: event.surfaceID)
    case .notification:
      setNotification(event, timestamp: timestamp)
    case .sessionEnd:
      surfaces[event.surfaceID] = nil
    case .sessionStart, .none:
      // sessionStart carries no attention; an unknown event is testimony we do
      // not yet understand and must never fabricate a candidate from.
      applyByRawKind(event, timestamp: timestamp)
    }
  }

  /// Handles event names that are not in the presence `EventName` enum but are
  /// meaningful to the log vocabulary (currently `process_exited`). Keeps the
  /// main switch focused on presence lifecycle while still reacting to the
  /// durable-log-only events.
  private mutating func applyByRawKind(_ event: AgentHookEvent, timestamp: Date) {
    guard event.event == AgentEventKind.processExited.rawValue else { return }
    // The process is gone: any prompt it was waiting on can never be answered, so
    // drop its live requests and awaiting flag regardless of exit status.
    var state = surfaces[event.surfaceID, default: SurfaceState()]
    state.inputRequests.removeAll()
    state.awaiting = nil
    // A clean exit (code 0) is an unremarkable stop and surfaces nothing; only a
    // non-zero/failure exit warrants a candidate the human should rank.
    if Self.decodeExitFailure(event) {
      state.exited = AttentionCandidate(
        id: "exited:\(event.surfaceID.uuidString)",
        sessionID: event.surfaceID,
        kind: .processExited(failure: true),
        occurredAt: timestamp)
    }
    surfaces[event.surfaceID] = state.isEmpty ? nil : state
  }

  private mutating func applyInputRequested(_ event: AgentHookEvent, timestamp: Date) {
    guard let requested = event.decodeData(InputRequested.self) else { return }
    let candidate = AttentionCandidate(
      id: "\(event.surfaceID.uuidString):\(requested.id)",
      requestID: requested.id,
      sessionID: event.surfaceID,
      kind: .inputRequested,
      question: requested.question,
      options: requested.options,
      recommendation: requested.recommendation,
      contextRefs: requested.contextRefs,
      occurredAt: timestamp)
    surfaces[event.surfaceID, default: SurfaceState()].inputRequests[requested.id] = candidate
  }

  private mutating func applyInputResolved(_ event: AgentHookEvent) {
    guard let resolved = event.decodeData(InputResolved.self) else { return }
    guard var state = surfaces[event.surfaceID] else { return }
    state.inputRequests[resolved.id] = nil
    surfaces[event.surfaceID] = state.isEmpty ? nil : state
  }

  private mutating func setAwaiting(_ event: AgentHookEvent, timestamp: Date) {
    let candidate = AttentionCandidate(
      id: "awaiting:\(event.surfaceID.uuidString)",
      sessionID: event.surfaceID,
      kind: .awaitingInput,
      occurredAt: timestamp)
    surfaces[event.surfaceID, default: SurfaceState()].awaiting = candidate
  }

  private mutating func clearAwaiting(surfaceID: UUID) {
    guard var state = surfaces[surfaceID] else { return }
    state.awaiting = nil
    surfaces[surfaceID] = state.isEmpty ? nil : state
  }

  private mutating func setNotification(_ event: AgentHookEvent, timestamp: Date) {
    guard let message = Self.decodeNotificationMessage(event) else { return }
    let candidate = AttentionCandidate(
      id: "notification:\(event.surfaceID.uuidString)",
      sessionID: event.surfaceID,
      kind: .notification,
      question: message,
      occurredAt: timestamp)
    surfaces[event.surfaceID, default: SurfaceState()].notification = candidate
  }

  /// Extracts a human-readable message from a `notification` payload, tolerant of
  /// the shapes agents emit today (`message`, `body`, or a bare string). Returns
  /// nil when nothing readable is present, so an empty notification never becomes
  /// a candidate.
  private static func decodeNotificationMessage(_ event: AgentHookEvent) -> String? {
    guard let data = event.data else { return nil }
    switch data {
    case .string(let text):
      return text.isEmpty ? nil : text
    case .object(let fields):
      for key in ["message", "body", "title"] {
        if case .string(let text)? = fields[key], !text.isEmpty { return text }
      }
      return nil
    default:
      return nil
    }
  }

  /// A process exit is a failure when the payload reports a non-zero exit code.
  /// Absent code → treated as a clean exit (no false crash alarm).
  private static func decodeExitFailure(_ event: AgentHookEvent) -> Bool {
    guard case .object(let fields)? = event.data else { return false }
    for key in ["exit_code", "code", "status"] {
      switch fields[key] {
      case .int(let value)?: return value != 0
      case .double(let value)?: return value != 0
      case .string(let text)?: return Int(text).map { $0 != 0 } ?? false
      default: continue
      }
    }
    return false
  }
}

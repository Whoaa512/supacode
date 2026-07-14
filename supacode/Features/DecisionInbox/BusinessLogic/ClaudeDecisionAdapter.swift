import CryptoKit
import Foundation
import SupacodeSettingsShared

/// Adapts Claude Code decision-hook events into the transport-agnostic
/// `input_requested` / `input_resolved` protocol the `AttentionDetector`
/// consumes.
///
/// The `supacode integration` CLI is a dumb pipe: it wraps the RAW Claude Code
/// hook stdin under a marker event and posts it over the local socket, so all
/// Claude-specific extraction lives here — app-side and unit-tested. This is the
/// plan's "extraction is the product" adapter boundary; adding a second agent
/// means a second adapter, not a change to the transport or the detector.
///
/// A stable id correlates the PreToolUse request with its PostToolUse
/// resolution. Claude's `tool_use_id` uniquely identifies the invocation and
/// is shared by both hooks. Older payloads fall back to a digest over the
/// session, tool name, and canonical tool input.
enum ClaudeDecisionAdapter {
  /// Marker event the CLI posts for a PreToolUse on AskUserQuestion / ExitPlanMode.
  static let requestedMarker = "claude_decision_requested"
  /// Marker event the CLI posts for the matching PostToolUse.
  static let resolvedMarker = "claude_decision_resolved"

  /// Returns the protocol event to dispatch, or nil to pass the original event
  /// through unchanged: a non-marker event, or a marker whose payload lacks the
  /// fields needed to build a protocol event (the detector would ignore the raw
  /// marker anyway, so a passthrough is safe).
  static func adapt(_ event: AgentHookEvent) -> AgentHookEvent? {
    switch event.event {
    case requestedMarker: return requested(from: event)
    case resolvedMarker: return resolved(from: event)
    default: return nil
    }
  }

  private static func requested(from event: AgentHookEvent) -> AgentHookEvent? {
    guard let hook = event.data?.objectValue,
      let toolName = hook["tool_name"]?.stringValue
    else { return nil }
    let id = stableID(hook: hook, toolName: toolName, surfaceID: event.surfaceID)
    let payload = inputRequested(id: id, toolName: toolName, toolInput: hook["tool_input"])
    guard let data = try? JSONValue(payload) else { return nil }
    return event.reshaped(event: AgentHookEvent.EventName.inputRequested.rawValue, data: data)
  }

  private static func resolved(from event: AgentHookEvent) -> AgentHookEvent? {
    guard let hook = event.data?.objectValue,
      let toolName = hook["tool_name"]?.stringValue
    else { return nil }
    let id = stableID(hook: hook, toolName: toolName, surfaceID: event.surfaceID)
    let payload = InputResolved(id: id, choice: choice(from: hook["tool_response"]))
    guard let data = try? JSONValue(payload) else { return nil }
    return event.reshaped(event: AgentHookEvent.EventName.inputResolved.rawValue, data: data)
  }

  // MARK: - Extraction.

  private static func inputRequested(
    id: String, toolName: String, toolInput: JSONValue?
  ) -> InputRequested {
    switch toolName {
    case "AskUserQuestion":
      return askUserQuestion(id: id, toolInput: toolInput)
    case "ExitPlanMode":
      return InputRequested(
        id: id,
        question: "Claude is requesting approval to proceed with its plan.",
        options: [])
    default:
      return InputRequested(
        id: id, question: "Claude is requesting input (\(toolName)).", options: [])
    }
  }

  /// AskUserQuestion carries `tool_input.questions[]`, each with a `question`
  /// string and an `options[]` list whose entries are either `{label,\u2026}`
  /// objects or bare strings. v1 surfaces the first question; a fallback keeps a
  /// non-empty question even if the shape drifts.
  private static func askUserQuestion(id: String, toolInput: JSONValue?) -> InputRequested {
    let first = toolInput?.objectValue?["questions"]?.arrayValue?.first?.objectValue
    let question = first?["question"]?.stringValue ?? "Claude has a question for you."
    let options = (first?["options"]?.arrayValue ?? []).compactMap(optionLabel)
    return InputRequested(id: id, question: question, options: options)
  }

  private static func optionLabel(_ option: JSONValue) -> String? {
    if let label = option.objectValue?["label"]?.stringValue { return label }
    return option.stringValue
  }

  /// Best-effort choice for the resolution record: scans the tool response for
  /// the common answer-bearing keys. An empty string is fine — `input_resolved`
  /// only needs the id to clear the candidate; the choice is annotation.
  private static func choice(from toolResponse: JSONValue?) -> String {
    guard let response = toolResponse else { return "" }
    if let direct = firstStringValue(in: response, keys: ["answer", "response", "selected", "choice"]) {
      return direct
    }
    if let answers = response.objectValue?["answers"]?.arrayValue {
      let labels = answers.compactMap {
        $0.objectValue?["answer"]?.stringValue ?? $0.stringValue
      }
      if !labels.isEmpty { return labels.joined(separator: ", ") }
    }
    return ""
  }

  private static func firstStringValue(in value: JSONValue, keys: [String]) -> String? {
    guard let object = value.objectValue else { return nil }
    for key in keys {
      if let match = object[key]?.stringValue { return match }
    }
    return nil
  }

  // MARK: - Stable id.

  private static func stableID(
    hook: [String: JSONValue], toolName: String, surfaceID: UUID
  ) -> String {
    let sessionID = hook["session_id"]?.stringValue ?? surfaceID.uuidString
    let invocationID = hook["tool_use_id"]?.stringValue
    let canonicalInput = canonicalJSON(hook["tool_input"])
    let seed = invocationID ?? "\(sessionID)\u{1F}\(toolName)\u{1F}\(canonicalInput)"
    let digest = SHA256.hash(data: Data(seed.utf8))
    return "cc-" + digest.prefix(16).map { String(format: "%02x", $0) }.joined()
  }

  private static func canonicalJSON(_ value: JSONValue?) -> String {
    guard let value else { return "" }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let data = try? encoder.encode(value) else { return "" }
    return String(bytes: data, encoding: .utf8) ?? ""
  }
}

extension AgentHookEvent {
  /// A copy of the event with a new `event` name and `data` payload, preserving
  /// surface / agent / pid / timestamp attribution. Used by adapters that
  /// rewrite a raw agent event into a protocol event.
  fileprivate func reshaped(event: String, data: JSONValue) -> AgentHookEvent {
    AgentHookEvent(
      version: version,
      agent: agent,
      event: event,
      surfaceID: surfaceID,
      pid: pid,
      timestamp: timestamp,
      data: data)
  }
}

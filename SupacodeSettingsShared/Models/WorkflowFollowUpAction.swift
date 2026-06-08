import Foundation

/// A short steering action surfaced on a live or completed run card. Actions
/// that carry `promptText` send that literal text into the linked terminal
/// (the stable steering vocabulary: `cont`, `intme`, `fix`, `verify`,
/// `handoff`). Actions without `promptText` are handled by the app itself
/// (stop the run, copy output, attach more context).
public nonisolated enum WorkflowFollowUpAction: String, Codable, CaseIterable, Sendable {
  case continueRun
  case stop
  case interviewMe
  case fixFindings
  case verify
  case copy
  case handoff
  case addContext

  public var displayName: String {
    switch self {
    case .continueRun: "Continue"
    case .stop: "Stop"
    case .interviewMe: "Interview Me"
    case .fixFindings: "Fix Findings"
    case .verify: "Verify"
    case .copy: "Copy"
    case .handoff: "Handoff"
    case .addContext: "Add Context"
    }
  }

  /// Literal text sent into the linked terminal. `nil` for app-handled actions.
  public var promptText: String? {
    switch self {
    case .continueRun: "cont"
    case .interviewMe: "intme"
    case .fixFindings: "fix"
    case .verify: "verify"
    case .handoff: "handoff"
    case .stop, .copy, .addContext: nil
    }
  }
}

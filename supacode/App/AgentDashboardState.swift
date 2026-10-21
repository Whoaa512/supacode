import Foundation

/// Triage state the CLI (`supacode agent list` / `agent wait`) reports. Ordered
/// by urgency: the raw value is the sort rank. `done` is an idle agent whose
/// last turn finished while its surface was unfocused; `unknown` covers agents
/// with no hook-reported activity.
enum AgentDashboardState: Int, Comparable, Sendable {
  case blocked = 0
  case working = 1
  case done = 2
  case idle = 3
  case unknown = 4

  static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

  /// `error` maps to `blocked` severity; the CLI reads `activity` for the distinction.
  static func from(_ activity: AgentPresenceFeature.Activity) -> Self {
    switch activity {
    case .awaitingInput, .error: .blocked
    case .busy, .compacting: .working
    case .idle: .idle
    }
  }

  /// Same mapping, promoting a finished-but-unseen turn to `done`.
  static func from(_ instance: AgentPresenceFeature.AgentInstance) -> Self {
    let state = from(instance.activity)
    guard state == .idle, instance.isDoneUnseen else { return state }
    return .done
  }
}

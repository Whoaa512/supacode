import Foundation

nonisolated enum SessionClassification {
  enum Lifecycle: String, Equatable, Sendable { case active, settled }
  enum Runtime: String, Equatable, Sendable { case live, dormant }
  enum Status: String, Equatable, Sendable {
    case needsYou = "needs-you"
    case working
    case doneUnseen = "done-unseen"
    case idle
  }

  struct Classification: Equatable, Sendable {
    var lifecycle: Lifecycle
    var runtime: Runtime
  }

  static func classify(isLive: Bool, sidecar: SessionSidecarEntry? = nil) -> Classification {
    Classification(
      lifecycle: sidecar?.settledAt == nil ? .active : .settled,
      runtime: isLive ? .live : .dormant
    )
  }

  /// Dormant sessions with fewer than 4 messages settle after this many seconds of inactivity.
  static let dormantInactivityThreshold: TimeInterval = 3_600

  static func classify(
    summary: SessionSummary, isLive: Bool, sidecar: SessionSidecarEntry? = nil,
    now: Date, idleDays: Int = 3
  ) -> Classification {
    let runtime: Runtime = isLive ? .live : .dormant
    if sidecar?.settledAt != nil { return Classification(lifecycle: .settled, runtime: runtime) }
    if isLive { return Classification(lifecycle: .active, runtime: runtime) }
    if let hold = sidecar?.manualUnsettledAtActivity, summary.lastActivity <= hold {
      return Classification(lifecycle: .active, runtime: runtime)
    }
    guard idleDays > 0 else { return Classification(lifecycle: .active, runtime: runtime) }
    let inactivity = now.timeIntervalSince(summary.lastActivity)
    let settled = (summary.messageCount < 4 && inactivity >= dormantInactivityThreshold)
      || inactivity >= Double(idleDays) * 86_400
    return Classification(lifecycle: settled ? .settled : .active, runtime: runtime)
  }

  static func ordered(_ sessions: [SessionSummary], sidecar: SessionSidecar = [:]) -> [SessionSummary] {
    sessions.sorted {
      let lhsSettled = sidecar[$0.id]?.settledAt != nil
      let rhsSettled = sidecar[$1.id]?.settledAt != nil
      if lhsSettled != rhsSettled { return !lhsSettled }
      if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
      return $0.id.rawValue < $1.id.rawValue
    }
  }
}

import Foundation

nonisolated enum SessionClassification {
  enum Lifecycle: String, Equatable, Sendable { case active, settled }
  enum Runtime: String, Equatable, Sendable { case live, dormant }

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

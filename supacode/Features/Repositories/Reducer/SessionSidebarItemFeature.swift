import ComposableArchitecture
import Foundation
import SupacodeSettingsShared

nonisolated enum SessionRowID: Hashable, Sendable {
  case session(SessionKey)
  case provisional(SkillAgent, UUID)

  var sortKey: String {
    switch self {
    case .session(let key): key.rawValue
    case .provisional(let agent, let surface): "provisional:\(agent.rawValue):\(surface)"
    }
  }
}

nonisolated struct SessionLocation: Equatable, Sendable {
  var worktreeID: Worktree.ID
  var tabID: TabID
  var surfaceID: UUID
}

nonisolated struct SessionLiveSnapshot: Equatable, Sendable {
  var harness: SkillAgent
  var sessionRef: String?
  var cwd: String
  var location: SessionLocation
  var status: SessionClassification.Status = .idle

  var id: SessionRowID {
    if let ref = AgentPresenceOSC.sanitizedSessionRef(sessionRef) {
      return .session(SessionKey(harness: harness, sessionID: ref))
    }
    return .provisional(harness, location.surfaceID)
  }
}

@Reducer
struct SessionSidebarItemFeature {
  @ObservableState
  struct State: Equatable, Identifiable {
    var id: SessionRowID
    var title: String
    var cwd: String
    var createdAt: Date
    var lifecycle: SessionClassification.Lifecycle = .active
    var location: SessionLocation?
    var status: SessionClassification.Status?
    var branchAnnotation: String?
    var isSynthetic = false

    var isLive: Bool { location != nil }

    mutating func update(from row: Self) {
      title = row.title
      cwd = row.cwd
      createdAt = row.createdAt
      lifecycle = row.lifecycle
      location = row.location
      status = row.status
      branchAnnotation = row.branchAnnotation
      isSynthetic = row.isSynthetic
    }
  }

  enum Action { case activate }

  var body: some Reducer<State, Action> {
    Reduce { _, _ in .none }
  }
}

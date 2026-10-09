import ComposableArchitecture
import Foundation
import SupacodeSettingsShared

nonisolated enum SessionRowID: Hashable, Sendable {
  case session(SessionKey)
  case provisional(SkillAgent, UUID)
  /// A task no live agent sits in: it has no session to be listed by.
  case task(LayoutID)

  var sortKey: String {
    switch self {
    case .session(let key): key.rawValue
    case .provisional(let agent, let surface): "provisional:\(agent.rawValue):\(surface)"
    case .task(let layoutID): "task:\(layoutID.persistenceKey)"
    }
  }
}

nonisolated struct SessionLocation: Equatable, Sendable {
  var layoutID: LayoutID
  var directoryID: Worktree.ID
  var tabID: TabID
  var surfaceID: UUID
}

nonisolated struct SelectedTask: Equatable, Sendable {
  var id: LayoutID
  var directoryID: Worktree.ID
}

nonisolated struct SessionLiveSnapshot: Equatable, Sendable {
  var harness: SkillAgent
  var sessionRef: String?
  var cwd: String
  /// Where the surface's tab was recorded running, when that is not `cwd`. Auto-settle only.
  var surfaceCwd: String?
  var location: SessionLocation
  var status: SessionClassification.Status = .idle
  var allowsAttentionNavigation = true

  var id: SessionRowID {
    if let ref = AgentPresenceOSC.sanitizedSessionRef(sessionRef) {
      return .session(SessionKey(harness: harness, sessionID: ref))
    }
    return .provisional(harness, location.surfaceID)
  }

  var withoutStatus: Self {
    var copy = self
    copy.status = .idle
    copy.allowsAttentionNavigation = true
    return copy
  }
}

/// A task that holds tabs but no live agent, so no session row leads to it.
nonisolated struct TaskLiveSnapshot: Equatable, Sendable {
  var title: String
  var cwd: String
  /// The record's creation date; nil for a task not stored yet.
  var createdAt: Date?
  /// The task and one of its tabs. The tab only anchors the row: activating
  /// it shows the task with whatever it had focused.
  var location: SessionLocation

  var id: SessionRowID { .task(location.layoutID) }
}

/// The row a reconcile pass wants, as a plain value: building observable row
/// state for every indexed session on each pass is what made it slow.
nonisolated struct SessionRowDraft: Equatable, Sendable {
  var id: SessionRowID
  var title: String
  var cwd: String
  var createdAt: Date
  var lifecycle: SessionClassification.Lifecycle = .active
  var location: SessionLocation?
  var status: SessionClassification.Status?
  var allowsAttentionNavigation = true
  var branchAnnotation: String?
  var isSynthetic = false
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
    var allowsAttentionNavigation = true
    var branchAnnotation: String?
    var isSynthetic = false

    var isLive: Bool { location != nil }

    func matches(_ draft: SessionRowDraft) -> Bool {
      title == draft.title && cwd == draft.cwd && createdAt == draft.createdAt
        && lifecycle == draft.lifecycle && location == draft.location && status == draft.status
        && allowsAttentionNavigation == draft.allowsAttentionNavigation
        && branchAnnotation == draft.branchAnnotation && isSynthetic == draft.isSynthetic
    }

    mutating func apply(_ draft: SessionRowDraft) {
      title = draft.title
      cwd = draft.cwd
      createdAt = draft.createdAt
      lifecycle = draft.lifecycle
      location = draft.location
      status = draft.status
      allowsAttentionNavigation = draft.allowsAttentionNavigation
      branchAnnotation = draft.branchAnnotation
      isSynthetic = draft.isSynthetic
    }
  }

  enum Action { case activate }

  var body: some Reducer<State, Action> {
    Reduce { _, _ in .none }
  }
}

extension SessionSidebarItemFeature.State {
  // In an extension so the memberwise initializer survives.
  init(_ draft: SessionRowDraft) {
    self.init(
      id: draft.id, title: draft.title, cwd: draft.cwd, createdAt: draft.createdAt,
      lifecycle: draft.lifecycle, location: draft.location, status: draft.status,
      allowsAttentionNavigation: draft.allowsAttentionNavigation,
      branchAnnotation: draft.branchAnnotation, isSynthetic: draft.isSynthetic)
  }
}

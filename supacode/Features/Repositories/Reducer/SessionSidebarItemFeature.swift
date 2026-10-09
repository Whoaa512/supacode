import ComposableArchitecture
import Foundation
import SupacodeSettingsShared

nonisolated enum SessionRowID: Hashable, Sendable {
  /// A task: its tabs and every session it lists, as one row.
  case task(LayoutID)
  /// An indexed session no task lists. Resuming it mints its task.
  case implicit(SessionKey)
  /// An agent that has not reported its session, on a surface no known task holds.
  case provisional(SkillAgent, UUID)

  var sortKey: String {
    switch self {
    case .implicit(let key): key.rawValue
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

  var sessionKey: SessionKey? {
    AgentPresenceOSC.sanitizedSessionRef(sessionRef).map { SessionKey(harness: harness, sessionID: $0) }
  }

  /// The row this agent has while no known task holds its surface.
  var id: SessionRowID {
    sessionKey.map(SessionRowID.implicit) ?? .provisional(harness, location.surfaceID)
  }

  var member: TaskMember {
    sessionKey.map(TaskMember.session) ?? .provisional(harness: harness, surfaceID: location.surfaceID)
  }

  var withoutStatus: Self {
    var copy = self
    copy.status = .idle
    copy.allowsAttentionNavigation = true
    return copy
  }
}

/// A task that holds tabs.
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

extension SessionClassification.Status {
  /// Lower is more urgent: needs you, working, done unseen, idle.
  nonisolated var urgency: Int {
    switch self {
    case .needsYou: 0
    case .working: 1
    case .doneUnseen: 2
    case .idle: 3
    }
  }
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
  /// A task's primary session. A shell-only task has none.
  var primary: SessionKey?
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
    var primary: SessionKey?

    var isLive: Bool { location != nil }
    /// The session whose sidecar entry is the row's settle state: the session
    /// itself, or a task's primary.
    var sessionKey: SessionKey? {
      if case .implicit(let key) = id { return key }
      return primary
    }
    var isTask: Bool {
      if case .task = id { return true }
      return false
    }

    func matches(_ draft: SessionRowDraft) -> Bool {
      title == draft.title && cwd == draft.cwd && createdAt == draft.createdAt
        && lifecycle == draft.lifecycle && location == draft.location && status == draft.status
        && allowsAttentionNavigation == draft.allowsAttentionNavigation
        && branchAnnotation == draft.branchAnnotation && isSynthetic == draft.isSynthetic
        && primary == draft.primary
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
      primary = draft.primary
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
      branchAnnotation: draft.branchAnnotation, isSynthetic: draft.isSynthetic, primary: draft.primary)
  }
}

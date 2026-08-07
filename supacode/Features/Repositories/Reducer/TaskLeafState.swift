import Foundation

/// The per-task invalidation unit — the task-row analogue of
/// `SidebarItemFeature.State`.
///
/// Everything a task row renders that is *not* in `TaskRecord` lives here:
/// title, branch and directory come from the record, activity comes from this
/// leaf. The reducer holds one leaf per task (`[TaskID: TaskLeafState]`), so an
/// agent tick or a notification mutates exactly one dictionary value and only
/// that row's observation invalidates — sibling rows and the cached
/// `TasksSidebarStructure` are untouched (assertion A10).
///
/// Deliberately *not* an input to `TasksSidebarStructure.compute`: activity
/// updates a row and can never reorder it (A4).
///
/// Population lands with the task reducer arms; this type only declares the
/// shape. Kept minimal for Phase 1 — status pills, working-elapsed
/// (`workingSince`) and PR projection arrive in Phase 5.
struct TaskLeafState: Equatable, Sendable, Identifiable {
  let id: TaskID
  /// Agents reported on the surfaces this task owns, projected from
  /// `AgentPresenceFeature` the same way a worktree row's snapshot is. Reused
  /// rather than re-modelled so a task row and a worktree row can never
  /// disagree about the same agent.
  var agentSnapshot: AgentPresenceFeature.RowSnapshot = .init()
  /// Unread terminal notifications on owned surfaces.
  var hasUnseenNotifications: Bool = false
  /// Every owned surface is hibernated, so the row shows the sleep marker.
  var allSurfacesDormant: Bool = false

  init(id: TaskID) {
    self.id = id
  }

  var agents: [AgentPresenceFeature.AgentInstance] { agentSnapshot.agents }
  var isWorking: Bool { agentSnapshot.isWorking }
  /// Sticky until the agent restarts or the user focuses the surface.
  var hasAgentError: Bool { agentSnapshot.hasError }
}

import ComposableArchitecture
import Foundation
import SupacodeSettingsShared

/// The per-task invalidation unit — the task-row analogue of
/// `SidebarItemFeature.State`.
///
/// Everything a task row renders that is *not* in `TaskRecord` lives here:
/// title, branch and directory come from the record, activity comes from this
/// leaf. The reducer holds one leaf per task in an
/// `IdentifiedArrayOf<TaskLeafState>`, and every leaf is `@ObservableState`, so
/// an agent tick mutates exactly one element and only that row's observation
/// invalidates — sibling rows and the cached `TasksSidebarStructure` are
/// untouched (assertion A10).
///
/// The container is deliberately *not* a `[TaskID: TaskLeafState]` dictionary:
/// TCA ships no `ObservableState` conformance for `Dictionary`, so a dictionary
/// would publish a whole-container change on every leaf tick and fan out to
/// every row view — exactly what A10 forbids. `IdentifiedArray` does conform
/// (element-wise), which is why the recompute must mutate per element and never
/// replace the container wholesale.
///
/// Deliberately *not* an input to `TasksSidebarStructure.compute`: activity
/// updates a row and can never reorder it (A4).
///
/// Population lands with the task reducer arms; this type only declares the
/// shape. Kept minimal for Phase 1 — status pills, working-elapsed
/// (`workingSince`) and PR projection arrive in Phase 5.
///
/// The missing `nonisolated` (unlike `TasksSidebarStructure`) is intentional:
/// this is reducer state, MainActor-isolated by the target's
/// `SWIFT_DEFAULT_ACTOR_ISOLATION` exactly like `SidebarItemFeature.State`, and
/// it is never touched off the main actor.
@ObservableState
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
}

extension TaskLeafState {
  /// One hook-reported agent, as a task's child row shows it (A22).
  ///
  /// Identified by agent *kind*, not by surface: a task can own several surfaces
  /// running the same agent, and they read as one worker doing one job. That is
  /// the same collapse `AgentDashboardEntry` applies per worktree, deliberately
  /// so the Tasks panel and the Agents tab can never disagree about the same
  /// agent.
  struct ChildAgent: Equatable, Sendable, Identifiable {
    let agent: SkillAgent
    /// User-assigned name (`supacode agent rename`), `nil` for an unnamed agent.
    let name: String?
    let state: AgentDashboardState

    var id: SkillAgent { agent }

    /// The custom name wins: a renamed agent reads as the thing the user
    /// addresses over the CLI, and an unnamed one falls back to its kind rather
    /// than rendering blank.
    var displayName: String { name ?? agent.displayName }

    /// Triage rank first, so a blocked agent is never buried under an idle one,
    /// then the name the row actually shows, then the kind as a deterministic
    /// final tie-break.
    static func ordersBefore(_ lhs: Self, _ rhs: Self) -> Bool {
      if lhs.state != rhs.state { return lhs.state < rhs.state }
      switch lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) {
      case .orderedAscending: return true
      case .orderedDescending: return false
      case .orderedSame: return lhs.agent.rawValue < rhs.agent.rawValue
      }
    }
  }

  /// The task's child rows, in render order.
  ///
  /// Computed rather than stored: it is a pure function of `agentSnapshot`, so
  /// storing it would add a second copy that can disagree with the snapshot and
  /// a second thing every leaf write has to keep in sync. A row body runs this
  /// over a handful of instances.
  ///
  /// Scoped to the leaf's snapshot, which is the whole *row's* snapshot: it
  /// carries no surface id, so a task owning part of a directory inherits every
  /// agent in it. Fixing that means projecting presence per surface where the
  /// per-surface records live (`AppFeature`), not guessing here.
  var childAgents: [ChildAgent] {
    var worstByAgent: [SkillAgent: ChildAgent] = [:]
    for instance in agentSnapshot.agents {
      let state = AgentDashboardState.from(instance)
      let previous = worstByAgent[instance.agent]
      worstByAgent[instance.agent] = ChildAgent(
        agent: instance.agent,
        // First named instance wins, matching the dashboard's per-kind collapse.
        name: previous?.name ?? instance.name,
        state: min(state, previous?.state ?? state)
      )
    }
    return worstByAgent.values.sorted(by: ChildAgent.ordersBefore)
  }
}

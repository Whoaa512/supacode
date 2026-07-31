import Foundation
import IdentifiedCollections
import OrderedCollections
import SupacodeSettingsShared

/// Sidebar-facing agent state. Ordered by triage urgency: the raw value is the
/// sort rank. `done` is reserved for Phase 2 (done-until-seen) and is never
/// produced yet; `unknown` covers agents with no hook-reported activity.
enum AgentDashboardState: Int, Comparable, Sendable {
  case blocked = 0
  case working = 1
  case done = 2
  case idle = 3
  case unknown = 4

  static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

  /// `error` maps to `blocked` severity; the red styling comes from the entry's
  /// `hasError` flag, not from a separate state.
  static func from(_ activity: AgentPresenceFeature.Activity) -> Self {
    switch activity {
    case .awaitingInput, .error: .blocked
    case .busy, .compacting: .working
    case .idle: .idle
    }
  }

  var title: String {
    switch self {
    case .blocked: "Blocked"
    case .working: "Working"
    case .done: "Done"
    case .idle: "Idle"
    case .unknown: "Unknown"
    }
  }

  var systemImage: String {
    switch self {
    case .blocked: "exclamationmark.circle.fill"
    case .working: "circle.dotted"
    case .done: "checkmark.circle.fill"
    case .idle: "circle"
    case .unknown: "questionmark.circle"
    }
  }
}

/// One agent on one worktree. Every display field is resolved reducer-side so
/// the Agents-tab view body never reads `sidebarItems[id:]` (see AGENTS.md,
/// "Sidebar performance").
struct AgentDashboardEntry: Identifiable, Equatable, Sendable {
  /// Composite key: a worktree can host several agents, and the same agent on
  /// two surfaces of one worktree collapses into a single entry.
  struct EntryID: Hashable, Sendable {
    let worktreeID: SidebarItemID
    let agent: SkillAgent
  }

  let id: EntryID
  let agent: SkillAgent
  let state: AgentDashboardState
  let worktreeID: SidebarItemID
  let repositoryID: Repository.ID
  /// Worktree display name, honoring the row's custom title.
  let title: String
  /// Repository display name, honoring the repo's custom title.
  let repositoryTitle: String
  let branchName: String
  let repoTint: RepositoryColor?
  let hasError: Bool

  var subtitle: String { "\(repositoryTitle) · \(branchName)" }

  /// Triage order: state rank first, then worktree title (case-insensitive),
  /// then the agent raw value as a deterministic final tie-break.
  static func ordersBefore(_ lhs: Self, _ rhs: Self) -> Bool {
    if lhs.state != rhs.state { return lhs.state < rhs.state }
    switch lhs.title.localizedCaseInsensitiveCompare(rhs.title) {
    case .orderedAscending: return true
    case .orderedDescending: return false
    case .orderedSame: return lhs.agent.rawValue < rhs.agent.rawValue
    }
  }
}

/// Single source of truth for the Agents tab. Built by the reducer's
/// post-reduce hook (`recomputeAgentDashboardStructureIfChanged()`) and
/// Equatable-diffed before publish, exactly like `SidebarStructure`.
struct AgentDashboardStructure: Equatable, Sendable {
  var entries: [AgentDashboardEntry] = []

  static let empty = AgentDashboardStructure()
}

extension RepositoriesFeature.State {
  /// Equatable-diffs the freshly-built dashboard against the cached one so a
  /// no-op rebuild doesn't invalidate SwiftUI observation.
  mutating func recomputeAgentDashboardStructureIfChanged() {
    let new = computeAgentDashboardStructure()
    if new != agentDashboardStructure {
      agentDashboardStructure = new
    }
  }

  /// Flat cross-repo agent list. Per-leaf reads on `sidebarItems[id:]` belong
  /// here, in the reducer, never in a view body.
  func computeAgentDashboardStructure() -> AgentDashboardStructure {
    let archived = archivedWorktreeIDSet
    var entries: [AgentDashboardEntry] = []
    var repositoryTitles: [Repository.ID: String] = [:]

    for id in sidebarItems.ids {
      guard let item = sidebarItems[id: id], !item.agents.isEmpty else { continue }
      // Same exclusions the Active rail applies: a winding-down or orphaned row
      // has nothing actionable behind its agent badge.
      guard !archived.contains(id), !item.lifecycle.isTerminating, !item.isMissing else { continue }

      let repositoryTitle: String
      if let cached = repositoryTitles[item.repositoryID] {
        repositoryTitle = cached
      } else {
        repositoryTitle = Repository.sidebarDisplayName(
          custom: sidebar.sections[item.repositoryID]?.title,
          fallback: repositoryName(for: item.repositoryID) ?? item.repositoryID.rawValue
        )
        repositoryTitles[item.repositoryID] = repositoryTitle
      }
      let title = Repository.sidebarDisplayName(custom: item.customTitle, fallback: item.name)

      // The same agent can run on two surfaces of one worktree. Collapse to one
      // row carrying the most urgent state so the List keeps unique ids.
      var worstByAgent: [SkillAgent: (state: AgentDashboardState, hasError: Bool)] = [:]
      for instance in item.agents {
        let state = AgentDashboardState.from(instance.activity)
        let previous = worstByAgent[instance.agent]
        worstByAgent[instance.agent] = (
          state: min(state, previous?.state ?? state),
          hasError: (previous?.hasError ?? false) || instance.activity == .error
        )
      }

      for (agent, worst) in worstByAgent {
        entries.append(
          AgentDashboardEntry(
            id: AgentDashboardEntry.EntryID(worktreeID: id, agent: agent),
            agent: agent,
            state: worst.state,
            worktreeID: id,
            repositoryID: item.repositoryID,
            title: title,
            repositoryTitle: repositoryTitle,
            branchName: item.branchName,
            repoTint: item.customTint ?? item.repositoryAccent,
            hasError: worst.hasError
          )
        )
      }
    }

    return AgentDashboardStructure(entries: entries.sorted(by: AgentDashboardEntry.ordersBefore))
  }
}

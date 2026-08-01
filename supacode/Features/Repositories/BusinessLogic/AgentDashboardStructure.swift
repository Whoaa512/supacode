import ComposableArchitecture
import Foundation
import IdentifiedCollections
import OrderedCollections
import SupacodeSettingsShared

/// Sidebar-facing agent state. Ordered by triage urgency: the raw value is the
/// sort rank. `done` is an idle agent whose last turn finished while its surface
/// was unfocused; `unknown` covers agents with no hook-reported activity.
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

  /// Same mapping, promoting a finished-but-unseen turn to `done`.
  static func from(_ instance: AgentPresenceFeature.AgentInstance) -> Self {
    let state = from(instance.activity)
    guard state == .idle, instance.isDoneUnseen else { return state }
    return .done
  }

  /// State order used by the grouped Agents panel and the Spaces rollup.
  static let triageOrder: [Self] = [.blocked, .working, .done, .idle, .unknown]

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
  /// One section of the grouped projection. Only non-empty states get a section.
  struct Section: Identifiable, Equatable, Sendable {
    let state: AgentDashboardState
    let entries: [AgentDashboardEntry]

    var id: AgentDashboardState { state }
    var title: String { state.title }
    var count: Int { entries.count }
  }

  /// One repository in the Spaces panel, with its agents rolled up to the worst
  /// state across every worktree it owns.
  struct SpaceEntry: Identifiable, Equatable, Sendable {
    let id: Repository.ID
    let title: String
    let tint: RepositoryColor?
    let worktreeCount: Int
    /// `nil` when the repository hosts no tracked agent, so the row shows no icon.
    let state: AgentDashboardState?
  }

  var entries: [AgentDashboardEntry] = []
  /// Grouped projection, empty when the group-by-state toggle is off (or when
  /// there is nothing to group). The view treats "empty" as "render flat".
  var sections: [Section] = []
  var spaces: [SpaceEntry] = []

  static let empty = AgentDashboardStructure()

  /// Groups already-sorted entries into triage-ordered sections, omitting empty ones.
  static func sections(from entries: [AgentDashboardEntry]) -> [Section] {
    let byState = Dictionary(grouping: entries, by: \.state)
    return AgentDashboardState.triageOrder.compactMap { state in
      guard let entries = byState[state], !entries.isEmpty else { return nil }
      return Section(state: state, entries: entries)
    }
  }
}

extension RepositoriesFeature.State {
  /// Equatable-diffs the freshly-built dashboard against the cached one so a
  /// no-op rebuild doesn't invalidate SwiftUI observation.
  mutating func recomputeAgentDashboardStructureIfChanged() {
    @Shared(.sidebarAgentsGroupByState) var groupByState
    let new = computeAgentDashboardStructure(groupByState: groupByState)
    if new != agentDashboardStructure {
      agentDashboardStructure = new
    }
  }

  /// Flat cross-repo agent list. Per-leaf reads on `sidebarItems[id:]` belong
  /// here, in the reducer, never in a view body.
  func computeAgentDashboardStructure(groupByState: Bool = false) -> AgentDashboardStructure {
    let archived = archivedWorktreeIDSet
    var entries: [AgentDashboardEntry] = []
    var repositoryTitles: [Repository.ID: String] = [:]
    var worktreeCounts: [Repository.ID: Int] = [:]
    var worstStateByRepository: [Repository.ID: AgentDashboardState] = [:]

    for id in sidebarItems.ids {
      guard let item = sidebarItems[id: id] else { continue }
      // Same exclusions the Active rail applies: a winding-down or orphaned row
      // has nothing actionable behind its agent badge.
      guard !archived.contains(id), !item.lifecycle.isTerminating, !item.isMissing else { continue }
      worktreeCounts[item.repositoryID, default: 0] += 1
      guard !item.agents.isEmpty else { continue }

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
        let state = AgentDashboardState.from(instance)
        let previous = worstByAgent[instance.agent]
        worstByAgent[instance.agent] = (
          state: min(state, previous?.state ?? state),
          hasError: (previous?.hasError ?? false) || instance.activity == .error
        )
      }

      for (agent, worst) in worstByAgent {
        worstStateByRepository[item.repositoryID] = min(
          worst.state, worstStateByRepository[item.repositoryID] ?? worst.state)
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

    let sorted = entries.sorted(by: AgentDashboardEntry.ordersBefore)
    return AgentDashboardStructure(
      entries: sorted,
      sections: groupByState ? AgentDashboardStructure.sections(from: sorted) : [],
      spaces: orderedRepositoryIDs().map { repositoryID in
        AgentDashboardStructure.SpaceEntry(
          id: repositoryID,
          title: repositoryTitles[repositoryID]
            ?? Repository.sidebarDisplayName(
              custom: sidebar.sections[repositoryID]?.title,
              fallback: repositoryName(for: repositoryID) ?? repositoryID.rawValue
            ),
          tint: sidebar.sections[repositoryID]?.color,
          worktreeCount: worktreeCounts[repositoryID] ?? 0,
          state: worstStateByRepository[repositoryID]
        )
      }
    )
  }
}

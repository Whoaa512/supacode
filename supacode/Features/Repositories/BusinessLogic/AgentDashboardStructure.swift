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

  /// Tooltip copy for the state glyph, which is otherwise an unlabeled icon.
  var help: String {
    switch self {
    case .blocked: "Blocked — waiting on you to answer a prompt or clear an error"
    case .working: "Working — the agent is running a turn right now"
    case .done: "Done — the agent finished a turn you haven't looked at yet"
    case .idle: "Idle — the agent is running but has nothing in flight"
    case .unknown: "Unknown — no activity reported for this agent yet"
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

/// One resolved token of a configurable Agents-tab row. `kind` carries the
/// styling role so the view stays a dumb renderer; `.stateIcon` has no text and
/// draws the entry's state glyph.
struct AgentRowSegment: Equatable, Sendable {
  enum Kind: Equatable, Sendable {
    case stateIcon
    /// The agent's name-or-kind: the row's headline.
    case agent
    case agentKind
    case repo
    case branch
    case worktree
    case stateText
    case metadata
  }

  let kind: Kind
  let text: String

  static let stateIcon = AgentRowSegment(kind: .stateIcon, text: "")
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
  /// User-assigned name (`supacode agent rename`). `nil` for an unnamed agent.
  let name: String?
  /// Display-only metadata tokens. They never participate in `state` or the
  /// Spaces rollup; `$<key>` row tokens resolve against them.
  let metadata: [String: String]
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
  /// Resolved custom row layout, or empty when the config is the default — in
  /// which case the view renders its built-in title/subtitle/caption layout.
  var rowLines: [[AgentRowSegment]] = []

  /// The agent's `summary` metadata token, rendered as a caption by the built-in
  /// layout.
  var summary: String? { metadata[AgentPresenceFeature.summaryToken] }

  /// Primary row text: the custom name wins, so a renamed agent reads as the
  /// thing the user addresses over the CLI.
  var displayName: String { name ?? agent.displayName }

  /// A named row loses the agent kind from its title, so the subtitle carries it.
  var subtitle: String {
    let base = "\(repositoryTitle) · \(branchName)"
    guard name != nil else { return base }
    return "\(base) · \(agent.displayName)"
  }

  /// Triage order: state rank first, then worktree title (case-insensitive),
  /// then the agent raw value as a deterministic final tie-break.
  /// Resolves one configured line, dropping segments whose text came back empty
  /// (an unreported `$token`) so a fully-empty line can be dropped by the caller.
  func resolvedLine(_ tokens: [String]) -> [AgentRowSegment] {
    tokens.compactMap { raw in
      if let key = AgentRowToken.metadataKey(of: raw) {
        guard let value = metadata[key], !value.isEmpty else { return nil }
        return AgentRowSegment(kind: .metadata, text: value)
      }
      guard let token = AgentRowToken(rawValue: raw) else { return nil }
      return switch token {
      case .stateIcon: .stateIcon
      case .agent: AgentRowSegment(kind: .agent, text: displayName)
      case .agentKind: AgentRowSegment(kind: .agentKind, text: agent.displayName)
      case .repo: AgentRowSegment(kind: .repo, text: repositoryTitle)
      case .branch: AgentRowSegment(kind: .branch, text: branchName)
      case .worktree: AgentRowSegment(kind: .worktree, text: title)
      case .stateText: AgentRowSegment(kind: .stateText, text: state.title)
      }
    }
  }

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

/// The worst state across every surface running one agent kind in one worktree,
/// which is what a single dashboard row reports.
private struct AgentRollup {
  let state: AgentDashboardState
  let hasError: Bool
  let name: String?
  let metadata: [String: String]
}

extension RepositoriesFeature.State {
  /// Equatable-diffs the freshly-built dashboard against the cached one so a
  /// no-op rebuild doesn't invalidate SwiftUI observation.
  mutating func recomputeAgentDashboardStructureIfChanged() {
    @Shared(.sidebarAgentsGroupByState) var groupByState
    let new = computeAgentDashboardStructure(groupByState: groupByState, rowConfig: agentsSidebar)
    if new != agentDashboardStructure {
      agentDashboardStructure = new
    }
  }

  /// Flat cross-repo agent list. Per-leaf reads on `sidebarItems[id:]` belong
  /// here, in the reducer, never in a view body.
  func computeAgentDashboardStructure(
    groupByState: Bool = false,
    rowConfig: AgentsSidebarSettings = .default
  ) -> AgentDashboardStructure {
    let archived = archivedWorktreeIDSet
    var entries: [AgentDashboardEntry] = []
    var repositoryTitles: [Repository.ID: String] = [:]
    var worstStateByRepository: [Repository.ID: AgentDashboardState] = [:]

    for id in sidebarItems.ids {
      guard let item = sidebarItems[id: id] else { continue }
      // Same exclusions the Active rail applies: a winding-down or orphaned row
      // has nothing actionable behind its agent badge.
      guard !archived.contains(id), !item.lifecycle.isTerminating, !item.isMissing else { continue }
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
      var worstByAgent: [SkillAgent: AgentRollup] = [:]
      for instance in item.agents {
        let state = AgentDashboardState.from(instance)
        let previous = worstByAgent[instance.agent]
        worstByAgent[instance.agent] = AgentRollup(
          state: min(state, previous?.state ?? state),
          hasError: (previous?.hasError ?? false) || instance.activity == .error,
          // First named instance wins; the collapse is per (worktree, agent), so
          // two surfaces of the same kind share one row and one name.
          name: previous?.name ?? instance.name,
          metadata: (previous?.metadata).flatMap { $0.isEmpty ? nil : $0 } ?? instance.metadata
        )
      }

      for (agent, worst) in worstByAgent {
        worstStateByRepository[item.repositoryID] = min(
          worst.state, worstStateByRepository[item.repositoryID] ?? worst.state)
        var entry = AgentDashboardEntry(
          id: AgentDashboardEntry.EntryID(worktreeID: id, agent: agent),
          agent: agent,
          name: worst.name,
          metadata: worst.metadata,
          state: worst.state,
          worktreeID: id,
          repositoryID: item.repositoryID,
          title: title,
          repositoryTitle: repositoryTitle,
          branchName: item.branchName,
          repoTint: item.customTint ?? item.repositoryAccent,
          hasError: worst.hasError
        )
        // Only a customized config resolves segments; the default config leaves
        // `rowLines` empty so the view keeps its built-in layout verbatim.
        if let lines = rowConfig.rows(forAgentKind: agent.rawValue) {
          entry.rowLines = lines.map(entry.resolvedLine).filter { !$0.isEmpty }
        }
        entries.append(entry)
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
          // Counted from the repository model, not per-row lifecycle: a
          // transient archiving/deleting flip must not churn the cached
          // structure in flows that don't touch the dashboard (see
          // RepositoriesFeatureTests archive/delete script coverage).
          worktreeCount: repositories[id: repositoryID]?.worktrees
            .count { !$0.isMissing && !archived.contains($0.id) } ?? 0,
          state: worstStateByRepository[repositoryID]
        )
      }
    )
  }
}

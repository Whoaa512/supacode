import Foundation
import IdentifiedCollections
import OrderedCollections
import SupacodeSettingsShared

/// Builds the `supacode agent list` / `agent wait` payload: one row per live
/// (surface, agent) presence record, joined to its worktree's sidebar row.
enum AgentQueryResponse {
  /// Socket wire keys. `AgentCommand` reads the same literals; keep both sides
  /// in sync (the CLI stays dependency-light, so no shared module).
  enum Key {
    static let name = "name"
    static let agent = "agent"
    static let activity = "activity"
    static let state = "state"
    static let worktreeID = "worktreeID"
    static let branch = "branch"
    static let repo = "repo"
    static let worktreeTitle = "worktreeTitle"
    /// Metadata tokens are flattened as `token.<key>` so the whole payload stays
    /// a flat `[String: String]` (the socket wire format) with no nested JSON to
    /// parse on the CLI side.
    static let tokenPrefix = "token."
  }

  /// Sorted by triage state, then worktree title, then agent kind, so repeated
  /// polls (`agent wait`) see a stable row order.
  static func rows(
    presence: AgentPresenceFeature.State,
    repositories: RepositoriesFeature.State
  ) -> [[String: String]] {
    var rows: [Row] = []
    for (key, record) in presence.records {
      guard let worktreeID = repositories.surfaceToItemID[key.surfaceID],
        let item = repositories.sidebarItems[id: worktreeID]
      else { continue }
      let state = AgentDashboardState.from(
        AgentPresenceFeature.AgentInstance(
          agent: key.agent, activity: record.activity, isDoneUnseen: record.isDoneUnseen)
      )
      let title = Repository.sidebarDisplayName(custom: item.customTitle, fallback: item.name)
      let repoTitle = Repository.sidebarDisplayName(
        custom: repositories.sidebar.sections[item.repositoryID]?.title,
        fallback: repositories.repositoryName(for: item.repositoryID) ?? item.repositoryID.rawValue
      )
      rows.append(
        Row(
          state: state,
          title: title,
          agent: key.agent.rawValue,
          fields: [
            Key.name: presence.nameByKey[key] ?? "",
            Key.agent: key.agent.rawValue,
            Key.activity: record.activity.rawValue,
            Key.state: state.wireValue,
            Key.worktreeID: percentEncodedID(worktreeID.rawValue),
            Key.branch: item.branchName,
            Key.repo: repoTitle,
            Key.worktreeTitle: title,
          ].merging(
            (presence.metadataByKey[key] ?? [:]).map { ("\(Key.tokenPrefix)\($0.key)", $0.value) },
            uniquingKeysWith: { _, token in token }
          )
        )
      )
    }
    return rows
      .sorted { lhs, rhs in
        if lhs.state != rhs.state { return lhs.state < rhs.state }
        switch lhs.title.localizedCaseInsensitiveCompare(rhs.title) {
        case .orderedAscending: return true
        case .orderedDescending: return false
        case .orderedSame: return lhs.agent < rhs.agent
        }
      }
      .map(\.fields)
  }

  /// One sorted row: the sort keys, plus the wire fields they order.
  private struct Row {
    let state: AgentDashboardState
    let title: String
    let agent: String
    let fields: [String: String]
  }

  /// Mirrors `AppFeature.percentEncodedID`: a returned id must round-trip as a
  /// `-w` argument, so encoded slashes stay encoded.
  private static func percentEncodedID(_ rawValue: String) -> String {
    let allowed = CharacterSet.urlPathAllowed.subtracting(.init(charactersIn: "/"))
    return rawValue.addingPercentEncoding(withAllowedCharacters: allowed) ?? rawValue
  }
}

extension AgentDashboardState {
  /// Stable CLI spelling. Distinct from `title` so renaming a section header
  /// can't silently break `agent wait --until`.
  var wireValue: String {
    switch self {
    case .blocked: "blocked"
    case .working: "working"
    case .done: "done"
    case .idle: "idle"
    case .unknown: "unknown"
    }
  }
}

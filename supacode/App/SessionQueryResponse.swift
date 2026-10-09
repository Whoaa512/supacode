import Foundation
import IdentifiedCollections

enum SessionQueryResponse {
  enum Key {
    static let id = "id"
    static let title = "title"
    static let cwd = "cwd"
    static let lifecycle = "lifecycle"
    static let live = "live"
    static let status = "status"
    static let branch = "branch"
    static let surfaceID = "surfaceID"
    static let all = [id, title, cwd, lifecycle, live, status, branch, surfaceID]
  }

  /// One entry per session, in sidebar order. A task's row only places its
  /// sessions, primary first: each answers with its own title, directory,
  /// mark and agent, never the task's.
  static func rows(repositories: RepositoriesFeature.State) -> [[String: String]] {
    let sidecar = repositories.sessions
    var summaries: [SessionKey: SessionSummary] = [:]
    for summary in repositories.sessionSummaries where summaries[summary.id] == nil {
      summaries[summary.id] = summary
    }
    var agentKeysByTask: [LayoutID: [SessionKey]] = [:]
    var agentByTaskAndKey: [LayoutID: [SessionKey: SessionLiveSnapshot]] = [:]
    var agentByKey: [SessionKey: SessionLiveSnapshot] = [:]
    let agents = repositories.sessionSnapshots.sorted {
      $0.location.surfaceID.uuidString < $1.location.surfaceID.uuidString
    }
    for agent in agents {
      guard let key = agent.sessionKey else { continue }
      let layoutID = agent.location.layoutID
      if agentByTaskAndKey[layoutID]?[key] == nil {
        agentByTaskAndKey[layoutID, default: [:]][key] = agent
        agentKeysByTask[layoutID, default: []].append(key)
      }
      if agentByKey[key] == nil { agentByKey[key] = agent }
    }
    var listed: Set<SessionKey> = []
    var entries: [[String: String]] = []
    for id in repositories.sessionsSidebarStructure.allIDs {
      guard let item = repositories.sessionItems[id: id] else { continue }
      guard case .task(let layoutID) = id else {
        guard let key = item.sessionKey, listed.insert(key).inserted else { continue }
        entries.append([
          Key.id: key.rawValue,
          Key.title: item.title,
          Key.cwd: item.cwd,
          Key.lifecycle: item.lifecycle == .active ? "active" : "settled",
          Key.live: item.isLive ? "1" : "",
          Key.status: item.status?.rawValue ?? "",
          Key.branch: item.branchAnnotation ?? sidecar[key]?.branches.last ?? "",
          Key.surfaceID: item.location?.surfaceID.uuidString ?? "",
        ])
        continue
      }
      // The sessions the task lists, then any reported agent on one of its
      // surfaces the list has not caught up with.
      let here = agentByTaskAndKey[layoutID] ?? [:]
      for key in (repositories.taskSessions[layoutID] ?? []) + (agentKeysByTask[layoutID] ?? [])
      where !listed.contains(key) {
        let agent = here[key] ?? agentByKey[key]
        let summary = summaries[key]
        // One that is neither running nor on disk cannot be resumed or shown,
        // but for the session a placeholder row is still waiting on.
        let isPlaceholder = item.isSynthetic && key == item.primary
        guard agent != nil || summary != nil || isPlaceholder else { continue }
        listed.insert(key)
        entries.append([
          Key.id: key.rawValue,
          Key.title: summary?.title ?? "New session",
          Key.cwd: summary?.cwd ?? agent?.cwd ?? item.cwd,
          Key.lifecycle: sidecar[key]?.settledAt == nil ? "active" : "settled",
          Key.live: agent == nil ? "" : "1",
          Key.status: agent?.status.rawValue ?? "",
          Key.branch: sidecar[key]?.branches.last ?? "",
          Key.surfaceID: agent?.location.surfaceID.uuidString ?? "",
        ])
      }
    }
    return entries
  }
}

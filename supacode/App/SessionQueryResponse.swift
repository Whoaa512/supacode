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

  /// One entry per session, in sidebar order. A task's row answers for its
  /// primary; its other sessions follow it, since they have no row of their own.
  static func rows(repositories: RepositoriesFeature.State) -> [[String: String]] {
    let sidecar = repositories.sessions
    var listed: Set<SessionKey> = []
    var entries: [[String: String]] = []
    var tangents: [(index: Int, key: SessionKey)] = []
    for id in repositories.sessionsSidebarStructure.allIDs {
      guard let item = repositories.sessionItems[id: id], let key = item.sessionKey, listed.insert(key).inserted
      else { continue }
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
      guard case .task(let layoutID) = id else { continue }
      for member in repositories.taskSessions[layoutID] ?? [] where member != key {
        tangents.append((entries.count, member))
      }
    }
    guard !tangents.isEmpty else { return entries }
    let wanted = Set(tangents.map(\.key))
    var summaries: [SessionKey: SessionSummary] = [:]
    for summary in repositories.sessionSummaries where wanted.contains(summary.id) && summaries[summary.id] == nil {
      summaries[summary.id] = summary
    }
    // Back to front, so an earlier insertion does not shift a later one.
    for tangent in tangents.reversed() where !listed.contains(tangent.key) {
      let key = tangent.key
      let agent = repositories.sessionSnapshots.first { $0.sessionKey == key }
      // One that is neither running nor on disk cannot be resumed or shown.
      guard agent != nil || summaries[key] != nil else { continue }
      listed.insert(key)
      entries.insert(
        [
          Key.id: key.rawValue,
          Key.title: summaries[key]?.title ?? "New session",
          Key.cwd: summaries[key]?.cwd ?? agent?.cwd ?? "",
          Key.lifecycle: sidecar[key]?.settledAt == nil ? "active" : "settled",
          Key.live: agent == nil ? "" : "1",
          Key.status: agent?.status.rawValue ?? "",
          Key.branch: sidecar[key]?.branches.last ?? "",
          Key.surfaceID: agent?.location.surfaceID.uuidString ?? "",
        ], at: tangent.index)
    }
    return entries
  }
}
